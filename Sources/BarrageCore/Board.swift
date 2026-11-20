import Foundation

/// The two armies. Red always moves first.
public enum Side: String, Codable, CaseIterable, Hashable {
    case red, blue

    public var opposite: Side { self == .red ? .blue : .red }
    public var name: String { self == .red ? "Red" : "Blue" }

    /// The four rows (`Square.y`) this side sets up on.
    public var homeRows: ClosedRange<Int> { self == .red ? 0...3 : 6...9 }
}

/// A square of the 10x10 board. `x` is the column (A-J) and `y` the row (1-10), both counted
/// from Red's side: Red sets up on rows 1-4, Blue on rows 7-10.
public struct Square: Hashable, Comparable, Codable, CustomStringConvertible {
    public static let size = 10
    public static let columnLetters: [Character] = Array("ABCDEFGHIJ")

    public let x: Int
    public let y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    public init?(index: Int) {
        guard (0..<Square.size * Square.size).contains(index) else { return nil }
        self.init(index % Square.size, index / Square.size)
    }

    /// Parses "A1" ... "J10".
    public init?(name: String) {
        let upper = name.uppercased()
        guard let letter = upper.first,
              let x = Square.columnLetters.firstIndex(of: letter),
              let row = Int(upper.dropFirst()), (1...Square.size).contains(row)
        else { return nil }
        self.init(x, row - 1)
    }

    /// The square at `column` (0 = leftmost) and `rowFromBack` (0 = back row) as seen by the
    /// player of `side`, sitting with their army at the bottom of the board.
    public init(column: Int, rowFromBack: Int, side: Side) {
        if side == .red {
            self.init(column, rowFromBack)
        } else {
            self.init(Square.size - 1 - column, Square.size - 1 - rowFromBack)
        }
    }

    public func column(for side: Side) -> Int { side == .red ? x : Square.size - 1 - x }
    public func rowFromBack(for side: Side) -> Int { side == .red ? y : Square.size - 1 - y }

    public var index: Int { y * Square.size + x }
    public var name: String { "\(Square.columnLetters[x])\(y + 1)" }
    public var description: String { name }

    public var isOnBoard: Bool { (0..<Square.size).contains(x) && (0..<Square.size).contains(y) }
    /// The two 2x2 lakes in the middle of the board: C5-D6 and G5-H6.
    public var isLake: Bool { (y == 4 || y == 5) && (x == 2 || x == 3 || x == 6 || x == 7) }
    public var isPlayable: Bool { isOnBoard && !isLake }

    public func isHome(of side: Side) -> Bool { isOnBoard && side.homeRows.contains(y) }

    public func offset(_ dx: Int, _ dy: Int) -> Square { Square(x + dx, y + dy) }

    public static let directions: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    public func isAdjacent(to other: Square) -> Bool {
        abs(x - other.x) + abs(y - other.y) == 1
    }

    public static let all: [Square] = (0..<(size * size)).compactMap { Square(index: $0) }

    public static func homeSquares(_ side: Side) -> [Square] { all.filter { $0.isHome(of: side) } }

    public static func < (a: Square, b: Square) -> Bool { a.index < b.index }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        guard let square = Square(index: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Square index \(value) is off the board")
        }
        self = square
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(index)
    }
}

/// The ranks in a Barrage army, strongest first.
public enum Rank: String, Codable, CaseIterable, Hashable {
    case marshal, general, miner, scout, spy, bomb, flag

    /// Battle strength. Bombs and the Flag never attack, so theirs is unused.
    public var strength: Int {
        switch self {
        case .marshal: return 10
        case .general: return 9
        case .miner: return 3
        case .scout: return 2
        case .spy: return 1
        case .bomb, .flag: return 0
        }
    }

    public var isMovable: Bool { self != .bomb && self != .flag }

    public var name: String {
        switch self {
        case .marshal: return "Marshal"
        case .general: return "General"
        case .miner: return "Miner"
        case .scout: return "Scout"
        case .spy: return "Spy"
        case .bomb: return "Bomb"
        case .flag: return "Flag"
        }
    }

    /// Short label printed on the piece.
    public var label: String {
        switch self {
        case .marshal: return "10"
        case .general: return "9"
        case .miner: return "3"
        case .scout: return "2"
        case .spy: return "S"
        case .bomb: return "B"
        case .flag: return "F"
        }
    }

    var order: Int { Rank.allCases.firstIndex(of: self) ?? 0 }

    /// The eight pieces each side plays with in Barrage.
    public static let barrageArmy: [Rank] = [.marshal, .general, .miner, .scout, .scout, .spy, .bomb, .flag]

    public static func count(in army: [Rank], of rank: Rank) -> Int { army.filter { $0 == rank }.count }

    public static func isBarrageArmy<S: Sequence>(_ ranks: S) -> Bool where S.Element == Rank {
        ranks.sorted { $0.order < $1.order } == barrageArmy
    }
}

/// A piece is identified by its side and the square it started on. Both players know every
/// piece's ID from the start, but only the owner knows its rank until it is revealed.
public struct PieceID: Hashable, Comparable, Codable, CustomStringConvertible {
    public let side: Side
    public let home: Square

    public init(_ side: Side, _ home: Square) {
        self.side = side
        self.home = home
    }

    public var rawValue: Int { (side == .red ? 0 : 100) + home.index }

    public init?(rawValue: Int) {
        let side: Side = rawValue >= 100 ? .blue : .red
        guard let home = Square(index: rawValue % 100), (0..<200).contains(rawValue) else { return nil }
        self.init(side, home)
    }

    public var description: String { "\(side == .red ? "R" : "B")@\(home.name)" }

    public static func < (a: PieceID, b: PieceID) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        guard let id = PieceID(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad piece ID \(value)")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
