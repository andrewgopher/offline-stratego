import Foundation

/// Movement, battle and anti-stalling rules (ISF rules, Barrage piece set).
public enum Rules {
    /// Two-squares rule: a piece may move back and forth between the same two squares at most
    /// this many times in a row (counting only its owner's turns).
    public static let maxShuttleMoves = 5

    /// Why an otherwise possible move is not allowed.
    public enum Restriction: Hashable {
        case twoSquares
        case chasing

        public var explanation: String {
            switch self {
            case .twoSquares:
                return "Two-squares rule: a piece can't move back and forth between the same squares more than \(Rules.maxShuttleMoves) times in a row."
            case .chasing:
                return "Chasing rule: you can't keep chasing a piece into a position that has already occurred."
            }
        }
    }

    public static func battle(attacker: Rank, defender: Rank) -> BattleOutcome {
        switch defender {
        case .flag:
            return .attackerWins
        case .bomb:
            return attacker == .miner ? .attackerWins : .defenderWins
        default:
            if attacker == .spy && defender == .marshal { return .attackerWins }
            if attacker.strength == defender.strength { return .bothLose }
            return attacker.strength > defender.strength ? .attackerWins : .defenderWins
        }
    }

    /// Where the piece on `from` could go by the movement rules alone: one step in a straight
    /// line, or any number of empty squares for a Scout, ending on an empty square or an enemy.
    public static func destinations(from: Square, rank: Rank, in position: Position) -> [Square] {
        guard rank.isMovable, let piece = position[from] else { return [] }
        var result: [Square] = []
        for (dx, dy) in Square.directions {
            var square = from.offset(dx, dy)
            while square.isPlayable {
                if let occupant = position[square] {
                    if occupant.side != piece.side { result.append(square) }
                    break
                }
                result.append(square)
                if rank != .scout { break }
                square = square.offset(dx, dy)
            }
        }
        return result
    }

    /// Moves allowed by the movement rules, before the repetition rules, for pieces whose
    /// ranks the viewer knows.
    public static func candidateMoves(in game: Game, for side: Side) -> [Move] {
        guard !game.isOver, !game.isAwaitingBattle, game.position.sideToMove == side else { return [] }
        var moves: [Move] = []
        for piece in game.position.alivePieces(of: side) {
            guard let from = piece.square, let rank = game.rank(of: piece.id) else { continue }
            for to in destinations(from: from, rank: rank, in: game.position) {
                moves.append(Move(from, to))
            }
        }
        return moves
    }

    public static func legalMoves(in game: Game, for side: Side) -> [Move] {
        candidateMoves(in: game, for: side).filter { restriction(on: $0, in: game) == nil }
    }

    /// Full check of a move, as far as the viewer's knowledge of ranks allows.
    public static func isLegal(_ move: Move, in game: Game) -> Bool {
        game.canApply(move) && restriction(on: move, in: game) == nil
    }

    /// The repetition rule that forbids this move, if any.
    public static func restriction(on move: Move, in game: Game) -> Restriction? {
        if violatesTwoSquares(move, in: game) { return .twoSquares }
        if violatesChasingRule(move, in: game) { return .chasing }
        return nil
    }

    /// Whether `side` has any piece that could physically move (ignoring whose turn it is and
    /// the repetition rules). Pieces of unknown rank count as movable.
    public static func canMoveAtAll(_ side: Side, in game: Game) -> Bool {
        let position = game.position
        return position.alivePieces(of: side).contains { piece in
            guard let square = piece.square else { return false }
            let rank = game.rank(of: piece.id) ?? .marshal
            return !destinations(from: square, rank: rank, in: position).isEmpty
        }
    }

    // MARK: - Repetition rules

    /// ISF two-squares rule: no more than five consecutive moves of the same piece between the
    /// same two squares, whatever the opponent does. For Scouts, every square passed over
    /// counts, so consecutive moves that keep crossing a common edge count as shuttling.
    static func violatesTwoSquares(_ move: Move, in game: Game) -> Bool {
        guard let piece = game.position[move.from]?.id else { return false }
        var recent: [MoveRecord] = []
        for record in game.records.reversed() where record.side == piece.side {
            recent.append(record)
            if recent.count == maxShuttleMoves { break }
        }
        guard recent.count == maxShuttleMoves, recent.allSatisfy({ $0.piece == piece }) else { return false }
        var shared = move.crossedEdges
        for record in recent {
            shared.formIntersection(record.move.crossedEdges)
            if shared.isEmpty { return false }
        }
        return true
    }

    /// ISF more-squares (chasing) rule. If our last move put a piece next to an enemy piece
    /// (a threat) and the opponent answered by moving that piece away (an evasion), a move that
    /// threatens it again may not recreate a position that has already occurred. Stepping the
    /// chasing piece straight back to the square it just came from is always allowed.
    static func violatesChasingRule(_ move: Move, in game: Game) -> Bool {
        let records = game.records
        let count = records.count
        let position = game.position
        guard count >= 2, let mover = position[move.from], position[move.to] == nil else { return false }
        let evasion = records[count - 1]
        let threat = records[count - 2]
        guard evasion.side != mover.side, threat.side == mover.side, !evasion.isAttack else { return false }

        let afterThreat = game.positions[count - 1]
        guard let chaserSquare = afterThreat.pieces[threat.piece]?.square,
              let evaderSquare = afterThreat.pieces[evasion.piece]?.square,
              chaserSquare.isAdjacent(to: evaderSquare),
              let evaderNow = position.pieces[evasion.piece]?.square,
              move.to.isAdjacent(to: evaderNow)
        else { return false }

        if mover.id == threat.piece && move.to == threat.move.from { return false }

        var board = position.cells
        board[move.from.index] = nil
        board[move.to.index] = mover.id
        return game.hasOccurred(board)
    }
}
