import BarrageCore
import SwiftUI

struct GameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if let match = model.match {
            if compact {
                CompactGameLayout(match: match)
            } else {
                GameLayout(match: match)
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Button("Back to Lobby") { model.leaveGame() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct GameLayout: View {
    @EnvironmentObject private var model: AppModel
    let match: Match

    private var displayedPosition: Position? {
        match.game.map { $0.positions[model.displayedPly] }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 10) {
                PlayerBar(match: match, side: match.opponentSide, position: displayedPosition)
                board
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PlayerBar(match: match, side: match.localSide, position: displayedPosition)
            }
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)

            SidePanel(match: match)
                .frame(width: 340)
        }
        .padding(20)
    }

    private var board: some View {
        SoloBoard(match: match)
    }
}

/// The 1v1 board: the setup board before the game, then the playing board.
private struct SoloBoard: View {
    @EnvironmentObject private var model: AppModel
    let match: Match

    var body: some View {
        board
    }

    @ViewBuilder
    private var board: some View {
        if let game = match.game {
            let ply = model.displayedPly
            let live = ply == game.ply
            let canMove = model.canMove
            ZStack {
                PlayBoardView(
                    position: game.positions[ply],
                    ranks: game.ranks,
                    localSide: match.localSide,
                    revealAll: model.revealsEverything,
                    lastMove: ply > 0 ? game.moves[ply - 1] : nil,
                    pendingAttack: live ? game.position.pendingAttack : nil,
                    interactive: canMove,
                    legalMoves: canMove ? match.legalMoves : [],
                    candidateMoves: canMove ? Rules.candidateMoves(in: game, for: match.localSide) : [],
                    onMove: { model.play($0) },
                    onBlockedMove: { model.explainBlockedMove($0) }
                )
                if let battle = model.battle {
                    BattleCard(report: battle, localSide: match.localSide)
                        .onTapGesture { model.dismissBattle() }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.battle)
        } else {
            SetupBoardView(
                setup: model.setupDraft,
                editable: model.canEditSetup,
                opponentName: match.opponent.name,
                opponentReady: match.isOpponentReady,
                onPlace: { model.placeFromTray($0, at: $1) },
                onMove: { model.moveSetupPiece(from: $0, to: $1) },
                onRemove: { model.removeSetupPiece(at: $0) }
            )
        }
    }
}

// MARK: - iPhone layout

/// The 1v1 screen stacked for a phone: the board between the two player bars, and a tabbed
/// panel underneath instead of the side panel.
private struct CompactGameLayout: View {
    @EnvironmentObject private var model: AppModel
    let match: Match
    @State private var tab: PanelTab = .game
    @State private var chat = UnreadChat()

    private var displayedPosition: Position? {
        match.game.map { $0.positions[model.displayedPly] }
    }

    private var tabs: [(tab: PanelTab, title: String)] {
        let unread = chat.unread(match.chat) { $0.senderID == model.playerID }
        if match.phase == .setup {
            return [(.game, "Setup"), (.chat, UnreadChat.title(unread))]
        }
        return [(.game, "Game"), (.moves, "Moves"), (.chat, UnreadChat.title(unread))]
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 6) {
                CompactTopBar(onBack: { model.leaveGame() },
                              detail: match.timeControl.isUnlimited ? "No clock" : match.timeControl.label) {
                    StatusCard(match: match, compact: true)
                }
                PlayerBar(match: match, side: match.opponentSide, position: displayedPosition, compact: true)
                SoloBoard(match: match)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                PlayerBar(match: match, side: match.localSide, position: displayedPosition, compact: true)
                PromptsView(match: match)
                PanelTabPicker(selection: $tab, tabs: tabs)
                panel
                    .frame(minHeight: max(150, geometry.size.height * (geometry.size.width > 600 ? 0.3 : 0.22)), maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .onAppear { chat.markRead(match.chat.count) }
        .onChange(of: match.chat.count) { count in
            if tab == .chat { chat.markRead(count) }
        }
        .onChange(of: tab) { tab in
            if tab == .chat { chat.markRead(match.chat.count) }
        }
        .onChange(of: match.phase) { phase in
            if phase == .setup && tab == .moves { tab = .game }
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch tab {
        case .moves:
            VStack(spacing: 8) {
                MoveListView(match: match)
                NavigationButtons(match: match)
            }
        case .chat:
            ChatView(match: match, showsTitle: false)
        case .game, .otherBoard:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if match.phase == .setup {
                        SetupPanel(isLocalReady: match.isLocalReady, compact: true)
                    } else {
                        StatusCard(match: match)
                        ActionButtons(match: match)
                        BadgeLegend()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Player bar & clock

private struct PlayerBar: View {
    let match: Match
    let side: Side
    let position: Position?
    /// iPhone: smaller pieces and clock, so it all fits in one line.
    var compact = false

    private var isLocal: Bool { side == match.localSide }
    private var isTurn: Bool {
        match.phase == .playing && match.stuckSide == nil && match.game?.position.sideToMove == side
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Palette.side(side))
                .frame(width: 14, height: 14)
            Text(match.player(side).name)
                .font(.headline)
                .lineLimit(1)
            if isLocal && !compact {
                Text("(you)").foregroundColor(.secondary)
            }
            if match.phase == .setup {
                readiness
            } else if let position = position {
                ArmyRoster(side: side, lost: lostRanks(position), size: compact ? 15 : 22)
                    .padding(.leading, compact ? 0 : 6)
                    .layoutPriority(1)
            }
            Spacer(minLength: compact ? 2 : 8)
            if let clock = match.clock {
                ClockView(clock: clock, side: side, isTurn: isTurn, fontSize: compact ? 17 : 22)
            } else if isTurn {
                Text("to move")
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)
            }
        }
        .frame(height: compact ? 28 : 34)
    }

    @ViewBuilder
    private var readiness: some View {
        let ready = isLocal ? match.isLocalReady : match.isOpponentReady
        Label(ready ? "Ready" : "Setting up…", systemImage: ready ? "checkmark.circle.fill" : "hourglass")
            .font(.caption.bold())
            .foregroundColor(ready ? .green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    /// Lost pieces were all revealed in battle, so their ranks are known to both players.
    private func lostRanks(_ position: Position) -> [Rank] {
        let ranks = match.knownRanks
        return position.lostPieces(of: side).compactMap { ranks[$0.id] }
    }
}

struct ClockView: View {
    let clock: GameClock
    let side: Side
    let isTurn: Bool
    var fontSize: CGFloat = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: clock.running != side)) { context in
            let remaining = max(0, clock.remaining(side, at: context.date))
            let running = clock.running == side
            let low = remaining < 20
            Text(ClockView.format(remaining))
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .padding(.horizontal, fontSize * 0.55)
                .padding(.vertical, 3)
                .foregroundColor(running ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(running ? (low ? Color.red : Palette.clockRunning) : Color.secondary.opacity(isTurn ? 0.3 : 0.12))
                )
        }
    }

    static func format(_ seconds: Double) -> String {
        if seconds < 10 {
            return String(format: "0:%04.1f", floor(seconds * 10) / 10)
        }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Side panel

private struct SidePanel: View {
    @EnvironmentObject private var model: AppModel
    let match: Match

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    model.leaveGame()
                } label: {
                    Label("Lobby", systemImage: "chevron.left")
                }
                Spacer()
                Text(match.timeControl.isUnlimited ? "No clock" : match.timeControl.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            StatusCard(match: match)
            PromptsView(match: match)
            if match.phase == .setup {
                SetupPanel(isLocalReady: match.isLocalReady)
                Spacer(minLength: 0)
            } else {
                MoveListView(match: match)
                    .frame(maxHeight: .infinity)
                NavigationButtons(match: match)
                BadgeLegend()
                ActionButtons(match: match)
            }
            Divider()
            ChatView(match: match)
                .frame(height: 180)
        }
    }
}

private struct StatusCard: View {
    @EnvironmentObject private var model: AppModel
    let match: Match
    /// The one-line version for the iPhone's top bar.
    var compact = false

    var body: some View {
        if compact {
            StatusPill(icon: icon, title: match.isOver ? shortResult : title, tint: tint)
        } else {
            card
        }
    }

    private var shortResult: String {
        guard let result = match.result else { return "Game over" }
        guard let winner = result.winner else { return "Draw" }
        return winner == match.localSide ? "You won" : "You lost"
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title).font(.headline)
            }
            if let detail = detail {
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsResumeButton {
                Button("Ask \(match.opponent.name) to Resume") { model.askToResume() }
                    .disabled(model.nearbyPlayer(match.opponent.id) == nil || model.outgoingInvite != nil)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)))
    }

    private var opponentName: String { match.opponent.name }
    private var opponentNearby: Bool { model.nearbyPlayer(match.opponent.id) != nil }

    private var showsResumeButton: Bool {
        !match.isOver && model.linkStatus == .waiting
    }

    private var title: String {
        if let result = match.result {
            return result.summary(red: match.red.name, blue: match.blue.name)
        }
        switch model.linkStatus {
        case .connecting: return "Connecting to \(opponentName)…"
        case .reconnecting: return "Connection lost. Reconnecting…"
        case .waiting: return model.opponentLeftOnPurpose ? "\(opponentName) left the game" : "\(opponentName) isn't responding"
        case .offline: return "Not connected"
        case .connected:
            switch match.phase {
            case .setup:
                if !match.isLocalReady { return "Set up your army" }
                return match.isOpponentReady ? "Starting…" : "Waiting for \(opponentName)"
            case .playing:
                if match.stuckSide == match.localSide { return "You can't move" }
                if match.stuckSide != nil { return "\(opponentName) can't move" }
                if match.isAwaitingBattle { return "Battle!" }
                return match.isLocalTurn ? "Your move" : "\(opponentName) is thinking…"
            case .over:
                return ""
            }
        }
    }

    private var detail: String? {
        if match.isOver {
            var lines: [String] = []
            switch match.verification {
            case .passed?: lines.append("Both armies were revealed and checked against every move.")
            case .failed(let reason)?: lines.append("⚠︎ Setup check failed: \(reason)")
            case nil:
                if model.linkStatus == .connected { lines.append("Revealing both armies…") }
            }
            switch model.linkStatus {
            case .connected: break
            case .offline: lines.append("Reviewing a saved game.")
            default: lines.append("\(opponentName) has disconnected.")
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        switch model.linkStatus {
        case .connecting:
            return "Waiting for \(opponentName) to answer."
        case .reconnecting:
            return opponentNearby
                ? "Clocks are paused. Trying to reach \(opponentName) again…"
                : "Clocks are paused. Waiting for \(opponentName) to come back in range with Offline Barrage open."
        case .waiting:
            return "The game is saved and the clocks are paused. You can resume whenever you're both ready."
        case .offline:
            return nil
        case .connected:
            switch match.phase {
            case .setup:
                if !match.isLocalReady {
                    return match.isOpponentReady ? "\(opponentName) is ready and waiting for you." : nil
                }
                return match.isOpponentReady ? nil : "Your setup is locked in. The game starts when \(opponentName) is ready."
            case .playing:
                if match.stuckSide != nil { return "Revealing both armies to settle the result…" }
                if match.isAwaitingBattle { return "Waiting for \(opponentName)'s app to reveal the defender." }
                return nil
            case .over:
                return nil
            }
        }
    }

    private var icon: String {
        if match.isOver { return "flag.checkered" }
        switch model.linkStatus {
        case .connected:
            if match.phase == .setup { return match.isLocalReady ? "hourglass" : "square.grid.3x3.fill" }
            if match.isAwaitingBattle { return "bolt.fill" }
            return match.isLocalTurn ? "hand.point.right.fill" : "hourglass"
        case .connecting, .reconnecting: return "antenna.radiowaves.left.and.right"
        case .waiting, .offline: return "pause.circle"
        }
    }

    private var tint: Color {
        if match.isOver {
            if case .failed? = match.verification { return .red }
            return .purple
        }
        switch model.linkStatus {
        case .connected:
            if match.phase == .setup { return match.isLocalReady ? .secondary : .green }
            return match.isLocalTurn ? .green : .secondary
        case .connecting, .reconnecting, .waiting: return .orange
        case .offline: return .secondary
        }
    }
}

/// Pending offers from the opponent (and our own pending requests).
private struct PromptsView: View {
    @EnvironmentObject private var model: AppModel
    let match: Match

    var body: some View {
        VStack(spacing: 8) {
            if match.drawOfferFrom == match.opponentSide {
                PromptRow(text: "\(match.opponent.name) offers a draw.",
                          accept: { model.respondToDraw(accept: true) },
                          decline: { model.respondToDraw(accept: false) })
            }
            if model.rematchOfferIn != nil {
                PromptRow(text: "\(match.opponent.name) wants a rematch (sides swapped).",
                          accept: { model.respondToRematch(accept: true) },
                          decline: { model.respondToRematch(accept: false) })
            }
            if match.drawOfferFrom == match.localSide {
                InfoRow(text: "You offered a draw.")
            }
            if model.rematchOfferOut != nil {
                InfoRow(text: "Rematch offered. Waiting for \(match.opponent.name)…")
            }
        }
    }
}

struct PromptRow: View {
    let text: String
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.callout.bold()).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Decline", action: decline)
                Button("Accept", action: accept)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
    }
}

struct InfoRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Setup

struct SetupPanel: View {
    @EnvironmentObject private var model: AppModel
    let isLocalReady: Bool
    /// iPhone: the buttons first, so Ready is visible without scrolling.
    var compact = false
    @State private var naming = false

    private var instructions: String {
        "Put all 8 pieces anywhere on your four back rows. Drag them from the tray, or \(Device.click) a piece and then a square. Drag a piece off the board to take it back."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if compact {
                buttons
                readyButton
                instructionsText
                RankLegend()
            } else {
                Text("Your army").font(.headline)
                instructionsText
                buttons
                RankLegend()
                readyButton
            }
        }
        .sheet(isPresented: $naming) {
            SaveSetupSheet { name in model.saveSetup(named: name) }
        }
    }

    private var instructionsText: some View {
        Text(instructions)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        let draft = model.setupDraft
        return HStack {
                Button { model.randomizeSetup() } label: { Label("Random", systemImage: "shuffle") }
                Button { model.clearSetup() } label: { Label("Clear", systemImage: "arrow.uturn.backward") }
                    .disabled(draft.isEmpty)
                Menu {
                    if model.savedSetups.isEmpty {
                        Text("No saved setups yet")
                    }
                    ForEach(model.savedSetups) { saved in
                        Button(saved.name) { model.loadSetup(saved) }
                    }
                    Divider()
                    Button("Save Current Setup…") { naming = true }
                        .disabled(!draft.isComplete)
                    if !model.savedSetups.isEmpty {
                        Menu("Delete") {
                            ForEach(model.savedSetups) { saved in
                                Button(saved.name, role: .destructive) { model.deleteSetup(saved) }
                            }
                        }
                    }
                } label: {
                    Label("Setups", systemImage: "tray.full")
                }
                .fixedSize()
            }
            .disabled(!model.canEditSetup)
    }

    private var readyButton: some View {
        let draft = model.setupDraft
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                model.lockSetup()
            } label: {
                Label(isLocalReady ? "Locked In" : "Ready", systemImage: isLocalReady ? "lock.fill" : "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canLockSetup)

            if model.canEditSetup {
                let left = draft.unplaced.count
                Text(left > 0 ? "\(left) piece\(left == 1 ? "" : "s") left to place." : "Your setup can't be changed once you press Ready.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// What each piece does, for reference during setup.
struct RankLegend: View {
    private static let rows: [(Rank, String)] = [
        (.marshal, "Strongest, but loses to a Spy that attacks it"),
        (.general, "Second strongest"),
        (.miner, "The only piece that can defuse the Bomb"),
        (.scout, "Moves any distance in a straight line (2 of them)"),
        (.spy, "Weakest, but beats the Marshal when it attacks"),
        (.bomb, "Can't move; destroys any attacker but a Miner"),
        (.flag, "Can't move; capture it to win"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(RankLegend.rows, id: \.0) { rank, text in
                HStack(spacing: 8) {
                    PieceToken(token: TokenModel(side: .red, rank: rank), size: 20)
                    Text("\(rank.name):").font(.caption.bold())
                    Text(text).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

private struct SaveSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Setup").font(.title3.bold())
            TextField("Name, e.g. \u{201C}Flag in the corner\u{201D}", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260, maxWidth: 300)
                .onSubmit(save)
            Text("Saved setups work for either color.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(name)
        dismiss()
    }
}

// MARK: - Moves

private struct MoveListView: View {
    @EnvironmentObject private var model: AppModel
    let match: Match

    var body: some View {
        let records = match.game?.records ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if records.isEmpty {
                        Text(match.localSide == .red ? "You're Red: make the first move." : "Waiting for Red's first move.")
                            .foregroundColor(.secondary)
                            .padding(6)
                    }
                    ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                        MoveRow(number: index + 1, record: record, isShown: model.displayedPly == index + 1)
                            .id(index)
                            .onTapGesture { model.showPly(index + 1) }
                    }
                }
                .padding(6)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .onChange(of: records.count) { count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            .onAppear {
                if !records.isEmpty { proxy.scrollTo(records.count - 1, anchor: .bottom) }
            }
        }
    }
}

private struct MoveRow: View {
    let number: Int
    let record: MoveRecord
    let isShown: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.side(record.side))
                .frame(width: 9, height: 9)
            Text(moveText)
                .font(.system(.body, design: .monospaced))
                .frame(width: 74, alignment: .leading)
            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(record.isAttack ? .primary : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(isShown ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
    }

    private var moveText: String {
        "\(record.move.from.name)\(record.isAttack ? "×" : "–")\(record.move.to.name)"
    }

    private var detail: String? {
        if record.isAttack {
            guard let attacker = record.attackerRank, let defender = record.defenderRank, let outcome = record.outcome else {
                return "Battle…"
            }
            return BattleText.describe(attacker: attacker, defender: defender, outcome: outcome)
        }
        // Ranks this Mac knows are ours, or were revealed.
        return record.attackerRank?.name
    }
}

private struct NavigationButtons: View {
    @EnvironmentObject private var model: AppModel
    let match: Match

    var body: some View {
        let ply = model.displayedPly
        let last = match.game?.ply ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { model.showPly(0) } label: { Image(systemName: "backward.end.fill") }
                    .disabled(ply == 0)
                    .help("Starting position")
                Button { model.showPly(ply - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(ply == 0)
                    .help("Previous move")
                Button { model.showPly(ply + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(ply >= last)
                    .help("Next move")
                Button { model.showLive() } label: { Image(systemName: "forward.end.fill") }
                    .disabled(ply >= last)
                    .help("Latest position")
                Spacer()
                if model.viewPly != nil {
                    Text("Move \(ply) of \(last)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            if match.isOver && match.hasFullReveal {
                Toggle("Show every piece's rank", isOn: $model.showAllPieces)
                    .checkboxToggleStyle()
            }
        }
    }
}

/// Explains the small marks on the pieces.
private struct BadgeLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item("arrow.up.and.down.and.arrow.left.and.right", "Has moved")
            item("eye.fill", "Your rank is known to them")
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private func item(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.black.opacity(0.55)))
            Text(text)
        }
    }
}

private struct ActionButtons: View {
    @EnvironmentObject private var model: AppModel
    let match: Match
    @State private var confirmingResign = false

    var body: some View {
        HStack {
            if match.isOver {
                if model.linkStatus == .connected {
                    Button(model.rematchOfferIn != nil ? "Accept Rematch" : "Rematch") { model.offerRematch() }
                        .disabled(model.rematchOfferOut != nil)
                }
                Spacer()
            } else {
                Button("Offer Draw") { model.offerDraw() }
                    .disabled(!model.canAct || !match.canOfferDraw)
                Spacer()
                Button("Resign") { confirmingResign = true }
                    .disabled(!model.canAct)
            }
        }
        .confirmationDialog("Resign this game?", isPresented: $confirmingResign) {
            Button("Resign", role: .destructive) { model.resign() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Chat

private struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    let match: Match
    var showsTitle = true
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text("Chat").font(.headline)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(match.chat) { message in
                            ChatBubble(message: message, isMine: message.senderID == model.playerID,
                                       senderName: message.senderID == match.red.id ? match.red.name : match.blue.name)
                                .id(message.id)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .onChange(of: match.chat.count) { _ in
                    if let last = match.chat.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                TextField(model.linkStatus == .connected ? "Message \(match.opponent.name)" : "Chat is available while connected",
                          text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.linkStatus != .connected)
            }
            .disabled(model.linkStatus != .connected)
        }
    }

    private func send() {
        guard model.linkStatus == .connected else { return }
        model.sendChat(draft)
        draft = ""
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let isMine: Bool
    let senderName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(isMine ? "You" : senderName)
                .font(.caption.bold())
                .foregroundColor(isMine ? .accentColor : .primary)
            Text(message.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
