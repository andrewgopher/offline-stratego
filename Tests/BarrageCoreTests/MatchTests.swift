import Foundation
import Testing
@testable import BarrageCore

func makeSetup(_ side: Side, _ placements: [String: Rank]) -> Setup {
    Setup(side: side, placements: Dictionary(uniqueKeysWithValues: placements.map { (sq($0.key), $0.value) }))
}

/// Scouts on A4 and J4 in front, everything else on the back row.
let redSetup = makeSetup(.red, ["A4": .scout, "J4": .scout, "A1": .marshal, "B1": .general,
                                "C1": .miner, "D1": .spy, "E1": .bomb, "F1": .flag])
/// The Marshal on B7 and the Flag exposed on J7.
let blueSetup = makeSetup(.blue, ["B7": .marshal, "J7": .flag, "A10": .general, "C10": .miner,
                                  "D10": .scout, "E10": .scout, "F10": .spy, "G10": .bomb])

/// Movable pieces face each other in the lake-free columns A, B, E, F, I and J.
let mirrorRed = makeSetup(.red, ["A4": .marshal, "B4": .general, "E4": .miner, "F4": .scout,
                                 "I4": .scout, "J4": .spy, "A1": .bomb, "B1": .flag])
let mirrorBlue = makeSetup(.blue, ["A7": .marshal, "B7": .general, "E7": .miner, "F7": .scout,
                                   "I7": .scout, "J7": .spy, "A10": .bomb, "B10": .flag])

/// Simulates the two Macs: `a` (Alice) plays Red, `b` (Bob) plays Blue. Messages go through
/// JSON like on the wire, and can be dropped to simulate a lost connection.
struct Table {
    var a: Match
    var b: Match
    var now = Date(timeIntervalSinceReferenceDate: 10_000)
    /// When set, messages from that side are silently lost.
    var dropFrom: Side?
    var events: [Side: [MatchEvent]] = [.red: [], .blue: []]

    static let alice = PlayerInfo(id: "A", name: "Alice")
    static let bob = PlayerInfo(id: "B", name: "Bob")

    init(timeControl: TimeControl = TimeControl(initialSeconds: 60, incrementSeconds: 2)) {
        let challenge = Challenge(challenger: Table.alice, challengerSide: .red, timeControl: timeControl)
        a = Match(challenge: challenge, accepter: Table.bob, localPlayerID: "A", now: now)
        b = Match(challenge: challenge, accepter: Table.bob, localPlayerID: "B", now: now)
    }

    mutating func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }

    static func wire(_ message: GameMessage) -> GameMessage {
        let data = try! Wire.encode(WireEnvelope(gameID: UUID(), message: message))
        return try! Wire.decode(WireEnvelope.self, from: data).message
    }

    /// Delivers everything `update` wants to send from Red (`a`) to Blue (`b`) or the reverse, recursively.
    mutating func deliver(_ update: MatchUpdate?, from side: Side) {
        guard let update = update else { return }
        events[side, default: []].append(contentsOf: update.events)
        guard dropFrom != side else { return }
        for message in update.outgoing {
            let reply: MatchUpdate
            if side == .red { reply = b.receive(Table.wire(message), at: now) } else { reply = a.receive(Table.wire(message), at: now) }
            deliver(reply, from: side.opposite)
        }
    }

    mutating func lock(_ red: Setup = redSetup, _ blue: Setup = blueSetup) {
        deliver(a.lockSetup(red, at: now), from: .red)
        deliver(b.lockSetup(blue, at: now), from: .blue)
    }

    /// Plays a move for whichever side is to move.
    mutating func play(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let move = mv(text)
        if a.isLocalTurn {
            let update = a.playLocalMove(move, at: now)
            #expect(update != nil, "Red couldn't play \(text)", sourceLocation: sourceLocation)
            deliver(update, from: .red)
        } else if b.isLocalTurn {
            let update = b.playLocalMove(move, at: now)
            #expect(update != nil, "Blue couldn't play \(text)", sourceLocation: sourceLocation)
            deliver(update, from: .blue)
        } else {
            Issue.record("nobody can move for \(text)", sourceLocation: sourceLocation)
        }
    }

    /// Both Macs exchange public snapshots, as on reconnect.
    mutating func resync() {
        let fromA = a.publicSnapshot(at: now)
        let fromB = b.publicSnapshot(at: now)
        let replyA = a.receive(Table.wire(.sync(fromB)), at: now)
        let replyB = b.receive(Table.wire(.sync(fromA)), at: now)
        deliver(replyA, from: .red)
        deliver(replyB, from: .blue)
    }

    func expectInSync(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.game?.moves == b.game?.moves, sourceLocation: sourceLocation)
        #expect(a.result == b.result, sourceLocation: sourceLocation)
        #expect(a.chat == b.chat, sourceLocation: sourceLocation)
        #expect(a.game?.position.cells == b.game?.position.cells, sourceLocation: sourceLocation)
    }

    func battles(_ side: Side) -> [BattleReport] {
        (events[side] ?? []).compactMap { if case .battle(let report) = $0 { return report } else { return nil } }
    }
}

@Suite struct SetupPhaseTests {
    @Test func setupsStaySecretUntilBothAreLockedIn() {
        var t = Table()
        #expect(t.a.phase == .setup)
        #expect(t.a.lockSetup(Setup(side: .red), at: t.now) == nil, "incomplete setups can't be locked")
        #expect(t.a.lockSetup(blueSetup, at: t.now) == nil, "wrong side")

        let update = t.a.lockSetup(redSetup, at: t.now)
        #expect(update?.outgoing.count == 1, "only the digest goes out")
        t.deliver(update, from: .red)
        #expect(t.b.isOpponentReady)
        #expect(t.b.remoteCommitments == nil, "Blue can't see which squares Red uses")
        #expect(t.b.phase == .setup)

        t.deliver(t.b.lockSetup(blueSetup, at: t.now), from: .blue)
        #expect(t.a.phase == .playing)
        #expect(t.b.phase == .playing)
        #expect(t.a.isLocalTurn, "Red moves first")
        #expect(!t.b.isLocalTurn)
        #expect(t.b.knownRanks.keys.allSatisfy { $0.side == .blue }, "no Red rank is known to Blue")
        #expect(t.a.game?.position.alivePieces(of: .blue).count == 8)
    }
}

@Suite struct PlayTests {
    @Test func scriptedGameEndsWithFlagCaptureAndVerifiedReveal() {
        var t = Table()
        t.lock()
        t.play("A4-A6")  // a long move reveals the Scout
        #expect(t.b.knownRanks[PieceID(.red, sq("A4"))] == .scout)
        #expect(t.b.game?.position.pieces[PieceID(.red, sq("A4"))]?.isRevealed == true)
        t.play("B7-B6")
        #expect(t.a.knownRanks[PieceID(.blue, sq("B7"))] == nil, "a one-step move reveals nothing")
        #expect(t.a.game?.position.pieces[PieceID(.blue, sq("B7"))]?.hasMoved == true)
        t.play("A6-B6")  // Scout attacks the Marshal and loses
        #expect(t.a.knownRanks[PieceID(.blue, sq("B7"))] == .marshal, "the defender's rank came back")
        #expect(t.battles(.red).last?.outcome == .defenderWins)
        #expect(t.battles(.blue).last?.outcome == .defenderWins)
        #expect(t.a.game?.position.lostPieces(of: .red).count == 1)
        t.play("B6-B5")
        t.play("J4-J7")  // the other Scout runs into the Flag
        t.expectInSync()
        #expect(t.a.result == GameResult(winner: .red, reason: .flagCaptured))
        #expect(t.a.hasFullReveal && t.b.hasFullReveal)
        #expect(t.a.verification == .passed)
        #expect(t.b.verification == .passed)
        #expect(t.a.knownRanks.count == 16 && t.b.knownRanks.count == 16)
    }

    @Test func publicSnapshotHidesUnrevealedRanks() {
        var t = Table()
        t.lock()
        t.play("A4-A6")
        let snapshot = t.a.publicSnapshot(at: t.now)
        #expect(snapshot.redSetup.reveals.map(\.piece) == [PieceID(.red, sq("A4"))])
        #expect(snapshot.redSetup.commitments?.count == 8)
        let saved = t.a.snapshot(at: t.now)
        #expect(saved.redSetup.reveals.count == 8, "our own saved copy keeps the whole setup")
        let restored = Match(snapshot: saved, localPlayerID: "A")
        #expect(restored?.game?.moves == t.a.game?.moves)
        #expect(restored?.knownRanks == t.a.knownRanks)
        #expect(Match(snapshot: saved, localPlayerID: "C") == nil)
    }

    @Test func attackWaitsForTheDefendersReveal() {
        var t = Table()
        t.lock()
        t.play("A4-A6")
        t.play("B7-B6")
        // Hold Blue's answer back.
        t.dropFrom = .blue
        t.play("A6-B6")
        #expect(t.a.isAwaitingBattle)
        #expect(!t.a.isLocalTurn && !t.b.isAwaitingBattle)
        #expect(t.b.isLocalTurn, "Blue already knows the outcome and is to move")
        t.dropFrom = nil
        t.resync()
        #expect(!t.a.isAwaitingBattle)
        t.expectInSync()
        t.play("B6-B5")
        t.expectInSync()
    }

    @Test func lostMoveIsRecoveredOnReconnect() {
        var t = Table()
        t.lock()
        t.dropFrom = .red
        t.play("J4-J6")
        #expect(t.b.game?.ply == 0)
        t.dropFrom = nil
        t.resync()
        t.expectInSync()
        #expect(t.b.isLocalTurn)
        #expect(t.b.knownRanks[PieceID(.red, sq("J4"))] == .scout, "the Scout's reveal came with the snapshot")
    }

    @Test func lostAttackIsRecoveredOnReconnect() {
        var t = Table()
        t.lock()
        t.play("A4-A6")
        t.play("B7-B6")
        t.dropFrom = .red
        t.play("A6-B6")  // never reaches Blue
        #expect(t.a.isAwaitingBattle)
        t.dropFrom = nil
        t.resync()
        t.expectInSync()
        #expect(!t.a.isAwaitingBattle)
        #expect(t.a.knownRanks[PieceID(.blue, sq("B7"))] == .marshal)
    }

    @Test func tamperedRevealIsIgnored() {
        var t = Table()
        t.lock()
        // Red claims its A4 piece is a Scout with a made-up nonce.
        let fake = PieceReveal(piece: PieceID(.red, sq("A4")), secret: PieceSecret(rank: .scout, nonce: "00"))
        let update = t.b.receive(.move(ply: 0, move: mv("A4-A7"), reveal: fake, remaining: nil), at: t.now)
        #expect(update.outgoing.isEmpty)
        #expect(t.b.game?.ply == 0)
    }

    @Test func clocksAndTimeout() {
        var t = Table()
        t.lock()
        #expect(t.a.clock?.running == nil, "no clock before Red's first move")
        t.play("A4-A5")
        #expect(t.b.clock?.running == .blue)
        t.advance(10)
        t.play("B7-B6")
        #expect(t.a.clock?.remaining(.blue, at: t.now) == 52)
        t.advance(61)
        #expect(t.b.checkTimeout(at: t.now) == nil, "only the clock's owner declares a timeout")
        t.deliver(t.a.checkTimeout(at: t.now), from: .red)
        #expect(t.b.result == GameResult(winner: .blue, reason: .timeout))
        t.expectInSync()
        #expect(t.a.verification == .passed && t.b.verification == .passed)
    }

    @Test func resignAndDrawOffers() {
        var t = Table()
        t.lock()
        t.play("A4-A5")
        t.play("B7-B6")
        t.deliver(t.b.offerDraw(at: t.now), from: .blue)
        #expect(t.a.drawOfferFrom == .blue)
        t.play("A5-A4")  // moving declines the offer
        #expect(t.a.drawOfferFrom == nil && t.b.drawOfferFrom == nil)
        t.deliver(t.b.offerDraw(at: t.now), from: .blue)
        t.deliver(t.a.respondToDrawOffer(accept: true, at: t.now), from: .red)
        #expect(t.b.result == GameResult(winner: nil, reason: .agreement))
        #expect(t.b.hasFullReveal)

        var u = Table()
        u.lock()
        u.deliver(u.b.resign(at: u.now), from: .blue)
        #expect(u.a.result == GameResult(winner: .red, reason: .resignation))
        #expect(u.a.hasFullReveal && u.b.hasFullReveal)
    }

    @Test func chatIsSharedAndMerged() {
        var t = Table()
        t.deliver(t.a.sendChat("hi", at: t.now), from: .red)
        t.advance(1)
        t.dropFrom = .blue
        t.deliver(t.b.sendChat("hello", at: t.now), from: .blue)
        t.dropFrom = nil
        t.resync()
        #expect(t.a.chat.map(\.text) == ["hi", "hello"])
        t.expectInSync()
    }
}

@Suite struct EndgameTests {
    static let trades = [
        "F4-F7",           // Scout x Scout
        "I7-I4",           // Scout x Scout
        "A4-A5", "A7-A6", "A5-A6",  // Marshal x Marshal
        "B7-B6", "B4-B5", "B6-B5",  // General x General
        "E4-E5", "E7-E6", "E5-E6",  // Miner x Miner
    ]

    @Test func neitherSideCanMoveIsADraw() {
        var t = Table()
        t.lock(mirrorRed, mirrorBlue)
        for move in EndgameTests.trades { t.play(move) }
        t.play("J7-J6")
        t.play("J4-J5")
        t.play("J6-J5")  // Spy x Spy: only Bombs and Flags are left
        #expect(t.events[.red]?.contains(.stuck(.red)) == true)
        #expect(t.a.result == GameResult(winner: nil, reason: .noMovablePieces))
        t.expectInSync()
        #expect(t.a.verification == .passed && t.b.verification == .passed)
    }

    @Test func aPlayerWhoCantMoveLoses() {
        // Same, but Blue keeps its Spy and Red's Spy dies on Blue's Bomb.
        let blue = makeSetup(.blue, ["A7": .marshal, "B7": .general, "E7": .miner, "F7": .scout,
                                     "I7": .scout, "J7": .bomb, "J10": .spy, "B10": .flag])
        var t = Table()
        t.lock(mirrorRed, blue)
        for move in EndgameTests.trades { t.play(move) }
        t.play("J10-I10")
        t.play("J4-J5")
        t.play("I10-H10")
        t.play("J5-J6")
        t.play("H10-I10")
        t.play("J6-J7")  // Spy hits the Bomb
        t.play("I10-H10")
        #expect(t.a.result == GameResult(winner: .blue, reason: .noMoves))
        t.expectInSync()
        #expect(t.b.verification == .passed)
    }

    @Test func falseNoMovesClaimIsCaught() {
        var t = Table()
        t.lock()
        // A tampered Red client claims to be stuck on its first turn, then reveals its army.
        _ = t.b.receive(.noLegalMoves(ply: 0), at: t.now)
        let reveals = t.a.snapshot(at: t.now).redSetup.reveals
        let update = t.b.receive(.reveal(reveals), at: t.now)
        #expect(t.b.result == GameResult(winner: .blue, reason: .noMoves))
        #expect(update.events.contains { if case .verificationFailed = $0 { return true } else { return false } })
        if case .failed = t.b.verification {} else { Issue.record("verification should fail") }
    }
}
