import BarrageCore
import SwiftUI

/// The 2v2 screen: our board, our partner's board, and the side panel (or, on a phone, our
/// board with a thumbnail of our partner's underneath).
struct TeamGameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if let table = model.teamTable {
            if compact {
                CompactTeamLayout(table: table)
            } else {
                TeamGameLayout(table: table)
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Button("Back to Lobby") { model.closeTeamTable() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TeamGameLayout: View {
    @ObservedObject var table: TeamTable

    static let panelWidth: CGFloat = 300

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 16
            let boardsWidth = max(560, geometry.size.width - TeamGameLayout.panelWidth - spacing * 2 - 32)
            let mine = floor(boardsWidth * 0.56)
            HStack(alignment: .top, spacing: spacing) {
                TeamBoardColumn(table: table, board: table.localSeat.board)
                    .frame(width: mine)
                TeamBoardColumn(table: table, board: table.localSeat.board.other)
                    .frame(width: boardsWidth - mine)
                TeamSidePanel(table: table)
                    .frame(width: TeamGameLayout.panelWidth)
            }
            .padding(16)
        }
    }
}

// MARK: - iPhone layout

/// The 2v2 screen stacked for a phone: our board between its two player bars, then a tabbed
/// panel whose first tab shows our partner's board as a thumbnail (tap it to enlarge).
private struct CompactTeamLayout: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var table: TeamTable
    @State private var tab: PanelTab = .game
    @State private var chat = UnreadChat()
    @State private var showingOtherBoard = false

    private var match: TeamMatch { table.match }
    private var myBoard: BoardID { table.localSeat.board }

    private var tabs: [(tab: PanelTab, title: String)] {
        let unread = chat.unread(match.chat) { $0.senderID == model.playerID }
        let other = (tab: PanelTab.otherBoard, title: myBoard.other.name)
        let chatTab = (tab: PanelTab.chat, title: UnreadChat.title(unread))
        switch match.phase {
        case .setup: return [(.game, "Setup"), other, chatTab]
        case .playing: return [other, (.game, "Game"), chatTab]
        case .over: return [(.game, "Review"), other, chatTab]
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 6) {
                CompactTopBar(onBack: { model.leaveTeamTable() }, detail: match.timeControl.label) {
                    TeamStatusCard(table: table, compact: true)
                }
                TeamPlayerBar(table: table, seat: table.localSeat.opponent, compact: false)
                TeamBoardSurface(table: table, board: myBoard, small: false)
                    .aspectRatio(match.hasStarted ? 1 : SetupBoardView.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                TeamPlayerBar(table: table, seat: table.localSeat, compact: false)
                TeamPromptsView(table: table)
                VStack(spacing: 6) {
                    PanelTabPicker(selection: $tab, tabs: tabs)
                    panel
                }
                .frame(minHeight: max(150, geometry.size.height * (geometry.size.width > 600 ? 0.3 : 0.22)), maxHeight: .infinity, alignment: .top)
                // Picking a reserve piece: say what to do next, right under the reserve, without
                // covering any of our pieces.
                .overlay(alignment: .top) {
                    if let rank = table.swapRank, table.canSwap {
                        SwapPrompt(rank: rank) { table.cancelSwap() }
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: table.swapRank)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        // What happens on the other board shows up top, since its thumbnail is small (and not
        // always on screen).
        .overlay(alignment: .top) {
            OtherBoardAlerts(table: table, board: myBoard.other)
                .padding(.horizontal, 12)
        }
        .sheet(isPresented: $showingOtherBoard) {
            OtherBoardSheet(table: table)
                .environmentObject(model)
        }
        .onAppear {
            chat.markRead(match.chat.count)
            if match.phase == .playing { tab = .otherBoard }
        }
        .onChange(of: match.chat.count) { count in
            if tab == .chat { chat.markRead(count) }
        }
        .onChange(of: tab) { tab in
            if tab == .chat { chat.markRead(match.chat.count) }
        }
        .onChange(of: match.phase) { phase in
            // Keep an eye on the other board while playing; review afterwards.
            if tab != .chat { tab = phase == .playing ? .otherBoard : .game }
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch tab {
        case .otherBoard:
            OtherBoardThumbnail(table: table) { showingOtherBoard = true }
        case .chat:
            TeamChatView(table: table, showsTitle: false)
        case .game, .moves:
            if match.phase == .over {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        TeamStatusCard(table: table)
                        TeamReviewPanel(table: table, inline: true)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if match.phase == .setup {
                            SetupPanel(isLocalReady: match.isLocalReady, compact: true)
                            TeamStatusCard(table: table)
                        } else {
                            TeamStatusCard(table: table)
                            SwapHelp(table: table)
                            TeamsCard(table: table)
                            TeamActionButtons(table: table)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

/// Our partner's board, small, with both players' clocks and reserves beside it.
private struct OtherBoardThumbnail: View {
    @ObservedObject var table: TeamTable
    let onEnlarge: () -> Void

    var body: some View {
        let partner = table.localSeat.partner
        GeometryReader { geometry in
            let side = min(geometry.size.height, geometry.size.width * 0.52)
            HStack(alignment: .top, spacing: 10) {
                TeamBoardSurface(table: table, board: partner.board, small: true, thumbnail: true, overlayScale: max(0.5, side / 330))
                    .frame(width: side, height: side)
                    .overlay {
                        // The thumbnail can't be played on; a tap opens the full-size board.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onEnlarge)
                    }
                VStack(alignment: .leading, spacing: 6) {
                    MiniSeatSummary(table: table, seat: partner.opponent)
                    Spacer(minLength: 0)
                    MiniSeatSummary(table: table, seat: partner)
                    Button(action: onEnlarge) {
                        Label("Enlarge", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: side, alignment: .topLeading)
            }
        }
    }
}

/// iPhone: the other board's swap notice and battle, as banners at the top of the screen.
private struct OtherBoardAlerts: View {
    @ObservedObject var table: TeamTable
    let board: BoardID

    var body: some View {
        VStack(spacing: 6) {
            if let text = table.notices[board] {
                NoticeCapsule(text: "\(board.name): \(text)", compact: false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let battle = table.battles[board] {
                BattleCard(team: battle, viewer: table.localSeat).asBanner()
                    .onTapGesture { table.dismissBattle(board) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: table.notices[board])
        .animation(.easeOut(duration: 0.18), value: table.battles[board])
    }
}

/// One player of the other board, for the thumbnail: name, clock and reserve.
private struct MiniSeatSummary: View {
    @ObservedObject var table: TeamTable
    let seat: Seat

    private var match: TeamMatch { table.match }

    private var isTurn: Bool {
        guard match.phase == .playing, let board = match.board(seat.board) else { return false }
        return !board.isOver && board.sideToMove == seat.side
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.side(seat.side))
                    .frame(width: 9, height: 9)
                Text(match.player(seat).name)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(seat == table.localSeat.partner ? "teammate" : "opponent")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if table.linkState(of: seat) != .connected && table.links != nil {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            if match.phase == .setup {
                let ready = match.isReady(seat)
                Label(ready ? "Ready" : "Setting up…", systemImage: ready ? "checkmark.circle.fill" : "hourglass")
                    .font(.caption2.bold())
                    .foregroundColor(ready ? .green : .secondary)
            } else if let clock = match.clocks[seat.board] {
                ClockView(clock: clock, side: seat.side, isTurn: isTurn, fontSize: 14)
            }
            if match.hasStarted {
                let groups = ReserveRow.grouped(match.reserve(of: seat))
                if groups.isEmpty {
                    Text("Reserve empty")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    FlowLayout(spacing: 3) {
                        ForEach(groups, id: \.rank) { group in
                            ReserveToken(side: seat.side, rank: group.rank, count: group.count, size: 16,
                                         selected: false, selectable: false)
                        }
                    }
                }
            }
        }
    }
}

/// The other board at full size (from the thumbnail).
private struct OtherBoardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var table: TeamTable

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .font(.headline)
            }
            TeamBoardColumn(table: table, board: table.localSeat.partner.board)
        }
        .padding()
    }
}

// MARK: - Boards

private struct TeamBoardColumn: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var table: TeamTable
    let board: BoardID

    private var match: TeamMatch { table.match }
    private var isMine: Bool { board == table.localSeat.board }
    /// Our team sits at the bottom of both boards.
    private var bottom: Seat { isMine ? table.localSeat : table.localSeat.partner }
    private var top: Seat { bottom.opponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(board.name).font(.caption.bold())
                Text(isMine ? "· Your game" : "· \(match.player(bottom).name)'s game")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            TeamPlayerBar(table: table, seat: top, compact: !isMine)
            TeamBoardSurface(table: table, board: board, small: !isMine)
                // Keep the player bars right against the board.
                .aspectRatio(isSetupBoard ? SetupBoardView.aspectRatio : 1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
            TeamPlayerBar(table: table, seat: bottom, compact: !isMine)
            if match.isOver {
                TeamNavigationButtons(table: table, board: board)
            }
            Spacer(minLength: 0)
        }
    }

    private var isSetupBoard: Bool { isMine && !match.hasStarted }
}

/// One board with its swap notice and battle card on top (the player bars go around it).
private struct TeamBoardSurface: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var table: TeamTable
    let board: BoardID
    /// The smaller notice and battle card of the other board.
    let small: Bool
    /// iPhone's thumbnail of the other board: its notices and battles show elsewhere.
    var thumbnail = false
    /// Shrinks the overlays to fit a thumbnail.
    var overlayScale: CGFloat = 1

    private var match: TeamMatch { table.match }
    private var isMine: Bool { board == table.localSeat.board }
    /// Our team sits at the bottom of both boards.
    private var bottom: Seat { isMine ? table.localSeat : table.localSeat.partner }
    private var top: Seat { bottom.opponent }

    var body: some View {
        boardView
            // Overlays, so the notice never changes the board's size.
            .overlay(alignment: .top) {
                if !thumbnail, let text = table.notices[board] {
                    NoticeCapsule(text: text, compact: small)
                        .padding(.top, 10 * overlayScale)
                        .padding(.horizontal, 10 * overlayScale)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: table.notices[board])
    }

    @ViewBuilder
    private var boardView: some View {
        if let teamBoard = match.board(board) {
            let ply = table.displayedPly(board)
            let live = ply == teamBoard.ply
            let interactive = isMine && table.canMove
            let swapping = interactive && table.swapRank != nil
            let revealed = table.revealsEverything ? match.revealedRanks(on: board, afterTurns: ply) : nil
            PlayBoardView(
                    position: teamBoard.positions[ply],
                    ranks: revealed ?? match.teamRanks(on: board),
                    localSide: bottom.side,
                    revealAll: revealed != nil,
                    lastMove: ply > 0 ? teamBoard.turns[ply - 1].move : nil,
                    pendingAttack: live ? teamBoard.position.pendingAttack : nil,
                    interactive: interactive,
                    legalMoves: interactive && !swapping ? match.legalMoves : [],
                    candidateMoves: interactive && !swapping ? match.candidateMoves : [],
                    onMove: { table.play($0) },
                    onBlockedMove: { table.explainBlockedMove($0) },
                    memoryAids: false,
                    swapTargets: swapping ? Set(match.swappablePieces.compactMap { teamBoard.position.pieces[$0]?.square }) : [],
                    onSwap: { table.swap(at: $0) },
                    highlight: isMine ? nil : table.partnerSwapSquare
                )
                .overlay {
                    if !thumbnail, let battle = table.battles[board] {
                        BattleCard(team: battle, viewer: table.localSeat, compact: small)
                            .scaleEffect(overlayScale)
                            .onTapGesture { table.dismissBattle(board) }
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: table.battles[board])
        } else if isMine {
            SetupBoardView(
                setup: model.setupDraft,
                editable: model.canEditSetup,
                opponentName: match.player(top).name,
                opponentReady: match.isReady(top),
                onPlace: { model.placeFromTray($0, at: $1) },
                onMove: { model.moveSetupPiece(from: $0, to: $1) },
                onRemove: { model.removeSetupPiece(at: $0) }
            )
        } else {
            partnerSetupPreview
        }
    }

    /// Before the game: our partner's setup (face up once they lock it in) and the readiness of
    /// both players on that board.
    private var partnerSetupPreview: some View {
        let ranks = match.partnerRanks
        let pieces = ranks.keys.map { $0 }
        return ZStack {
            PlayBoardView(
                position: Position(pieces: pieces),
                ranks: ranks,
                localSide: bottom.side,
                revealAll: false,
                lastMove: nil,
                pendingAttack: nil,
                interactive: false,
                legalMoves: [],
                candidateMoves: [],
                onMove: { _ in },
                onBlockedMove: { _ in },
                memoryAids: false
            )
            GeometryReader { geometry in
                VStack(spacing: 6) {
                    readiness(top)
                    readiness(bottom)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                .scaleEffect(overlayScale)
                // In the middle of the opponent's four rows.
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.2)
            }
        }
    }

    private func readiness(_ seat: Seat) -> some View {
        HStack(spacing: 6) {
            if match.isReady(seat) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("\(match.player(seat).name) is ready")
            } else {
                ProgressView().controlSize(.small)
                Text("\(match.player(seat).name) is setting up…")
            }
        }
    }
}

/// iPhone: "Tap one of your pieces…" over the board while a reserve piece is picked.
private struct SwapPrompt: View {
    let rank: Rank
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("Tap one of your pieces to swap in your \(rank.name).")
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
        }
        .font(.callout.bold())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

private struct NoticeCapsule: View {
    let text: String
    let compact: Bool

    var body: some View {
        // On a phone the text often wraps, which a capsule doesn't suit.
        let shape = Device.isTouch ? AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) : AnyShape(Capsule())
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(compact ? .caption.bold() : .callout.bold())
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(shape.fill(.regularMaterial))
        .overlay(shape.stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Player bar

private struct TeamPlayerBar: View {
    @ObservedObject var table: TeamTable
    let seat: Seat
    let compact: Bool

    private var match: TeamMatch { table.match }

    private var tag: String {
        if seat == table.localSeat { return "you" }
        if seat == table.localSeat.partner { return "teammate" }
        return "opponent"
    }

    private var isTurn: Bool {
        guard match.phase == .playing, let board = match.board(seat.board) else { return false }
        return !board.isOver && board.sideToMove == seat.side
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Palette.side(seat.side))
                    .frame(width: 12, height: 12)
                Text(match.player(seat).name)
                    .font(compact ? .subheadline.bold() : .headline)
                    .lineLimit(1)
                Text(tag)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if table.linkState(of: seat) != .connected && table.links != nil {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundColor(.orange)
                        .help("Not connected to \(match.player(seat).name)")
                }
                if match.phase == .setup {
                    let ready = match.isReady(seat)
                    Label(ready ? "Ready" : "Setting up…", systemImage: ready ? "checkmark.circle.fill" : "hourglass")
                        .font(.caption.bold())
                        .foregroundColor(ready ? .green : .secondary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let clock = match.clocks[seat.board] {
                    ClockView(clock: clock, side: seat.side, isTurn: isTurn, fontSize: compact ? 16 : (Device.isTouch ? 18 : 21))
                }
            }
            if match.hasStarted {
                ReserveRow(table: table, seat: seat, compact: compact)
            }
        }
    }
}

/// The pieces a player can swap in, with their ranks (everyone sees every reserve).
private struct ReserveRow: View {
    @ObservedObject var table: TeamTable
    let seat: Seat
    let compact: Bool

    var body: some View {
        let ranks = table.match.reserve(of: seat)
        let mine = seat == table.localSeat
        let groups = ReserveRow.grouped(ranks)
        // Our own reserve is tapped on a touch screen: make it bigger there.
        let size: CGFloat = compact ? 18 : (mine && Device.isTouch ? 28 : 22)
        HStack(spacing: mine && Device.isTouch ? 6 : 4) {
            Text("Reserve")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
            if groups.isEmpty {
                Text("empty")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            ForEach(groups, id: \.rank) { group in
                ReserveToken(side: seat.side, rank: group.rank, count: group.count, size: size,
                             selected: mine && table.swapRank == group.rank,
                             selectable: mine && table.canSwap)
                    .onTapGesture { if mine { table.toggleSwapRank(group.rank) } }
                    .help(mine ? (table.canSwap ? "\(Device.Click) to swap a \(group.rank.name) in for one of your pieces" : "\(group.rank.fullName)")
                               : group.rank.fullName)
            }
            Spacer(minLength: 0)
        }
        .frame(height: size + 2)
    }

    static func grouped(_ ranks: [Rank]) -> [(rank: Rank, count: Int)] {
        var result: [(rank: Rank, count: Int)] = []
        for rank in ranks {
            if let last = result.last, last.rank == rank {
                result[result.count - 1].count += 1
            } else {
                result.append((rank, 1))
            }
        }
        return result
    }
}

struct ReserveToken: View {
    let side: Side
    let rank: Rank
    let count: Int
    let size: CGFloat
    let selected: Bool
    let selectable: Bool

    var body: some View {
        HStack(spacing: 1) {
            PieceToken(token: TokenModel(side: side, rank: rank), size: size)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: size * 0.2)
                            .strokeBorder(Color.green, lineWidth: 3)
                            .padding(-3)
                    }
                }
            if count > 1 {
                Text("×\(count)")
                    .font(.caption2.bold())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .opacity(selectable || selected ? 1 : 0.9)
    }
}

// MARK: - Side panel

private struct TeamSidePanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var table: TeamTable

    private var match: TeamMatch { table.match }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    model.leaveTeamTable()
                } label: {
                    Label("Lobby", systemImage: "chevron.left")
                }
                Spacer()
                Text("2v2 · \(match.timeControl.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            TeamStatusCard(table: table)
            TeamPromptsView(table: table)
            switch match.phase {
            case .setup:
                ScrollView {
                    SetupPanel(isLocalReady: match.isLocalReady)
                }
            case .playing:
                SwapHelp(table: table)
                TeamsCard(table: table)
                Spacer(minLength: 0)
                TeamActionButtons(table: table)
            case .over:
                TeamReviewPanel(table: table)
                    .frame(maxHeight: .infinity)
            }
            Divider()
            TeamChatView(table: table)
                .frame(height: 170)
        }
    }
}

private struct TeamStatusCard: View {
    @ObservedObject var table: TeamTable
    /// The one-line version for the iPhone's top bar.
    var compact = false

    private var match: TeamMatch { table.match }

    private var shortResult: String {
        guard let result = match.result else { return "Game over" }
        guard let winner = result.winner else { return "Draw" }
        return winner == table.localSeat.team ? "You won" : "You lost"
    }

    private func names(_ seats: [Seat]) -> String {
        let list = seats.map { match.player($0).name }
        switch list.count {
        case 0: return ""
        case 1: return list[0]
        default: return list.dropLast().joined(separator: ", ") + " and " + list.last!
        }
    }

    var body: some View {
        if compact {
            StatusPill(icon: icon, title: compactTitle, tint: tint)
        } else {
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
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)))
        }
    }

    /// The top bar's version of `title`, short enough for a phone.
    private var compactTitle: String {
        if match.isOver { return shortResult }
        if table.isLive && match.phase == .playing && match.isWaitingForPieces { return "Can't move: wait for teammate" }
        return title
    }

    private var missing: [Seat] { table.missingSeats }
    private var reviewing: Bool { table.isReviewOnly }

    private var title: String {
        if let result = match.result {
            let summary = result.summary { match.player($0).name }
            guard let winner = result.winner else { return summary }
            return "\(winner == table.localSeat.team ? "You won" : "You lost"): \(summary)"
        }
        if !match.isConfirmed { return "Waiting for everyone to join…" }
        if !table.isLive {
            let left = missing.filter { table.leftOnPurpose.contains(match.player($0).id) }
            if !left.isEmpty { return "\(names(left)) left the game" }
            return "Connection lost"
        }
        switch match.phase {
        case .setup:
            if !match.isLocalReady { return "Set up your army" }
            let waiting = Seat.all.filter { !match.isReady($0) }
            return waiting.isEmpty ? "Starting…" : "Waiting for \(names(waiting))"
        case .playing:
            guard let board = match.localBoard else { return "" }
            if board.isAwaitingBattle { return "Battle!" }
            if match.isWaitingForPieces { return "You can't move: wait for your teammate" }
            return match.isLocalTurn ? "Your move" : "\(match.player(table.localSeat.opponent).name) is thinking…"
        case .over:
            return ""
        }
    }

    private var detail: String? {
        if match.isOver {
            var lines: [String] = []
            switch match.verification {
            case .passed?: lines.append("All four armies were revealed and checked against every turn.")
            case .failed(let reason)?: lines.append("⚠︎ Setup check failed: \(reason)")
            case nil: lines.append(reviewing ? "Not every army was revealed." : "Revealing all four armies…")
            }
            if reviewing { lines.append("Reviewing a saved game.") }
            return lines.joined(separator: "\n")
        }
        if !match.isConfirmed {
            return missing.isEmpty ? nil : "Waiting for \(names(missing)) to accept the invitation."
        }
        if !table.isLive {
            return "Clocks are paused until all four players are connected again. Waiting for \(names(missing)) (Offline Barrage needs to be open and nearby)."
        }
        switch match.phase {
        case .setup:
            if !match.isLocalReady {
                return "Your teammate \(match.player(table.localSeat.partner).name) plays the other board with the other color. Captured pieces go to the capturer's teammate."
            }
            return "Your setup is locked in. The game starts when all four players are ready."
        case .playing:
            if match.isWaitingForPieces {
                if match.swappablePieces.isEmpty {
                    // Only the Flag is left: a swap needs a piece to replace, and the Flag can't be swapped out.
                    return "Only your Flag is left. It can't move or be swapped out, so nothing from your reserve can come in. Your clock is running: your teammate can still win the match on their board before it runs out."
                }
                return "None of your pieces can move and your reserve is empty. Your clock is running: wait for your teammate to capture something you can swap in, or to win on their board."
            }
            if match.localBoard?.isAwaitingBattle == true {
                return "Waiting for the defender's app to reveal its rank."
            }
            return nil
        case .over:
            return nil
        }
    }

    private var icon: String {
        if match.isOver { return "flag.checkered" }
        if !match.isConfirmed || !table.isLive { return "antenna.radiowaves.left.and.right" }
        if match.phase == .setup { return match.isLocalReady ? "hourglass" : "square.grid.3x3.fill" }
        if match.isWaitingForPieces { return "hourglass" }
        return match.isLocalTurn ? "hand.point.right.fill" : "hourglass"
    }

    private var tint: Color {
        if match.isOver {
            if case .failed? = match.verification { return .red }
            return .purple
        }
        if !match.isConfirmed || !table.isLive { return .orange }
        if match.phase == .setup { return match.isLocalReady ? .secondary : .green }
        if match.isWaitingForPieces { return .orange }
        return match.isLocalTurn ? .green : .secondary
    }
}

private struct TeamPromptsView: View {
    @ObservedObject var table: TeamTable

    var body: some View {
        let match = table.match
        if let offer = match.drawOffer, !match.isOver {
            if match.drawOfferAwaitsUs {
                PromptRow(text: "\(match.player(offer.from).name) offers a draw. It takes all four players to agree.",
                          accept: { table.answerDraw(accept: true) },
                          decline: { table.answerDraw(accept: false) })
            } else {
                let waiting = Seat.all.filter { !offer.acceptedSeats.contains($0) }.map { match.player($0).name }
                InfoRow(text: "Draw offered. Waiting for \(waiting.joined(separator: ", ")).")
            }
        }
    }
}

private struct SwapHelp: View {
    @ObservedObject var table: TeamTable

    var body: some View {
        let match = table.match
        if let rank = table.swapRank {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Device.Click) one of your pieces (not the Flag) to replace it with your \(rank.name).")
                    .font(.callout.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your opponents learn both ranks, but not which piece it was.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Cancel Swap") { table.cancelSwap() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.15)))
        } else if table.canSwap {
            Text("Move a piece, or swap: \(Device.click) a piece in your reserve, then the piece of yours it replaces.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if match.isLocalTurn && match.reserve(of: table.localSeat).isEmpty {
            Text("Pieces your teammate captures land in your reserve, ready to swap in.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Who plays with whom, as a reminder.
private struct TeamsCard: View {
    @ObservedObject var table: TeamTable

    var body: some View {
        let match = table.match
        VStack(alignment: .leading, spacing: 6) {
            ForEach([table.localSeat.team, table.localSeat.team.other], id: \.self) { team in
                HStack(spacing: 6) {
                    Text(team == table.localSeat.team ? "Your team" : "Opponents")
                        .font(.caption.bold())
                        .frame(width: 70, alignment: .leading)
                    ForEach(Seat.seats(of: team), id: \.self) { seat in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Palette.side(seat.side))
                                .frame(width: 9, height: 9)
                            Text(match.player(seat).name).font(.caption)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

private struct TeamActionButtons: View {
    @ObservedObject var table: TeamTable
    @State private var confirmingResign = false

    var body: some View {
        HStack {
            Button("Offer Draw") { table.offerDraw() }
                .disabled(!table.canAct || !table.match.canOfferDraw)
            Spacer()
            Button("Resign") { confirmingResign = true }
                .disabled(!table.canAct)
        }
        .confirmationDialog("Resign? Your team loses the game.", isPresented: $confirmingResign) {
            Button("Resign", role: .destructive) { table.resign() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - After the game

private struct TeamReviewPanel: View {
    @ObservedObject var table: TeamTable
    /// iPhone: part of a scrolling tab, with the step buttons here rather than under each board.
    var inline = false

    var body: some View {
        let match = table.match
        VStack(alignment: .leading, spacing: 8) {
            Picker("Board", selection: $table.reviewBoard) {
                ForEach(BoardID.allCases, id: \.self) { board in
                    Text(board == table.localSeat.board ? "\(board.name) (yours)" : board.name).tag(board)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if inline {
                TeamNavigationButtons(table: table, board: table.reviewBoard)
                revealToggle
                TeamTurnList(table: table, board: table.reviewBoard, inline: true)
            } else {
                TeamTurnList(table: table, board: table.reviewBoard)
                revealToggle
            }
        }
    }
}

extension TeamReviewPanel {
    @ViewBuilder
    var revealToggle: some View {
        if table.match.hasFullReveal {
            Toggle("Show every piece's rank", isOn: $table.showAllPieces)
                .checkboxToggleStyle()
        }
    }
}

private struct TeamTurnList: View {
    @ObservedObject var table: TeamTable
    let board: BoardID
    /// Inside a scroll view already (iPhone), so no scrolling of its own.
    var inline = false

    var body: some View {
        if inline {
            rows
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        } else {
            let turns = table.match.board(board)?.turns ?? []
            ScrollViewReader { proxy in
                ScrollView {
                    rows
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .onAppear {
                    if !turns.isEmpty { proxy.scrollTo(turns.count - 1, anchor: .bottom) }
                }
            }
        }
    }

    private var rows: some View {
        let turns = table.match.board(board)?.turns ?? []
        let shown = table.displayedPly(board)
        return LazyVStack(alignment: .leading, spacing: 1) {
            if turns.isEmpty {
                Text("No turns were played on this board.")
                    .foregroundColor(.secondary)
                    .padding(6)
            }
            ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                TeamTurnRow(number: index + 1, turn: turn, isShown: shown == index + 1)
                    .id(index)
                    .onTapGesture { table.showPly(index + 1, on: board) }
            }
        }
        .padding(6)
    }
}

private struct TeamTurnRow: View {
    let number: Int
    let turn: TeamTurn
    let isShown: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.side(turn.side))
                .frame(width: 9, height: 9)
            if let swap = turn.swap {
                Text("Swap")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 64, alignment: .leading)
                Text("\(swap.removed.name) → \(swap.placed.name)")
                    .font(.caption)
                    .lineLimit(1)
            } else if let move = turn.move {
                Text("\(move.from.name)\(turn.isAttack ? "×" : "–")\(move.to.name)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 64, alignment: .leading)
                if let attacker = turn.moverRank, let defender = turn.defenderRank, let outcome = turn.outcome {
                    Text(BattleText.describe(attacker: attacker, defender: defender, outcome: outcome))
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(isShown ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
    }
}

private struct TeamNavigationButtons: View {
    @ObservedObject var table: TeamTable
    let board: BoardID

    var body: some View {
        let ply = table.displayedPly(board)
        let last = table.match.board(board)?.ply ?? 0
        HStack {
            Button { table.showPly(0, on: board) } label: { Image(systemName: "backward.end.fill") }
                .disabled(ply == 0)
                .help("Starting position")
            Button { table.showPly(ply - 1, on: board) } label: { Image(systemName: "chevron.left") }
                .disabled(ply == 0)
                .help("Previous turn")
            Button { table.showPly(ply + 1, on: board) } label: { Image(systemName: "chevron.right") }
                .disabled(ply >= last)
                .help("Next turn")
            Button { table.showLive(board) } label: { Image(systemName: "forward.end.fill") }
                .disabled(ply >= last)
                .help("Final position")
            Spacer()
            Text("Turn \(ply) of \(last)")
                .font(.caption)
                .foregroundColor(ply < last ? .orange : .secondary)
        }
        .controlSize(.small)
    }
}

// MARK: - Chat

private struct TeamChatView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var table: TeamTable
    var showsTitle = true
    @State private var draft = ""
    @State private var teamOnly = false

    var body: some View {
        let match = table.match
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if showsTitle {
                    Text("Chat").font(.headline)
                }
                Spacer()
                Picker("To", selection: $teamOnly) {
                    Text("Everyone").tag(false)
                    Text("Team").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(match.chat) { message in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                if message.teamOnly {
                                    Text("TEAM")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .background(Capsule().fill(Color.green))
                                }
                                ChatBubble(message: ChatMessage(id: message.id, senderID: message.senderID,
                                                                text: message.text, sentAt: message.sentAt),
                                           isMine: message.senderID == model.playerID,
                                           senderName: sender(message))
                            }
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
                TextField(teamOnly ? "Message \(match.player(table.localSeat.partner).name)" : "Message everyone", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || table.isReviewOnly)
            }
            .disabled(table.isReviewOnly)
        }
    }

    private func sender(_ message: TeamChatMessage) -> String {
        let match = table.match
        guard let seat = match.seat(ofPlayer: message.senderID) else { return "?" }
        return match.player(seat).name
    }

    private func send() {
        guard !table.isReviewOnly else { return }
        table.sendChat(draft, teamOnly: teamOnly)
        draft = ""
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
