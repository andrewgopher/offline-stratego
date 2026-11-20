import BarrageCore
import Foundation
import MultipeerConnectivity
import PeerKit

/// One of four players in a scripted 2v2 game over real links (see main.swift).
private final class TeamRunner: PeerServiceDelegate, TableLinksDelegate {
    enum Step {
        case move(String)
        case swap(Rank, String)
    }

    static let players: [Seat: PlayerInfo] = [
        Seat(.one, .red): PlayerInfo(id: "smoke-a", name: "Smoke A"),
        Seat(.one, .blue): PlayerInfo(id: "smoke-b", name: "Smoke B"),
        Seat(.two, .red): PlayerInfo(id: "smoke-c", name: "Smoke C"),
        Seat(.two, .blue): PlayerInfo(id: "smoke-d", name: "Smoke D"),
    ]

    let seat: Seat
    let me: PlayerInfo
    let service: PeerService
    var match: TeamMatch?
    var links: TableLinks?
    var script: [Step]
    var discovered: [String: MCPeerID] = [:]
    var invited = false
    var locked = false
    var finished = false
    var exitCode: Int32?

    init(seat: Seat) {
        self.seat = seat
        me = TeamRunner.players[seat]!
        // Board 1: A's Scout runs into B's Marshal and is lost, so it goes to C's reserve.
        // Board 2: C waits for that Scout, swaps it in for the Marshal, then takes D's Flag.
        switch (seat.board, seat.side) {
        case (.one, .red): script = [.move("A4-A6"), .move("A6-B6")]
        case (.one, .blue): script = [.move("B7-B6")]
        case (.two, .red): script = [.swap(.scout, "A1"), .move("J4-J7")]
        case (.two, .blue): script = [.move("B7-B6")]
        }
        let defaults = UserDefaults(suiteName: "local.offlinebarrage.smoketest.\(me.id)") ?? .standard
        service = PeerService(displayName: me.name, playerID: me.id, defaults: defaults)
        service.delegate = self
    }

    var isHost: Bool { seat == Seat(.one, .red) }

    func start() {
        service.start()
        say("advertising and browsing as \(me.name)")
        if isHost {
            let challenge = TeamChallenge(host: me, players: TeamRunner.players,
                                          timeControl: TimeControl(initialSeconds: 300, incrementSeconds: 2))
            open(TeamMatch(challenge: challenge, localPlayerID: me.id, now: Date())!)
        }
    }

    func open(_ match: TeamMatch) {
        self.match = match
        let links = TableLinks(service: service, gameID: match.gameID, me: me, members: match.challenge.players)
        links.delegate = self
        if isHost {
            links.shouldAutoJoin = { [weak self] id in self?.links?.everConnected.contains(id) ?? false }
        }
        self.links = links
    }

    func tick() {
        guard let links = links, let match = match else { return }
        if isHost && !invited && Set(discovered.keys).isSuperset(of: links.members.map(\.id)) {
            invited = true
            guard let context = try? Wire.encode(InvitationEnvelope(.teamChallenge(match.challenge))) else { return fail("encode") }
            for member in links.members {
                say("inviting \(member.name)")
                links.invite(member.id, peer: discovered[member.id]!, context: context, timeout: 30)
            }
        }
        links.tick(now: Date(), nearby: discovered)
    }

    // MARK: PeerServiceDelegate

    func peerService(_ service: PeerService, didUpdateNearby peers: [DiscoveredPeer]) {
        discovered = [:]
        for peer in peers where peer.protocolVersion == Wire.protocolVersion { discovered[peer.playerID] = peer.peerID }
        say("nearby: \(peers.map(\.name).sorted())")
    }

    func peerService(_ service: PeerService, didReceiveInvitation context: Data?, from peerID: MCPeerID,
                     reply: @escaping (InvitationAnswer) -> Void) {
        guard let context = context, let envelope = try? Wire.decode(InvitationEnvelope.self, from: context) else {
            reply(.decline)
            return
        }
        switch envelope.invitation {
        case .teamChallenge(let challenge):
            guard match == nil, let opened = TeamMatch(challenge: challenge, localPlayerID: me.id, now: Date()) else {
                reply(.decline)
                return
            }
            say("accepting the invitation from \(challenge.host.name)")
            open(opened)
            links?.expectLink(from: challenge.host.id, peer: peerID)
            reply(.acceptAlongside)
        case let .teamJoin(gameID, player):
            guard let links = links, gameID == match?.gameID else {
                reply(.decline)
                return
            }
            links.answerJoin(from: player.id, peer: peerID, reply: reply)
        default:
            reply(.decline)
        }
    }

    func peerService(_ service: PeerService, linkDidChange state: PeerLinkState, peer: MCPeerID) {
        links?.linkDidChange(state, peer: peer)
    }

    func peerService(_ service: PeerService, didReceive data: Data, from peerID: MCPeerID) {
        links?.didReceive(data, from: peerID)
    }

    // MARK: TableLinksDelegate

    func tableLinks(_ links: TableLinks, memberDidConnect memberID: String) {
        guard var current = match, let other = current.seat(ofPlayer: memberID) else { return }
        say("linked with \(current.player(other).name) (\(links.connectedCount)/3)")
        if isHost, !current.isConfirmed, links.members.allSatisfy({ links.everConnected.contains($0.id) }),
           let update = current.confirm(at: Date()) {
            match = current
            handle(update)
        }
        send(.sync(current.snapshot(for: other, at: Date())), to: [memberID])
        lockIfReady()
    }

    func tableLinks(_ links: TableLinks, memberDidDisconnect memberID: String) {
        say("link to \(memberID) dropped")
        if !finished && links.everConnected.contains(memberID) { fail("a link dropped before the game finished") }
    }

    func tableLinks(_ links: TableLinks, didReceive data: Data, from memberID: String) {
        guard var current = match, let sender = current.seat(ofPlayer: memberID),
              let envelope = try? Wire.decode(TeamEnvelope.self, from: data), envelope.gameID == current.gameID
        else { return }
        let update = current.receive(envelope.team, from: sender, at: Date())
        match = current
        handle(update)
    }

    // MARK: Playing

    func lockIfReady() {
        guard !locked, let links = links, links.allConnected, var current = match else { return }
        locked = true
        guard let update = current.lockSetup(seat.side == .red ? redArmy : blueArmy, at: Date()) else { return fail("could not lock setup") }
        match = current
        say("all three linked; setup locked in")
        handle(update)
    }

    func handle(_ update: TeamUpdate) {
        for event in update.events {
            switch event {
            case .battle(let report):
                say("battle on \(report.board.name): \(report.attackerRank.name) vs \(report.defenderRank.name) → \(report.outcome)")
            case .swapped(let report):
                say("\(report.seat): \(report.removed.name) swapped out for \(report.placed.name)")
            default:
                say("event: \(event)")
            }
        }
        for outgoing in update.outgoing {
            let ids: [String]
            switch outgoing.to {
            case .everyone: ids = links?.members.map(\.id) ?? []
            case .partner: ids = [TeamRunner.players[seat.partner]!.id]
            }
            send(outgoing.message, to: ids)
        }
        match?.resumeClocks(at: Date())
        checkFinished()
        playIfMyTurn()
    }

    func playIfMyTurn() {
        guard var current = match, current.isLocalTurn, let step = script.first else { return }
        let now = Date()
        var update: TeamUpdate?
        switch step {
        case .move(let text):
            guard let move = Move(text) else { return fail("bad script move") }
            update = current.playLocalMove(move, at: now)
            if update == nil { return fail("could not play \(text)") }
            say("played \(text)")
        case let .swap(rank, square):
            // Wait (bughouse style) until the piece arrives from the other board.
            guard current.reserve(of: seat).contains(rank) else { return }
            guard let piece = current.localBoard?.position[Square(name: square)!]?.id,
                  let swapped = current.swap(in: rank, for: piece, at: now)
            else { return fail("could not swap a \(rank) in at \(square)") }
            update = swapped
            say("swapped a \(rank.name) in at \(square)")
        }
        script.removeFirst()
        match = current
        if let update = update { handle(update) }
    }

    func checkFinished() {
        guard !finished, let current = match, let result = current.result, current.verification != nil else { return }
        finished = true
        let one = current.board(.one)?.entries.count ?? 0
        let two = current.board(.two)?.entries.count ?? 0
        say("game over: \(result.summary { current.player($0).name }); \(one) + \(two) turns; check: \(String(describing: current.verification))")
        guard result.reason == .flagCaptured, result.winner == .two, result.seat == Seat(.two, .red),
              current.verification == .passed, one == 3, two == 3,
              current.reserve(of: Seat(.two, .red)) == [.marshal]
        else {
            return fail("unexpected end state")
        }
        say("all four armies revealed and verified")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.exitCode = 0 }
    }

    func send(_ message: TeamMessage, to ids: [String]) {
        guard let current = match, let links = links,
              let data = try? Wire.encode(TeamEnvelope(gameID: current.gameID, message: message))
        else { return }
        for id in ids where !links.send(data, to: id) { say("send to \(id) failed") }
    }

    func say(_ text: String) {
        print("[\(role)] \(text)")
    }

    func fail(_ reason: String) {
        say("FAIL: \(reason)")
        exitCode = 1
    }
}

func runTeamSmokeTest() -> Never {
    let seats: [String: Seat] = ["team-a": Seat(.one, .red), "team-b": Seat(.one, .blue),
                                 "team-c": Seat(.two, .red), "team-d": Seat(.two, .blue)]
    guard let seat = seats[role] else {
        print("usage: PeerSmokeTest host|guest|team-a|team-b|team-c|team-d")
        exit(2)
    }
    let runner = TeamRunner(seat: seat)
    runner.start()
    let deadline = Date().addingTimeInterval(120)
    var lastTick = Date.distantPast
    while runner.exitCode == nil && Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        if Date().timeIntervalSince(lastTick) >= 1 {
            lastTick = Date()
            runner.tick()
        }
    }
    if runner.exitCode == nil { runner.say("FAIL: timed out") }
    let code = runner.exitCode ?? 1
    runner.links?.close()
    runner.service.disconnect()
    runner.say(code == 0 ? "PASS" : "exiting with failure")
    exit(code)
}
