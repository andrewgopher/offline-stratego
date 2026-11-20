// Headless end-to-end check of PeerKit + the match protocols.
//
// 1v1: run two copies on the same Mac (or one on each of two Macs):
//     PeerSmokeTest guest &
//     PeerSmokeTest host
// They discover each other with the same PeerService the app uses. The host (Red) sends a
// challenge, the guest (Blue) accepts, both lock in fixed setups, and they play a short game
// with a scout run, a lost battle and a flag capture over the real link. Both sides then
// reveal their armies and check them. Exit status 0 means the transport and protocol worked.
//
// 2v2: run four copies, `team-b`, `team-c` and `team-d` first, then `team-a` (the host). They
// link up pairwise with TableLinks, play a short game on two boards (a capture on board 1 feeds
// a swap on board 2, then a Flag capture ends it) and check all four armies.

import BarrageCore
import Foundation
import MultipeerConnectivity
import PeerKit

setvbuf(stdout, nil, _IOLBF, 0)

let role = CommandLine.arguments.dropFirst().first ?? "host"
let isHost = role == "host" || role == "team-a"
let me = PlayerInfo(id: isHost ? "smoke-host" : "smoke-guest", name: isHost ? "Smoke Host" : "Smoke Guest")
let redArmy = setup(.red, ["A4": .scout, "J4": .scout, "A1": .marshal, "B1": .general,
                           "C1": .miner, "D1": .spy, "E1": .bomb, "F1": .flag])
let blueArmy = setup(.blue, ["B7": .marshal, "J7": .flag, "A10": .general, "C10": .miner,
                             "D10": .scout, "E10": .scout, "F10": .spy, "G10": .bomb])
let script: [String] = isHost ? ["A4-A6", "A6-B6", "J4-J7"] : ["B7-B6", "B6-B5"]

func setup(_ side: Side, _ placements: [String: Rank]) -> Setup {
    Setup(side: side, placements: Dictionary(uniqueKeysWithValues: placements.map { (Square(name: $0.key)!, $0.value) }))
}

let mySetup = isHost ? redArmy : blueArmy

func say(_ text: String) {
    print("[\(role)] \(text)")
}

final class Runner: PeerServiceDelegate {
    let service: PeerService
    var match: Match?
    var pendingChallenge: Challenge?
    var pendingOpponent: PlayerInfo?
    var invited = false
    var nextScriptIndex = 0
    var finished = false
    var exitCode: Int32?

    init() {
        let defaults = UserDefaults(suiteName: "local.offlinebarrage.smoketest.\(role)") ?? .standard
        service = PeerService(displayName: me.name, playerID: me.id, defaults: defaults)
        service.delegate = self
    }

    func start() {
        service.start()
        say("advertising and browsing as \(me.name)")
    }

    func peerService(_ service: PeerService, didUpdateNearby peers: [DiscoveredPeer]) {
        say("nearby: \(peers.map(\.name))")
        guard isHost, !invited, let guest = peers.first(where: { $0.playerID == "smoke-guest" }) else { return }
        invited = true
        let challenge = Challenge(challenger: me, challengerSide: .red,
                                  timeControl: TimeControl(initialSeconds: 300, incrementSeconds: 2))
        pendingChallenge = challenge
        pendingOpponent = PlayerInfo(id: guest.playerID, name: guest.name)
        guard let data = try? Wire.encode(InvitationEnvelope(.challenge(challenge))) else { return fail("encode") }
        say("inviting \(guest.name)")
        service.invite(guest.peerID, context: data, timeout: 30)
    }

    func peerService(_ service: PeerService, didReceiveInvitation context: Data?, from peerID: MCPeerID,
                     reply: @escaping (InvitationAnswer) -> Void) {
        guard !isHost, let context = context,
              let envelope = try? Wire.decode(InvitationEnvelope.self, from: context),
              case .challenge(let challenge) = envelope.invitation
        else {
            reply(.decline)
            return
        }
        say("accepting challenge from \(challenge.challenger.name)")
        match = Match(challenge: challenge, accepter: me, localPlayerID: me.id, now: Date())
        reply(.accept)
    }

    func peerService(_ service: PeerService, linkDidChange state: PeerLinkState, peer: MCPeerID) {
        say("link: \(state)")
        switch state {
        case .connected:
            if isHost, let challenge = pendingChallenge, let opponent = pendingOpponent {
                match = Match(challenge: challenge, accepter: opponent, localPlayerID: me.id, now: Date())
            }
            guard var current = match else { return fail("connected without a game") }
            send(.sync(current.publicSnapshot(at: Date())))
            guard let update = current.lockSetup(mySetup, at: Date()) else { return fail("could not lock setup") }
            match = current
            say("setup locked in")
            handle(update)
        case .disconnected:
            if !finished { fail("link dropped before the game finished") }
        case .connecting:
            break
        }
    }

    func peerService(_ service: PeerService, didReceive data: Data, from peerID: MCPeerID) {
        guard var current = match,
              let envelope = try? Wire.decode(WireEnvelope.self, from: data),
              envelope.gameID == current.gameID
        else { return }
        let update = current.receive(envelope.message, at: Date())
        match = current
        handle(update)
    }

    func handle(_ update: MatchUpdate) {
        for event in update.events { say("event: \(event)") }
        for message in update.outgoing { send(message) }
        checkFinished()
        playIfMyTurn()
    }

    func playIfMyTurn() {
        guard var current = match, current.isLocalTurn, nextScriptIndex < script.count else { return }
        guard let move = Move(script[nextScriptIndex]) else { return fail("bad script move") }
        nextScriptIndex += 1
        guard let update = current.playLocalMove(move, at: Date()) else { return fail("could not play \(move)") }
        match = current
        say("played \(move)")
        handle(update)
    }

    func checkFinished() {
        guard !finished, let current = match, let result = current.result, current.verification != nil else { return }
        finished = true
        let moves = current.game?.moves.map(\.description).joined(separator: " ") ?? ""
        say("game over: \(result.summary(red: current.red.name, blue: current.blue.name)). Moves: \(moves)")
        guard result == GameResult(winner: .red, reason: .flagCaptured),
              moves == "A4-A6 B7-B6 A6-B6 B6-B5 J4-J7",
              current.verification == .passed,
              current.knownRanks.count == 16
        else {
            return fail("unexpected end state: \(result), verification \(String(describing: current.verification))")
        }
        say("both armies revealed and verified")
        // Leave time for the final messages to reach the other side before quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.exitCode = 0 }
    }

    func send(_ message: GameMessage) {
        guard let current = match,
              let data = try? Wire.encode(WireEnvelope(gameID: current.gameID, message: message))
        else { return }
        if !service.send(data) { say("send failed: \(message)") }
    }

    func fail(_ reason: String) {
        say("FAIL: \(reason)")
        exitCode = 1
    }
}

if role.hasPrefix("team-") {
    runTeamSmokeTest()
}

let runner = Runner()
runner.start()
let deadline = Date().addingTimeInterval(90)
while runner.exitCode == nil && Date() < deadline {
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
}
if runner.exitCode == nil { say("FAIL: timed out") }
let code = runner.exitCode ?? 1
runner.service.disconnect()
say(code == 0 ? "PASS" : "exiting with failure")
exit(code)
