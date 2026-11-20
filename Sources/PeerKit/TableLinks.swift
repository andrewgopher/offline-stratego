import Foundation
import MultipeerConnectivity
import BarrageCore

public protocol TableLinksDelegate: AnyObject {
    func tableLinks(_ links: TableLinks, memberDidConnect memberID: String)
    func tableLinks(_ links: TableLinks, memberDidDisconnect memberID: String)
    func tableLinks(_ links: TableLinks, didReceive data: Data, from memberID: String)
}

/// The links of one 2v2 table: a direct, encrypted link from this device to each of the other
/// three players, so a message for one player (say, ranks for the partner) goes to that player only.
///
/// Missing links are re-established automatically: for each pair, the player with the lower ID
/// invites right away and the other only after a few seconds, so invitations rarely cross (and
/// when they do, the lower ID's invitation wins).
///
/// `PeerService` has a single delegate (the app), which hands this object the callbacks that
/// concern the table. Everything runs on the main queue.
public final class TableLinks {
    public enum LinkState: Hashable {
        case disconnected
        case connecting
        case connected
    }

    public weak var delegate: TableLinksDelegate?

    public let gameID: UUID
    public let me: PlayerInfo
    /// The other three players.
    public let members: [PlayerInfo]
    /// Members to keep inviting when their link is down (e.g. the host only joins guests that
    /// have accepted the challenge). Defaults to all.
    public var shouldAutoJoin: (String) -> Bool = { _ in true }

    public private(set) var states: [String: LinkState] = [:]
    public private(set) var everConnected: Set<String> = []

    private let service: PeerService
    private var peerOf: [String: MCPeerID] = [:]
    private var memberOf: [MCPeerID: String] = [:]
    private var invitedAt: [String: Date] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var downSince: [String: Date] = [:]
    private var isClosed = false

    static let retryInterval: TimeInterval = 6
    static let higherIDGrace: TimeInterval = 4
    /// Long enough for a player in the lobby to answer a resume request.
    public static let joinTimeout: TimeInterval = 30

    public init(service: PeerService, gameID: UUID, me: PlayerInfo, members: [PlayerInfo], now: Date = Date()) {
        self.service = service
        self.gameID = gameID
        self.me = me
        self.members = members.filter { $0.id != me.id }
        for member in self.members {
            states[member.id] = .disconnected
            downSince[member.id] = now
        }
    }

    public func isMember(_ id: String) -> Bool { members.contains { $0.id == id } }
    public func isConnected(_ id: String) -> Bool { states[id] == .connected }
    public var allConnected: Bool { members.allSatisfy { isConnected($0.id) } }
    public var connectedCount: Int { members.filter { isConnected($0.id) }.count }

    public func handles(_ peer: MCPeerID) -> Bool { memberOf[peer] != nil }

    // MARK: - Inviting

    /// Invites a member with a custom context (the host's challenge, for instance).
    public func invite(_ memberID: String, peer: MCPeerID, context: Data, timeout: TimeInterval, now: Date = Date()) {
        guard !isClosed, isMember(memberID) else { return }
        register(peer, for: memberID)
        states[memberID] = .connecting
        invitedAt[memberID] = now
        lastAttempt[memberID] = now
        service.invite(peer, context: context, timeout: timeout, alongside: true)
    }

    /// Answers a `.teamJoin` invitation for this table from a member.
    public func answerJoin(from memberID: String, peer: MCPeerID, now: Date = Date(),
                           reply: @escaping (InvitationAnswer) -> Void) {
        guard !isClosed, isMember(memberID) else {
            reply(.decline)
            return
        }
        // Invitations crossed: the lower player ID's invitation wins.
        if states[memberID] == .connecting, me.id < memberID, peerOf[memberID] == peer {
            reply(.decline)
            return
        }
        expectLink(from: memberID, peer: peer, now: now)
        reply(.acceptAlongside)
    }

    /// Call right before accepting an invitation from a member (e.g. the host's challenge).
    public func expectLink(from memberID: String, peer: MCPeerID, now: Date = Date()) {
        guard isMember(memberID) else { return }
        register(peer, for: memberID)
        states[memberID] = .connecting
        invitedAt[memberID] = now
    }

    private func register(_ peer: MCPeerID, for memberID: String) {
        if let old = peerOf[memberID], old != peer { memberOf[old] = nil }
        peerOf[memberID] = peer
        memberOf[peer] = memberID
    }

    /// Re-invites members whose link is down. `nearby` maps the player IDs of compatible nearby
    /// Macs to their peers. Call about once a second.
    public func tick(now: Date, nearby: [String: MCPeerID]) {
        guard !isClosed else { return }
        for member in members {
            let id = member.id
            if states[id] == .connecting, let since = invitedAt[id], now.timeIntervalSince(since) > TableLinks.joinTimeout + 10 {
                // Safety net in case MultipeerConnectivity never reports the outcome.
                states[id] = .disconnected
                downSince[id] = now
            }
            guard states[id] == .disconnected, shouldAutoJoin(id), let peer = nearby[id] else { continue }
            if let last = lastAttempt[id], now.timeIntervalSince(last) < TableLinks.retryInterval { continue }
            if me.id > id, let since = downSince[id], now.timeIntervalSince(since) < TableLinks.higherIDGrace { continue }
            guard let context = try? Wire.encode(InvitationEnvelope(.teamJoin(gameID: gameID, player: me))) else { continue }
            invite(id, peer: peer, context: context, timeout: TableLinks.joinTimeout, now: now)
        }
    }

    // MARK: - Traffic

    /// Returns false if `peer` isn't one of this table's links.
    @discardableResult
    public func linkDidChange(_ state: PeerLinkState, peer: MCPeerID, now: Date = Date()) -> Bool {
        guard let id = memberOf[peer], peerOf[id] == peer else { return false }
        switch state {
        case .connecting:
            break
        case .connected:
            states[id] = .connected
            everConnected.insert(id)
            invitedAt[id] = nil
            delegate?.tableLinks(self, memberDidConnect: id)
        case .disconnected:
            let wasConnected = states[id] == .connected
            states[id] = .disconnected
            downSince[id] = now
            invitedAt[id] = nil
            if wasConnected {
                lastAttempt[id] = nil  // try again soon
            }
            delegate?.tableLinks(self, memberDidDisconnect: id)
        }
        return true
    }

    @discardableResult
    public func didReceive(_ data: Data, from peer: MCPeerID) -> Bool {
        guard let id = memberOf[peer], peerOf[id] == peer else { return false }
        delegate?.tableLinks(self, didReceive: data, from: id)
        return true
    }

    @discardableResult
    public func send(_ data: Data, to memberID: String) -> Bool {
        guard isConnected(memberID), let peer = peerOf[memberID] else { return false }
        return service.send(data, to: peer)
    }

    public func sendToAll(_ data: Data) {
        for member in members { send(data, to: member.id) }
    }

    /// Drops one member's link (e.g. a declined invitation).
    public func drop(_ memberID: String) {
        guard let peer = peerOf[memberID] else { return }
        service.disconnect(peer: peer)
        states[memberID] = .disconnected
    }

    /// Drops every link for now without closing the table (the app is going to the background);
    /// `tick` re-establishes them once the other players are nearby again.
    public func suspend(now: Date = Date()) {
        guard !isClosed else { return }
        for member in members {
            if let peer = peerOf[member.id] { service.disconnect(peer: peer) }
            states[member.id] = .disconnected
            downSince[member.id] = now
            invitedAt[member.id] = nil
            lastAttempt[member.id] = nil
        }
    }

    /// Drops every link of the table, optionally after a delay so final messages get out.
    public func close(after delay: TimeInterval = 0) {
        isClosed = true
        for peer in peerOf.values { service.disconnect(peer: peer, after: delay) }
        for member in members { states[member.id] = .disconnected }
    }
}
