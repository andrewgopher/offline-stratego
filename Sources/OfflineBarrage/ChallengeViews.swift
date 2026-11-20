import BarrageCore
import SwiftUI

/// Pick a side and a time control, then invite a nearby player.
struct ChallengeSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let player: NearbyPlayer

    @AppStorage("lastSideChoice", store: AppEnvironment.defaults) private var sideChoice: String = SideChoice.random.rawValue
    @AppStorage("lastPresetIndex", store: AppEnvironment.defaults) private var presetIndex: Int = 6
    @AppStorage("lastCustomMinutes", store: AppEnvironment.defaults) private var customMinutes: Int = 10
    @AppStorage("lastCustomIncrement", store: AppEnvironment.defaults) private var customIncrement: Int = 0

    private static let customTag = -1

    private var timeControl: TimeControl {
        if presetIndex == ChallengeSheet.customTag {
            return TimeControl(initialSeconds: customMinutes * 60, incrementSeconds: customIncrement)
        }
        let presets = TimeControl.presets
        return presets[min(max(presetIndex, 0), presets.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Challenge \(player.name)").font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("You play").font(.headline)
                Picker("You play", selection: $sideChoice) {
                    ForEach(SideChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Red moves first.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Clock").font(.headline)
                Picker("Clock", selection: $presetIndex) {
                    ForEach(Array(TimeControl.presets.enumerated()), id: \.offset) { index, preset in
                        Text(preset.isUnlimited ? "No clock" : preset.displayName).tag(index)
                    }
                    Divider()
                    Text("Custom…").tag(ChallengeSheet.customTag)
                }
                .labelsHidden()
                .frame(width: 260)

                if presetIndex == ChallengeSheet.customTag {
                    Stepper(value: $customMinutes, in: 1...120) {
                        Text("\(customMinutes) minute\(customMinutes == 1 ? "" : "s") per player")
                    }
                    Stepper(value: $customIncrement, in: 0...60) {
                        Text("+\(customIncrement) second\(customIncrement == 1 ? "" : "s") per move")
                    }
                }
                Text(timeControl.isUnlimited
                     ? "Take as long as you like."
                     : "Each player has a time bank, plus the increment after every move. Setup isn't timed; clocks start after Red's first move, and a dropped connection pauses both.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send Challenge") {
                    model.sendChallenge(to: player, side: SideChoice(rawValue: sideChoice) ?? .random, timeControl: timeControl)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.nearbyPlayer(player.id) == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// Accept or decline a challenge / resume request from another Mac.
struct IncomingInviteView: View {
    @EnvironmentObject private var model: AppModel
    let invite: IncomingInvite

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch invite.invitation {
            case .challenge(let challenge):
                Text("\(invite.from.name) challenges you!").font(.title2.bold())
                Label("You play \(challenge.challengerSide.opposite.name)\(challenge.challengerSide == .blue ? " and move first" : "")",
                      systemImage: "person.fill")
                Label(challenge.timeControl.isUnlimited ? "No clock" : challenge.timeControl.displayName, systemImage: "clock")
            case .resume:
                Text("\(invite.from.name) wants to resume your game").font(.title2.bold())
                if let saved = invite.savedGame {
                    let mySide = saved.side(of: model.playerID) ?? .red
                    Label("You play \(mySide.name)", systemImage: "person.fill")
                    Label(saved.hasStarted ? "\(saved.moves.count) moves played · \(saved.timeControl.label)" : "Still setting up · \(saved.timeControl.label)",
                          systemImage: "clock")
                }
            }

            TimelineView(.periodic(from: Date(), by: 1)) { context in
                let seconds = max(0, Int(invite.expiresAt.timeIntervalSince(context.date)))
                Text("This request expires in \(seconds)s.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Decline") { model.declineIncomingInvite() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { model.acceptIncomingInvite() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}
