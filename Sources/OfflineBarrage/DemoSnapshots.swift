#if DEBUG
import AppKit
import BarrageCore
import MultipeerConnectivity
import SwiftUI

/// Developer aid (debug builds only): renders the real UI in a series of demo states to PNG
/// files, without going online. Run with
///     OFFLINE_BARRAGE_PROFILE=snapshots OFFLINE_BARRAGE_SNAPSHOTS=/some/dir .build/debug/OfflineBarrage
enum DemoSnapshots {
    static func run() {
        guard let path = ProcessInfo.processInfo.environment["OFFLINE_BARRAGE_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel.shared
        let size = NSSize(width: 1240, height: 860)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        // The offscreen capture doesn't include the window's own background, so draw one.
        let root = RootView().environmentObject(model).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()

        let darkScenes: Set<String> = ["2-setup", "4-playing", "7-game-over"]
        for (name, apply) in scenes(model) {
            for dark in [false, true] where !dark || darkScenes.contains(name) {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                apply()
                pump(0.8)
                render(host, to: directory.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
            }
        }
        NSApp.terminate(nil)
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func render(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Both sides of a game, played locally.
    private struct Table {
        var red: Match
        var blue: Match
        var now = Date()
        var lastBattle: BattleReport?

        init(local: PlayerInfo, opponent: PlayerInfo, timeControl: TimeControl) {
            let challenge = Challenge(challenger: local, challengerSide: .red, timeControl: timeControl)
            red = Match(challenge: challenge, accepter: opponent, localPlayerID: local.id, now: now)
            blue = Match(challenge: challenge, accepter: opponent, localPlayerID: opponent.id, now: now)
        }

        mutating func deliver(_ update: MatchUpdate?, from side: Side) {
            guard let update = update else { return }
            for event in update.events {
                if case .battle(let report) = event { lastBattle = report }
            }
            for message in update.outgoing {
                let reply = side == .red ? blue.receive(message, at: now) : red.receive(message, at: now)
                deliver(reply, from: side.opposite)
            }
        }

        mutating func play(_ moves: [String]) {
            for text in moves {
                now = now.addingTimeInterval(7)
                guard let move = Move(text) else { continue }
                if red.isLocalTurn {
                    deliver(red.playLocalMove(move, at: now), from: .red)
                } else {
                    deliver(blue.playLocalMove(move, at: now), from: .blue)
                }
            }
        }
    }

    private static func setup(_ side: Side, _ placements: [String: Rank]) -> Setup {
        Setup(side: side, placements: Dictionary(uniqueKeysWithValues: placements.map { (Square(name: $0.key)!, $0.value) }))
    }

    private static let redSetup = setup(.red, ["B1": .flag, "B2": .bomb, "D4": .marshal, "H4": .general,
                                               "A3": .miner, "E4": .scout, "J4": .scout, "C3": .spy])
    private static let blueSetup = setup(.blue, ["I10": .flag, "I9": .bomb, "E7": .marshal, "B7": .general,
                                                 "J8": .miner, "A7": .scout, "F7": .scout, "D8": .spy])
    private static let opening = ["E4-E6", "A7-A5", "E6-E7", "E7-E6", "D4-E4", "A5-A3", "J4-J6", "E6-F6"]

    private static func scenes(_ model: AppModel) -> [(String, () -> Void)] {
        let local = model.localInfo
        let sam = PlayerInfo(id: "demo-opponent", name: "Sam")
        let clock = TimeControl(initialSeconds: 300, incrementSeconds: 3)

        let fresh = Table(local: local, opponent: sam, timeControl: clock)
        var partial = Setup(side: .red)
        for (square, rank) in redSetup.placements.sorted(by: { $0.key < $1.key }).prefix(5) {
            partial.place(rank, at: square)
        }

        var locked = Table(local: local, opponent: sam, timeControl: clock)
        locked.deliver(locked.red.lockSetup(redSetup, at: locked.now), from: .red)

        var midgame = Table(local: local, opponent: sam, timeControl: clock)
        midgame.deliver(midgame.red.lockSetup(redSetup, at: midgame.now), from: .red)
        midgame.deliver(midgame.blue.lockSetup(blueSetup, at: midgame.now), from: .blue)
        midgame.play(opening)
        let battle = midgame.lastBattle
        midgame.deliver(midgame.red.sendChat("good luck!", at: midgame.now), from: .red)
        midgame.deliver(midgame.blue.sendChat("you too", at: midgame.now), from: .blue)

        var finished = midgame
        finished.play(["J6-J8", "F6-F5"])
        finished.deliver(finished.blue.resign(at: finished.now), from: .blue)

        let nearby = [
            NearbyPlayer(id: "demo-opponent", name: "Sam", peerID: MCPeerID(displayName: "Sam"), isCompatible: true),
            NearbyPlayer(id: "demo-old", name: "Alex's MacBook", peerID: MCPeerID(displayName: "Alex"), isCompatible: false),
        ]
        let saved = [midgame.red.snapshot(at: midgame.now), finished.red.snapshot(at: finished.now)]

        return [
            ("1-lobby", { model.showDemo(match: nil, linkStatus: .offline, nearby: nearby, savedGames: saved) }),
            ("2-setup", { model.showDemo(match: fresh.red, linkStatus: .connected, draft: partial) }),
            ("3-setup-locked", { model.showDemo(match: locked.red, linkStatus: .connected, draft: redSetup) }),
            ("4-playing", { model.showDemo(match: midgame.red, linkStatus: .connected) }),
            ("5-battle", { model.showDemo(match: midgame.red, linkStatus: .connected, battle: battle) }),
            ("6-blue-view", { model.showDemo(match: midgame.blue, linkStatus: .connected) }),
            ("7-game-over", { model.showDemo(match: finished.red, linkStatus: .connected) }),
            ("8-reconnecting", {
                model.showDemo(match: midgame.red, linkStatus: .reconnecting,
                               banner: "Two-squares rule: a piece can't move back and forth between the same squares more than 5 times in a row.")
            }),
            ("9-history", { model.showDemo(match: finished.red, linkStatus: .offline, viewPly: 3) }),
        ]
    }
}
#endif
