import Foundation

/// Something the 2v2 UI may want to react to.
public enum TeamEvent: Hashable {
    case playerReady(Seat)
    /// All four players have joined the table.
    case confirmed
    case gameStarted
    case acted(Seat, isSwap: Bool)
    case battle(TeamBattleReport)
    case swapped(TeamSwapReport)
    /// Our partner's swap changed this piece (only partners learn which piece it was).
    case partnerSwapped(PieceID)
    case gameOver(TeamResult)
    case drawOffered(Seat)
    case drawDeclined(Seat)
    case chatReceived(TeamChatMessage)
    case resynced
    case verificationFailed(String)
}

public struct TeamBattleReport: Hashable {
    public let board: BoardID
    public let index: Int
    public let attackerSide: Side
    public let attackerRank: Rank
    public let defenderRank: Rank
    public let outcome: BattleOutcome
    public let square: Square

    public var attacker: Seat { Seat(board, attackerSide) }
    public var defender: Seat { Seat(board, attackerSide.opposite) }
}

public struct TeamSwapReport: Hashable {
    public let seat: Seat
    public let removed: Rank
    public let placed: Rank

    public init(seat: Seat, removed: Rank, placed: Rank) {
        self.seat = seat
        self.removed = removed
        self.placed = placed
    }

    public var board: BoardID { seat.board }
}

public enum Recipients: Hashable {
    case everyone
    case partner
}

public struct TeamOutgoing: Hashable {
    public let message: TeamMessage
    public let to: Recipients
}

/// Result of a local action or a remote message: what to send and what happened.
public struct TeamUpdate {
    public var outgoing: [TeamOutgoing] = []
    public var events: [TeamEvent] = []
    public init() {}

    mutating func send(_ message: TeamMessage, to recipients: Recipients = .everyone) {
        outgoing.append(TeamOutgoing(message: message, to: recipients))
    }
}

/// A 2v2 game as seen from one of the four Macs.
///
/// All four run an identical `TeamMatch`. Each player is authoritative for their own turns,
/// clock and ranks, and proves every rank they show with a hash commitment, as in 1v1. On top:
/// - partners share their ranks with each other directly (so team pieces are face up);
/// - a piece lost on one board joins the reserve of the winner's partner on the other board;
/// - a turn may be a swap: a reserve piece replaces one of the player's pieces. Everyone learns
///   both ranks but not which piece changed, because the swapper re-commits all their pieces
///   with fresh nonces (a new commitment epoch). Everything is checked once the game is over.
public struct TeamMatch {
    public let challenge: TeamChallenge
    public let localSeat: Seat
    public let createdAt: Date
    public private(set) var updatedAt: Date
    /// The host has seen all three invited players join.
    public private(set) var isConfirmed = false

    /// Our ranks and nonces, one map per commitment epoch: 0 is the setup, then one per swap.
    public private(set) var localEpochs: [[PieceID: PieceSecret]]?
    public private(set) var readyDigests: [Seat: String] = [:]
    /// Every seat's epoch-0 commitments (later epochs travel inside the swaps).
    public private(set) var initialCommitments: [Seat: [PieceID: String]] = [:]
    /// Our partner's current ranks, as their Mac told us.
    public private(set) var partnerRanks: [PieceID: Rank] = [:]
    /// Empty until all four armies are committed.
    public private(set) var boards: [BoardID: TeamBoard] = [:]
    /// One two-sided clock per board.
    public private(set) var clocks: [BoardID: GameClock] = [:]
    /// Resignations, timeouts and a draw by agreement. A captured Flag follows from the boards.
    public private(set) var declaredResults: [TeamResult] = []
    public private(set) var drawOffer: TeamDrawOffer?
    private var answeredDrawOffers: Set<UUID> = []
    public private(set) var chat: [TeamChatMessage] = []
    /// Each seat's ranks and nonces for every epoch, revealed once the game is over.
    public private(set) var finalReveals: [Seat: [[PieceReveal]]] = [:]
    public private(set) var verification: Verification?

    private var verifiedKey = -1
    private var reportedResult: TeamResult?
    private var sentCommitments = false
    /// Turns and reveals that arrived before what they build on (they wait here, in memory).
    private var pending: [Pending] = []

    public static let maxChatLength = 500
    static let maxPending = 400

    private enum Pending: Hashable {
        /// `sender` is nil for entries taken from a snapshot.
        case action(BoardID, Int, BoardEntry, sender: Seat?)
        case reveal(BoardID, Int, PieceReveal, sender: Seat?)
    }

    private enum Outcome {
        case applied
        case notYet
        case invalid
    }

    // MARK: - Creating

    /// Builds a new game from the host's challenge. Call on all four Macs with the same challenge.
    public init?(challenge: TeamChallenge, localPlayerID: String, now: Date) {
        guard challenge.isValid, let seat = challenge.seat(of: localPlayerID) else { return nil }
        self.challenge = challenge
        localSeat = seat
        createdAt = now
        updatedAt = now
        if let initial = challenge.timeControl.initialSeconds {
            for board in BoardID.allCases {
                clocks[board] = GameClock(red: Double(initial), blue: Double(initial))
            }
        }
    }

    /// Restores a saved game. Fails if the local player isn't its author or it doesn't replay.
    public init?(snapshot: TeamSnapshot, localPlayerID: String) {
        guard let seat = snapshot.seat(of: localPlayerID), snapshot.author == seat,
              var match = TeamMatch(challenge: snapshot.challenge, localPlayerID: localPlayerID, now: snapshot.createdAt)
        else { return nil }
        if let own = snapshot.ownSecrets, !own.isEmpty {
            let epochs = own.map { list in
                Dictionary(list.map { ($0.piece, $0.secret) }, uniquingKeysWith: { first, _ in first })
            }
            guard let setup = epochs.first, setup.count == Rank.barrageArmy.count,
                  setup.keys.allSatisfy({ $0.side == seat.side && $0.home.isHome(of: seat.side) }),
                  Rank.isBarrageArmy(setup.values.map(\.rank))
            else { return nil }
            match.localEpochs = epochs
            let commitments = match.commitmentMap(epochs[0], epoch: 0)
            match.initialCommitments[seat] = commitments
            match.readyDigests[seat] = Commitments.teamSetupDigest(gameID: snapshot.gameID, seat: seat, commitments: commitments)
        }
        var ignored = TeamUpdate()
        match.merge(snapshot, from: nil, at: snapshot.updatedAt, update: &ignored)
        if let board = match.localBoard, let epochs = match.localEpochs,
           epochs.count != 1 + board.epoch(of: seat.side, before: board.ply) {
            return nil
        }
        match.updatedAt = snapshot.updatedAt
        self = match
    }

    /// The copy for `recipient` (nil: the copy saved on this Mac).
    public func snapshot(for recipient: Seat?, at now: Date) -> TeamSnapshot {
        let allReady = readyDigests.count == Seat.all.count
        let commitments = initialCommitments.keys.sorted().compactMap { seat -> SeatCommitments? in
            // Which squares we use stays hidden until everyone is locked in.
            if seat == localSeat && recipient != nil && !allReady { return nil }
            guard let map = initialCommitments[seat] else { return nil }
            return SeatCommitments(seat: seat, commitments: TeamMatch.commitmentList(map))
        }
        let shareTeamChat = recipient == nil || recipient?.team == localSeat.team
        var clockValues: [SeatClock] = []
        for seat in Seat.all {
            if let clock = clocks[seat.board] {
                clockValues.append(SeatClock(seat: seat, remaining: max(0, clock.remaining(seat.side, at: now))))
            }
        }
        return TeamSnapshot(
            challenge: challenge,
            author: localSeat,
            confirmed: isConfirmed,
            readyDigests: readyDigests.keys.sorted().map { SeatDigest(seat: $0, digest: readyDigests[$0] ?? "") },
            initialCommitments: commitments,
            boards: boards.keys.sorted().compactMap { id in
                boards[id].map { board in
                    BoardRecord(board: id, entries: board.entries,
                                defenderReveals: board.defenderReveals.keys.sorted().map {
                                    IndexedReveal(index: $0, reveal: board.defenderReveals[$0]!)
                                })
                }
            },
            clocks: clockValues,
            declaredResults: declaredResults,
            result: result,
            drawOffer: drawOffer,
            answeredDrawOffers: answeredDrawOffers.sorted { $0.uuidString < $1.uuidString },
            chat: chat.filter { shareTeamChat || !$0.teamOnly },
            finalReveals: finalReveals.keys.sorted().map { SeatReveals(seat: $0, epochs: finalReveals[$0] ?? []) },
            createdAt: createdAt,
            updatedAt: updatedAt,
            ownSecrets: recipient == nil ? localEpochs.map { $0.map(TeamMatch.revealList) } : nil,
            partnerRanks: recipient == nil ? TeamMatch.rankList(partnerRanks) : nil,
            authorRanks: recipient == localSeat.partner ? TeamMatch.rankList(localRanks) : nil
        )
    }

    // MARK: - Queries

    public var gameID: UUID { challenge.gameID }
    public var timeControl: TimeControl { challenge.timeControl }
    public var hostSeat: Seat { challenge.seat(of: challenge.host.id) ?? Seat(.one, .red) }
    public var isHost: Bool { localSeat == hostSeat }
    public var partnerSeat: Seat { localSeat.partner }

    public func player(_ seat: Seat) -> PlayerInfo {
        challenge.player(at: seat) ?? PlayerInfo(id: "", name: "?")
    }

    public var localPlayer: PlayerInfo { player(localSeat) }

    public func seat(ofPlayer id: String) -> Seat? { challenge.seat(of: id) }

    public var hasStarted: Bool { !boards.isEmpty }

    /// The event that ended the game: the earliest captured Flag, resignation, timeout or agreed draw.
    public var result: TeamResult? {
        var candidates = declaredResults
        for (id, board) in boards {
            if let capture = board.flagCapture {
                let seat = Seat(id, capture.side)
                candidates.append(TeamResult(winner: seat.team, reason: .flagCaptured, seat: seat, at: capture.at))
            }
        }
        return TeamResult.first(of: candidates)
    }

    public var isOver: Bool { result != nil }

    public var phase: MatchPhase {
        if result != nil { return .over }
        return hasStarted ? .playing : .setup
    }

    public var isLocalReady: Bool { localEpochs != nil }
    public func isReady(_ seat: Seat) -> Bool { readyDigests[seat] != nil }

    public func board(_ id: BoardID) -> TeamBoard? { boards[id] }
    public var localBoard: TeamBoard? { boards[localSeat.board] }

    /// Our current ranks.
    public var localRanks: [PieceID: Rank] { (localEpochs?.last ?? [:]).mapValues(\.rank) }

    public var localSetup: Setup? {
        localEpochs?.first.map { secrets in
            Setup(side: localSeat.side, placements: Dictionary(uniqueKeysWithValues: secrets.map { ($0.key.home, $0.value.rank) }))
        }
    }

    /// The partner's setup as their Mac shared it (once they are locked in).
    public var partnerSetup: Setup? {
        guard !partnerRanks.isEmpty else { return nil }
        return Setup(side: partnerSeat.side,
                     placements: Dictionary(partnerRanks.map { ($0.key.home, $0.value) }, uniquingKeysWith: { first, _ in first }))
    }

    /// The ranks shown face up on `board` during play: ours or our partner's.
    public func teamRanks(on board: BoardID) -> [PieceID: Rank] {
        board == localSeat.board ? localRanks : partnerRanks
    }

    /// Every piece's rank after `ply` turns on `board`, once all four armies are revealed.
    public func revealedRanks(on id: BoardID, afterTurns ply: Int) -> [PieceID: Rank]? {
        guard let board = boards[id] else { return nil }
        var ranks: [PieceID: Rank] = [:]
        for side in [Side.red, .blue] {
            guard let epochs = finalReveals[Seat(id, side)] else { return nil }
            // Pieces lost before an epoch began aren't in it, so layer the epochs up to this one.
            let epoch = board.epoch(of: side, before: ply)
            for list in epochs.prefix(epoch + 1) {
                for reveal in list { ranks[reveal.piece] = reveal.secret.rank }
            }
        }
        return ranks
    }

    public var hasFullReveal: Bool { finalReveals.count == Seat.all.count }

    public var isLocalTurn: Bool {
        guard result == nil, let board = localBoard, !board.isOver, !board.isAwaitingBattle else { return false }
        return board.sideToMove == localSeat.side
    }

    public var candidateMoves: [Move] {
        guard isLocalTurn, let board = localBoard else { return [] }
        return Rules.candidateMoves(in: board, for: localSeat.side, ranks: localRanks)
    }

    public var legalMoves: [Move] {
        guard isLocalTurn, let board = localBoard else { return [] }
        return Rules.legalMoves(in: board, for: localSeat.side, ranks: localRanks)
    }

    /// The pieces `seat` can swap in now.
    public func reserve(of seat: Seat) -> [Rank] {
        reserve(of: seat, otherCount: nil, ownCount: nil) ?? []
    }

    /// Our pieces that a swap may replace: all but the Flag.
    public var swappablePieces: [PieceID] {
        guard let board = localBoard else { return [] }
        let ranks = localRanks
        return board.position.alivePieces(of: localSeat.side).map(\.id).filter { ranks[$0] != nil && ranks[$0] != .flag }
    }

    public var canSwap: Bool { isLocalTurn && !reserve(of: localSeat).isEmpty && !swappablePieces.isEmpty }

    /// It's our turn but nothing can move and nothing can be swapped in: we wait for our partner.
    public var isWaitingForPieces: Bool { isLocalTurn && legalMoves.isEmpty && !canSwap }

    public var canOfferDraw: Bool { hasStarted && result == nil && drawOffer == nil }

    // MARK: - Local actions

    /// Host only: all three invited players have joined.
    public mutating func confirm(at now: Date) -> TeamUpdate? {
        guard isHost, !isConfirmed else { return nil }
        isConfirmed = true
        updatedAt = now
        var update = TeamUpdate()
        update.send(.confirmed)
        update.events.append(.confirmed)
        return update
    }

    /// Locks in our setup. It can't be changed afterwards.
    public mutating func lockSetup(_ setup: Setup, at now: Date) -> TeamUpdate? {
        guard result == nil, localEpochs == nil, !hasStarted, setup.side == localSeat.side, setup.isComplete else { return nil }
        var secrets: [PieceID: PieceSecret] = [:]
        for (square, rank) in setup.placements {
            secrets[PieceID(localSeat.side, square)] = PieceSecret(rank: rank, nonce: Commitments.makeNonce())
        }
        localEpochs = [secrets]
        let commitments = commitmentMap(secrets, epoch: 0)
        initialCommitments[localSeat] = commitments
        let digest = Commitments.teamSetupDigest(gameID: gameID, seat: localSeat, commitments: commitments)
        readyDigests[localSeat] = digest
        updatedAt = now
        var update = TeamUpdate()
        update.send(.ready(digest: digest))
        update.send(.teamRanks(TeamMatch.rankList(localRanks), swapped: nil), to: .partner)
        update.events.append(.playerReady(localSeat))
        settle(now: now, update: &update)
        return update
    }

    /// Plays a move for the local player. Returns nil if it isn't our turn or the move is illegal.
    public mutating func playLocalMove(_ move: Move, at now: Date) -> TeamUpdate? {
        guard isLocalTurn, var board = localBoard, let secrets = localEpochs?.last,
              legalMoves.contains(move), let mover = board.position[move.from]
        else { return nil }
        let revealsMover = board.position[move.to] != nil || move.distance > 1
        let reveal = revealsMover ? secrets[mover.id].map { PieceReveal(piece: mover.id, secret: $0) } : nil
        let index = board.ply
        let entry = BoardEntry(action: .move(move, reveal: reveal), at: now, remaining: remainingAfterTurn(at: now))
        guard board.append(entry) else { return nil }
        boards[localSeat.board] = board
        passTurnOnClock(at: now)
        updatedAt = now
        var update = TeamUpdate()
        update.send(.action(board: localSeat.board, index: index, entry: entry))
        update.events.append(.acted(localSeat, isSwap: false))
        settle(now: now, update: &update)
        return update
    }

    /// Swaps `rank` from our reserve in for our piece `piece`. The piece's rank goes to our reserve.
    public mutating func swap(in rank: Rank, for piece: PieceID, at now: Date) -> TeamUpdate? {
        guard isLocalTurn, var board = localBoard, let epochs = localEpochs, let current = epochs.last,
              let old = current[piece], old.rank != .flag, piece.side == localSeat.side,
              board.position.pieces[piece]?.isAlive == true,
              reserve(of: localSeat).contains(rank), let other = boards[localSeat.board.other]
        else { return nil }
        let epoch = epochs.count
        var next: [PieceID: PieceSecret] = [:]
        for alive in board.position.alivePieces(of: localSeat.side) {
            guard let known = current[alive.id] else { return nil }
            next[alive.id] = PieceSecret(rank: alive.id == piece ? rank : known.rank, nonce: Commitments.makeNonce())
        }
        let swap = SwapAction(removed: old.rank, placed: rank, otherBoardCount: other.resolvedCount,
                              commitments: TeamMatch.commitmentList(commitmentMap(next, epoch: epoch)))
        let index = board.ply
        guard isValidSwap(swap, by: localSeat, at: index) else { return nil }
        let entry = BoardEntry(action: .swap(swap), at: now, remaining: remainingAfterTurn(at: now))
        guard board.append(entry) else { return nil }
        boards[localSeat.board] = board
        localEpochs?.append(next)
        passTurnOnClock(at: now)
        updatedAt = now
        var update = TeamUpdate()
        update.send(.action(board: localSeat.board, index: index, entry: entry))
        update.send(.teamRanks(TeamMatch.rankList(localRanks), swapped: piece), to: .partner)
        update.events.append(.acted(localSeat, isSwap: true))
        update.events.append(.swapped(TeamSwapReport(seat: localSeat, removed: old.rank, placed: rank)))
        settle(now: now, update: &update)
        return update
    }

    public mutating func resign(at now: Date) -> TeamUpdate? {
        guard hasStarted, result == nil else { return nil }
        declaredResults.append(TeamResult(winner: localSeat.team.other, reason: .resignation, seat: localSeat, at: now))
        updatedAt = now
        var update = TeamUpdate()
        update.send(.resign(at: now))
        settle(now: now, update: &update)
        return update
    }

    public mutating func offerDraw(at now: Date) -> TeamUpdate? {
        guard canOfferDraw else { return nil }
        let id = UUID()
        drawOffer = TeamDrawOffer(id: id, from: localSeat, accepted: [TeamDrawOffer.Acceptance(seat: localSeat, at: now)])
        updatedAt = now
        var update = TeamUpdate()
        update.send(.drawOffer(id: id, at: now))
        return update
    }

    /// Whether the open draw offer is waiting for our answer.
    public var drawOfferAwaitsUs: Bool {
        guard let offer = drawOffer else { return false }
        return !offer.acceptedSeats.contains(localSeat)
    }

    public mutating func answerDrawOffer(accept: Bool, at now: Date) -> TeamUpdate? {
        guard result == nil, var offer = drawOffer, drawOfferAwaitsUs else { return nil }
        updatedAt = now
        var update = TeamUpdate()
        update.send(.drawAnswer(id: offer.id, accept: accept, at: now))
        if accept {
            offer.accepted.append(TeamDrawOffer.Acceptance(seat: localSeat, at: now))
            drawOffer = offer
        } else {
            answeredDrawOffers.insert(offer.id)
            drawOffer = nil
        }
        settle(now: now, update: &update)
        return update
    }

    public mutating func sendChat(_ text: String, teamOnly: Bool, at now: Date) -> TeamUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let message = TeamChatMessage(senderID: localPlayer.id, text: String(trimmed.prefix(TeamMatch.maxChatLength)),
                                      sentAt: now, teamOnly: teamOnly)
        chat.append(message)
        updatedAt = now
        var update = TeamUpdate()
        update.send(.chat(message), to: teamOnly ? .partner : .everyone)
        return update
    }

    /// Call periodically. Ends the game if our own clock has run out (only a clock's owner
    /// declares that, so everyone agrees).
    public mutating func checkTimeout(at now: Date) -> TeamUpdate? {
        guard result == nil, var clock = clocks[localSeat.board], clock.running == localSeat.side,
              clock.remaining(localSeat.side, at: now) <= 0
        else { return nil }
        clock.stop(at: now)
        clock.set(localSeat.side, 0)
        clocks[localSeat.board] = clock
        declaredResults.append(TeamResult(winner: localSeat.team.other, reason: .timeout, seat: localSeat, at: now))
        updatedAt = now
        var update = TeamUpdate()
        update.send(.timeout(at: now))
        settle(now: now, update: &update)
        return update
    }

    /// Stops every clock (while the table isn't fully connected).
    public mutating func pauseClocks(at now: Date) {
        for id in clocks.keys { clocks[id]?.stop(at: now) }
    }

    /// Runs the clock of the player to move on each board. In 2v2 clocks run from the start.
    public mutating func resumeClocks(at now: Date) {
        guard hasStarted, result == nil else { return }
        for (id, board) in boards where !board.isOver {
            if clocks[id]?.running != board.sideToMove { clocks[id]?.start(board.sideToMove, at: now) }
        }
    }

    // MARK: - Remote messages

    public mutating func receive(_ message: TeamMessage, from sender: Seat, at now: Date) -> TeamUpdate {
        var update = TeamUpdate()
        guard sender != localSeat else { return update }
        switch message {
        case .sync(let snapshot):
            merge(snapshot, from: sender, at: now, update: &update)
            return update

        case .confirmed:
            guard sender == hostSeat, !isConfirmed else { break }
            isConfirmed = true
            update.events.append(.confirmed)

        case .cancelled, .leaving:
            break  // handled by the app

        case .ready(let digest):
            guard readyDigests[sender] == nil, !hasStarted, result == nil else { break }
            readyDigests[sender] = digest
            update.events.append(.playerReady(sender))

        case .commitments(let list):
            acceptCommitments(list, of: sender)

        case let .action(board, index, entry):
            pending.append(.action(board, index, entry, sender: sender))

        case let .defenderReveal(board, index, reveal):
            pending.append(.reveal(board, index, reveal, sender: sender))

        case let .teamRanks(list, swapped):
            guard sender == partnerSeat else { break }
            partnerRanks = TeamMatch.rankMap(list, side: sender.side)
            if let piece = swapped { update.events.append(.partnerSwapped(piece)) }

        case .resign(let at):
            guard hasStarted else { break }
            addDeclared(TeamResult(winner: sender.team.other, reason: .resignation, seat: sender, at: at))

        case .timeout(let at):
            guard hasStarted else { break }
            if var clock = clocks[sender.board] {
                clock.stop(at: now)
                clock.set(sender.side, 0)
                clocks[sender.board] = clock
            }
            addDeclared(TeamResult(winner: sender.team.other, reason: .timeout, seat: sender, at: at))

        case let .drawOffer(id, at):
            guard hasStarted, result == nil, drawOffer == nil, !answeredDrawOffers.contains(id) else { break }
            drawOffer = TeamDrawOffer(id: id, from: sender, accepted: [TeamDrawOffer.Acceptance(seat: sender, at: at)])
            update.events.append(.drawOffered(sender))

        case let .drawAnswer(id, accept, at):
            guard var offer = drawOffer, offer.id == id, !offer.acceptedSeats.contains(sender) else { break }
            if accept {
                offer.accepted.append(TeamDrawOffer.Acceptance(seat: sender, at: at))
                drawOffer = offer
            } else {
                answeredDrawOffers.insert(id)
                drawOffer = nil
                update.events.append(.drawDeclined(sender))
            }

        case .chat(let message):
            guard message.senderID == player(sender).id, !message.teamOnly || sender == partnerSeat,
                  !chat.contains(where: { $0.id == message.id })
            else { break }
            var incoming = message
            incoming.text = String(incoming.text.prefix(TeamMatch.maxChatLength))
            chat.append(incoming)
            update.events.append(.chatReceived(incoming))

        case .finalReveal(let epochs):
            if finalReveals[sender] == nil { finalReveals[sender] = epochs }
        }
        updatedAt = max(updatedAt, now)
        settle(now: now, update: &update)
        return update
    }

    // MARK: - Reconciliation

    /// Merges another player's snapshot (or, with `sender` nil, our own saved copy). The board
    /// logs are append-only, so the longer one wins when it extends ours; every entry taken from
    /// it is checked like a live message.
    mutating func merge(_ remote: TeamSnapshot, from sender: Seat?, at now: Date, update: inout TeamUpdate) {
        guard remote.challenge == challenge else { return }
        if let sender = sender, remote.author != sender { return }
        let restoring = sender == nil
        let awaitingBefore = boards.compactMapValues { $0.isAwaitingBattle ? $0.ply - 1 : nil }
        let wasConfirmed = isConfirmed

        if remote.confirmed { isConfirmed = true }
        for entry in remote.readyDigests where readyDigests[entry.seat] == nil && (restoring || entry.seat != localSeat) {
            readyDigests[entry.seat] = entry.digest
            if !restoring { update.events.append(.playerReady(entry.seat)) }
        }
        for entry in remote.initialCommitments where restoring || entry.seat != localSeat {
            acceptCommitments(entry.commitments, of: entry.seat)
        }
        if restoring, let ranks = remote.partnerRanks {
            partnerRanks = TeamMatch.rankMap(ranks, side: partnerSeat.side)
        }
        if sender == partnerSeat, let ranks = remote.authorRanks {
            partnerRanks = TeamMatch.rankMap(ranks, side: partnerSeat.side)
        }
        startIfPossible(now: now, update: &update)

        for record in remote.boards {
            let local = boards[record.board]
            let count = local?.ply ?? 0
            if let local = local {
                guard record.entries.count >= count, Array(record.entries.prefix(count)) == local.entries else { continue }
            }
            for (index, entry) in record.entries.enumerated() where index >= count {
                pending.append(.action(record.board, index, entry, sender: nil))
            }
            for item in record.defenderReveals {
                pending.append(.reveal(record.board, item.index, item.reveal, sender: nil))
            }
        }

        for declared in remote.declaredResults where !declaredResults.contains(declared) {
            // Nobody else speaks for our own seat.
            if !restoring, declared.seat == localSeat { continue }
            addDeclared(declared)
        }

        answeredDrawOffers.formUnion(remote.answeredDrawOffers)
        if let offer = drawOffer, answeredDrawOffers.contains(offer.id) { drawOffer = nil }
        if let offer = remote.drawOffer, !answeredDrawOffers.contains(offer.id) {
            if var mine = drawOffer {
                if mine.id == offer.id {
                    for acceptance in offer.accepted where !mine.acceptedSeats.contains(acceptance.seat) {
                        mine.accepted.append(acceptance)
                    }
                    drawOffer = mine
                }
            } else if result == nil {
                drawOffer = offer
            }
        }

        var known = Set(chat.map(\.id))
        for message in remote.chat where !known.contains(message.id) {
            if message.teamOnly && seat(ofPlayer: message.senderID)?.team != localSeat.team { continue }
            chat.append(message)
            known.insert(message.id)
        }
        chat.sort { ($0.sentAt, $0.id.uuidString) < ($1.sentAt, $1.id.uuidString) }

        for entry in remote.finalReveals where finalReveals[entry.seat] == nil && (restoring || entry.seat != localSeat) {
            finalReveals[entry.seat] = entry.epochs
        }

        settle(now: now, update: &update)

        // Each player is authoritative for their own clock.
        for value in remote.clocks where restoring || value.seat == sender {
            guard var clock = clocks[value.seat.board] else { continue }
            clock.stop(at: now)
            clock.set(value.seat.side, value.remaining)
            clocks[value.seat.board] = clock
        }

        for (id, index) in awaitingBefore {
            if let board = boards[id], index < board.turns.count, board.turns[index].outcome != nil,
               let report = battleReport(id, index) {
                update.events.append(.battle(report))
            }
        }
        if !restoring {
            if !wasConfirmed && isConfirmed { update.events.append(.confirmed) }
            update.events.append(.resynced)
        }
        updatedAt = max(updatedAt, remote.updatedAt)
    }

    // MARK: - Settling

    /// Runs after every change: starts the game when everyone is committed, applies whatever
    /// waiting turns and reveals now fit, answers attacks on our pieces, and checks for the end.
    private mutating func settle(now: Date, update: inout TeamUpdate) {
        if readyDigests.count == Seat.all.count, !sentCommitments, let map = initialCommitments[localSeat], localEpochs != nil {
            sentCommitments = true
            update.send(.commitments(TeamMatch.commitmentList(map)))
        }
        startIfPossible(now: now, update: &update)
        var progress = true
        while progress {
            progress = drainPending(now: now, update: &update)
            if answerAttacks(update: &update) { progress = true }
        }
        if pending.count > TeamMatch.maxPending { pending.removeFirst(pending.count - TeamMatch.maxPending) }
        checkDraw()
        checkResult(now: now, update: &update)
        runVerification(update: &update)
    }

    private mutating func startIfPossible(now: Date, update: inout TeamUpdate) {
        guard boards.isEmpty, localEpochs != nil, initialCommitments.count == Seat.all.count else { return }
        for id in BoardID.allCases {
            var pieces: [PieceID] = []
            for side in [Side.red, .blue] {
                if let map = initialCommitments[Seat(id, side)] { pieces += map.keys }
            }
            boards[id] = TeamBoard(board: id, pieces: pieces)
        }
        for id in BoardID.allCases { clocks[id]?.start(.red, at: now) }
        updatedAt = now
        update.events.append(.gameStarted)
    }

    /// Applies waiting items until nothing more fits. Returns whether anything was applied.
    private mutating func drainPending(now: Date, update: inout TeamUpdate) -> Bool {
        var appliedAny = false
        var progress = true
        while progress && !pending.isEmpty {
            progress = false
            var remaining: [Pending] = []
            for item in pending {
                switch apply(item, now: now, update: &update) {
                case .applied:
                    progress = true
                    appliedAny = true
                case .notYet:
                    remaining.append(item)
                case .invalid:
                    break
                }
            }
            pending = remaining
        }
        return appliedAny
    }

    private mutating func apply(_ item: Pending, now: Date, update: inout TeamUpdate) -> Outcome {
        switch item {
        case let .action(id, index, entry, sender):
            guard var board = boards[id] else { return .notYet }
            if index < board.ply { return .invalid }
            if index > board.ply || board.isAwaitingBattle { return .notYet }
            let author = Seat(id, TeamBoard.author(ofEntry: index))
            if let sender = sender, sender != author { return .invalid }
            if author == localSeat && sender != nil { return .invalid }
            switch entry.action {
            case let .move(_, reveal):
                if let reveal = reveal, !isValidReveal(reveal, of: author, on: board, at: index) { return .invalid }
            case .swap(let swap):
                guard let other = boards[id.other] else { return .notYet }
                if swap.otherBoardCount > other.resolvedCount { return .notYet }
                guard isValidSwap(swap, by: author, at: index) else { return .invalid }
            }
            guard board.append(entry) else { return .invalid }
            boards[id] = board
            if var clock = clocks[id] {
                clock.stop(at: now)
                if let remaining = entry.remaining { clock.set(author.side, remaining) }
                if !board.isOver { clock.start(author.side.opposite, at: now) }
                clocks[id] = clock
            }
            if sender != nil {
                if case .swap(let swap) = entry.action {
                    update.events.append(.acted(author, isSwap: true))
                    update.events.append(.swapped(TeamSwapReport(seat: author, removed: swap.removed, placed: swap.placed)))
                } else {
                    update.events.append(.acted(author, isSwap: false))
                }
            }
            return .applied

        case let .reveal(id, index, reveal, sender):
            guard var board = boards[id] else { return .notYet }
            if index >= board.ply { return .notYet }
            guard index == board.ply - 1, board.isAwaitingBattle, let defender = board.turns[index].defender else { return .invalid }
            let defenderSeat = Seat(id, defender.side)
            if let sender = sender, sender != defenderSeat { return .invalid }
            guard reveal.piece == defender, isValidReveal(reveal, of: defenderSeat, on: board, at: index),
                  board.resolve(index: index, defender: reveal)
            else { return .invalid }
            boards[id] = board
            if sender != nil, let report = battleReport(id, index) { update.events.append(.battle(report)) }
            return .applied
        }
    }

    /// Our piece was attacked: answer with its rank, proven against the epoch in force.
    private mutating func answerAttacks(update: inout TeamUpdate) -> Bool {
        let id = localSeat.board
        guard var board = boards[id], board.isAwaitingBattle else { return false }
        let index = board.ply - 1
        guard let defender = board.turns[index].defender, defender.side == localSeat.side, let epochs = localEpochs else { return false }
        let epoch = board.epoch(of: localSeat.side, before: index)
        guard epoch < epochs.count, let secret = epochs[epoch][defender] else { return false }
        let reveal = PieceReveal(piece: defender, secret: secret)
        guard board.resolve(index: index, defender: reveal) else { return false }
        boards[id] = board
        update.send(.defenderReveal(board: id, index: index, reveal: reveal))
        if let report = battleReport(id, index) { update.events.append(.battle(report)) }
        return true
    }

    private mutating func checkDraw() {
        guard let offer = drawOffer, offer.acceptedSeats.count == Seat.all.count else { return }
        answeredDrawOffers.insert(offer.id)
        drawOffer = nil
        let at = offer.accepted.map(\.at).max() ?? Date()
        addDeclared(TeamResult(winner: nil, reason: .agreement, seat: nil, at: at))
    }

    private mutating func addDeclared(_ declared: TeamResult) {
        guard !declaredResults.contains(declared) else { return }
        switch declared.reason {
        case .resignation, .timeout:
            guard let seat = declared.seat, declared.winner == seat.team.other else { return }
        case .agreement:
            guard declared.winner == nil else { return }
        case .flagCaptured:
            return  // follows from the boards
        }
        declaredResults.append(declared)
    }

    private mutating func checkResult(now: Date, update: inout TeamUpdate) {
        let current = result
        guard current != reportedResult else { return }
        reportedResult = current
        guard let current = current else { return }
        pauseClocks(at: now)
        drawOffer = nil
        update.events.append(.gameOver(current))
        // The game is over: show everyone our whole history of ranks so all can review and check it.
        if finalReveals[localSeat] == nil, let epochs = localEpochs {
            let reveals = epochs.map(TeamMatch.revealList)
            finalReveals[localSeat] = reveals
            update.send(.finalReveal(reveals))
        }
    }

    // MARK: - Verification

    private mutating func runVerification(update: inout TeamUpdate) {
        guard hasStarted, hasFullReveal else { return }
        let key = boards.values.reduce(0) { $0 + $1.ply * 2 + $1.defenderReveals.count }
        guard key != verifiedKey else { return }
        // Wait until each revealed history lines up with the log we hold.
        for seat in Seat.all {
            guard let board = boards[seat.board], let epochs = finalReveals[seat],
                  epochs.count == 1 + board.epoch(of: seat.side, before: board.ply)
            else { return }
        }
        verifiedKey = key
        let previous = verification
        var outcome = Verification.passed
        for seat in Seat.all {
            if let failure = verify(seat) {
                outcome = .failed(failure)
                break
            }
        }
        verification = outcome
        if case .failed(let reason) = outcome, previous != outcome { update.events.append(.verificationFailed(reason)) }
    }

    /// Replays `seat`'s board with their revealed ranks: a standard army, each epoch opening its
    /// commitments, every swap changing exactly one piece as announced, every move legal.
    func verify(_ seat: Seat) -> String? {
        let name = player(seat).name
        guard let board = boards[seat.board], let epochs = finalReveals[seat] else { return "\(name)'s army wasn't revealed." }
        var maps: [[PieceID: Rank]] = []
        for (epoch, list) in epochs.enumerated() {
            guard let commitments = commitments(of: seat, epoch: epoch, on: board) else {
                return "\(name)'s revealed ranks don't line up with their swaps."
            }
            var map: [PieceID: Rank] = [:]
            for reveal in list {
                let digest = Commitments.teamDigest(gameID: gameID, board: seat.board, epoch: epoch, piece: reveal.piece, secret: reveal.secret)
                guard commitments[reveal.piece] == digest else { return "\(name)'s revealed ranks don't match what they committed to." }
                map[reveal.piece] = reveal.secret.rank
            }
            guard Set(map.keys) == Set(commitments.keys) else { return "\(name) didn't reveal every piece." }
            maps.append(map)
        }
        guard let setup = maps.first, Rank.isBarrageArmy(setup.values) else {
            return "\(name)'s army isn't the standard eight Barrage pieces."
        }
        var epoch = 0
        var ranks = setup
        for (index, turn) in board.turns.enumerated() {
            let number = "turn \(index + 1) on \(seat.board.name)"
            if turn.side == seat.side {
                if let swap = turn.swap {
                    guard epoch + 1 < maps.count else { return "\(name)'s revealed ranks don't line up with their swaps." }
                    let next = maps[epoch + 1]
                    let alive = board.positions[index].alivePieces(of: seat.side).map(\.id)
                    let changed = alive.filter { ranks[$0] != next[$0] }
                    if swap.removed == swap.placed {
                        guard changed.isEmpty, alive.contains(where: { ranks[$0] == swap.removed }) else {
                            return "\(name)'s swap (\(number)) doesn't match their army."
                        }
                    } else {
                        guard changed.count == 1, ranks[changed[0]] == swap.removed, next[changed[0]] == swap.placed else {
                            return "\(name)'s swap (\(number)) doesn't match their army."
                        }
                    }
                    for (piece, rank) in next { ranks[piece] = rank }
                    epoch += 1
                } else if let move = turn.move, let piece = turn.piece {
                    guard let rank = ranks[piece], rank.isMovable, move.distance == 1 || rank == .scout,
                          turn.moverRank == nil || turn.moverRank == rank
                    else { return "\(name)'s move \(move) (\(number)) wasn't legal for the piece that made it." }
                }
            } else if let defender = turn.defender, defender.side == seat.side, let shown = turn.defenderRank {
                guard ranks[defender] == shown else { return "\(name)'s defender (\(number)) doesn't match their army." }
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// The reserve of `seat` judged against the first `otherCount` entries of the other board and
    /// the first `ownCount` of its own (nil: everything known). Nil if the swaps don't add up.
    func reserve(of seat: Seat, otherCount: Int?, ownCount: Int?) -> [Rank]? {
        guard let own = boards[seat.board], let other = boards[seat.board.other] else { return [] }
        var pool = other.losses(of: seat.side, inFirst: otherCount ?? other.resolvedCount)
        for swap in own.swaps(of: seat.side, inFirst: ownCount ?? own.ply) {
            guard let index = pool.firstIndex(of: swap.placed) else { return nil }
            pool.remove(at: index)
            pool.append(swap.removed)
        }
        return pool.sorted { $0.order < $1.order }
    }

    /// Public checks of a swap: neither rank is the Flag, the piece is in the reserve, and the
    /// fresh commitments cover exactly the swapper's pieces on the board.
    private func isValidSwap(_ swap: SwapAction, by seat: Seat, at index: Int) -> Bool {
        guard swap.removed != .flag, swap.placed != .flag,
              let board = boards[seat.board], let other = boards[seat.board.other],
              index == board.ply, swap.otherBoardCount <= other.resolvedCount
        else { return false }
        if let previous = board.swaps(of: seat.side, inFirst: index).last, swap.otherBoardCount < previous.otherBoardCount {
            return false
        }
        guard let pool = reserve(of: seat, otherCount: swap.otherBoardCount, ownCount: index), pool.contains(swap.placed) else {
            return false
        }
        let alive = Set(board.position.alivePieces(of: seat.side).map(\.id))
        var covered = Set<PieceID>()
        for commitment in swap.commitments {
            guard alive.contains(commitment.piece), covered.insert(commitment.piece).inserted, !commitment.digest.isEmpty else { return false }
        }
        return covered == alive
    }

    private func isValidReveal(_ reveal: PieceReveal, of seat: Seat, on board: TeamBoard, at index: Int) -> Bool {
        guard reveal.piece.side == seat.side else { return false }
        let epoch = board.epoch(of: seat.side, before: index)
        guard let digest = commitments(of: seat, epoch: epoch, on: board)?[reveal.piece] else { return false }
        return Commitments.teamDigest(gameID: gameID, board: seat.board, epoch: epoch, piece: reveal.piece, secret: reveal.secret) == digest
    }

    private func commitments(of seat: Seat, epoch: Int, on board: TeamBoard) -> [PieceID: String]? {
        if epoch == 0 { return initialCommitments[seat] }
        guard let list = board.swapCommitments(of: seat.side, epoch: epoch) else { return nil }
        return Dictionary(list.map { ($0.piece, $0.digest) }, uniquingKeysWith: { first, _ in first })
    }

    private mutating func acceptCommitments(_ list: [PieceCommitment], of seat: Seat) {
        guard initialCommitments[seat] == nil, let digest = readyDigests[seat],
              let map = TeamMatch.validCommitments(list, seat: seat),
              Commitments.teamSetupDigest(gameID: gameID, seat: seat, commitments: map) == digest
        else { return }
        initialCommitments[seat] = map
    }

    private func remainingAfterTurn(at now: Date) -> Double? {
        guard var clock = clocks[localSeat.board] else { return nil }
        clock.stop(at: now)
        clock.add(Double(timeControl.incrementSeconds), to: localSeat.side)
        return clock.remaining(localSeat.side, at: now)
    }

    private mutating func passTurnOnClock(at now: Date) {
        guard var clock = clocks[localSeat.board] else { return }
        clock.stop(at: now)
        clock.add(Double(timeControl.incrementSeconds), to: localSeat.side)
        if localBoard?.isOver == false { clock.start(localSeat.side.opposite, at: now) }
        clocks[localSeat.board] = clock
    }

    private func battleReport(_ id: BoardID, _ index: Int) -> TeamBattleReport? {
        guard let board = boards[id], index >= 0, index < board.turns.count else { return nil }
        let turn = board.turns[index]
        guard let outcome = turn.outcome, let attacker = turn.moverRank, let defender = turn.defenderRank, let move = turn.move else {
            return nil
        }
        return TeamBattleReport(board: id, index: index, attackerSide: turn.side, attackerRank: attacker,
                                defenderRank: defender, outcome: outcome, square: move.to)
    }

    func commitmentMap(_ secrets: [PieceID: PieceSecret], epoch: Int) -> [PieceID: String] {
        secrets.reduce(into: [PieceID: String]()) { result, entry in
            result[entry.key] = Commitments.teamDigest(gameID: gameID, board: localSeat.board, epoch: epoch,
                                                       piece: entry.key, secret: entry.value)
        }
    }

    static func commitmentList(_ map: [PieceID: String]) -> [PieceCommitment] {
        map.sorted { $0.key < $1.key }.map { PieceCommitment(piece: $0.key, digest: $0.value) }
    }

    static func revealList(_ secrets: [PieceID: PieceSecret]) -> [PieceReveal] {
        secrets.sorted { $0.key < $1.key }.map { PieceReveal(piece: $0.key, secret: $0.value) }
    }

    static func rankList(_ ranks: [PieceID: Rank]) -> [PieceRank] {
        ranks.sorted { $0.key < $1.key }.map { PieceRank(piece: $0.key, rank: $0.value) }
    }

    static func rankMap(_ list: [PieceRank], side: Side) -> [PieceID: Rank] {
        var map: [PieceID: Rank] = [:]
        for entry in list where entry.piece.side == side { map[entry.piece] = entry.rank }
        return map
    }

    /// Eight distinct pieces, all on the seat's setup rows.
    static func validCommitments(_ list: [PieceCommitment], seat: Seat) -> [PieceID: String]? {
        var map: [PieceID: String] = [:]
        for commitment in list {
            guard commitment.piece.side == seat.side, commitment.piece.home.isHome(of: seat.side), map[commitment.piece] == nil else {
                return nil
            }
            map[commitment.piece] = commitment.digest
        }
        return map.count == Rank.barrageArmy.count ? map : nil
    }
}
