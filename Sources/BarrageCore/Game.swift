import Foundation

/// A move from one square to another. An attack is a move onto an enemy piece.
public struct Move: Hashable, Codable, CustomStringConvertible {
    public var from: Square
    public var to: Square

    public init(_ from: Square, _ to: Square) {
        self.from = from
        self.to = to
    }

    /// Parses "A4-A6" (or "A4xA6").
    public init?(_ text: String) {
        let parts = text.split { $0 == "-" || $0 == "x" || $0 == "X" || $0 == "×" }
        guard parts.count == 2,
              let from = Square(name: String(parts[0])),
              let to = Square(name: String(parts[1]))
        else { return nil }
        self.init(from, to)
    }

    public var isStraight: Bool { from != to && (from.x == to.x || from.y == to.y) }
    public var distance: Int { abs(from.x - to.x) + abs(from.y - to.y) }

    /// The squares passed over between `from` and `to`, both excluded.
    public var path: [Square] {
        guard isStraight else { return [] }
        let dx = (to.x - from.x).signum()
        let dy = (to.y - from.y).signum()
        var result: [Square] = []
        var square = from.offset(dx, dy)
        while square != to {
            result.append(square)
            square = square.offset(dx, dy)
        }
        return result
    }

    /// The edges between squares that this move crosses. Moving back and forth between two
    /// squares crosses the same edge every time, and so do overlapping Scout moves along one
    /// line, which is how the two-squares rule treats Scouts.
    var crossedEdges: Set<Int> {
        guard isStraight else { return [] }
        var edges = Set<Int>()
        if from.y == to.y {
            for x in min(from.x, to.x)..<max(from.x, to.x) { edges.insert(from.y * 10 + x) }
        } else {
            for y in min(from.y, to.y)..<max(from.y, to.y) { edges.insert(1000 + y * 10 + from.x) }
        }
        return edges
    }

    public var description: String { "\(from.name)-\(to.name)" }
}

public enum BattleOutcome: String, Codable, Hashable {
    case attackerWins, defenderWins, bothLose
}

/// What a move did, as far as the viewer knows.
public struct MoveRecord: Hashable {
    public let move: Move
    public let side: Side
    public let piece: PieceID
    /// The mover's rank, when known to the viewer.
    public internal(set) var attackerRank: Rank?
    public internal(set) var defender: PieceID? = nil
    public internal(set) var defenderRank: Rank? = nil
    /// Nil for plain moves, and for an attack whose battle is still waiting for a rank.
    public internal(set) var outcome: BattleOutcome? = nil

    public var isAttack: Bool { defender != nil }
    public var isPendingBattle: Bool { isAttack && outcome == nil }
    /// The move made the piece's rank public: it fought, or it moved more than one square.
    public var revealsMover: Bool { isAttack || move.distance > 1 }
}

public struct PieceState: Hashable {
    public let id: PieceID
    /// Where the piece stands, or nil once it has been lost in battle.
    public internal(set) var square: Square?
    /// It has moved at least once, so it can't be a Bomb or the Flag.
    public internal(set) var hasMoved = false
    /// Both players know its rank: it fought, or it moved like a Scout.
    public internal(set) var isRevealed = false

    public var side: Side { id.side }
    public var isAlive: Bool { square != nil }
}

/// Where every piece stands at one moment. Ranks are kept separately (see `Game.ranks`)
/// because each Mac knows a different subset of them.
public struct Position: Hashable {
    /// Which piece stands on each square, indexed by `Square.index`.
    public private(set) var cells: [PieceID?]
    public private(set) var pieces: [PieceID: PieceState]
    public internal(set) var sideToMove: Side = .red
    /// An attack whose battle can't be resolved yet because a rank is still hidden from this viewer.
    public internal(set) var pendingAttack: Move?

    public init(pieces ids: [PieceID]) {
        var cells = [PieceID?](repeating: nil, count: Square.size * Square.size)
        var pieces: [PieceID: PieceState] = [:]
        for id in ids {
            cells[id.home.index] = id
            pieces[id] = PieceState(id: id, square: id.home)
        }
        self.cells = cells
        self.pieces = pieces
    }

    public subscript(square: Square) -> PieceState? {
        guard square.isOnBoard, let id = cells[square.index] else { return nil }
        return pieces[id]
    }

    public func pieces(of side: Side) -> [PieceState] {
        pieces.values.filter { $0.side == side }.sorted { $0.id < $1.id }
    }

    public func alivePieces(of side: Side) -> [PieceState] { pieces(of: side).filter(\.isAlive) }
    public func lostPieces(of side: Side) -> [PieceState] { pieces(of: side).filter { !$0.isAlive } }

    mutating func update(_ id: PieceID, _ body: (inout PieceState) -> Void) {
        guard var piece = pieces[id] else { return }
        body(&piece)
        pieces[id] = piece
    }

    mutating func relocate(_ id: PieceID, to square: Square) {
        guard let old = pieces[id]?.square else { return }
        cells[old.index] = nil
        cells[square.index] = id
        update(id) { $0.square = square }
    }

    mutating func remove(_ id: PieceID) {
        guard let old = pieces[id]?.square else { return }
        if cells[old.index] == id { cells[old.index] = nil }
        update(id) { $0.square = nil }
    }
}

/// A game's move history replayed into positions, using whatever ranks the viewer knows.
///
/// Both Macs hold the same `moves`; they differ only in `ranks`. A battle needs both ranks:
/// until the missing one arrives, the attack stays pending and no further move is possible.
public struct Game {
    public let pieceIDs: [PieceID]
    public private(set) var ranks: [PieceID: Rank]
    public private(set) var moves: [Move] = []
    public private(set) var records: [MoveRecord] = []
    /// `positions[i]` is the position after `i` moves.
    public private(set) var positions: [Position]
    public private(set) var winnerByFlag: Side?
    private var seenBoards: Set<[PieceID?]>

    public init(pieces: [PieceID], ranks: [PieceID: Rank] = [:]) {
        pieceIDs = pieces.sorted()
        self.ranks = ranks
        let start = Position(pieces: pieceIDs)
        positions = [start]
        seenBoards = [start.cells]
    }

    /// Replays `moves`; fails if one of them can't be played.
    public init?(pieces: [PieceID], ranks: [PieceID: Rank], moves: [Move]) {
        self.init(pieces: pieces, ranks: ranks)
        for move in moves {
            guard apply(move) else { return nil }
        }
    }

    public var position: Position { positions[positions.count - 1] }
    public var ply: Int { moves.count }
    public var isOver: Bool { winnerByFlag != nil }
    public var isAwaitingBattle: Bool { position.pendingAttack != nil }

    public func rank(of id: PieceID) -> Rank? { ranks[id] }

    /// Whether this exact arrangement of pieces has appeared earlier in the game.
    func hasOccurred(_ board: [PieceID?]) -> Bool { seenBoards.contains(board) }

    /// Movement rules only, judged with the ranks this viewer knows. A long (Scout) move needs
    /// the mover's rank. The repetition rules are checked separately by `Rules`.
    public func canApply(_ move: Move) -> Bool {
        let position = self.position
        guard winnerByFlag == nil, position.pendingAttack == nil, move.isStraight,
              move.from.isPlayable, move.to.isPlayable,
              let mover = position[move.from], mover.side == position.sideToMove
        else { return false }
        if let target = position[move.to], target.side == mover.side { return false }
        guard move.path.allSatisfy({ $0.isPlayable && position[$0] == nil }) else { return false }
        if let rank = ranks[mover.id] {
            guard rank.isMovable, move.distance == 1 || rank == .scout else { return false }
        } else if move.distance > 1 {
            return false
        }
        return true
    }

    @discardableResult
    public mutating func apply(_ move: Move) -> Bool {
        guard canApply(move), let mover = position[move.from]?.id else { return false }
        var next = position
        let side = mover.side
        next.update(mover) {
            $0.hasMoved = true
            if move.distance > 1 { $0.isRevealed = true }
        }
        var record = MoveRecord(move: move, side: side, piece: mover, attackerRank: ranks[mover])
        if let defender = next[move.to]?.id {
            record.defender = defender
            record.defenderRank = ranks[defender]
            next.update(mover) { $0.isRevealed = true }
            next.update(defender) { $0.isRevealed = true }
            if let attackerRank = ranks[mover], let defenderRank = ranks[defender] {
                let outcome = Rules.battle(attacker: attackerRank, defender: defenderRank)
                record.outcome = outcome
                switch outcome {
                case .attackerWins:
                    next.remove(defender)
                    next.relocate(mover, to: move.to)
                    if defenderRank == .flag { winnerByFlag = side }
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
        next.sideToMove = side.opposite
        moves.append(move)
        records.append(record)
        positions.append(next)
        seenBoards.insert(next.cells)
        return true
    }

    /// Adds newly learned ranks and replays the game, which resolves a pending battle.
    @discardableResult
    public mutating func learn(_ newRanks: [PieceID: Rank]) -> Bool {
        var merged = ranks
        for (id, rank) in newRanks { merged[id] = rank }
        guard merged != ranks else { return true }
        guard let replayed = Game(pieces: pieceIDs, ranks: merged, moves: moves) else { return false }
        self = replayed
        return true
    }
}
