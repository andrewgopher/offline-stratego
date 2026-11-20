import Foundation

/// Something the UI may want to react to (sounds, banners, the battle card).
public enum MatchEvent: Hashable {
    case opponentReady
    case gameStarted
    case moved(byLocalPlayer: Bool)
    case battle(BattleReport)
    /// The side to move has no legal move; the result follows once both armies are revealed.
    case stuck(Side)
    case gameOver(GameResult)
    case drawOffered
    case drawDeclined
    case chatReceived(ChatMessage)
    case resynced
    /// The final reveal doesn't match the game that was played.
    case verificationFailed(String)
}

public struct BattleReport: Hashable {
    public let ply: Int
    public let attackerSide: Side
    public let attackerRank: Rank
    public let defenderRank: Rank
    public let outcome: BattleOutcome
    public let square: Square

    public var defenderSide: Side { attackerSide.opposite }
}

/// Result of applying a local action or a remote message: what to send and what happened.
public struct MatchUpdate {
    public var outgoing: [GameMessage] = []
    public var events: [MatchEvent] = []
    public init() {}
}

public enum MatchPhase: Hashable {
    /// Players are arranging their armies.
    case setup
    case playing
    case over
}

/// The post-game check of the opponent's revealed army against the game that was played.
public enum Verification: Hashable {
    case passed
    case failed(String)
}

/// One game between the local player and an opponent, as seen from one Mac.
///
/// Both Macs run an identical `Match`, but each knows only its own ranks plus those the
/// opponent has revealed (with proof, see `Commitments`). Each side is authoritative for its
/// own moves, its own clock and its own ranks: an attack carries the attacker's rank, the
/// defender answers with theirs, and both resolve the battle the same way. When the game ends
/// both reveal everything and check the whole game. On (re)connect both exchange a public
/// snapshot and run the same deterministic `merge`.
public struct Match {
    public let gameID: UUID
    public private(set) var red: PlayerInfo
    public private(set) var blue: PlayerInfo
    public let localSide: Side
    public let timeControl: TimeControl
    public let createdAt: Date
    public private(set) var updatedAt: Date

    /// Our locked-in setup (rank and nonce per piece); nil while still arranging.
    public private(set) var localSecrets: [PieceID: PieceSecret]?
    public private(set) var remoteReadyDigest: String?
    public private(set) var remoteCommitments: [PieceID: String]?
    /// Opponent ranks revealed so far, each checked against its commitment.
    public private(set) var remoteSecrets: [PieceID: PieceSecret] = [:]

    /// Nil until both setups are locked in and exchanged.
    public private(set) var game: Game?
    public private(set) var clock: GameClock?
    public private(set) var result: GameResult?
    public private(set) var stuckSide: Side?
    public private(set) var chat: [ChatMessage] = []
    /// Which side has an open draw offer.
    public private(set) var drawOfferFrom: Side?
    public private(set) var verification: Verification?

    public static let maxChatLength = 500

    // MARK: - Creating

    /// Builds a new game from a challenge. Call on both Macs with the same challenge.
    public init(challenge: Challenge, accepter: PlayerInfo, localPlayerID: String, now: Date) {
        gameID = challenge.gameID
        if challenge.challengerSide == .red {
            red = challenge.challenger
            blue = accepter
        } else {
            red = accepter
            blue = challenge.challenger
        }
        localSide = localPlayerID == red.id ? .red : .blue
        timeControl = challenge.timeControl
        createdAt = now
        updatedAt = now
        if let initial = challenge.timeControl.initialSeconds {
            clock = GameClock(red: Double(initial), blue: Double(initial))
        }
    }

    /// Restores a saved game. Fails if the local player isn't in it or it doesn't replay.
    public init?(snapshot: MatchSnapshot, localPlayerID: String) {
        guard let side = snapshot.side(of: localPlayerID) else { return nil }
        gameID = snapshot.gameID
        red = snapshot.red
        blue = snapshot.blue
        localSide = side
        timeControl = snapshot.timeControl
        createdAt = snapshot.createdAt
        updatedAt = snapshot.updatedAt

        let mine = snapshot.setup(side)
        if !mine.reveals.isEmpty {
            var secrets: [PieceID: PieceSecret] = [:]
            for reveal in mine.reveals { secrets[reveal.piece] = reveal.secret }
            guard secrets.keys.allSatisfy({ $0.side == side && $0.home.isHome(of: side) }),
                  Rank.isBarrageArmy(secrets.values.map(\.rank))
            else { return nil }
            localSecrets = secrets
        }

        let theirs = snapshot.setup(side.opposite)
        remoteReadyDigest = theirs.readyDigest
        if let list = theirs.commitments, let digest = remoteReadyDigest,
           let map = Match.validCommitments(list, side: side.opposite),
           Commitments.setupDigest(gameID: gameID, commitments: map) == digest {
            remoteCommitments = map
        }
        for reveal in theirs.reveals where isValidRemoteReveal(reveal) {
            remoteSecrets[reveal.piece] = reveal.secret
        }

        result = snapshot.result
        stuckSide = snapshot.stuckSide
        chat = snapshot.chat
        if let initial = snapshot.timeControl.initialSeconds {
            clock = GameClock(red: snapshot.redRemaining ?? Double(initial),
                              blue: snapshot.blueRemaining ?? Double(initial))
        }
        if localSecrets != nil, remoteCommitments != nil {
            guard let replayed = Game(pieces: allPieceIDs, ranks: knownRanks, moves: snapshot.moves) else { return nil }
            game = replayed
        }
        var ignored = MatchUpdate()
        runVerification(update: &ignored)
    }

    /// The copy saved on this Mac, including our full setup.
    public func snapshot(at now: Date) -> MatchSnapshot {
        makeSnapshot(at: now, forOpponent: false)
    }

    /// The copy sent to the opponent: only ranks they are entitled to know.
    public func publicSnapshot(at now: Date) -> MatchSnapshot {
        makeSnapshot(at: now, forOpponent: true)
    }

    private func makeSnapshot(at now: Date, forOpponent: Bool) -> MatchSnapshot {
        var mine = SideSetupRecord()
        if let secrets = localSecrets {
            mine.readyDigest = localReadyDigest
            if !forOpponent || remoteReadyDigest != nil { mine.commitments = localCommitmentList }
            let shown = forOpponent ? publiclyRevealedLocalPieces : Set(secrets.keys)
            mine.reveals = reveals(of: shown)
        }
        let theirs = SideSetupRecord(
            readyDigest: remoteReadyDigest,
            commitments: remoteCommitments.map { map in
                map.sorted { $0.key < $1.key }.map { PieceCommitment(piece: $0.key, digest: $0.value) }
            },
            reveals: remoteSecrets.sorted { $0.key < $1.key }.map { PieceReveal(piece: $0.key, secret: $0.value) }
        )
        return MatchSnapshot(
            gameID: gameID,
            red: red,
            blue: blue,
            timeControl: timeControl,
            redSetup: localSide == .red ? mine : theirs,
            blueSetup: localSide == .blue ? mine : theirs,
            moves: game?.moves ?? [],
            result: result,
            stuckSide: stuckSide,
            redRemaining: clock.map { max(0, $0.remaining(.red, at: now)) },
            blueRemaining: clock.map { max(0, $0.remaining(.blue, at: now)) },
            chat: chat,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Queries

    public var opponentSide: Side { localSide.opposite }
    public func player(_ side: Side) -> PlayerInfo { side == .red ? red : blue }
    public var localPlayer: PlayerInfo { player(localSide) }
    public var opponent: PlayerInfo { player(opponentSide) }

    public var isOver: Bool { result != nil }
    public var phase: MatchPhase {
        if result != nil { return .over }
        return game == nil ? .setup : .playing
    }

    public var isLocalReady: Bool { localSecrets != nil }
    public var isOpponentReady: Bool { remoteReadyDigest != nil }

    /// Our locked-in setup, if any.
    public var localSetup: Setup? {
        localSecrets.map { secrets in
            Setup(side: localSide, placements: Dictionary(uniqueKeysWithValues: secrets.map { ($0.key.home, $0.value.rank) }))
        }
    }

    public var isAwaitingBattle: Bool { game?.isAwaitingBattle ?? false }

    public var isLocalTurn: Bool {
        guard result == nil, stuckSide == nil, let game = game, !game.isAwaitingBattle else { return false }
        return game.position.sideToMove == localSide
    }

    public var legalMoves: [Move] {
        guard isLocalTurn, let game = game else { return [] }
        return Rules.legalMoves(in: game, for: localSide)
    }

    /// Every rank this Mac knows: all of ours, and the opponent's revealed ones.
    public var knownRanks: [PieceID: Rank] {
        var ranks: [PieceID: Rank] = [:]
        for (id, secret) in localSecrets ?? [:] { ranks[id] = secret.rank }
        for (id, secret) in remoteSecrets { ranks[id] = secret.rank }
        return ranks
    }

    /// Both armies are fully known (normally only after the game ends).
    public var hasFullReveal: Bool {
        guard localSecrets != nil, let commitments = remoteCommitments else { return false }
        return remoteSecrets.count == commitments.count
    }

    public var canOfferDraw: Bool {
        result == nil && game != nil && stuckSide == nil && drawOfferFrom == nil
    }

    var localReadyDigest: String? {
        localCommitments.map { Commitments.setupDigest(gameID: gameID, commitments: $0) }
    }

    var localCommitments: [PieceID: String]? {
        localSecrets.map { secrets in
            secrets.reduce(into: [PieceID: String]()) { result, entry in
                result[entry.key] = Commitments.digest(gameID: gameID, piece: entry.key, secret: entry.value)
            }
        }
    }

    var localCommitmentList: [PieceCommitment] {
        (localCommitments ?? [:]).sorted { $0.key < $1.key }.map { PieceCommitment(piece: $0.key, digest: $0.value) }
    }

    var allPieceIDs: [PieceID] {
        Array((localSecrets ?? [:]).keys) + Array((remoteCommitments ?? [:]).keys)
    }

    /// Our pieces whose ranks the opponent is entitled to know.
    var publiclyRevealedLocalPieces: Set<PieceID> {
        guard let secrets = localSecrets else { return [] }
        if result != nil || stuckSide == localSide { return Set(secrets.keys) }
        guard let game = game else { return [] }
        return Set(game.position.pieces.values.filter { $0.side == localSide && $0.isRevealed }.map(\.id))
    }

    private func reveals(of pieces: Set<PieceID>) -> [PieceReveal] {
        guard let secrets = localSecrets else { return [] }
        return pieces.sorted().compactMap { id in secrets[id].map { PieceReveal(piece: id, secret: $0) } }
    }

    private var fullLocalReveal: [PieceReveal] {
        reveals(of: Set((localSecrets ?? [:]).keys))
    }

    // MARK: - Local actions

    /// Locks in our setup. It can't be changed afterwards.
    public mutating func lockSetup(_ setup: Setup, at now: Date) -> MatchUpdate? {
        guard result == nil, localSecrets == nil, setup.side == localSide, setup.isComplete else { return nil }
        var secrets: [PieceID: PieceSecret] = [:]
        for (square, rank) in setup.placements {
            secrets[PieceID(localSide, square)] = PieceSecret(rank: rank, nonce: Commitments.makeNonce())
        }
        localSecrets = secrets
        updatedAt = now
        var update = MatchUpdate()
        if let digest = localReadyDigest { update.outgoing.append(.ready(digest: digest)) }
        if remoteReadyDigest != nil { update.outgoing.append(.commitments(localCommitmentList)) }
        startIfPossible(now: now, update: &update)
        return update
    }

    /// Plays a move for the local player. Returns nil if it isn't our turn or the move is illegal.
    public mutating func playLocalMove(_ move: Move, at now: Date) -> MatchUpdate? {
        guard isLocalTurn, var current = game, let secrets = localSecrets,
              Rules.legalMoves(in: current, for: localSide).contains(move),
              let mover = current.position[move.from]
        else { return nil }
        let revealsMover = current.position[move.to] != nil || move.distance > 1
        let reveal = revealsMover ? secrets[mover.id].map { PieceReveal(piece: mover.id, secret: $0) } : nil
        let ply = current.ply
        guard current.apply(move) else { return nil }
        game = current

        var remaining: Double?
        if var c = clock {
            c.stop(at: now)
            // No time is used before the first move, so it earns no increment.
            if ply > 0 { c.add(Double(timeControl.incrementSeconds), to: localSide) }
            remaining = c.remaining(localSide, at: now)
            clock = c
        }
        if drawOfferFrom == opponentSide { drawOfferFrom = nil }  // moving declines their offer

        var update = MatchUpdate()
        update.outgoing.append(.move(ply: ply, move: move, reveal: reveal, remaining: remaining))
        update.events.append(.moved(byLocalPlayer: true))
        afterMove(now: now, update: &update)
        return update
    }

    public mutating func resign(at now: Date) -> MatchUpdate? {
        guard result == nil else { return nil }
        var update = MatchUpdate()
        update.outgoing.append(.resign(side: localSide))
        finish(GameResult(winner: opponentSide, reason: .resignation), now: now, update: &update)
        return update
    }

    public mutating func offerDraw(at now: Date) -> MatchUpdate? {
        guard canOfferDraw else { return nil }
        drawOfferFrom = localSide
        updatedAt = now
        var update = MatchUpdate()
        update.outgoing.append(.drawOffer)
        return update
    }

    public mutating func respondToDrawOffer(accept: Bool, at now: Date) -> MatchUpdate? {
        guard result == nil, drawOfferFrom == opponentSide else { return nil }
        drawOfferFrom = nil
        var update = MatchUpdate()
        if accept {
            update.outgoing.append(.drawAccepted)
            finish(GameResult(winner: nil, reason: .agreement), now: now, update: &update)
        } else {
            update.outgoing.append(.drawDeclined)
            updatedAt = now
        }
        return update
    }

    public mutating func sendChat(_ text: String, at now: Date) -> MatchUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let message = ChatMessage(senderID: localPlayer.id, text: String(trimmed.prefix(Match.maxChatLength)), sentAt: now)
        chat.append(message)
        updatedAt = now
        var update = MatchUpdate()
        update.outgoing.append(.chat(message))
        return update
    }

    /// Call periodically. Ends the game if the local player's own clock has run out.
    /// Only the owner of a clock declares it, so both sides always agree.
    public mutating func checkTimeout(at now: Date) -> MatchUpdate? {
        guard result == nil, var c = clock, c.running == localSide, c.remaining(localSide, at: now) <= 0 else { return nil }
        c.stop(at: now)
        c.set(localSide, 0)
        clock = c
        var update = MatchUpdate()
        update.outgoing.append(.timeout(side: localSide))
        finish(GameResult(winner: opponentSide, reason: .timeout), now: now, update: &update)
        return update
    }

    /// Stops the clock (e.g. while disconnected).
    public mutating func pauseClock(at now: Date) {
        clock?.stop(at: now)
    }

    /// Restarts the clock of the side to move. Clocks only run after Red's first move.
    public mutating func resumeClock(at now: Date) {
        guard result == nil, stuckSide == nil, let game = game, game.ply > 0 else { return }
        clock?.start(game.position.sideToMove, at: now)
    }

    // MARK: - Remote messages

    public mutating func receive(_ message: GameMessage, at now: Date) -> MatchUpdate {
        var update = MatchUpdate()
        switch message {
        case .sync(let remote):
            merge(remote, at: now, update: &update)

        case .ready(let digest):
            guard remoteReadyDigest == nil, result == nil else { break }
            remoteReadyDigest = digest
            updatedAt = now
            update.events.append(.opponentReady)
            if localSecrets != nil { update.outgoing.append(.commitments(localCommitmentList)) }

        case .commitments(let list):
            guard remoteCommitments == nil, let digest = remoteReadyDigest,
                  let map = Match.validCommitments(list, side: opponentSide),
                  Commitments.setupDigest(gameID: gameID, commitments: map) == digest
            else { break }
            remoteCommitments = map
            updatedAt = now
            startIfPossible(now: now, update: &update)

        case let .move(ply, move, reveal, remaining):
            receiveMove(ply: ply, move: move, reveal: reveal, remaining: remaining, now: now, update: &update)

        case .reveal(let reveals):
            receiveReveals(reveals, now: now, update: &update)

        case .noLegalMoves(let ply):
            guard result == nil, stuckSide == nil, let game = game, ply == game.ply,
                  !game.isAwaitingBattle, game.position.sideToMove == opponentSide
            else { break }
            stuckSide = opponentSide
            clock?.stop(at: now)
            drawOfferFrom = nil
            updatedAt = now
            update.events.append(.stuck(opponentSide))
            resolveStuck(now: now, update: &update)

        case .resign(let side):
            guard result == nil, side == opponentSide else { break }
            finish(GameResult(winner: localSide, reason: .resignation), now: now, update: &update)

        case .timeout(let side):
            guard result == nil, side == opponentSide else { break }
            if var c = clock {
                c.stop(at: now)
                c.set(opponentSide, 0)
                clock = c
            }
            finish(GameResult(winner: localSide, reason: .timeout), now: now, update: &update)

        case .drawOffer:
            guard result == nil, game != nil else { break }
            drawOfferFrom = opponentSide
            updatedAt = now
            update.events.append(.drawOffered)

        case .drawDeclined:
            guard drawOfferFrom == localSide else { break }
            drawOfferFrom = nil
            updatedAt = now
            update.events.append(.drawDeclined)

        case .drawAccepted:
            // The opponent has already ended the game on their side; always honor it.
            guard result == nil else { break }
            drawOfferFrom = nil
            finish(GameResult(winner: nil, reason: .agreement), now: now, update: &update)

        case .chat(let message):
            guard !chat.contains(where: { $0.id == message.id }) else { break }
            var incoming = message
            incoming.text = String(incoming.text.prefix(Match.maxChatLength))
            chat.append(incoming)
            updatedAt = now
            update.events.append(.chatReceived(incoming))

        case .rematchOffer, .rematchDeclined, .rematchAccepted, .leaving:
            break  // handled by the app (they concern the connection, not this game)
        }
        return update
    }

    private mutating func receiveMove(ply: Int, move: Move, reveal: PieceReveal?, remaining: Double?,
                                      now: Date, update: inout MatchUpdate) {
        // Stale, out-of-turn or illegal moves are ignored.
        guard result == nil, stuckSide == nil, var current = game, ply == current.ply,
              !current.isAwaitingBattle, current.position.sideToMove == opponentSide,
              let mover = current.position[move.from], mover.side == opponentSide
        else { return }
        let defender = current.position[move.to]
        if defender != nil || move.distance > 1 {
            guard let reveal = reveal, reveal.piece == mover.id, isValidRemoteReveal(reveal) else { return }
            current.learn([mover.id: reveal.secret.rank])
        }
        guard Rules.isLegal(move, in: current), current.apply(move) else { return }
        if let reveal = reveal, defender != nil || move.distance > 1 {
            remoteSecrets[reveal.piece] = reveal.secret
        }
        game = current

        if var c = clock {
            c.stop(at: now)
            if let remaining = remaining { c.set(opponentSide, remaining) }
            clock = c
        }
        if drawOfferFrom == localSide { drawOfferFrom = nil }  // they moved instead of accepting
        update.events.append(.moved(byLocalPlayer: false))
        if let defender = defender, let secret = localSecrets?[defender.id] {
            // Our piece was attacked: answer with its rank. We already know both, so the battle is decided.
            update.outgoing.append(.reveal([PieceReveal(piece: defender.id, secret: secret)]))
            if let report = battleReport(ply: ply) { update.events.append(.battle(report)) }
        }
        afterMove(now: now, update: &update)
    }

    private mutating func receiveReveals(_ reveals: [PieceReveal], now: Date, update: inout MatchUpdate) {
        var learned: [PieceID: Rank] = [:]
        for reveal in reveals where remoteSecrets[reveal.piece] == nil && isValidRemoteReveal(reveal) {
            remoteSecrets[reveal.piece] = reveal.secret
            learned[reveal.piece] = reveal.secret.rank
        }
        guard !learned.isEmpty else { return }
        updatedAt = now
        if var current = game {
            let wasAwaiting = current.isAwaitingBattle
            if current.learn(learned) { game = current }
            if wasAwaiting && !current.isAwaitingBattle {
                if let report = battleReport(ply: current.ply - 1) { update.events.append(.battle(report)) }
                afterMove(now: now, update: &update)
            }
        }
        resolveStuck(now: now, update: &update)
        runVerification(update: &update)
    }

    // MARK: - Reconciliation

    /// Merges the opponent's public snapshot into ours. Deterministic and symmetric: when both
    /// sides merge each other's snapshot they end up with the same moves, result and chat.
    mutating func merge(_ remote: MatchSnapshot, at now: Date, update: inout MatchUpdate) {
        guard remote.gameID == gameID else { return }
        let theirs = remote.setup(opponentSide)
        let mine = remote.setup(localSide)
        let previousResult = result

        // Their setup.
        if remoteReadyDigest == nil, let digest = theirs.readyDigest {
            remoteReadyDigest = digest
            update.events.append(.opponentReady)
        }
        if remoteCommitments == nil, let list = theirs.commitments, let digest = remoteReadyDigest,
           let map = Match.validCommitments(list, side: opponentSide),
           Commitments.setupDigest(gameID: gameID, commitments: map) == digest {
            remoteCommitments = map
        }
        for reveal in theirs.reveals where remoteSecrets[reveal.piece] == nil && isValidRemoteReveal(reveal) {
            remoteSecrets[reveal.piece] = reveal.secret
        }

        // Each side is authoritative for its own name.
        if opponentSide == .red { red.name = remote.red.name } else { blue.name = remote.blue.name }

        // Moves: the longer history wins when one extends the other.
        if localSecrets != nil, remoteCommitments != nil {
            let wasStarted = game != nil
            let localMoves = game?.moves ?? []
            let chosen = Match.chooseHistory(localMoves, remote.moves)
            if let replayed = Game(pieces: allPieceIDs, ranks: knownRanks, moves: chosen) {
                game = replayed
            } else if let replayed = Game(pieces: allPieceIDs, ranks: knownRanks, moves: localMoves) {
                game = replayed
            }
            if !wasStarted && game != nil { update.events.append(.gameStarted) }
        }

        // Each side is authoritative for its own clock.
        if var c = clock {
            c.stop(at: now)
            if let theirClock = remote.remaining(opponentSide) { c.set(opponentSide, theirClock) }
            clock = c
        }

        if stuckSide == nil, let stuck = remote.stuckSide, let game = game,
           !game.isAwaitingBattle, game.position.sideToMove == stuck {
            stuckSide = stuck
        }
        let localEvent = result.flatMap { $0.isAutomatic ? nil : $0 }
        let remoteEvent = remote.result.flatMap { $0.isAutomatic ? nil : $0 }
        result = automaticResult() ?? Match.chooseResult(localEvent, remoteEvent)
        if let result = result, result != previousResult {
            clock?.stop(at: now)
            update.events.append(.gameOver(result))
        }

        var known = Set(chat.map(\.id))
        for message in remote.chat where !known.contains(message.id) {
            chat.append(message)
            known.insert(message.id)
        }
        chat.sort { ($0.sentAt, $0.id.uuidString) < ($1.sentAt, $1.id.uuidString) }

        drawOfferFrom = nil
        updatedAt = max(updatedAt, remote.updatedAt)
        update.events.append(.resynced)

        // Send whatever the opponent is missing from us.
        if localSecrets != nil {
            if mine.readyDigest == nil, let digest = localReadyDigest { update.outgoing.append(.ready(digest: digest)) }
            if remoteReadyDigest != nil && mine.commitments == nil { update.outgoing.append(.commitments(localCommitmentList)) }
            let missing = publiclyRevealedLocalPieces.subtracting(mine.reveals.map(\.piece))
            if !missing.isEmpty { update.outgoing.append(.reveal(reveals(of: missing))) }
        }
        if result == nil { afterTurnChange(now: now, update: &update) }
        runVerification(update: &update)
    }

    /// If one history extends the other, the longer one wins. Otherwise (should not happen)
    /// pick deterministically so both sides still agree.
    static func chooseHistory(_ a: [Move], _ b: [Move]) -> [Move] {
        if a.count >= b.count, Array(a.prefix(b.count)) == b { return a }
        if b.count > a.count, Array(b.prefix(a.count)) == a { return b }
        if a.count != b.count { return a.count > b.count ? a : b }
        return a.map(\.description).joined(separator: " ") > b.map(\.description).joined(separator: " ") ? a : b
    }

    static func chooseResult(_ a: GameResult?, _ b: GameResult?) -> GameResult? {
        switch (a, b) {
        case (nil, nil): return nil
        case let (x?, nil): return x
        case let (nil, y?): return y
        case let (x?, y?): return x.sortKey <= y.sortKey ? x : y
        }
    }

    // MARK: - Helpers

    private mutating func startIfPossible(now: Date, update: inout MatchUpdate) {
        guard game == nil, localSecrets != nil, remoteCommitments != nil,
              let started = Game(pieces: allPieceIDs, ranks: knownRanks, moves: [])
        else { return }
        game = started
        updatedAt = now
        update.events.append(.gameStarted)
        afterTurnChange(now: now, update: &update)
    }

    /// Bookkeeping after a move or a resolved battle: end the game on a captured Flag, otherwise
    /// run the clock of the side to move and check whether we are left without a legal move.
    private mutating func afterMove(now: Date, update: inout MatchUpdate) {
        updatedAt = now
        guard let game = game else { return }
        if let winner = game.winnerByFlag {
            finish(GameResult(winner: winner, reason: .flagCaptured), now: now, update: &update)
            return
        }
        if result == nil, stuckSide == nil {
            clock?.start(game.position.sideToMove, at: now)
        }
        afterTurnChange(now: now, update: &update)
    }

    /// A player with no legal move on their turn loses. Only that player knows their ranks, so
    /// they declare it and reveal their army; the result is settled once both are revealed.
    private mutating func afterTurnChange(now: Date, update: inout MatchUpdate) {
        guard isLocalTurn, let game = game, Rules.legalMoves(in: game, for: localSide).isEmpty else { return }
        stuckSide = localSide
        clock?.stop(at: now)
        drawOfferFrom = nil
        updatedAt = now
        update.outgoing.append(.noLegalMoves(ply: game.ply))
        update.outgoing.append(.reveal(fullLocalReveal))
        update.events.append(.stuck(localSide))
        resolveStuck(now: now, update: &update)
    }

    private mutating func resolveStuck(now: Date, update: inout MatchUpdate) {
        guard result == nil, let outcome = automaticResult() else { return }
        finish(outcome, now: now, update: &update)
    }

    /// A result that follows from the board: a captured Flag, or a stuck player once both
    /// armies are known (a draw if neither side can move at all).
    private func automaticResult() -> GameResult? {
        guard let game = game else { return nil }
        if let winner = game.winnerByFlag { return GameResult(winner: winner, reason: .flagCaptured) }
        guard let stuck = stuckSide, hasFullReveal else { return nil }
        if !Rules.canMoveAtAll(stuck, in: game) && !Rules.canMoveAtAll(stuck.opposite, in: game) {
            return GameResult(winner: nil, reason: .noMovablePieces)
        }
        return GameResult(winner: stuck.opposite, reason: .noMoves)
    }

    private mutating func finish(_ outcome: GameResult, now: Date, update: inout MatchUpdate) {
        result = outcome
        clock?.stop(at: now)
        drawOfferFrom = nil
        updatedAt = now
        update.events.append(.gameOver(outcome))
        // The game is over: show the opponent our whole army so both can review and check it.
        if localSecrets != nil { update.outgoing.append(.reveal(fullLocalReveal)) }
        runVerification(update: &update)
    }

    private mutating func runVerification(update: inout MatchUpdate) {
        guard verification == nil, hasFullReveal, let game = game else { return }
        let outcome = verify(game)
        verification = outcome
        if case .failed(let reason) = outcome { update.events.append(.verificationFailed(reason)) }
    }

    /// Replays the whole game with both armies known and checks that every move was legal.
    func verify(_ game: Game) -> Verification {
        let name = opponent.name
        guard Rank.isBarrageArmy(remoteSecrets.values.map(\.rank)) else {
            return .failed("\(name)'s revealed army isn't the standard eight Barrage pieces.")
        }
        var replay = Game(pieces: allPieceIDs, ranks: knownRanks)
        for (index, move) in game.moves.enumerated() {
            guard Rules.isLegal(move, in: replay), replay.apply(move) else {
                return .failed("Move \(index + 1) (\(move)) wasn't legal for the piece that made it.")
            }
        }
        if let stuck = stuckSide, !Rules.legalMoves(in: replay, for: stuck).isEmpty {
            return .failed("\(player(stuck).name) said they had no legal move, but they had one.")
        }
        return .passed
    }

    private func battleReport(ply: Int) -> BattleReport? {
        guard let game = game, ply >= 0, ply < game.records.count else { return nil }
        let record = game.records[ply]
        guard let outcome = record.outcome, let attacker = record.attackerRank, let defender = record.defenderRank else { return nil }
        return BattleReport(ply: ply, attackerSide: record.side, attackerRank: attacker, defenderRank: defender,
                            outcome: outcome, square: record.move.to)
    }

    private func isValidRemoteReveal(_ reveal: PieceReveal) -> Bool {
        guard reveal.piece.side == opponentSide, let commitment = remoteCommitments?[reveal.piece] else { return false }
        if let known = remoteSecrets[reveal.piece], known != reveal.secret { return false }
        return Commitments.digest(gameID: gameID, piece: reveal.piece, secret: reveal.secret) == commitment
    }

    /// Eight distinct pieces, all on `side`'s setup rows.
    static func validCommitments(_ list: [PieceCommitment], side: Side) -> [PieceID: String]? {
        var map: [PieceID: String] = [:]
        for commitment in list {
            guard commitment.piece.side == side, commitment.piece.home.isHome(of: side),
                  map[commitment.piece] == nil
            else { return nil }
            map[commitment.piece] = commitment.digest
        }
        return map.count == Rank.barrageArmy.count ? map : nil
    }
}
