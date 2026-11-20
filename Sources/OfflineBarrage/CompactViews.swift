import SwiftUI

/// Pieces shared by the stacked (iPhone) game screens: a slim top bar and the tabbed panel
/// under the board that replaces the Mac's side panel.

enum PanelTab: Hashable {
    case game
    case moves
    case otherBoard
    case chat
}

/// "‹ Lobby", the game's status in one line, and the time control.
struct CompactTopBar<Status: View>: View {
    let onBack: () -> Void
    let detail: String
    @ViewBuilder let status: () -> Status

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Label("Lobby", systemImage: "chevron.left")
            }
            Spacer(minLength: 4)
            status()
            Spacer(minLength: 4)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(height: 30)
    }
}

/// The one-line status in `CompactTopBar`.
struct StatusPill: View {
    let icon: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.subheadline.bold())
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.18)))
    }
}

/// The segmented control above the panel.
struct PanelTabPicker: View {
    @Binding var selection: PanelTab
    let tabs: [(tab: PanelTab, title: String)]

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(tabs, id: \.tab) { item in
                Text(item.title).tag(item.tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Counts chat messages from others that arrived while the chat tab wasn't showing.
struct UnreadChat {
    private(set) var seen = 0

    mutating func markRead(_ count: Int) { seen = count }

    func unread<Message>(_ messages: [Message], isMine: (Message) -> Bool) -> Int {
        messages.dropFirst(seen).filter { !isMine($0) }.count
    }

    static func title(_ unread: Int) -> String {
        unread > 0 ? "Chat (\(unread))" : "Chat"
    }
}
