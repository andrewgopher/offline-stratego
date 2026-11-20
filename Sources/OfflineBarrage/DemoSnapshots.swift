#if DEBUG
import BarrageCore
import MultipeerConnectivity
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Developer aid (debug builds only): renders the real UI in a series of demo states to PNG
/// files, without going online. Run with
///     OFFLINE_BARRAGE_PROFILE=snapshots OFFLINE_BARRAGE_SNAPSHOTS=/some/dir .build/debug/OfflineBarrage
/// The iOS version (see scripts/check-ios.sh) renders at an iPhone's size by default, or another
/// size with OFFLINE_BARRAGE_SNAPSHOT_SIZE=820x1180.
enum DemoSnapshots {
    private static let darkScenes: Set<String> = ["1-lobby", "2-setup", "4-playing", "7-game-over", "11-team-playing"]

    #if os(macOS)
    static func run() {
        guard let path = ProcessInfo.processInfo.environment["OFFLINE_BARRAGE_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel.shared
        let size = NSSize(width: 1280, height: 860)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        // The offscreen capture doesn't include the window's own background, so draw one.
        let root = RootView().environmentObject(model).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()

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

    private static func render(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #else
    static func run() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["OFFLINE_BARRAGE_SNAPSHOTS"],
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first, let root = window.rootViewController
        else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel.shared
        // An iPhone 15's screen, with its status bar and home indicator as safe-area insets.
        var size = CGSize(width: 393, height: 852)
        var insets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        if let value = environment["OFFLINE_BARRAGE_SNAPSHOT_SIZE"] {
            let parts = value.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                size = CGSize(width: parts[0], height: parts[1])
                insets = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
            }
        }
        let host = UIHostingController(rootView: RootView().environmentObject(model))
        host.view.backgroundColor = .systemBackground
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.additionalSafeAreaInsets = insets

        for (name, apply) in scenes(model) {
            for dark in [false, true] where !dark || darkScenes.contains(name) {
                host.overrideUserInterfaceStyle = dark ? .dark : .light
                // Without animations, so each picture shows the finished state.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, apply)
                pump(0.8)
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: directory.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
            }
        }
        exit(0)
    }
    #endif

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
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

    /// All four Macs of a 2v2 game, played locally.
    private struct TeamDemo {
        var macs: [Seat: TeamMatch] = [:]
        var now = Date()
        var lastBattle: TeamBattleReport?

        init(players: [Seat: PlayerInfo], host: PlayerInfo) {
            let challenge = TeamChallenge(host: host, players: players, timeControl: TimeControl(initialSeconds: 300, incrementSeconds: 3))
            for (seat, player) in players {
                macs[seat] = TeamMatch(challenge: challenge, localPlayerID: player.id, now: now)
            }
            let start = now
            act(Seat(.one, .red)) { $0.confirm(at: start) }
        }

        mutating func deliver(_ update: TeamUpdate?, from seat: Seat) {
            guard let update = update else { return }
            for event in update.events {
                if case .battle(let report) = event { lastBattle = report }
            }
            for outgoing in update.outgoing {
                let recipients = outgoing.to == .partner ? [seat.partner] : Seat.all.filter { $0 != seat }
                for recipient in recipients {
                    let reply = macs[recipient]?.receive(outgoing.message, from: seat, at: now)
                    deliver(reply, from: recipient)
                }
            }
        }

        mutating func act(_ seat: Seat, _ body: (inout TeamMatch) -> TeamUpdate?) {
            guard var mac = macs[seat] else { return }
            let update = body(&mac)
            macs[seat] = mac
            deliver(update, from: seat)
        }

        mutating func lock(_ seat: Seat, _ setup: Setup) {
            let at = now
            act(seat) { $0.lockSetup(setup, at: at) }
        }

        mutating func play(_ seat: Seat, _ text: String) {
            now = now.addingTimeInterval(6)
            let at = now
            guard let move = Move(text) else { return }
            act(seat) { $0.playLocalMove(move, at: at) }
        }

        mutating func swap(_ seat: Seat, _ rank: Rank, _ square: String) {
            now = now.addingTimeInterval(6)
            let at = now
            act(seat) { mac in
                guard let piece = mac.localBoard?.position[Square(name: square)!]?.id else { return nil }
                return mac.swap(in: rank, for: piece, at: at)
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
            NearbyPlayer(id: "demo-opponent", name: "Sam", peerID: MCPeerID(displayName: "Sam"), isCompatible: true, device: "mac"),
            NearbyPlayer(id: "demo-jo", name: "Jo", peerID: MCPeerID(displayName: "Jo"), isCompatible: true, device: "iphone"),
            NearbyPlayer(id: "demo-old", name: "Alex's MacBook", peerID: MCPeerID(displayName: "Alex"), isCompatible: false),
        ]
        let saved = [midgame.red.snapshot(at: midgame.now), finished.red.snapshot(at: finished.now)]

        return [
            ("1-lobby", {
                model.showTeamDemo(nil)
                model.showDemo(match: nil, linkStatus: .offline, nearby: nearby, savedGames: saved)
            }),
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
        ] + teamScenes(model)
    }

    private static func teamScenes(_ model: AppModel) -> [(String, () -> Void)] {
        let me = Seat(.one, .red)
        let players: [Seat: PlayerInfo] = [
            me: model.localInfo,
            Seat(.one, .blue): PlayerInfo(id: "demo-sam", name: "Sam"),
            Seat(.two, .red): PlayerInfo(id: "demo-alex", name: "Alex"),
            Seat(.two, .blue): PlayerInfo(id: "demo-kim", name: "Kim"),
        ]
        func table(_ demo: TeamDemo, seat: Seat = me) -> TeamTable {
            TeamTable(match: demo.macs[seat]!, app: model, service: nil, demoConnected: true)
        }

        var setupDemo = TeamDemo(players: players, host: model.localInfo)
        setupDemo.lock(Seat(.one, .blue), blueSetup)
        setupDemo.lock(Seat(.two, .blue), blueSetup)
        var partial = Setup(side: .red)
        for (square, rank) in redSetup.placements.sorted(by: { $0.key < $1.key }).prefix(6) {
            partial.place(rank, at: square)
        }

        var demo = TeamDemo(players: players, host: model.localInfo)
        demo.lock(me, redSetup)
        demo.lock(Seat(.one, .blue), blueSetup)
        demo.lock(Seat(.two, .red), redSetup)
        demo.lock(Seat(.two, .blue), blueSetup)
        demo.play(me, "E4-E6")
        demo.play(Seat(.two, .red), "J4-J6")
        demo.play(Seat(.one, .blue), "F7-F6")
        demo.play(Seat(.two, .blue), "J8-J7")
        demo.play(me, "E6-F6")                  // Scouts trade on board 1
        demo.play(Seat(.two, .red), "J6-J7")    // Alex's Scout loses to Kim's Miner
        let battle = demo.lastBattle
        demo.play(Seat(.one, .blue), "B7-B6")
        demo.swap(Seat(.two, .blue), .scout, "D8")  // Kim swaps the Scout from board 1 in for the Spy
        demo.swap(Seat(.two, .red), .scout, "H4")   // Alex swaps his Scout in for the General
        let notice = TeamSwapReport(seat: Seat(.two, .red), removed: .general, placed: .scout)

        var finished = demo
        finished.swap(me, .scout, "C3")
        finished.play(Seat(.one, .blue), "E7-E6")
        finished.play(Seat(.two, .blue), "J7-J6")
        finished.act(Seat(.one, .blue)) { [now = finished.now] in $0.resign(at: now) }

        // Alex (board 2, Red) is down to the Flag with a Scout in reserve: no move, no swap.
        let alex = Seat(.two, .red), kim = Seat(.two, .blue)
        var lone = TeamDemo(players: players, host: model.localInfo)
        lone.lock(me, setup(.red, ["A4": .scout, "J4": .scout, "A1": .marshal, "B1": .general,
                                   "C1": .miner, "D1": .spy, "E1": .bomb, "F1": .flag]))
        lone.lock(Seat(.one, .blue), setup(.blue, ["B7": .marshal, "J7": .flag, "A10": .general, "C10": .miner,
                                                   "D10": .scout, "E10": .scout, "F10": .spy, "G10": .bomb]))
        lone.lock(alex, setup(.red, ["A4": .bomb, "B4": .marshal, "E4": .general, "E3": .miner,
                                     "F4": .spy, "F3": .scout, "F2": .scout, "A1": .flag]))
        lone.lock(kim, setup(.blue, ["A7": .miner, "B7": .spy, "E7": .marshal, "F7": .general,
                                     "I7": .scout, "J7": .scout, "I10": .bomb, "J10": .flag]))
        let loneMoves: [(Seat, String)] = [
            (me, "A4-A6"), (Seat(.one, .blue), "B7-B6"), (me, "A6-B6"),
            (alex, "F2-G2"), (kim, "E7-E6"), (alex, "G2-F2"), (kim, "E6-E5"), (alex, "E4-E5"),
            (kim, "A7-A6"), (alex, "E3-E4"), (kim, "A6-A5"), (alex, "E4-E5"), (kim, "F7-F6"),
            (alex, "F2-G2"), (kim, "F6-F5"), (alex, "F4-F5"), (kim, "B7-B6"), (alex, "F3-F5"),
            (kim, "B6-B5"), (alex, "G2-F2"), (kim, "B5-B4"), (alex, "F2-F5"), (kim, "A5-A4"),
        ]
        for (seat, move) in loneMoves { lone.play(seat, move) }

        return [
            ("10-team-setup", { model.showTeamDemo(table(setupDemo), draft: partial) }),
            ("11-team-playing", {
                let t = table(demo)
                t.showDemo(notice: (.two, TeamTable.noticeText(notice, viewer: me)), swapRank: .scout)
                model.showTeamDemo(t)
            }),
            ("12-team-battle", {
                let t = table(demo)
                t.showDemo(battle: battle)
                model.showTeamDemo(t)
            }),
            ("13-team-partner-view", {
                let t = table(demo, seat: Seat(.two, .blue))
                t.showDemo(notice: (.two, TeamTable.noticeText(notice, viewer: Seat(.two, .blue))))
                model.showTeamDemo(t)
            }),
            ("14-team-over", { model.showTeamDemo(table(finished)) }),
            ("15-team-lone-flag", { model.showTeamDemo(table(lone, seat: alex)) }),
        ]
    }
}
#endif
