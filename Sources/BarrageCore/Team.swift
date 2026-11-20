import Foundation

// Shared vocabulary of the 2v2 mode: four players on two boards, partners on opposite colors.
// A piece captured on one board goes to the capturer's partner on the other board, who can
// swap it in for one of their own pieces instead of moving.

/// The two boards of a 2v2 game.
public enum BoardID: Int, Codable, CaseIterable, Hashable, Comparable {
    case one = 1
    case two = 2

    public var other: BoardID { self == .one ? .two : .one }
    public var name: String { "Board \(rawValue)" }

    public static func < (a: BoardID, b: BoardID) -> Bool { a.rawValue < b.rawValue }
}

/// Team one is Red on board 1 and Blue on board 2; team two is the other two seats. Because
/// partners play opposite colors, a captured piece is always the color of the partner who gets it.
public enum Team: Int, Codable, CaseIterable, Hashable {
    case one = 1
    case two = 2

    public var other: Team { self == .one ? .two : .one }
}

public struct Seat: Hashable, Codable, Comparable, CustomStringConvertible {
    public let board: BoardID
    public let side: Side

    public init(_ board: BoardID, _ side: Side) {
        self.board = board
        self.side = side
    }

    public var team: Team { (board == .one) == (side == .red) ? .one : .two }
    /// The teammate, on the other board with the other color.
    public var partner: Seat { Seat(board.other, side.opposite) }
    /// The opponent across this seat's own board.
    public var opponent: Seat { Seat(board, side.opposite) }
    /// The opponent on the other board.
    public var otherOpponent: Seat { Seat(board.other, side) }

    public static let all: [Seat] = [Seat(.one, .red), Seat(.one, .blue), Seat(.two, .red), Seat(.two, .blue)]

    public static func seats(of team: Team) -> [Seat] { all.filter { $0.team == team } }

    /// Who receives a piece of `side` lost in battle on `board`: the partner of whoever beat it,
    /// who sits on the other board with the same color as the piece.
    public static func receiver(ofPieceOf side: Side, lostOn board: BoardID) -> Seat { Seat(board.other, side) }

    var order: Int { (board.rawValue - 1) * 2 + (side == .red ? 0 : 1) }

    public static func < (a: Seat, b: Seat) -> Bool { a.order < b.order }

    public var description: String { "\(board.name) \(side.name)" }
}

public struct SeatedPlayer: Codable, Hashable {
    public var seat: Seat
    public var player: PlayerInfo

    public init(seat: Seat, player: PlayerInfo) {
        self.seat = seat
        self.player = player
    }
}

/// A proposal for a 2v2 game, sent by the host to the other three players. Seats are fixed
/// when it is sent, so every Mac builds the identical game from it.
public struct TeamChallenge: Codable, Hashable {
    public var gameID: UUID
    public var host: PlayerInfo
    public var seats: [SeatedPlayer]
    public var timeControl: TimeControl

    public init(gameID: UUID = UUID(), host: PlayerInfo, players: [Seat: PlayerInfo], timeControl: TimeControl) {
        self.gameID = gameID
        self.host = host
        self.seats = players.sorted { $0.key < $1.key }.map { SeatedPlayer(seat: $0.key, player: $0.value) }
        self.timeControl = timeControl
    }

    public func player(at seat: Seat) -> PlayerInfo? { seats.first { $0.seat == seat }?.player }

    public func seat(of playerID: String) -> Seat? { seats.first { $0.player.id == playerID }?.seat }

    public var players: [PlayerInfo] { seats.sorted { $0.seat < $1.seat }.map(\.player) }

    /// Four different players in the four seats, the host among them, and a clock (players may
    /// wait for pieces in 2v2, so the clock is what keeps the game moving).
    public var isValid: Bool {
        Set(seats.map(\.seat)) == Set(Seat.all) && seats.count == 4
            && Set(seats.map(\.player.id)).count == 4
            && seat(of: host.id) != nil
            && timeControl.initialSeconds != nil
    }
}

public struct TeamResult: Codable, Hashable {
    public enum Reason: String, Codable, Hashable {
        case flagCaptured
        case resignation
        case timeout
        case agreement
    }

    /// Nil for a draw.
    public var winner: Team?
    public var reason: Reason
    /// Whose action decided it: who captured the Flag, resigned or ran out of time.
    public var seat: Seat?
    /// When it happened, by the clock of the Mac that decided it. If two boards end at almost
    /// the same moment, the earlier event counts.
    public var at: Date

    public init(winner: Team?, reason: Reason, seat: Seat?, at: Date) {
        self.winner = winner
        self.reason = reason
        self.seat = seat
        self.at = at
    }

    var sortKey: String { "\(reason.rawValue)-\(seat.map { String($0.order) } ?? "-")-\(winner.map { String($0.rawValue) } ?? "draw")" }

    /// Picks the event that ended the game: the earliest one, deterministically.
    static func first(of results: [TeamResult]) -> TeamResult? {
        results.min { ($0.at, $0.sortKey) < ($1.at, $1.sortKey) }
    }

    public func summary(name: (Seat) -> String) -> String {
        switch reason {
        case .agreement:
            return "Draw by agreement"
        case .flagCaptured:
            guard let seat = seat else { return "The Flag was captured" }
            return "\(name(seat)) captured \(name(seat.opponent))'s Flag"
        case .resignation:
            guard let seat = seat else { return "A player resigned" }
            return "\(name(seat)) resigned"
        case .timeout:
            guard let seat = seat else { return "A clock ran out" }
            return "\(name(seat)) ran out of time"
        }
    }
}

/// A swap: instead of moving, a player replaces one of their pieces on the board with a piece
/// from their reserve. Everyone learns both ranks, but not which piece was replaced.
public struct SwapAction: Codable, Hashable {
    /// The rank taken off the board; it goes into the swapper's own reserve.
    public var removed: Rank
    /// The reserve piece put in its place.
    public var placed: Rank
    /// How much of the other board the swapper had seen (all battles settled). The reserve is
    /// judged against exactly that much of the other board, so every Mac reaches the same verdict.
    public var otherBoardCount: Int
    /// Fresh commitments for all of the swapper's pieces on the board, so nobody can tell which
    /// one changed.
    public var commitments: [PieceCommitment]

    public init(removed: Rank, placed: Rank, otherBoardCount: Int, commitments: [PieceCommitment]) {
        self.removed = removed
        self.placed = placed
        self.otherBoardCount = otherBoardCount
        self.commitments = commitments
    }
}

public enum BoardAction: Codable, Hashable {
    /// `reveal` proves the mover's rank. It is required for an attack and for a move of more
    /// than one square (a Scout).
    case move(Move, reveal: PieceReveal?)
    case swap(SwapAction)
}

/// One turn on one board, as broadcast by the player who made it.
public struct BoardEntry: Codable, Hashable {
    public var action: BoardAction
    /// The author's wall clock when they made it.
    public var at: Date
    /// The author's remaining time after the turn (increment included).
    public var remaining: Double?

    public init(action: BoardAction, at: Date, remaining: Double?) {
        self.action = action
        self.at = at
        self.remaining = remaining
    }
}

public struct TeamChatMessage: Codable, Hashable, Identifiable {
    public var id: UUID
    public var senderID: String
    public var text: String
    public var sentAt: Date
    /// Only for the sender's partner.
    public var teamOnly: Bool

    public init(id: UUID = UUID(), senderID: String, text: String, sentAt: Date, teamOnly: Bool) {
        self.id = id
        self.senderID = senderID
        self.text = text
        self.sentAt = sentAt
        self.teamOnly = teamOnly
    }
}

public struct PieceRank: Codable, Hashable {
    public var piece: PieceID
    public var rank: Rank

    public init(piece: PieceID, rank: Rank) {
        self.piece = piece
        self.rank = rank
    }
}

public struct TeamDrawOffer: Codable, Hashable {
    public struct Acceptance: Codable, Hashable {
        public var seat: Seat
        public var at: Date
    }

    public var id: UUID
    public var from: Seat
    /// Everyone who agreed so far, the offerer included. A draw needs all four.
    public var accepted: [Acceptance]

    public var acceptedSeats: Set<Seat> { Set(accepted.map(\.seat)) }
}

/// 2v2 messages. The sender is known from the link they arrive on, and every message speaks
/// only for the sender's own seat.
public enum TeamMessage: Codable, Hashable {
    /// The sender's view of the game, exchanged whenever a link (re)opens. Filtered for the
    /// recipient: an opponent only gets public information.
    case sync(TeamSnapshot)
    /// From the host: all three invited players have joined.
    case confirmed
    /// The table is called off before it got going (someone declined or left).
    case cancelled(reason: String)
    /// The sender locked in their setup; the digest hides even which squares they used.
    case ready(digest: String)
    /// The sender's per-piece commitments, sent once all four players are locked in.
    case commitments([PieceCommitment])
    /// A move or a swap. `index` is the 0-based turn number on that board.
    case action(board: BoardID, index: Int, entry: BoardEntry)
    /// The defender's rank, answering an attack.
    case defenderReveal(board: BoardID, index: Int, reveal: PieceReveal)
    /// To the partner only: the sender's current ranks, and the piece a swap just changed.
    case teamRanks([PieceRank], swapped: PieceID?)
    case resign(at: Date)
    /// Sent by the player whose own clock ran out.
    case timeout(at: Date)
    case drawOffer(id: UUID, at: Date)
    case drawAnswer(id: UUID, accept: Bool, at: Date)
    case chat(TeamChatMessage)
    /// After the game: the sender's ranks and nonces for every commitment epoch.
    case finalReveal([[PieceReveal]])
    /// The sender is closing the game on purpose (not a connection drop).
    case leaving
}

/// Uses the key `team` instead of `message`, so 1v1 and 2v2 traffic can never be confused.
public struct TeamEnvelope: Codable, Hashable {
    public var protocolVersion: Int
    public var gameID: UUID
    public var team: TeamMessage

    public init(gameID: UUID, message: TeamMessage) {
        self.protocolVersion = Wire.protocolVersion
        self.gameID = gameID
        self.team = message
    }
}

// MARK: - Snapshot

public struct SeatDigest: Codable, Hashable {
    public var seat: Seat
    public var digest: String
}

public struct SeatCommitments: Codable, Hashable {
    public var seat: Seat
    public var commitments: [PieceCommitment]
}

public struct IndexedReveal: Codable, Hashable {
    public var index: Int
    public var reveal: PieceReveal
}

public struct BoardRecord: Codable, Hashable {
    public var board: BoardID
    public var entries: [BoardEntry]
    public var defenderReveals: [IndexedReveal]
}

public struct SeatClock: Codable, Hashable {
    public var seat: Seat
    public var remaining: Double
}

public struct SeatReveals: Codable, Hashable {
    public var seat: Seat
    public var epochs: [[PieceReveal]]
}

/// Everything needed to save, resume and reconcile a 2v2 game.
///
/// The copy saved on disk holds the owner's own ranks and nonces and the partner's ranks. A copy
/// sent to another player is filtered: the partner also gets the sender's current ranks, an
/// opponent only public information.
public struct TeamSnapshot: Codable, Hashable, Identifiable {
    public var challenge: TeamChallenge
    /// Who wrote this copy.
    public var author: Seat
    public var confirmed: Bool
    public var readyDigests: [SeatDigest]
    public var initialCommitments: [SeatCommitments]
    public var boards: [BoardRecord]
    public var clocks: [SeatClock]
    /// Resignations, timeouts and a draw by agreement (a captured Flag follows from the boards).
    public var declaredResults: [TeamResult]
    /// For listing only; a restored game recomputes it.
    public var result: TeamResult?
    public var drawOffer: TeamDrawOffer?
    public var answeredDrawOffers: [UUID]
    public var chat: [TeamChatMessage]
    public var finalReveals: [SeatReveals]
    public var createdAt: Date
    public var updatedAt: Date
    /// Saved copy only: the author's own ranks and nonces, one list per commitment epoch.
    public var ownSecrets: [[PieceReveal]]?
    /// Saved copy only: the partner's current ranks.
    public var partnerRanks: [PieceRank]?
    /// Copy for the partner only: the author's current ranks.
    public var authorRanks: [PieceRank]?

    public var gameID: UUID { challenge.gameID }
    public var id: UUID { gameID }

    public func player(_ seat: Seat) -> PlayerInfo? { challenge.player(at: seat) }
    public func seat(of playerID: String) -> Seat? { challenge.seat(of: playerID) }

    public var hasStarted: Bool { initialCommitments.count == 4 }
    public var turnCount: Int { boards.reduce(0) { $0 + $1.entries.count } }
}
