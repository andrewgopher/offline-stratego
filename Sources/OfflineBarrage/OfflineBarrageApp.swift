import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@main
struct OfflineBarrageApp: App {
    @StateObject private var model = AppModel.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Offline Barrage", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #else
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: model.didEnterBackground()
            case .active: model.willEnterForeground()
            default: break
            }
        }
        #endif
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`); harmless inside the .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        if AppModel.isSnapshotMode {
            DispatchQueue.main.async { DemoSnapshots.run() }
        }
        Autoplay.start()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.prepareForTermination()
    }
}
#else
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        if AppModel.isSnapshotMode {
            // Give the window scene a moment to connect.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DemoSnapshots.run() }
        }
        Autoplay.start()
        #endif
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppModel.shared.prepareForTermination()
    }
}
#endif

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    #if os(iOS)
    @State private var compact = true
    #endif

    var body: some View {
        #if os(macOS)
        content
            .frame(minWidth: model.screen == .teamGame ? 1200 : 1000, minHeight: 760)
        #else
        content
            .environment(\.compactLayout, compact)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Measured without the keyboard, so typing in the chat doesn't change the layout.
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { compact = LayoutRule.isCompact(geometry.size) }
                        .onChange(of: geometry.size) { compact = LayoutRule.isCompact($0) }
                }
                .ignoresSafeArea(.keyboard)
            )
            // Don't let the screen lock (and the app go to the background) during a game.
            .onAppear { UIApplication.shared.isIdleTimerDisabled = model.screen != .lobby }
            .onChange(of: model.screen) { UIApplication.shared.isIdleTimerDisabled = $0 != .lobby }
        #endif
    }

    private var content: some View {
        ZStack(alignment: .top) {
            switch model.screen {
            case .lobby: LobbyView()
            case .game: GameView()
            case .teamGame: TeamGameView()
            }
            if let banner = model.banner {
                BannerView(text: banner) { model.dismissBanner() }
                    .padding(.top, 8)
                    .padding(.horizontal, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
        .sheet(item: $model.incomingInvite) { invite in
            IncomingInviteView(invite: invite)
                .environmentObject(model)
        }
    }
}

struct BannerView: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 640)
        // A capsule on the Mac; on a phone the text often wraps, so use a rounded rectangle.
        .background(.regularMaterial, in: Device.isTouch ? AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) : AnyShape(Capsule()))
        .shadow(radius: 4)
    }
}
