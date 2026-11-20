import Foundation

/// What one turn on a 2v2 board did, as far as everyone at the table knows.
public struct TeamTurn: Hashable {
    public struct SwapSummary: Hashable {
        public let removed: Rank
        public let placed: Rank
    }

    public let side: Side
    public let at: Date
    /// Nil for a swap.
    public let move: Move?
    public let piece: PieceID?
    public let swap: SwapSummary?
    /// The mover's rank, when it was proven (an attack or a Scout's long move).
    public internal(set) var moverRank: Rank?
    public internal(set) var defender: PieceID? = nil
    public internal(set) var defenderRank: Rank? = nil
    /// Nil for plain moves and swaps, and for an attack whose defender hasn't answered yet.
    public internal(set) var outcome: BattleOutcome? = nil

    public var isAttack: Bool { defender != nil }
    public var isSwap: Bool { swap != nil }
    public var isPendingBattle: Bool { isAttack && outcome == nil }

    /// The pieces lost in this turn's battle, which go to the other board. A captured Flag
    /// ends the game instead, so it never joins a reserve.
    public var losses: [(side: Side, rank: Rank)] {
        guard let outcome = outcome, let attacker = moverRank, let defender = defenderRank, defender != .flag else { return [] }
        switch outcome {
        case .attackerWins: return [(side.opposite, defender)]
        case .defenderWins: return [(side, attacker)]
        case .bothLose: return [(side, attacker), (side.opposite, defender)]
        }
    }
}

public struct FlagCapture: Hashable {
    public let side: Side
    public let index: Int
    public let at: Date
}

/// One board of a 2v2 game: the shared log of turns replayed into positions.
///
/// Every Mac holds the same entries. Battles are settled by the proofs inside the log (the
/// attacker's reveal travels with the move, the defender's arrives separately), so no Mac needs
/// to know anyone's hidden ranks. A swap changes nothing visible: the replaced piece keeps its
/// identity on the board, only its (hidden) rank changes.
public struct TeamBoard {
    public let board: BoardID
    public let pieceIDs: [PieceID]
    public private(set) var entries: [BoardEntry] = []
    public private(set) var defenderReveals: [Int: PieceReveal] = [:]
    public private(set) var turns: [TeamTurn] = []
    /// `positions[i]` is the position after `i` turns.
    public private(set) var positions: [Position]
    public private(set) var flagCapture: FlagCapture?
    private var seenBoards: Set<[PieceID?]>

    public init(board: BoardID, pieces: [PieceID]) {
        self.board = board
        pieceIDs = pieces.sorted()
        let start = Position(pieces: pieceIDs)
        positions = [start]
        seenBoards = [start.cells]
    }

    public var position: Position { positions[positions.count - 1] }
    public var ply: Int { entries.count }
    public var sideToMove: Side { position.sideToMove }
    public var isAwaitingBattle: Bool { position.pendingAttack != nil }
    public var isOver: Bool { flagCapture != nil }

    /// How many entries from the start have all their battles settled.
    public var resolvedCount: Int { isAwaitingBattle ? entries.count - 1 : entries.count }

    /// Turns alternate strictly, starting with Red.
    public static func author(ofEntry index: Int) -> Side { index % 2 == 0 ? .red : .blue }

    /// Whether `action` can be the next turn, judged from the public board and the proofs it
    /// carries: movement, whose turn it is, the Scout proof, and both repetition rules. Swaps are
    /// checked further by `TeamMatch` (reserve and commitments).
    public func canAppend(_ action: BoardAction) -> Bool {
        let position = self.position
        guard !isOver, position.pendingAttack == nil else { return false }
        switch action {
        case .swap:
            return true
        case let .move(move, reveal):
            guard move.isStraight, move.from.isPlayable, move.to.isPlayable,
                  let mover = position[move.from], mover.side == position.sideToMove
            else { return false }
            if let target = position[move.to], target.side == mover.side { return false }
            guard move.path.allSatisfy({ $0.isPlayable && position[$0] == nil }) else { return false }
            let isAttack = position[move.to] != nil
            if isAttack || move.distance > 1 {
                guard reveal != nil else { return false }
            }
            if let reveal = reveal {
                guard reveal.piece == mover.id, reveal.secret.rank.isMovable else { return false }
                if move.distance > 1 && reveal.secret.rank != .scout { return false }
            }
            return Rules.repetitionRestriction(on: move, in: self) == nil
        }
    }

    @discardableResult
    public mutating func append(_ entry: BoardEntry) -> Bool {
        guard canAppend(entry.action) else { return false }
        let index = entries.count
        var next = position
        let side = next.sideToMove
        var turn: TeamTurn
        switch entry.action {
        case .swap(let swap):
            turn = TeamTurn(side: side, at: entry.at, move: nil, piece: nil,
                            swap: TeamTurn.SwapSummary(removed: swap.removed, placed: swap.placed))
        case let .move(move, reveal):
            guard let mover = next[move.from]?.id else { return false }
            next.update(mover) {
                $0.hasMoved = true
                if move.distance > 1 { $0.isRevealed = true }
            }
            turn = TeamTurn(side: side, at: entry.at, move: move, piece: mover, swap: nil, moverRank: reveal?.secret.rank)
            if let defender = next[move.to]?.id {
                turn.defender = defender
                next.update(mover) { $0.isRevealed = true }
                next.update(defender) { $0.isRevealed = true }
                if let answer = defenderReveals[index], answer.piece == defender, let attackerRank = reveal?.secret.rank {
                    let defenderRank = answer.secret.rank
                    turn.defenderRank = defenderRank
                    let outcome = Rules.battle(attacker: attackerRank, defender: defenderRank)
                    turn.outcome = outcome
                    switch outcome {
                    case .attackerWins:
                        next.remove(defender)
                        next.relocate(mover, to: move.to)
                        if defenderRank == .flag { flagCapture = FlagCapture(side: side, index: index, at: entry.at) }
                    case .defenderWins:
                        next.remove(mover)
                    case .bothLose:
                        next.remove(mover)
                        next.remove(defender)
                    }
                } else {
                    next.pendingAttack = move
                }
            } else {
                next.relocate(mover, to: move.to)
            }
        }
        next.sideToMove = side.opposite
        entries.append(entry)
        turns.append(turn)
        positions.append(next)
        seenBoards.insert(next.cells)
        return true
    }

    /// Settles the pending battle with the defender's (already verified) rank.
    @discardableResult
    public mutating func resolve(index: Int, defender reveal: PieceReveal) -> Bool {
        guard isAwaitingBattle, index == entries.count - 1, turns[index].defender == reveal.piece else { return false }
        let entry = entries.removeLast()
        turns.removeLast()
        positions.removeLast()
        defenderReveals[index] = reveal
        return append(entry)
    }

    /// How many swaps `side` made before entry `index`: the commitment epoch in force there.
    public func epoch(of side: Side, before index: Int) -> Int {
        var count = 0
        for i in 0..<min(index, entries.count) where TeamBoard.author(ofEntry: i) == side {
            if case .swap = entries[i].action { count += 1 }
        }
        return count
    }

    /// The commitments `side` made with its `epoch`-th swap (1-based).
    public func swapCommitments(of side: Side, epoch: Int) -> [PieceCommitment]? {
        var count = 0
        for (i, entry) in entries.enumerated() where TeamBoard.author(ofEntry: i) == side {
            if case .swap(let swap) = entry.action {
                count += 1
                if count == epoch { return swap.commitments }
            }
        }
        return nil
    }

    /// The swaps `side` made in the first `count` entries, in order.
    public func swaps(of side: Side, inFirst count: Int) -> [SwapAction] {
        entries.prefix(count).enumerated().compactMap { i, entry in
            guard TeamBoard.author(ofEntry: i) == side, case .swap(let swap) = entry.action else { return nil }
            return swap
        }
    }

    /// Ranks of `side` lost in battle in the first `count` turns.
    public func losses(of side: Side, inFirst count: Int) -> [Rank] {
        turns.prefix(count).flatMap { turn in turn.losses.filter { $0.side == side }.map(\.rank) }
    }
}

extension TeamBoard: TurnHistory {
    var turnCount: Int { turns.count }

    func turn(at index: Int) -> TurnSummary {
        let turn = turns[index]
        return TurnSummary(side: turn.side, piece: turn.piece, move: turn.move, isAttack: turn.isAttack)
    }

    func hasOccurred(_ board: [PieceID?]) -> Bool { seenBoards.contains(board) }
}

extension Rules {
    /// The repetition rule that forbids this move on a 2v2 board, if any.
    public static func restriction(on move: Move, in board: TeamBoard) -> Restriction? {
        repetitionRestriction(on: move, in: board)
    }

    /// Moves `side` could make by the movement rules alone, judged with `ranks` (the player's own).
    public static func candidateMoves(in board: TeamBoard, for side: Side, ranks: [PieceID: Rank]) -> [Move] {
        guard !board.isOver, !board.isAwaitingBattle, board.sideToMove == side else { return [] }
        var moves: [Move] = []
        for piece in board.position.alivePieces(of: side) {
            guard let from = piece.square, let rank = ranks[piece.id] else { continue }
            for to in destinations(from: from, rank: rank, in: board.position) {
                moves.append(Move(from, to))
            }
        }
        return moves
    }

    public static func legalMoves(in board: TeamBoard, for side: Side, ranks: [PieceID: Rank]) -> [Move] {
        candidateMoves(in: board, for: side, ranks: ranks).filter { restriction(on: $0, in: board) == nil }
    }
}
