import Foundation
import MultipeerConnectivity
import BarrageCore

/// A Mac running Offline Barrage that we can currently see.
public struct DiscoveredPeer: Hashable {
    public let peerID: MCPeerID
    public let playerID: String
    public let name: String
    public let protocolVersion: Int
    public let foundAt: Date
}

public enum PeerLinkState {
    case connecting
    case connected
    case disconnected
}

public protocol PeerServiceDelegate: AnyObject {
    func peerService(_ service: PeerService, didUpdateNearby peers: [DiscoveredPeer])
    /// Call `reply` exactly once (extra calls are ignored).
    func peerService(_ service: PeerService, didReceiveInvitation context: Data?, from peerID: MCPeerID, reply: @escaping (Bool) -> Void)
    func peerService(_ service: PeerService, linkDidChange state: PeerLinkState, peer: MCPeerID)
    func peerService(_ service: PeerService, didReceive data: Data, from peerID: MCPeerID)
}

/// Discovery and a single 1:1 link over MultipeerConnectivity.
///
/// On macOS, MultipeerConnectivity runs over peer-to-peer Wi-Fi (AWDL, the same link AirDrop
/// uses) as well as any shared network, so two Macs can play with Wi-Fi switched on but not
/// joined to any network, e.g. in airplane mode.
///
/// All delegate callbacks are delivered on the main queue.
public final class PeerService: NSObject {
    public static let serviceType = "offline-barrage"  // Bonjour: _offline-barrage._tcp / _udp (see Info.plist)

    public weak var delegate: PeerServiceDelegate?

    private let playerID: String
    private let defaults: UserDefaults
    public private(set) var myPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var discovered: [MCPeerID: DiscoveredPeer] = [:]

    /// The one session we care about (pending invitation or live game link).
    private var session: MCSession?
    private var sessionPeer: MCPeerID?

    /// `defaults` stores the archived MCPeerID (use a separate suite per test profile).
    public init(displayName: String, playerID: String, defaults: UserDefaults = .standard) {
        self.playerID = playerID
        self.defaults = defaults
        self.myPeerID = PeerService.makePeerID(displayName: displayName, defaults: defaults)
        super.init()
    }

    // MARK: - Identity

    /// Reuses the archived MCPeerID when the name is unchanged, as Apple recommends,
    /// so other Macs don't see duplicate "ghost" peers after a relaunch.
    private static func makePeerID(displayName: String, defaults: UserDefaults) -> MCPeerID {
        let name = sanitize(displayName)
        if let data = defaults.data(forKey: "mcPeerID"),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           saved.displayName == name {
            return saved
        }
        let peerID = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: peerID, requiringSecureCoding: true) {
            defaults.set(data, forKey: "mcPeerID")
        }
        return peerID
    }

    /// MCPeerID display names must be non-empty and at most 63 bytes of UTF-8.
    public static func sanitize(_ name: String) -> String {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = "Player" }
        while clean.utf8.count > 63 { clean.removeLast() }
        return clean
    }

    // MARK: - Discovery

    public func start() {
        stopDiscovery()
        let info = ["pid": playerID, "v": String(Wire.protocolVersion)]
        let advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: info, serviceType: PeerService.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: PeerService.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    public func stopDiscovery() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        discovered.removeAll()
        publishNearby()
    }

    /// Changes the advertised name. Drops any link.
    public func restart(displayName: String) {
        disconnect()
        myPeerID = PeerService.makePeerID(displayName: displayName, defaults: defaults)
        start()
    }

    private func publishNearby() {
        var byPlayer: [String: DiscoveredPeer] = [:]
        for peer in discovered.values {
            if let existing = byPlayer[peer.playerID], existing.foundAt > peer.foundAt { continue }
            byPlayer[peer.playerID] = peer
        }
        delegate?.peerService(self, didUpdateNearby: Array(byPlayer.values))
    }

    // MARK: - Link

    public func invite(_ peer: MCPeerID, context: Data, timeout: TimeInterval) {
        guard let browser = browser else { return }
        let session = makeSession(with: peer)
        browser.invitePeer(peer, to: session, withContext: context, timeout: timeout)
    }

    private func makeSession(with peer: MCPeerID) -> MCSession {
        disconnect()
        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        self.sessionPeer = peer
        return session
    }

    public var isConnected: Bool {
        guard let session = session, let peer = sessionPeer else { return false }
        return session.connectedPeers.contains(peer)
    }

    @discardableResult
    public func send(_ data: Data) -> Bool {
        guard let session = session, let peer = sessionPeer, session.connectedPeers.contains(peer) else { return false }
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
            return true
        } catch {
            NSLog("Offline Barrage: send failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Forgets the current link immediately (no further callbacks for it). The actual
    /// disconnect can be delayed so a final message (e.g. "leaving") gets flushed first.
    public func disconnect(after delay: TimeInterval = 0) {
        guard let session = session else { return }
        self.session = nil
        self.sessionPeer = nil
        session.delegate = nil
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { session.disconnect() }
        } else {
            session.disconnect()
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerService: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, advertiser === self.advertiser, let delegate = self.delegate else {
                invitationHandler(false, nil)
                return
            }
            var answered = false
            let reply: (Bool) -> Void = { [weak self] accept in
                guard !answered else { return }
                answered = true
                if accept, let self = self {
                    invitationHandler(true, self.makeSession(with: peerID))
                } else {
                    invitationHandler(false, nil)
                }
            }
            delegate.peerService(self, didReceiveInvitation: context, from: peerID, reply: reply)
        }
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("Offline Barrage: could not advertise: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerService: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, browser === self.browser,
                  let pid = info?["pid"], pid != self.playerID
            else { return }
            let version = Int(info?["v"] ?? "") ?? 0
            self.discovered[peerID] = DiscoveredPeer(peerID: peerID, playerID: pid, name: peerID.displayName,
                                                     protocolVersion: version, foundAt: Date())
            self.publishNearby()
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, browser === self.browser else { return }
            self.discovered[peerID] = nil
            self.publishNearby()
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("Offline Barrage: could not browse: \(error.localizedDescription)")
    }
}

// MARK: - MCSessionDelegate

extension PeerService: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, session === self.session, peerID == self.sessionPeer else { return }
            let mapped: PeerLinkState
            switch state {
            case .connecting: mapped = .connecting
            case .connected: mapped = .connected
            case .notConnected: mapped = .disconnected
            @unknown default: mapped = .disconnected
            }
            if mapped == .disconnected {
                self.session?.delegate = nil
                self.session = nil
                self.sessionPeer = nil
            }
            self.delegate?.peerService(self, linkDidChange: mapped, peer: peerID)
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, session === self.session, peerID == self.sessionPeer else { return }
            self.delegate?.peerService(self, didReceive: data, from: peerID)
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}

    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    public func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?,
                 fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}
