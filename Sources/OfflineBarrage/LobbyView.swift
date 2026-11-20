import BarrageCore
import SwiftUI

struct LobbyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var nameDraft = ""
    @State private var gamePendingDeletion: MatchSnapshot? = nil

    var body: some View {
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
                SavedGamesColumn(gamePendingDeletion: $gamePendingDeletion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { nameDraft = model.playerName }
        .sheet(item: $model.challengeTarget) { player in
            ChallengeSheet(player: player)
                .environmentObject(model)
        }
        .confirmationDialog("Delete this game?", isPresented: deletionBinding, presenting: gamePendingDeletion) { game in
            Button("Delete", role: .destructive) { model.deleteSavedGame(game.gameID) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will be removed from this Mac. The other player keeps their copy.")
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { gamePendingDeletion != nil }, set: { if !$0 { gamePendingDeletion = nil } })
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "flag.2.crossed.fill")
                .font(.system(size: 38))
                .foregroundColor(Palette.side(.red))
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline Barrage").font(.largeTitle.bold())
                Text("Hidden-rank battles against another Mac nearby. No internet or Wi-Fi network needed.")
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
                    .toggleStyle(.checkbox)
            }
        }
        .padding(20)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nearby players").font(.title2.bold())

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
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.nearby) { player in
                            NearbyPlayerRow(player: player)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

private struct NearbyPlayerRow: View {
    @EnvironmentObject private var model: AppModel
    let player: NearbyPlayer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.title2)
                .foregroundColor(.accentColor)
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
                Text("Looking for nearby Macs…")
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not seeing the other Mac?").font(.headline)
            Group {
                Text("• Open Offline Barrage on both Macs, and keep the Macs within a few meters of each other.")
                Text("• Turn Wi-Fi on for both (Control Center). In airplane mode, just switch Wi-Fi back on. No network needed.")
                Text("• Allow Local Network access: System Settings → Privacy & Security → Local Network → Offline Barrage.")
                Text("• If the macOS firewall blocks all incoming connections, allow Offline Barrage in System Settings → Network → Firewall.")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Unfinished games").font(.title2.bold())
                if model.unfinishedGames.isEmpty {
                    Text("Games in progress are saved automatically and can be resumed later.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(model.unfinishedGames) { game in
                        SavedGameRow(game: game, gamePendingDeletion: $gamePendingDeletion)
                    }
                }

                Text("Finished games").font(.title2.bold()).padding(.top, 12)
                if model.finishedGames.isEmpty {
                    Text("No finished games yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(model.finishedGames) { game in
                        SavedGameRow(game: game, gamePendingDeletion: $gamePendingDeletion)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
