import Foundation
import Testing
@testable import BarrageCore

let ann = Seat(.one, .red)   // team one, with Di
let bo = Seat(.one, .blue)   // team two, with Cy
let cy = Seat(.two, .red)    // team two
let di = Seat(.two, .blue)   // team one

/// Simulates the four Macs of a 2v2 game. Messages go through JSON like on the wire. A link can
/// be held (messages queue up until released) or a player muted (their messages are lost).
struct Quartet {
    struct Link: Hashable {
        let from: Seat
        let to: Seat
    }

    var macs: [Seat: TeamMatch] = [:]
    var now = Date(timeIntervalSinceReferenceDate: 50_000)
    var events: [Seat: [TeamEvent]] = [:]
    var muted: Set<Seat> = []
    var heldLinks: Set<Link> = []
    var held: [(Link, TeamMessage)] = []

    static let players: [Seat: PlayerInfo] = [
        ann: PlayerInfo(id: "A", name: "Ann"),
        bo: PlayerInfo(id: "B", name: "Bo"),
        cy: PlayerInfo(id: "C", name: "Cy"),
        di: PlayerInfo(id: "D", name: "Di"),
    ]

    init(timeControl: TimeControl = TimeControl(initialSeconds: 60, incrementSeconds: 2)) {
        let challenge = TeamChallenge(host: Quartet.players[ann]!, players: Quartet.players, timeControl: timeControl)
        for (seat, player) in Quartet.players {
            macs[seat] = TeamMatch(challenge: challenge, localPlayerID: player.id, now: now)
        }
    }

    subscript(seat: Seat) -> TeamMatch { macs[seat]! }

    mutating func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }

    static func wire(_ message: TeamMessage) -> TeamMessage {
        let data = try! Wire.encode(TeamEnvelope(gameID: UUID(), message: message))
        return try! Wire.decode(TeamEnvelope.self, from: data).team
    }

    /// Sends everything in `update` from `seat`, recursively delivering the replies.
    mutating func deliver(_ update: TeamUpdate?, from seat: Seat) {
        guard let update = update else { return }
        events[seat, default: []].append(contentsOf: update.events)
        guard !muted.contains(seat) else { return }
        for outgoing in update.outgoing {
            let recipients = outgoing.to == .partner ? [seat.partner] : Seat.all.filter { $0 != seat }
            for recipient in recipients {
                send(outgoing.message, over: Link(from: seat, to: recipient))
            }
        }
    }

    mutating func send(_ message: TeamMessage, over link: Link) {
        if heldLinks.contains(link) {
            held.append((link, message))
            return
        }
        let reply = macs[link.to]!.receive(Quartet.wire(message), from: link.from, at: now)
        deliver(reply, from: link.to)
    }

    mutating func release() {
        heldLinks = []
        let queue = held
        held = []
        for (link, message) in queue { send(message, over: link) }
    }

    mutating func act(_ seat: Seat, _ body: (inout TeamMatch) -> TeamUpdate?) {
        var mac = macs[seat]!
        let update = body(&mac)
        macs[seat] = mac
        deliver(update, from: seat)
    }

    mutating func lockAll(_ setups: [Seat: Setup]? = nil) {
        let chosen = setups ?? [ann: redSetup, bo: blueSetup, cy: redSetup, di: blueSetup]
        for seat in Seat.all {
            let now = self.now
            act(seat) { $0.lockSetup(chosen[seat]!, at: now) }
        }
    }

    mutating func play(_ seat: Seat, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let now = self.now
        var played = false
        act(seat) { match in
            let update = match.playLocalMove(mv(text), at: now)
            played = update != nil
            return update
        }
        #expect(played, "\(seat) couldn't play \(text)", sourceLocation: sourceLocation)
    }

    mutating func swap(_ seat: Seat, in rank: Rank, at square: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let now = self.now
        var swapped = false
        act(seat) { match in
            guard let piece = match.localBoard?.position[sq(square)]?.id else { return nil }
            let update = match.swap(in: rank, for: piece, at: now)
            swapped = update != nil
            return update
        }
        #expect(swapped, "\(seat) couldn't swap a \(rank) in at \(square)", sourceLocation: sourceLocation)
    }

    /// Every pair of Macs exchanges snapshots, as when the links come back.
    mutating func resync() {
        for from in Seat.all {
            for to in Seat.all where to != from {
                let snapshot = macs[from]!.snapshot(for: to, at: now)
                send(.sync(snapshot), over: Link(from: from, to: to))
            }
        }
    }

    func expectInSync(sourceLocation: SourceLocation = #_sourceLocation) {
        for seat in Seat.all.dropFirst() {
            for board in BoardID.allCases {
                #expect(macs[seat]!.board(board)?.entries == macs[ann]!.board(board)?.entries,
                        "\(seat) sees \(board.name) differently", sourceLocation: sourceLocation)
                #expect(macs[seat]!.board(board)?.position.cells == macs[ann]!.board(board)?.position.cells,
                        sourceLocation: sourceLocation)
            }
            #expect(macs[seat]!.result == macs[ann]!.result, sourceLocation: sourceLocation)
            for other in Seat.all {
                #expect(macs[seat]!.reserve(of: other) == macs[ann]!.reserve(of: other),
                        "\(seat) sees \(other)'s reserve differently", sourceLocation: sourceLocation)
            }
        }
    }

    func events(_ seat: Seat) -> [TeamEvent] { events[seat] ?? [] }
}

@Suite struct TeamSetupTests {
    @Test func gameStartsOnceAllFourAreLockedIn() {
        var q = Quartet()
        let now = q.now
        q.act(ann) { $0.lockSetup(redSetup, at: now) }
        q.act(bo) { $0.lockSetup(blueSetup, at: now) }
        q.act(cy) { $0.lockSetup(redSetup, at: now) }
        #expect(!q[ann].hasStarted)
        #expect(q[bo].initialCommitments[ann] == nil, "nobody sees which squares are used before all are ready")
        #expect(q[di].isReady(ann) && q[di].isReady(bo) && q[di].isReady(cy))
        #expect(q[di].partnerRanks.count == 8, "Di sees Ann's setup face up")
        #expect(q[cy].partnerRanks.count == 8 && q[cy].partnerRanks.keys.allSatisfy { $0.side == .blue }, "Bo is Cy's partner")
        #expect(q[ann].partnerRanks.isEmpty, "Di hasn't locked in yet")

        q.act(di) { $0.lockSetup(blueSetup, at: now) }
        for seat in Seat.all {
            #expect(q[seat].hasStarted)
            #expect(q[seat].phase == .playing)
            #expect(q[seat].clocks[.one]?.running == .red, "clocks run from the start in 2v2")
            #expect(q[seat].clocks[.two]?.running == .red)
        }
        #expect(q[ann].isLocalTurn && q[cy].isLocalTurn)
        #expect(!q[bo].isLocalTurn && !q[di].isLocalTurn)
        #expect(q[ann].board(.one)?.position.alivePieces(of: .blue).count == 8)
        #expect(q[ann].teamRanks(on: .two).keys.allSatisfy { $0.side == .blue }, "Ann sees only her partner's ranks on board 2")
    }

    @Test func invalidChallengesAreRejected() {
        var players = Quartet.players
        players[di] = Quartet.players[ann]
        let duplicate = TeamChallenge(host: Quartet.players[ann]!, players: players, timeControl: TimeControl(initialSeconds: 60))
        #expect(!duplicate.isValid)
        let noClock = TeamChallenge(host: Quartet.players[ann]!, players: Quartet.players, timeControl: .unlimited)
        #expect(!noClock.isValid, "2v2 needs a clock")
        #expect(TeamMatch(challenge: noClock, localPlayerID: "A", now: Date()) == nil)
    }
}

@Suite struct TeamPlayTests {
    /// Board 1: Ann's Scout runs into Bo's Marshal and is lost, so it goes to Cy (Bo's partner).
    static func scoutLostOnBoardOne(_ q: inout Quartet) {
        q.play(ann, "A4-A6")
        q.play(bo, "B7-B6")
        q.play(ann, "A6-B6")
    }

    @Test func capturedPieceGoesToTheWinnersPartner() {
        var q = Quartet()
        q.lockAll()
        Self.scoutLostOnBoardOne(&q)
        q.expectInSync()
        for seat in Seat.all {
            #expect(q[seat].reserve(of: cy) == [.scout], "the lost red Scout joins Cy's reserve")
            #expect(q[seat].reserve(of: ann).isEmpty && q[seat].reserve(of: bo).isEmpty && q[seat].reserve(of: di).isEmpty)
        }
        let battles = q.events(di).compactMap { if case .battle(let report) = $0 { return report } else { return nil } }
        #expect(battles.last?.attackerRank == .scout && battles.last?.defenderRank == .marshal,
                "the other board's players see the battle too")
    }

    @Test func swapIsHiddenFromOpponentsButNotFromThePartner() {
        var q = Quartet()
        q.lockAll()
        Self.scoutLostOnBoardOne(&q)
        q.swap(cy, in: .scout, at: "A1")  // the Marshal goes into Cy's reserve
        q.expectInSync()
        for seat in Seat.all {
            #expect(q[seat].reserve(of: cy) == [.marshal])
            #expect(q[seat].board(.two)?.sideToMove == .blue, "a swap uses the turn")
        }
        let marshalHome = PieceID(.red, sq("A1"))
        #expect(q[cy].localRanks[marshalHome] == .scout)
        #expect(q[bo].partnerRanks[marshalHome] == .scout, "the partner sees the new rank")
        #expect(q.events(bo).contains(.partnerSwapped(marshalHome)))
        let notice = q.events(di).compactMap { if case .swapped(let report) = $0 { return report } else { return nil } }
        #expect(notice == [TeamSwapReport(seat: cy, removed: .marshal, placed: .scout)])

        // What Di's Mac holds about Cy's army doesn't say which piece changed.
        let forDi = q[cy].snapshot(for: di, at: q.now)
        #expect(forDi.ownSecrets == nil && forDi.authorRanks == nil && forDi.partnerRanks == nil)
        let forBo = q[cy].snapshot(for: bo, at: q.now)
        #expect(forBo.authorRanks?.count == 8)
        let saved = q[cy].snapshot(for: nil, at: q.now)
        #expect(saved.ownSecrets?.count == 2, "two commitment epochs: the setup and the swap")
        if case .swap(let swap)? = q[di].board(.two)?.entries.first?.action {
            #expect(swap.commitments.count == 8, "all pieces are re-committed")
            let before = q[di].initialCommitments[cy] ?? [:]
            #expect(swap.commitments.allSatisfy { before[$0.piece] != $0.digest }, "every commitment changed")
        } else {
            Issue.record("the swap is missing")
        }
    }

    @Test func swapThenFlagCaptureEndsTheMatchAndEverythingChecksOut() {
        var q = Quartet()
        q.lockAll()
        Self.scoutLostOnBoardOne(&q)
        q.swap(cy, in: .scout, at: "A1")
        q.play(di, "B7-B6")
        q.play(cy, "J4-J7")  // Cy's Scout runs into Di's exposed Flag
        q.expectInSync()
        for seat in Seat.all {
            let result = q[seat].result
            #expect(result?.winner == .two)
            #expect(result?.reason == .flagCaptured)
            #expect(result?.seat == cy)
            #expect(q[seat].hasFullReveal)
            #expect(q[seat].verification == .passed, "\(seat): \(String(describing: q[seat].verification))")
            #expect(q[seat].clocks.values.allSatisfy { !$0.isRunning })
            #expect(!q[seat].isLocalTurn)
        }
        #expect(q[ann].reserve(of: ann).isEmpty, "a captured Flag ends the game; it never joins a reserve")
        #expect(q[di].revealedRanks(on: .two, afterTurns: 0)?[PieceID(.red, sq("A1"))] == .marshal)
        #expect(q[di].revealedRanks(on: .two, afterTurns: 1)?[PieceID(.red, sq("A1"))] == .scout, "the replay shows the swap")
        #expect(q[ann].play(after: "Bo can't move any more") == nil)
    }

    @Test func swapWaitsForTheOtherBoardItDependsOn() {
        var q = Quartet()
        q.lockAll()
        q.heldLinks = [Quartet.Link(from: bo, to: di)]
        Self.scoutLostOnBoardOne(&q)
        #expect(q[di].board(.one)?.ply == 1, "Di is missing Bo's move and answer")
        q.swap(cy, in: .scout, at: "A1")
        #expect(q[di].board(.two)?.ply == 0, "the swap needs the battle Di hasn't seen settled yet")
        #expect(!q[di].isLocalTurn)
        q.release()
        q.expectInSync()
        #expect(q[di].board(.two)?.ply == 1)
        #expect(q[di].isLocalTurn)
    }

    @Test func lostTurnIsRecoveredByResync() {
        var q = Quartet()
        q.lockAll()
        Self.scoutLostOnBoardOne(&q)
        q.muted = [cy]
        q.swap(cy, in: .scout, at: "A1")
        #expect(q[di].board(.two)?.ply == 0)
        q.muted = []
        q.advance(3)
        q.resync()
        q.expectInSync()
        #expect(q[di].isLocalTurn)
        #expect(q[bo].partnerRanks[PieceID(.red, sq("A1"))] == .scout, "the partner's ranks came with the snapshot")
    }

    @Test func savedGameRestores() {
        var q = Quartet()
        q.lockAll()
        Self.scoutLostOnBoardOne(&q)
        q.swap(cy, in: .scout, at: "A1")
        let saved = q[cy].snapshot(for: nil, at: q.now)
        let restored = TeamMatch(snapshot: saved, localPlayerID: "C")
        #expect(restored != nil)
        #expect(restored?.board(.one)?.entries == q[cy].board(.one)?.entries)
        #expect(restored?.board(.two)?.entries == q[cy].board(.two)?.entries)
        #expect(restored?.localRanks == q[cy].localRanks)
        #expect(restored?.partnerRanks == q[cy].partnerRanks)
        #expect(restored?.reserve(of: cy) == [.marshal])
        #expect(restored?.localEpochs?.count == 2)
        #expect(TeamMatch(snapshot: saved, localPlayerID: "A") == nil, "only the author can open their copy")
        let theirs = q[di].snapshot(for: nil, at: q.now)
        let reopened = TeamMatch(snapshot: theirs, localPlayerID: "D")
        #expect(reopened?.isLocalTurn == true)
    }

    @Test func forgedSwapIsRejected() {
        var q = Quartet()
        q.lockAll()
        // Cy has nothing in reserve, so a swap can't be legal.
        let commitments = q[ann].initialCommitments[cy]!.map { PieceCommitment(piece: $0.key, digest: $0.value) }
        let forged = BoardEntry(action: .swap(SwapAction(removed: .scout, placed: .general, otherBoardCount: 0, commitments: commitments)),
                                at: q.now, remaining: 60)
        q.send(.action(board: .two, index: 0, entry: forged), over: Quartet.Link(from: cy, to: ann))
        #expect(q[ann].board(.two)?.ply == 0)
        // Nor can anyone else speak for Cy.
        let move = BoardEntry(action: .move(mv("J4-J5"), reveal: nil), at: q.now, remaining: 60)
        q.send(.action(board: .two, index: 0, entry: move), over: Quartet.Link(from: bo, to: ann))
        #expect(q[ann].board(.two)?.ply == 0)
    }

    @Test func theFlagCantBeSwappedOut() {
        var q = Quartet()
        q.lockAll()
        Self.scoutLostOnBoardOne(&q)
        let flag = PieceID(.red, sq("F1"))
        var mac = q[cy]
        #expect(!mac.swappablePieces.contains(flag))
        #expect(mac.swap(in: .scout, for: flag, at: q.now) == nil)
        #expect(mac.swap(in: .general, for: PieceID(.red, sq("A1")), at: q.now) == nil, "not in the reserve")
    }

    @Test func aSwapBreaksTheTwoSquaresRule() {
        var q = Quartet()
        // Board 2 trades Scouts, so Ann (red, board 1) and Bo (blue, board 1) each get one.
        q.lockAll([ann: redSetup, bo: blueSetup, cy: mirrorRed, di: mirrorBlue])
        q.play(cy, "F4-F6")
        q.play(di, "F7-F6")
        #expect(q[ann].reserve(of: ann) == [.scout] && q[ann].reserve(of: bo) == [.scout])
        let annMoves = ["A4-A5", "A5-A4", "A4-A5", "A5-A4", "A4-A5"]
        let boMoves = ["B7-B6", "A10-A9", "B6-B7", "A9-A10", "B7-B6"]
        for (mine, theirs) in zip(annMoves, boMoves) {
            q.play(ann, mine)
            q.play(bo, theirs)
        }
        #expect(q[ann].board(.one).map { Rules.restriction(on: mv("A5-A4"), in: $0) } == .twoSquares)
        #expect(!q[ann].legalMoves.contains(mv("A5-A4")))
        q.swap(ann, in: .scout, at: "B1")
        q.play(bo, "A10-A9")
        #expect(q[ann].legalMoves.contains(mv("A5-A4")), "the swap broke the sequence")
        q.expectInSync()
    }
}

@Suite struct TeamEndgameTests {
    @Test func resignationLosesForTheTeam() {
        var q = Quartet()
        q.lockAll()
        q.play(ann, "A4-A5")
        let now = q.now
        q.act(di) { $0.resign(at: now) }
        q.expectInSync()
        #expect(q[bo].result == TeamResult(winner: .two, reason: .resignation, seat: di, at: now))
        #expect(q[cy].result?.summary(name: { Quartet.players[$0]!.name }) == "Di resigned")
        #expect(q[ann].verification == .passed)
        #expect(!q[cy].isLocalTurn, "the other board stops too")
    }

    @Test func runningOutOfTimeLosesForTheTeam() {
        var q = Quartet()
        q.lockAll()
        q.play(ann, "A4-A5")
        q.advance(70)  // Cy hasn't moved on board 2 and has 60 seconds
        let now = q.now
        q.act(ann) { $0.checkTimeout(at: now) }
        #expect(q[ann].result == nil, "only Cy's own Mac declares Cy's timeout")
        q.act(cy) { $0.checkTimeout(at: now) }
        q.expectInSync()
        #expect(q[ann].result?.reason == .timeout)
        #expect(q[ann].result?.winner == .one)
        #expect(q[di].result?.seat == cy)
    }

    /// Cy's army on board 2 is whittled down to the Flag while a Scout sits in Cy's reserve. Cy
    /// can't move, and can't swap either (a swap replaces a piece on the board, never the Flag),
    /// so Cy waits with the clock running: until the clock runs out, or until the teammate wins
    /// on the other board.
    @Test func aLoneFlagWaitsEvenWithPiecesInReserve() {
        var q = Quartet()
        let cySetup = makeSetup(.red, ["A4": .bomb, "B4": .marshal, "E4": .general, "E3": .miner,
                                       "F4": .spy, "F3": .scout, "F2": .scout, "A1": .flag])
        let diSetup = makeSetup(.blue, ["A7": .miner, "B7": .spy, "E7": .marshal, "F7": .general,
                                        "I7": .scout, "J7": .scout, "I10": .bomb, "J10": .flag])
        q.lockAll([ann: redSetup, bo: blueSetup, cy: cySetup, di: diSetup])
        TeamPlayTests.scoutLostOnBoardOne(&q)  // a Scout for Cy's reserve
        let board2: [(Seat, String)] = [
            (cy, "F2-G2"), (di, "E7-E6"), (cy, "G2-F2"), (di, "E6-E5"),
            (cy, "E4-E5"),  // General loses to the Marshal
            (di, "A7-A6"), (cy, "E3-E4"), (di, "A6-A5"),
            (cy, "E4-E5"),  // Miner loses to the Marshal
            (di, "F7-F6"), (cy, "F2-G2"), (di, "F6-F5"),
            (cy, "F4-F5"),  // Spy loses to the General
            (di, "B7-B6"),
            (cy, "F3-F5"),  // Scout loses to the General
            (di, "B6-B5"), (cy, "G2-F2"),
            (di, "B5-B4"),  // Spy takes the Marshal
            (cy, "F2-F5"),  // the last Scout loses to the General
            (di, "A5-A4"),  // Miner defuses the Bomb
        ]
        for (seat, move) in board2 { q.play(seat, move) }
        q.expectInSync()

        var mac = q[cy]
        #expect(mac.localBoard?.position.alivePieces(of: .red).count == 1, "only the Flag is left")
        #expect(mac.reserve(of: cy) == [.scout])
        #expect(mac.isLocalTurn)
        #expect(mac.legalMoves.isEmpty)
        #expect(mac.swappablePieces.isEmpty)
        #expect(!mac.canSwap)
        #expect(mac.isWaitingForPieces)
        #expect(mac.clocks[.two]?.running == .red, "Cy's clock keeps running while Cy waits")
        #expect(mac.swap(in: .scout, for: PieceID(.red, sq("A1")), at: q.now) == nil)
        #expect(q[ann].result == nil, "waiting doesn't end the game")

        q.advance(200)
        let now = q.now
        q.act(cy) { $0.checkTimeout(at: now) }
        q.expectInSync()
        #expect(q[ann].result?.reason == .timeout)
        #expect(q[ann].result?.winner == .one)
        #expect(q[bo].verification == .passed)
    }

    @Test func drawNeedsAllFour() {
        var q = Quartet()
        q.lockAll()
        let now = q.now
        q.act(ann) { $0.offerDraw(at: now) }
        #expect(q[cy].drawOfferAwaitsUs)
        q.act(bo) { $0.answerDrawOffer(accept: true, at: now) }
        q.act(cy) { $0.answerDrawOffer(accept: true, at: now) }
        #expect(q[di].result == nil)
        q.act(di) { $0.answerDrawOffer(accept: false, at: now) }
        for seat in Seat.all { #expect(q[seat].drawOffer == nil && q[seat].result == nil) }

        q.act(bo) { $0.offerDraw(at: now) }
        for seat in [ann, cy, di] { q.act(seat) { $0.answerDrawOffer(accept: true, at: now) } }
        q.expectInSync()
        #expect(q[ann].result?.reason == .agreement)
        #expect(q[ann].result?.winner == nil)
    }

    @Test func tamperedRevealFailsTheCheck() {
        var q = Quartet()
        q.lockAll()
        q.muted = [cy]
        let now = q.now
        q.act(ann) { $0.resign(at: now) }
        #expect(q[ann].finalReveals[cy] == nil)
        // Cy's Mac claims its General was the Marshal.
        var epochs = q[cy].finalReveals[cy]!
        let index = epochs[0].firstIndex { $0.secret.rank == .general }!
        epochs[0][index].secret.rank = .marshal
        q.muted = []
        q.send(.finalReveal(epochs), over: Quartet.Link(from: cy, to: ann))
        #expect(q[ann].hasFullReveal)
        if case .failed(let reason)? = q[ann].verification {
            #expect(reason.contains("Cy"))
        } else {
            Issue.record("the check should fail, got \(String(describing: q[ann].verification))")
        }
    }

    @Test func teamChatReachesOnlyThePartner() {
        var q = Quartet()
        q.lockAll()
        let now = q.now
        q.act(ann) { $0.sendChat("go for their flag", teamOnly: true, at: now) }
        q.act(bo) { $0.sendChat("good luck all", teamOnly: false, at: now) }
        #expect(q[di].chat.map(\.text) == ["go for their flag", "good luck all"])
        #expect(q[cy].chat.map(\.text) == ["good luck all"])
        #expect(q[ann].snapshot(for: bo, at: now).chat.map(\.text) == ["good luck all"], "snapshots for opponents leave team chat out")
    }
}

private extension TeamMatch {
    /// Tries a move after the game is over (should do nothing).
    func play(after reason: String) -> TeamUpdate? {
        var copy = self
        return copy.playLocalMove(mv("A6-A7"), at: Date())
    }
}

@Suite struct TeamEdgeCaseTests {
    /// Ann's Miner faces Bo's Bomb on A7.
    static let minerFront = makeSetup(.red, ["A4": .miner, "J4": .scout, "A1": .marshal, "B1": .general,
                                             "C1": .scout, "D1": .spy, "E1": .bomb, "F1": .flag])
    static let bombFront = makeSetup(.blue, ["A7": .bomb, "F7": .scout, "A10": .general, "B10": .marshal,
                                             "C10": .miner, "D10": .scout, "F10": .spy, "J10": .flag])

    @Test func defusedBombsAndSwappedOutBombsTravelThroughReserves() {
        var q = Quartet()
        q.lockAll([ann: Self.minerFront, bo: Self.bombFront, cy: redSetup, di: blueSetup])
        q.play(ann, "A4-A5")
        q.play(bo, "F7-F6")
        q.play(ann, "A5-A6")
        q.play(bo, "F6-F7")
        q.play(ann, "A6-A7")  // the Miner defuses the Bomb, which goes to Di
        #expect(q[cy].reserve(of: di) == [.bomb])
        q.play(cy, "J4-J5")
        q.swap(di, in: .bomb, at: "D10")   // a Bomb where a Scout stood
        #expect(q[ann].reserve(of: di) == [.scout])
        q.play(cy, "J5-J4")
        q.swap(di, in: .scout, at: "G10")  // and a Bomb swapped out
        #expect(q[bo].reserve(of: di) == [.bomb])
        q.play(cy, "J4-J5")
        q.swap(di, in: .bomb, at: "D10")   // Bomb for Bomb: a waiting move
        #expect(q[cy].reserve(of: di) == [.bomb])
        #expect(q[di].localRanks[PieceID(.blue, sq("G10"))] == .scout)
        #expect(q[ann].partnerRanks[PieceID(.blue, sq("D10"))] == .bomb)
        q.expectInSync()
        let now = q.now
        q.act(cy) { $0.resign(at: now) }
        for seat in Seat.all {
            #expect(q[seat].verification == .passed, "\(seat): \(String(describing: q[seat].verification))")
        }
    }

    @Test func theEarlierEndingCountsWhicheverArrivesFirst() {
        var q = Quartet()
        q.lockAll()
        q.play(ann, "A4-A5")
        // Bo resigns first, but his message is held up; Di resigns a second later.
        q.heldLinks = Set(Seat.all.filter { $0 != bo }.map { Quartet.Link(from: bo, to: $0) })
        let first = q.now
        q.act(bo) { $0.resign(at: first) }
        q.advance(1)
        let second = q.now
        q.act(di) { $0.resign(at: second) }
        #expect(q[ann].result?.seat == di)
        q.release()
        q.expectInSync()
        for seat in Seat.all {
            #expect(q[seat].result == TeamResult(winner: .one, reason: .resignation, seat: bo, at: first))
        }
    }

    @Test func movingASwappedInBombFailsTheCheck() {
        var q = Quartet()
        q.lockAll([ann: Self.minerFront, bo: Self.bombFront, cy: redSetup, di: blueSetup])
        for (seat, move) in [(ann, "A4-A5"), (bo, "F7-F6"), (ann, "A5-A6"), (bo, "F6-F7"), (ann, "A6-A7"), (cy, "J4-J5")] {
            q.play(seat, move)
        }
        q.swap(di, in: .bomb, at: "D10")
        q.play(cy, "J5-J4")
        // A tampered Mac moves the new Bomb (its own app would never allow that).
        #expect(!q[di].legalMoves.contains(mv("D10-D9")))
        let forged = BoardEntry(action: .move(mv("D10-D9"), reveal: nil), at: q.now, remaining: 290)
        for seat in [ann, bo, cy] {
            q.send(.action(board: .two, index: 3, entry: forged), over: Quartet.Link(from: di, to: seat))
        }
        #expect(q[ann].board(.two)?.ply == 4, "nobody can tell yet")
        let now = q.now
        q.act(ann) { $0.resign(at: now) }
        if case .failed(let reason)? = q[bo].verification {
            #expect(reason.contains("Di") && reason.contains("D10-D9"))
        } else {
            Issue.record("the check should fail, got \(String(describing: q[bo].verification))")
        }
    }

    @Test func gameInSetupRestores() {
        var q = Quartet()
        let now = q.now
        q.act(bo) { $0.lockSetup(blueSetup, at: now) }
        let restored = TeamMatch(snapshot: q[bo].snapshot(for: nil, at: now), localPlayerID: "B")
        #expect(restored?.isLocalReady == true)
        #expect(restored?.localSetup == blueSetup)
        #expect(restored?.hasStarted == false)
        let fresh = TeamMatch(snapshot: q[ann].snapshot(for: nil, at: now), localPlayerID: "A")
        #expect(fresh?.isLocalReady == false && fresh?.isReady(bo) == true)
    }
}
