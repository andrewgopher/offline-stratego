import SwiftUI
#if os(macOS)
import AppKit
#else
import AudioToolbox
import UIKit
#endif

/// What differs between the Mac app and the iPhone/iPad app, in one place.
enum Device {
    /// "Mac", "iPhone" or "iPad": how the app refers to the device it runs on.
    static let noun: String = {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }()

    /// Sent to nearby players so their lobby shows the right icon ("mac", "iphone" or "ipad").
    static let kind: String = noun.lowercased()

    static var isTouch: Bool {
        #if os(macOS)
        return false
        #else
        return true
        #endif
    }

    /// "click" or "tap", for instructions.
    static let click = isTouch ? "tap" : "click"
    static let Click = isTouch ? "Tap" : "Click"

    /// The SF Symbol for a nearby player's device.
    static func symbol(forKind kind: String?) -> String {
        switch kind {
        case "iphone": return "iphone"
        case "ipad": return "ipad"
        default: return "laptopcomputer"
        }
    }

    /// The name to start with, before the player picks one.
    static func defaultPlayerName() -> String {
        #if os(macOS)
        var name = Host.current().localizedName ?? "Player"
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespaces)
        if let first = fullName.split(separator: " ").first, !first.isEmpty {
            name = String(first)
        }
        return name
        #else
        // iOS doesn't tell apps the owner's name or the device's own name, so pick something
        // that tells four phones apart until the players type their names.
        return "\(noun) \(Int.random(in: 10...99))"
        #endif
    }
}

/// Sounds on the Mac; on iPhone and iPad, haptics plus a few quiet system sounds.
enum Feedback {
    static func play(_ name: String) {
        #if os(macOS)
        NSSound(named: NSSound.Name(name))?.play()
        #else
        switch name {
        case "Tink":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioServicesPlaySystemSound(1104)  // keyboard click
        case "Pop", "Bottle", "Submarine":
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "Hero", "Glass":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "Basso":
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "Funk":
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "Ping", "Morse":
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            AudioServicesPlaySystemSound(1007)  // tri-tone
        case "Purr":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioServicesPlaySystemSound(1003)  // message received
        default:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #endif
    }

    /// Bounces the Dock icon when the Mac app is in the background. (A backgrounded iPhone app
    /// is suspended, so there's nothing to do there.)
    static func requestAttention() {
        #if os(macOS)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        #endif
    }
}

// MARK: - Layout

private struct CompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True on iPhone (and narrow or portrait iPad windows): screens stack vertically instead
    /// of putting a side panel next to the board. Always false on the Mac.
    var compactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}

enum LayoutRule {
    /// Whether a window of `size` gets the stacked (phone) layout.
    static func isCompact(_ size: CGSize) -> Bool {
        #if os(macOS)
        return false
        #else
        return size.width < 900 || size.width < size.height
        #endif
    }
}

extension View {
    /// Mac: a fixed-width sheet, as before. iPhone/iPad: the sheet's content scrolls and is at
    /// most `width` wide.
    @ViewBuilder
    func sheetLayout(width: CGFloat) -> some View {
        #if os(macOS)
        self.frame(width: width)
        #else
        ScrollView {
            self.frame(maxWidth: width)
                .frame(maxWidth: .infinity)
        }
        #endif
    }

    /// A checkbox on the Mac, a switch elsewhere.
    @ViewBuilder
    func checkboxToggleStyle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self.toggleStyle(.switch)
        #endif
    }

    /// The small borderless "⋯" menus in the lobby.
    @ViewBuilder
    func borderlessMenuStyle() -> some View {
        #if os(macOS)
        self.menuStyle(.borderlessButton)
        #else
        self
        #endif
    }
}
