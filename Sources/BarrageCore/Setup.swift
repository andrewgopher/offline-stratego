import Foundation

/// One piece of a setup, in the owner's own view (army at the bottom), so the same setup
/// works whether you play Red or Blue.
public struct SetupSlot: Codable, Hashable {
    public var column: Int
    public var rowFromBack: Int
    public var rank: Rank

    public init(column: Int, rowFromBack: Int, rank: Rank) {
        self.column = column
        self.rowFromBack = rowFromBack
        self.rank = rank
    }
}

/// Where a player puts their eight pieces before the game. Pieces may stand on any square of
/// the player's four back rows.
public struct Setup: Hashable {
    public let side: Side
    public private(set) var placements: [Square: Rank] = [:]

    public init(side: Side, placements: [Square: Rank] = [:]) {
        self.side = side
        for (square, rank) in placements.sorted(by: { $0.key < $1.key }) {
            place(rank, at: square)
        }
    }

    public init(side: Side, slots: [SetupSlot]) {
        var placements: [Square: Rank] = [:]
        for slot in slots {
            placements[Square(column: slot.column, rowFromBack: slot.rowFromBack, side: side)] = slot.rank
        }
        self.init(side: side, placements: placements)
    }

    public var slots: [SetupSlot] {
        placements
            .map { SetupSlot(column: $0.key.column(for: side), rowFromBack: $0.key.rowFromBack(for: side), rank: $0.value) }
            .sorted { ($0.rowFromBack, $0.column) < ($1.rowFromBack, $1.column) }
    }

    public subscript(square: Square) -> Rank? { placements[square] }

    public var isEmpty: Bool { placements.isEmpty }
    public var isComplete: Bool { Rank.isBarrageArmy(placements.values) }

    public func placedCount(_ rank: Rank) -> Int { placements.values.filter { $0 == rank }.count }

    /// Pieces still to be placed, in army order.
    public var unplaced: [Rank] {
        var remaining = Rank.barrageArmy
        for rank in placements.values {
            if let index = remaining.firstIndex(of: rank) { remaining.remove(at: index) }
        }
        return remaining
    }

    /// Puts a piece from the tray on `square`. A piece already there goes back to the tray.
    @discardableResult
    public mutating func place(_ rank: Rank, at square: Square) -> Bool {
        guard square.isHome(of: side) else { return false }
        var trial = placements
        trial[square] = nil
        guard trial.values.filter({ $0 == rank }).count < Rank.count(in: Rank.barrageArmy, of: rank) else { return false }
        trial[square] = rank
        placements = trial
        return true
    }

    /// Moves a placed piece, swapping with whatever stands on the destination.
    @discardableResult
    public mutating func move(from: Square, to: Square) -> Bool {
        guard from != to, to.isHome(of: side), let rank = placements[from] else { return false }
        let other = placements[to]
        placements[to] = rank
        placements[from] = other
        return true
    }

    public mutating func remove(at square: Square) {
        placements[square] = nil
    }

    public mutating func clear() {
        placements = [:]
    }

    public static func random<G: RandomNumberGenerator>(side: Side, using generator: inout G) -> Setup {
        let squares = Square.homeSquares(side).shuffled(using: &generator)
        var placements: [Square: Rank] = [:]
        for (rank, square) in zip(Rank.barrageArmy, squares) { placements[square] = rank }
        return Setup(side: side, placements: placements)
    }

    public static func random(side: Side) -> Setup {
        var generator = SystemRandomNumberGenerator()
        return random(side: side, using: &generator)
    }
}

/// A named setup kept in the player's library.
public struct SavedSetup: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var slots: [SetupSlot]
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, slots: [SetupSlot], savedAt: Date) {
        self.id = id
        self.name = name
        self.slots = slots
        self.savedAt = savedAt
    }
}
