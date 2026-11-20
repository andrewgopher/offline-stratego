import BarrageCore
import SwiftUI

/// Pick the four seats and a clock, then invite the other three players.
struct TeamChallengeSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("lastTeamPresetIndex", store: AppEnvironment.defaults) private var presetIndex: Int = 5
    @AppStorage("lastTeamCustomMinutes", store: AppEnvironment.defaults) private var customMinutes: Int = 5
    @AppStorage("lastTeamCustomIncrement", store: AppEnvironment.defaults) private var customIncrement: Int = 2
    /// Player ID in each seat.
    @State private var seats: [Seat: String] = [:]

    private static let customTag = -1
    /// 2v2 always has a clock: players may wait for pieces, and the clock keeps that fair.
    static let presets: [TimeControl] = TimeControl.presets.filter { !$0.isUnlimited }

    private var timeControl: TimeControl {
        if presetIndex == TeamChallengeSheet.customTag {
            return TimeControl(initialSeconds: customMinutes * 60, incrementSeconds: customIncrement)
        }
        let presets = TeamChallengeSheet.presets
        return presets[min(max(presetIndex, 0), presets.count - 1)]
    }

    /// Us plus the compatible Macs nearby.
    private var candidates: [(id: String, name: String)] {
        [(model.playerID, "\(model.playerName) (you)")] + model.compatibleNearby.map { ($0.id, $0.name) }
    }

    private var isComplete: Bool {
        let chosen = Seat.all.compactMap { seats[$0] }
        return chosen.count == 4 && Set(chosen).count == 4 && chosen.contains(model.playerID)
            && chosen.allSatisfy { $0 == model.playerID || model.nearbyPlayer($0)?.isCompatible == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New 2v2 Game").font(.title2.bold())
            Text("Four players, two boards. Teammates play opposite colors on different boards. A piece you capture goes to your teammate, who can swap it in for one of their own pieces instead of moving.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.compatibleNearby.count < 3 {
                Label("Waiting for three more players nearby with Offline Barrage open (\(model.compatibleNearby.count) found).",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            teamsStack {
                ForEach(Team.allCases, id: \.self) { team in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Team \(team.rawValue)").font(.headline)
                        ForEach(Seat.seats(of: team), id: \.self) { seat in
                            seatPicker(seat)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
            }
            HStack {
                Button {
                    shuffle()
                } label: {
                    Label("Shuffle Seats", systemImage: "shuffle")
                }
                .disabled(model.compatibleNearby.count < 3)
                Spacer()
                if !isComplete {
                    Text("Pick four different players.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Clock").font(.headline)
                Picker("Clock", selection: $presetIndex) {
                    ForEach(Array(TeamChallengeSheet.presets.enumerated()), id: \.offset) { index, preset in
                        Text(preset.displayName).tag(index)
                    }
                    Divider()
                    Text("Custom…").tag(TeamChallengeSheet.customTag)
                }
                .labelsHidden()
                .frame(width: 260)
                if presetIndex == TeamChallengeSheet.customTag {
                    Stepper(value: $customMinutes, in: 1...120) {
                        Text("\(customMinutes) minute\(customMinutes == 1 ? "" : "s") per player")
                    }
                    Stepper(value: $customIncrement, in: 0...60) {
                        Text("+\(customIncrement) second\(customIncrement == 1 ? "" : "s") per turn")
                    }
                }
                Text("Every player has their own clock. Clocks start when all four armies are in place, and they pause if anyone drops out.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send Invitations") {
                    model.startTeamGame(seats: seats, timeControl: timeControl)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete)
            }
        }
        .padding(24)
        .sheetLayout(width: 520)
        .onAppear(perform: fillDefaults)
    }

    /// The two teams side by side, or one above the other on a phone.
    @ViewBuilder
    private func teamsStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if Device.isTouch {
            VStack(alignment: .leading, spacing: 12, content: content)
        } else {
            HStack(alignment: .top, spacing: 16, content: content)
        }
    }

    private func seatPicker(_ seat: Seat) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Palette.side(seat.side))
                .frame(width: 12, height: 12)
            Text("\(seat.board.name), \(seat.side.name)")
                .font(.callout)
                .frame(width: 104, alignment: .leading)
            Picker(seat.description, selection: binding(for: seat)) {
                Text("Choose…").tag("")
                ForEach(candidates, id: \.id) { candidate in
                    Text(candidate.name).tag(candidate.id)
                }
            }
            .labelsHidden()
        }
    }

    private func binding(for seat: Seat) -> Binding<String> {
        Binding(get: { seats[seat] ?? "" }, set: { newValue in
            // Picking someone already seated swaps the two seats.
            if let other = Seat.all.first(where: { $0 != seat && seats[$0] == newValue && !newValue.isEmpty }) {
                seats[other] = seats[seat]
            }
            seats[seat] = newValue.isEmpty ? nil : newValue
        })
    }

    private func fillDefaults() {
        guard seats.isEmpty else { return }
        let order = [Seat(.one, .red), Seat(.one, .blue), Seat(.two, .red), Seat(.two, .blue)]
        let ids = candidates.map(\.id)
        for (seat, id) in zip(order, ids) { seats[seat] = id }
    }

    private func shuffle() {
        let ids = ([model.playerID] + Seat.all.compactMap { seats[$0] }.filter { $0 != model.playerID }
                   + model.compatibleNearby.map(\.id)).reduce(into: [String]()) { list, id in
            if !list.contains(id) { list.append(id) }
        }
        guard ids.count >= 4 else { return }
        let chosen = Array(ids.prefix(4)).shuffled()
        for (seat, id) in zip(Seat.all, chosen) { seats[seat] = id }
    }
}

/// Who sits where, from the viewer's point of view (used in invitations).
struct TeamSeatsSummary: View {
    let challenge: TeamChallenge
    let localPlayerID: String

    var body: some View {
        let mine = challenge.seat(of: localPlayerID)
        VStack(alignment: .leading, spacing: 6) {
            if let mine = mine {
                Label("You play \(mine.side.name) on \(mine.board.name)\(mine.side == .red ? " and move first there" : "")",
                      systemImage: "person.fill")
                if let partner = challenge.player(at: mine.partner) {
                    Label("Your teammate: \(partner.name) (\(mine.partner.side.name), \(mine.partner.board.name))",
                          systemImage: "person.2.fill")
                }
                let opponents = [mine.opponent, mine.otherOpponent].compactMap { challenge.player(at: $0)?.name }
                Label("Opponents: \(opponents.joined(separator: " and "))", systemImage: "person.2")
            }
        }
    }
}

/// A saved 2v2 game in the lobby.
struct TeamSavedGameRow: View {
    @EnvironmentObject private var model: AppModel
    let game: TeamSnapshot
    @Binding var pendingDeletion: TeamSnapshot?

    private var mySeat: Seat? { game.seat(of: model.playerID) }
    private var others: [PlayerInfo] { game.challenge.players.filter { $0.id != model.playerID } }
    private var nearbyCount: Int { others.filter { model.nearbyPlayer($0.id) != nil }.count }

    private var title: String {
        guard let seat = mySeat else { return "2v2" }
        let partner = game.player(seat.partner)?.name ?? "?"
        let opponents = [seat.opponent, seat.otherOpponent].compactMap { game.player($0)?.name }
        return "You & \(partner) vs \(opponents.joined(separator: " & "))"
    }

    private var subtitle: String {
        let progress: String
        if !game.hasStarted {
            progress = "setting up"
        } else {
            progress = game.turnCount == 1 ? "1 turn" : "\(game.turnCount) turns"
        }
        let date = game.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let side = mySeat.map { "\($0.side.name) on \($0.board.name)" } ?? ""
        return "You played \(side) · \(progress) · \(game.challenge.timeControl.label) · \(date)"
    }

    private var resultText: String? {
        guard let result = game.result else { return nil }
        guard let winner = result.winner else { return "Draw" }
        return winner == mySeat?.team ? "You won" : "You lost"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("2v2")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                    Text(title).font(.headline).lineLimit(1)
                    if let resultText = resultText {
                        Text(resultText)
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    } else if nearbyCount > 0 {
                        Text("\(nearbyCount) of 3 nearby")
                            .font(.caption.bold())
                            .foregroundColor(nearbyCount == 3 ? .green : .secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if game.result == nil {
                Button("Resume") { model.openSavedTeamGame(game) }
                    .help("Reconnect with the other three players")
                    .disabled(model.teamTable != nil)
            } else {
                Button("View") { model.openSavedTeamGame(game) }
                    .disabled(model.teamTable != nil)
            }
            Menu {
                Button("Delete…", role: .destructive) { pendingDeletion = game }
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
