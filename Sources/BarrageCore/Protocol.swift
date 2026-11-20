import Foundation

/// Bump when the wire format changes incompatibly; peers with a different version are ignored.
public enum Wire {
    /// 2: adds the 2v2 mode (team invitations and messages).
    public static let protocolVersion = 2

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

public struct PlayerInfo: Codable, Hashable {
    /// Stable random identifier for this installation.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ChatMessage: Codable, Hashable, Identifiable {
    public var id: UUID
    public var senderID: String
    public var text: String
    public var sentAt: Date

    public init(id: UUID = UUID(), senderID: String, text: String, sentAt: Date) {
        self.id = id
        self.senderID = senderID
        self.text = text
        self.sentAt = sentAt
    }
}

public struct GameResult: Codable, Hashable {
    public enum Reason: String, Codable, Hashable {
        /// The winner captured the loser's Flag.
        case flagCaptured
        /// The loser had no legal move on their turn.
        case noMoves
        /// Draw: neither side has a piece that can move.
        case noMovablePieces
        case resignation
        case timeout
        case agreement
    }

    public var winner: Side?
    public var reason: Reason

    public init(winner: Side?, reason: Reason) {
        self.winner = winner
        self.reason = reason
    }

    /// Results that follow from the board itself rather than from a player's action.
    public var isAutomatic: Bool {
        reason == .flagCaptured || reason == .noMoves || reason == .noMovablePieces
    }

    public func summary(red: String, blue: String) -> String {
        func name(_ side: Side) -> String { side == .red ? red : blue }
        guard let winner = winner else {
            return reason == .agreement ? "Draw by agreement" : "Draw: neither side can move"
        }
        switch reason {
        case .flagCaptured: return "\(name(winner)) captured the Flag"
        case .noMoves: return "\(name(winner)) wins: \(name(winner.opposite)) can't move"
        case .resignation: return "\(name(winner)) wins: \(name(winner.opposite)) resigned"
        case .timeout: return "\(name(winner)) wins on time"
        case .noMovablePieces, .agreement: return "\(name(winner)) wins"
        }
    }

    /// Deterministic tie-break when both Macs report different results.
    var sortKey: String { "\(reason.rawValue)-\(winner?.rawValue ?? "draw")" }
}

/// A proposal for a new game. Sides are already resolved (no "random" on the wire),
/// so both Macs build the identical game from it.
public struct Challenge: Codable, Hashable {
    public var gameID: UUID
    public var challenger: PlayerInfo
    public var challengerSide: Side
    public var timeControl: TimeControl

    public init(gameID: UUID = UUID(), challenger: PlayerInfo, challengerSide: Side, timeControl: TimeControl) {
        self.gameID = gameID
        self.challenger = challenger
        self.challengerSide = challengerSide
        self.timeControl = timeControl
    }
}

/// Sent as the context of a connection invitation.
public enum Invitation: Codable, Hashable {
    case challenge(Challenge)
    case resume(gameID: UUID, player: PlayerInfo)
    /// 2v2: the host invites one of the three other players.
    case teamChallenge(TeamChallenge)
    /// 2v2: links between the players of a table (also used to resume a saved 2v2 game).
    case teamJoin(gameID: UUID, player: PlayerInfo)
}

public struct InvitationEnvelope: Codable, Hashable {
    public var protocolVersion: Int
    public var invitation: Invitation

    public init(_ invitation: Invitation) {
        self.protocolVersion = Wire.protocolVersion
        self.invitation = invitation
    }
}

/// One side's setup as known to the snapshot's owner: the lock-in digest, the per-piece
/// commitments, and the ranks (with nonces) that have been revealed.
public struct SideSetupRecord: Codable, Hashable {
    public var readyDigest: String?
    public var commitments: [PieceCommitment]?
    public var reveals: [PieceReveal]

    public init(readyDigest: String? = nil, commitments: [PieceCommitment]? = nil, reveals: [PieceReveal] = []) {
        self.readyDigest = readyDigest
        self.commitments = commitments
        self.reveals = reveals
    }
}

/// Everything needed to save, resume and reconcile a game.
///
/// The copy saved on disk holds the owner's full setup. The copy sent to the opponent
/// (`Match.publicSnapshot`) holds only ranks the opponent is entitled to know.
public struct MatchSnapshot: Codable, Hashable, Identifiable {
    public var gameID: UUID
    public var red: PlayerInfo
    public var blue: PlayerInfo
    public var timeControl: TimeControl
    public var redSetup: SideSetupRecord
    public var blueSetup: SideSetupRecord
    public var moves: [Move]
    public var result: GameResult?
    /// A side that declared it had no legal move, while the result waits for the final reveal.
    public var stuckSide: Side?
    public var redRemaining: Double?
    public var blueRemaining: Double?
    public var chat: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public var id: UUID { gameID }

    public func player(_ side: Side) -> PlayerInfo { side == .red ? red : blue }

    public func side(of playerID: String) -> Side? {
        if red.id == playerID { return .red }
        if blue.id == playerID { return .blue }
        return nil
    }

    public func setup(_ side: Side) -> SideSetupRecord { side == .red ? redSetup : blueSetup }
    public func remaining(_ side: Side) -> Double? { side == .red ? redRemaining : blueRemaining }

    public var hasStarted: Bool { redSetup.commitments != nil && blueSetup.commitments != nil }
}

/// In-game messages. Every message travels inside a `WireEnvelope` tagged with its game.
public enum GameMessage: Codable, Hashable {
    /// Public state, exchanged whenever a connection (re)opens.
    case sync(MatchSnapshot)
    /// The sender locked in their setup; the digest commits to it without revealing anything.
    case ready(digest: String)
    /// Per-piece commitments, sent once both players are locked in.
    case commitments([PieceCommitment])
    /// `ply` is the 0-based index of the move. Attacks and multi-square moves carry the mover's
    /// rank. `remaining` is the mover's clock after the move.
    case move(ply: Int, move: Move, reveal: PieceReveal?, remaining: Double?)
    /// Ranks revealed after the fact: a defender's rank, or the whole army once the game ends.
    case reveal([PieceReveal])
    /// The sender has no legal move on their turn (followed by a full reveal).
    case noLegalMoves(ply: Int)
    case resign(side: Side)
    /// Sent by the player whose own clock ran out.
    case timeout(side: Side)
    case drawOffer
    case drawDeclined
    case drawAccepted
    case chat(ChatMessage)
    case rematchOffer(Challenge)
    case rematchDeclined
    case rematchAccepted(gameID: UUID)
    /// The sender is closing the game on purpose (not a connection drop).
    case leaving
}

public struct WireEnvelope: Codable, Hashable {
    public var protocolVersion: Int
    public var gameID: UUID
    public var message: GameMessage

    public init(gameID: UUID, message: GameMessage) {
        self.protocolVersion = Wire.protocolVersion
        self.gameID = gameID
        self.message = message
    }
}
