import BarrageCore
import SwiftUI

enum Palette {
    static func side(_ side: Side) -> Color {
        side == .red ? Color(red: 0.80, green: 0.24, blue: 0.20) : Color(red: 0.20, green: 0.42, blue: 0.76)
    }

    static func sideDark(_ side: Side) -> Color {
        side == .red ? Color(red: 0.55, green: 0.12, blue: 0.11) : Color(red: 0.10, green: 0.24, blue: 0.50)
    }

    static let fieldLight = Color(red: 0.86, green: 0.89, blue: 0.74)
    static let fieldDark = Color(red: 0.80, green: 0.85, blue: 0.67)
    static let lake = Color(red: 0.35, green: 0.62, blue: 0.83)
    static let lakeDeep = Color(red: 0.22, green: 0.47, blue: 0.70)
    static let gridLine = Color.black.opacity(0.10)
    static let lastMove = Color(red: 0.98, green: 0.84, blue: 0.25).opacity(0.55)
    static let selected = Color(red: 0.10, green: 0.55, blue: 0.25).opacity(0.45)
    static let hint = Color.black.opacity(0.28)
    static let homeZone = Color.white.opacity(0.32)
    /// A running clock (red is kept for low time).
    static let clockRunning = Color(red: 0.16, green: 0.52, blue: 0.30)
}

extension Rank {
    /// SF Symbol drawn on the piece.
    var symbol: String {
        switch self {
        case .marshal: return "crown.fill"
        case .general: return "star.fill"
        case .miner: return "hammer.fill"
        case .scout: return "binoculars.fill"
        case .spy: return "theatermasks.fill"
        case .bomb: return "burst.fill"
        case .flag: return "flag.fill"
        }
    }

    /// "Marshal (10)", "Bomb", ...
    var fullName: String {
        switch self {
        case .bomb, .flag: return name
        case .spy: return "Spy (1)"
        default: return "\(name) (\(label))"
        }
    }
}

/// What a piece looks like to the viewer.
struct TokenModel: Hashable {
    var side: Side
    /// Nil shows the back of the piece (rank unknown to the viewer).
    var rank: Rank?
    var showsMoved = false
    var showsRevealed = false
}

struct PieceToken: View {
    let token: TokenModel
    let size: CGFloat

    var body: some View {
        let corner = size * 0.17
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(LinearGradient(colors: [Palette.side(token.side), Palette.sideDark(token.side)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(Color.black.opacity(0.35), lineWidth: max(1, size * 0.03))
            if let rank = token.rank {
                face(rank)
            } else {
                // The plain back of a piece whose rank is hidden.
                RoundedRectangle(cornerRadius: corner * 0.6)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: max(1, size * 0.045))
                    .padding(size * 0.17)
            }
            if size >= 30 { badges }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.28), radius: size * 0.03, y: size * 0.025)
    }

    @ViewBuilder
    private func face(_ rank: Rank) -> some View {
        if size >= 30 {
            VStack(spacing: size * 0.01) {
                Image(systemName: rank.symbol)
                    .font(.system(size: size * 0.27, weight: .semibold))
                Text(rank.label)
                    .font(.system(size: size * (rank.label.count > 1 ? 0.33 : 0.37), weight: .heavy, design: .rounded))
            }
            .foregroundColor(.white)
            .offset(y: size * 0.02)
        } else {
            Text(rank.label)
                .font(.system(size: size * (rank.label.count > 1 ? 0.5 : 0.58), weight: .heavy, design: .rounded))
                .foregroundColor(.white)
        }
    }

    private var badges: some View {
        VStack {
            HStack(spacing: 0) {
                if token.showsRevealed { badge("eye.fill") }
                Spacer(minLength: 0)
                if token.showsMoved { badge("arrow.up.and.down.and.arrow.left.and.right") }
            }
            Spacer(minLength: 0)
        }
        .padding(size * 0.035)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.13, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size * 0.25, height: size * 0.25)
            .background(Circle().fill(Color.black.opacity(0.5)))
    }
}

/// A side's eight pieces, with the ones lost in battle faded and struck through.
struct ArmyRoster: View {
    let side: Side
    let lost: [Rank]
    var size: CGFloat = 22

    var body: some View {
        let flags = ArmyRoster.lostFlags(lost)
        HStack(spacing: 3) {
            ForEach(Array(Rank.barrageArmy.enumerated()), id: \.offset) { index, rank in
                PieceToken(token: TokenModel(side: side, rank: rank), size: size)
                    .opacity(flags[index] ? 0.25 : 1)
                    .overlay {
                        if flags[index] {
                            Image(systemName: "xmark")
                                .font(.system(size: size * 0.7, weight: .bold))
                                .foregroundColor(.primary.opacity(0.75))
                        }
                    }
                    .contentShape(Rectangle())
                    .help(flags[index] ? "\(rank.fullName): captured" : "\(rank.fullName): still on the board")
            }
        }
    }

    /// Marks which of the army's slots are lost (for two Scouts, the first one goes first).
    static func lostFlags(_ lost: [Rank]) -> [Bool] {
        var remaining = lost
        return Rank.barrageArmy.map { rank in
            if let index = remaining.firstIndex(of: rank) {
                remaining.remove(at: index)
                return true
            }
            return false
        }
    }
}

enum BattleText {
    static func describe(attacker: Rank, defender: Rank, outcome: BattleOutcome) -> String {
        if defender == .flag { return "\(attacker.name) captures the Flag!" }
        if defender == .bomb {
            return outcome == .attackerWins ? "Miner defuses the Bomb" : "\(attacker.name) hits the Bomb"
        }
        switch outcome {
        case .attackerWins:
            return attacker == .spy ? "Spy takes out the Marshal" : "\(attacker.name) beats \(defender.name)"
        case .defenderWins:
            return "\(attacker.name) loses to \(defender.name)"
        case .bothLose:
            return attacker == defender ? "Both \(attacker.name)s fall" : "\(attacker.name) and \(defender.name) both fall"
        }
    }
}

/// Shown over the board for a moment after each battle.
struct BattleCard: View {
    let title: String
    let attackerSide: Side
    let attackerRank: Rank
    let attackerLabel: String
    let defenderRank: Rank
    let defenderLabel: String
    let outcome: BattleOutcome
    /// Smaller, for the other board in 2v2.
    var compact = false
    /// A one-line strip (iPhone: the other board's battles, shown at the top of the screen).
    private var banner = false

    func asBanner() -> BattleCard {
        var card = self
        card.banner = true
        return card
    }

    init(report: BattleReport, localSide: Side) {
        title = report.attackerSide == localSide ? "You attack!" : "You're attacked!"
        attackerSide = report.attackerSide
        attackerRank = report.attackerRank
        defenderRank = report.defenderRank
        outcome = report.outcome
        attackerLabel = report.attackerSide == localSide ? "Your \(report.attackerRank.name)" : "Their \(report.attackerRank.name)"
        defenderLabel = report.defenderSide == localSide ? "Your \(report.defenderRank.name)" : "Their \(report.defenderRank.name)"
    }

    /// A 2v2 battle as `viewer` sees it: on their own board, or on their partner's.
    init(team report: TeamBattleReport, viewer: Seat, compact: Bool = false) {
        let ownBoard = report.board == viewer.board
        let ours = ownBoard ? viewer.side : viewer.partner.side
        let possessive = ownBoard ? "Your" : "Teammate's"
        if report.attackerSide == ours {
            title = ownBoard ? "You attack!" : "Your teammate attacks!"
        } else {
            title = ownBoard ? "You're attacked!" : "Your teammate is attacked!"
        }
        attackerSide = report.attackerSide
        attackerRank = report.attackerRank
        defenderRank = report.defenderRank
        outcome = report.outcome
        attackerLabel = report.attackerSide == ours ? "\(possessive) \(report.attackerRank.name)" : "Their \(report.attackerRank.name)"
        defenderLabel = report.attackerSide == ours ? "Their \(report.defenderRank.name)" : "\(possessive) \(report.defenderRank.name)"
        self.compact = compact
    }

    private var defenderSide: Side { attackerSide.opposite }

    private func lost(_ attacker: Bool) -> Bool {
        switch outcome {
        case .attackerWins: return !attacker
        case .defenderWins: return attacker
        case .bothLose: return true
        }
    }

    @ViewBuilder
    var body: some View {
        if banner {
            bannerBody
        } else {
            cardBody
        }
    }

    private var bannerBody: some View {
        HStack(spacing: 8) {
            token(side: attackerSide, rank: attackerRank, lost: lost(true), size: 30)
            Image(systemName: "bolt.fill")
                .foregroundColor(.orange)
            token(side: defenderSide, rank: defenderRank, lost: lost(false), size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(BattleText.describe(attacker: attackerRank, defender: defenderRank, outcome: outcome))
                    .font(.callout.bold())
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private func token(side: Side, rank: Rank, lost: Bool, size: CGFloat) -> some View {
        PieceToken(token: TokenModel(side: side, rank: rank), size: size)
            .opacity(lost ? 0.35 : 1)
            .overlay {
                if lost {
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.63, weight: .bold))
                        .foregroundColor(.black.opacity(0.6))
                }
            }
    }

    private var cardBody: some View {
        VStack(spacing: compact ? 8 : 12) {
            Text(title)
                .font(compact ? .subheadline.bold() : .headline)
                .foregroundColor(.secondary)
            HStack(spacing: compact ? 12 : 18) {
                fighter(side: attackerSide, rank: attackerRank, label: attackerLabel, lost: lost(true))
                Image(systemName: "bolt.fill")
                    .font(.system(size: compact ? 18 : 26))
                    .foregroundColor(.orange)
                fighter(side: defenderSide, rank: defenderRank, label: defenderLabel, lost: lost(false))
            }
            Text(BattleText.describe(attacker: attackerRank, defender: defenderRank, outcome: outcome))
                .font(compact ? .callout.bold() : .title3.bold())
        }
        .padding(.horizontal, compact ? 16 : 26)
        .padding(.vertical, compact ? 12 : 18)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
    }

    private func fighter(side: Side, rank: Rank, label: String, lost: Bool) -> some View {
        let size: CGFloat = compact ? 48 : 70
        return VStack(spacing: 6) {
            PieceToken(token: TokenModel(side: side, rank: rank), size: size)
                .opacity(lost ? 0.35 : 1)
                .overlay {
                    if lost {
                        Image(systemName: "xmark")
                            .font(.system(size: size * 0.63, weight: .bold))
                            .foregroundColor(.black.opacity(0.6))
                    }
                }
            Text(label)
                .font(compact ? .caption : .callout)
        }
    }
}
