#if DEBUG
import BarrageCore
import Foundation

/// Developer aid (debug builds only): plays a 2v2 game through the real app, without a mouse.
/// Start three copies with `OFFLINE_BARRAGE_AUTOPLAY=guest` and one with `=host`, each with its own
/// `OFFLINE_BARRAGE_PROFILE`. The host invites the other three, everyone sets up at random and
/// plays random legal moves and swaps; after a while the host resigns. Each copy prints what
/// happens and quits with status 0 once all four armies were revealed and checked.
enum Autoplay {
    private static var role: String?
    private static var startedAt = Date()
    private static var lastAction = Date.distantPast
    private static var lastLog = ""
    private static var resigned = false
    private static var finishing = false
    private static var swaps = 0
    private static var wentToBackground = false

    static func start() {
        guard let value = ProcessInfo.processInfo.environment["OFFLINE_BARRAGE_AUTOPLAY"] else { return }
        role = value
        setvbuf(stdout, nil, _IOLBF, 0)
        log("autoplay as \(value)")
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in step() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func log(_ text: String) {
        print("[\(AppModel.shared.playerName)] \(text)")
    }

    private static func step() {
        let model = AppModel.shared
        let now = Date()
        if now.timeIntervalSince(startedAt) > 200 {
            log("FAIL: timed out")
            exit(2)
        }
        if model.incomingInvite != nil {
            log("accepting \(String(describing: model.incomingInvite!.invitation).prefix(40))…")
            model.acceptIncomingInvite()
            return
        }
        guard let table = model.teamTable else {
            if role == "host", model.screen == .lobby, model.compatibleNearby.count >= 3 {
                let others = model.compatibleNearby.map(\.id).sorted().prefix(3)
                let seats = [model.playerID] + others
                let assignment = Dictionary(uniqueKeysWithValues: zip(Seat.all, seats))
                log("inviting \(others.count) players")
                model.startTeamGame(seats: assignment, timeControl: TimeControl(initialSeconds: 180, incrementSeconds: 2))
            }
            return
        }
        let match = table.match
        let summary = "confirmed=\(match.isConfirmed) live=\(table.isLive) phase=\(match.phase) "
            + "turns=\(match.board(.one)?.ply ?? 0)+\(match.board(.two)?.ply ?? 0) "
            + "reserves=\(Seat.all.map { match.reserve(of: $0).map(\.label).joined() })"
        if summary != lastLog && now.timeIntervalSince(lastAction) > 0 {
            lastLog = summary
            if match.phase != .playing || (match.board(.one)?.ply ?? 0) % 10 == 0 { log(summary) }
        }
        if match.isOver {
            guard !finishing, match.verification != nil else { return }
            finishing = true
            let result = match.result.map { $0.summary { match.player($0).name } } ?? "?"
            log("game over: \(result); turns \(match.board(.one)?.ply ?? 0)+\(match.board(.two)?.ply ?? 0); own swaps \(swaps); check: \(String(describing: match.verification))")
            let passed = match.verification == .passed
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                log(passed ? "PASS" : "FAIL")
                exit(passed ? 0 : 1)
            }
            return
        }
        if model.canEditSetup && table.isLive {
            // Keep the Flag on the back row so the game lasts long enough for some swaps.
            repeat { model.randomizeSetup() } while model.setupDraft.slots.contains { $0.rank == .flag && $0.rowFromBack > 0 }
            model.lockSetup()
            log("setup locked in")
            return
        }
        if let crash = ProcessInfo.processInfo.environment["OFFLINE_BARRAGE_AUTOPLAY_CRASH_AFTER"].flatMap(Double.init),
           match.phase == .playing, now.timeIntervalSince(startedAt) > crash {
            log("crashing on purpose at turns \(match.board(.one)?.ply ?? 0)+\(match.board(.two)?.ply ?? 0)")
            exit(3)
        }
        #if os(iOS)
        // OFFLINE_BARRAGE_AUTOPLAY_BACKGROUND_AT=<seconds>: act as if the app went to the
        // background for 10 seconds (links dropped, clocks paused), then came back.
        if !wentToBackground, match.phase == .playing,
           let at = ProcessInfo.processInfo.environment["OFFLINE_BARRAGE_AUTOPLAY_BACKGROUND_AT"].flatMap(Double.init),
           now.timeIntervalSince(startedAt) > at {
            wentToBackground = true
            log("going to the background at turns \(match.board(.one)?.ply ?? 0)+\(match.board(.two)?.ply ?? 0)")
            model.didEnterBackground()
            log("links after suspending: \(table.missingSeats.count) missing; live=\(table.isLive)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                log("back in the foreground")
                model.willEnterForeground()
            }
            return
        }
        #endif
        if match.phase == .playing && !table.isLive && now.timeIntervalSince(lastAction) > 2 {
            lastAction = now
            log("waiting: \(table.missingSeats.map { match.player($0).name }) missing; my clock running: \(match.clocks[table.localSeat.board]?.isRunning == true)")
        }
        // Even when no one can move (both players to move may be waiting for pieces).
        if role == "host", !resigned, table.canAct, now.timeIntervalSince(startedAt) > 100 {
            resigned = true
            log("resigning")
            table.resign()
            return
        }
        guard table.canMove, now.timeIntervalSince(lastAction) > 0.3 else { return }
        lastAction = now
        if table.canSwap, Int.random(in: 0..<2) == 0,
           let rank = match.reserve(of: table.localSeat).randomElement(),
           let piece = match.swappablePieces.randomElement(),
           let square = match.localBoard?.position.pieces[piece]?.square {
            table.toggleSwapRank(rank)
            table.swap(at: square)
            swaps += 1
            log("swapped a \(rank.name) in at \(square.name)")
            return
        }
        let moves = match.legalMoves
        let attacks = moves.filter { match.localBoard?.position[$0.to] != nil }
        let quiet = moves.filter { match.localBoard?.position[$0.to] == nil }
        if let move = (Int.random(in: 0..<4) == 0 ? attacks.randomElement() : nil) ?? quiet.randomElement() ?? moves.randomElement() {
            table.play(move)
        }
    }
}
#endif
