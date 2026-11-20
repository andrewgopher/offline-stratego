import CryptoKit
import Foundation

/// A piece's rank together with the random nonce that hides it inside its commitment.
public struct PieceSecret: Codable, Hashable {
    public var rank: Rank
    public var nonce: String

    public init(rank: Rank, nonce: String) {
        self.rank = rank
        self.nonce = nonce
    }
}

/// Proof of a piece's rank: the opponent checks it against the piece's commitment.
public struct PieceReveal: Codable, Hashable {
    public var piece: PieceID
    public var secret: PieceSecret

    public init(piece: PieceID, secret: PieceSecret) {
        self.piece = piece
        self.secret = secret
    }
}

/// A hash that binds a piece to its rank without revealing it.
public struct PieceCommitment: Codable, Hashable {
    public var piece: PieceID
    public var digest: String

    public init(piece: PieceID, digest: String) {
        self.piece = piece
        self.digest = digest
    }
}

/// Hash commitments that keep each player's setup secret without a referee.
///
/// When a player locks in their setup they send only `setupDigest`, a hash of all their piece
/// commitments, which hides even which squares are occupied. Once both are locked in, each
/// sends the per-piece commitments (checked against the digest). A rank is later revealed with
/// its nonce, and the other Mac checks it against the commitment, so nobody can change a
/// piece's rank after the setup.
public enum Commitments {
    static let domain = "offline-barrage/1"

    public static func digest(gameID: UUID, piece: PieceID, secret: PieceSecret) -> String {
        hash("\(domain)|piece|\(gameID.uuidString)|\(piece.rawValue)|\(secret.rank.rawValue)|\(secret.nonce)")
    }

    public static func setupDigest(gameID: UUID, commitments: [PieceID: String]) -> String {
        let body = commitments
            .sorted { $0.key < $1.key }
            .map { "\($0.key.rawValue):\($0.value)" }
            .joined(separator: ",")
        return hash("\(domain)|setup|\(gameID.uuidString)|\(body)")
    }

    public static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
