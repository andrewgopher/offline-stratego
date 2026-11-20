import BarrageCore
import SwiftUI

struct LobbyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.compactLayout) private var compact
    @State private var nameDraft = ""
    @State private var gamePendingDeletion: MatchSnapshot? = nil
    @State private var teamGamePendingDeletion: TeamSnapshot? = nil

    var body: some View {
        Group {
            if compact {
                // iPhone: one scrolling column.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        compactHeader
                        Divider()
                        NearbyPlayersColumn(compact: true)
                        Divider()
                        SavedGamesColumn(gamePendingDeletion: $gamePendingDeletion, teamGamePendingDeletion: $teamGamePendingDeletion,
                                         compact: true)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                VStack(spacing: 0) {
                    header
                    if model.wifiPoweredOff {
                        WiFiWarning()
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 0) {
                        NearbyPlayersColumn()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        Divider()
                        SavedGamesColumn(gamePendingDeletion: $gamePendingDeletion, teamGamePendingDeletion: $teamGamePendingDeletion)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .onAppear { nameDraft = model.playerName }
        .sheet(item: $model.challengeTarget) { player in
            ChallengeSheet(player: player)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingTeamSheet) {
            TeamChallengeSheet()
                .environmentObject(model)
        }
        .confirmationDialog("Delete this 2v2 game?", isPresented: teamDeletionBinding, presenting: teamGamePendingDeletion) { game in
            Button("Delete", role: .destructive) { model.deleteSavedTeamGame(game.gameID) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will be removed from this \(Device.noun). The other players keep their copies.")
        }
        .confirmationDialog("Delete this game?", isPresented: deletionBinding, presenting: gamePendingDeletion) { game in
            Button("Delete", role: .destructive) { model.deleteSavedGame(game.gameID) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will be removed from this \(Device.noun). The other player keeps their copy.")
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { gamePendingDeletion != nil }, set: { if !$0 { gamePendingDeletion = nil } })
    }

    private var teamDeletionBinding: Binding<Bool> {
        Binding(get: { teamGamePendingDeletion != nil }, set: { if !$0 { teamGamePendingDeletion = nil } })
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "flag.2.crossed.fill")
                .font(.system(size: 38))
                .foregroundColor(Palette.side(.red))
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline Barrage").font(.largeTitle.bold())
                Text(LobbyView.tagline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Text("Your name")
                        .foregroundColor(.secondary)
                    TextField("Your name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit(saveName)
                        .disabled(model.isWaitingForChallengeAnswer)
                    if nameDraft != model.playerName {
                        Button("Save", action: saveName)
                            .disabled(model.isWaitingForChallengeAnswer)
                    }
                }
                Toggle("Sounds", isOn: $model.soundsEnabled)
                    .checkboxToggleStyle()
            }
        }
        .padding(20)
    }

    static let tagline = "Hidden-rank battles with players nearby: 1v1, or 2v2 on two boards. No internet or Wi-Fi network needed."

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "flag.2.crossed.fill")
                    .font(.system(size: 26))
                    .foregroundColor(Palette.side(.red))
                Text("Offline Barrage").font(.title.bold())
            }
            Text(LobbyView.tagline)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Your name")
                    .foregroundColor(.secondary)
                TextField("Your name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit(saveName)
                    .disabled(model.isWaitingForChallengeAnswer)
                if nameDraft != model.playerName {
                    Button("Save", action: saveName)
                        .disabled(model.isWaitingForChallengeAnswer)
                }
            }
            Toggle(Device.isTouch ? "Sounds and haptics" : "Sounds", isOn: $model.soundsEnabled)
        }
        .padding(16)
    }

    private func saveName() {
        model.rename(nameDraft)
        nameDraft = model.playerName
    }
}

private struct WiFiWarning: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            Text("Wi-Fi is off. Turn Wi-Fi on to find other players. You don't need to join a network, and it works in airplane mode.")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.2))
    }
}

private struct NearbyPlayersColumn: View {
    @EnvironmentObject private var model: AppModel
    /// iPhone: part of the lobby's single scrolling column.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nearby players").font(compact ? .title3.bold() : .title2.bold())
                Spacer()
                Button {
                    model.showingTeamSheet = true
                } label: {
                    Label(compact ? "New 2v2…" : "New 2v2 Game…", systemImage: "person.2.fill")
                }
                .disabled(model.outgoingInvite != nil || model.compatibleNearby.count < 3)
                .help(model.compatibleNearby.count < 3 ? "2v2 needs three other players nearby" : "Play two against two on four devices")
            }

            if let out = model.outgoingInvite, out.isChallenge {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(out.to.name) to answer…")
                    Spacer()
                    Button("Cancel") { model.cancelChallenge() }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            }

            if model.nearby.isEmpty {
                SearchingView()
            } else if compact {
                VStack(spacing: 8) {
                    ForEach(model.nearby) { player in
                        NearbyPlayerRow(player: player)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.nearby) { player in
                            NearbyPlayerRow(player: player)
                        }
                    }
                }
            }
            if !compact {
                Spacer(minLength: 0)
            }
        }
        .padding(compact ? 16 : 20)
    }
}

private struct NearbyPlayerRow: View {
    @EnvironmentObject private var model: AppModel
    let player: NearbyPlayer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Device.symbol(forKind: player.device))
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.name).font(.headline)
                Text(player.isCompatible ? "Ready to play" : "Has a different version of Offline Barrage")
                    .font(.caption)
                    .foregroundColor(player.isCompatible ? .secondary : .orange)
            }
            Spacer()
            Button("Challenge…") { model.challengeTarget = player }
                .disabled(!player.isCompatible || model.outgoingInvite != nil)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

private struct SearchingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for nearby players…")
                    .foregroundColor(.secondary)
            }
            TimelineView(.periodic(from: model.launchedAt, by: 5)) { context in
                if context.date.timeIntervalSince(model.launchedAt) > 15 {
                    TroubleshootingTips()
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct TroubleshootingTips: View {
    private static let tips: [String] = {
        let common = "• Open Offline Barrage on both devices, and keep them within a few meters of each other. Every player needs the same version of the app."
        #if os(macOS)
        return [
            common,
            "• Turn Wi-Fi on (Control Center). In airplane mode, just switch Wi-Fi back on. No network needed.",
            "• Allow Local Network access: System Settings → Privacy & Security → Local Network → Offline Barrage.",
            "• If the macOS firewall blocks all incoming connections, allow Offline Barrage in System Settings → Network → Firewall.",
        ]
        #else
        return [
            common,
            "• Turn Wi-Fi and Bluetooth on (Control Center). In airplane mode, just switch them back on. No network needed.",
            "• Allow Local Network access: Settings → Privacy & Security → Local Network → Offline Barrage.",
            "• Keep Offline Barrage open on screen: other players can't see it while it's in the background.",
        ]
        #endif
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not seeing the other player?").font(.headline)
            Group {
                ForEach(TroubleshootingTips.tips, id: \.self) { Text($0) }
            }
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

private struct SavedGamesColumn: View {
    @EnvironmentObject private var model: AppModel
    @Binding var gamePendingDeletion: MatchSnapshot?
    @Binding var teamGamePendingDeletion: TeamSnapshot?
    /// iPhone: part of the lobby's single scrolling column.
    var compact = false

    private enum Item: Identifiable {
        case solo(MatchSnapshot)
        case team(TeamSnapshot)

        var id: UUID {
            switch self {
            case .solo(let game): return game.gameID
            case .team(let game): return game.gameID
            }
        }

        var updatedAt: Date {
            switch self {
            case .solo(let game): return game.updatedAt
            case .team(let game): return game.updatedAt
            }
        }
    }

    private func items(_ solo: [MatchSnapshot], _ team: [TeamSnapshot]) -> [Item] {
        (solo.map(Item.solo) + team.map(Item.team)).sorted { $0.updatedAt > $1.updatedAt }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .solo(let game): SavedGameRow(game: game, gamePendingDeletion: $gamePendingDeletion)
        case .team(let game): TeamSavedGameRow(game: game, pendingDeletion: $teamGamePendingDeletion)
        }
    }

    var body: some View {
        if compact {
            list
        } else {
            ScrollView { list }
        }
    }

    private var list: some View {
        let unfinished = items(model.unfinishedGames, model.unfinishedTeamGames)
        let finished = items(model.finishedGames, model.finishedTeamGames)
        let titleFont: Font = compact ? .title3.bold() : .title2.bold()
        return VStack(alignment: .leading, spacing: 12) {
                Text("Unfinished games").font(titleFont)
                if unfinished.isEmpty {
                    Text("Games in progress are saved automatically and can be resumed later.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(unfinished) { row($0) }
                }

                Text("Finished games").font(titleFont).padding(.top, 12)
                if finished.isEmpty {
                    Text("No finished games yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(finished) { row($0) }
                }
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SavedGameRow: View {
    @EnvironmentObject private var model: AppModel
    let game: MatchSnapshot
    @Binding var gamePendingDeletion: MatchSnapshot?

    private var mySide: Side { game.side(of: model.playerID) ?? .red }
    private var opponent: PlayerInfo { game.player(mySide.opposite) }
    private var opponentNearby: Bool { model.nearbyPlayer(opponent.id) != nil }

    private var subtitle: String {
        let progress: String
        if !game.hasStarted {
            progress = "setting up"
        } else {
            progress = game.moves.count == 1 ? "1 move" : "\(game.moves.count) moves"
        }
        let date = game.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return "You played \(mySide.name) · \(progress) · \(game.timeControl.label) · \(date)"
    }

    private var resultText: String? {
        guard let result = game.result else { return nil }
        if result.winner == nil { return "Draw" }
        return result.winner == mySide ? "You won" : "You lost"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("vs \(opponent.name)").font(.headline)
                    if let resultText = resultText {
                        Text(resultText)
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    } else if opponentNearby {
                        Text("Nearby")
                            .font(.caption.bold())
                            .foregroundColor(.green)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if game.result == nil {
                Button("Resume") { model.openSavedGame(game) }
                    .help(opponentNearby ? "Reconnect with \(opponent.name)" : "Open and wait for \(opponent.name) to come nearby")
            } else {
                Button("View") { model.openSavedGame(game) }
            }
            Menu {
                Button("Delete…", role: .destructive) { gamePendingDeletion = game }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .borderlessMenuStyle()
            .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
