import BarrageCore
import Foundation
import MultipeerConnectivity
import PeerKit

/// A 2v2 table on this device: the game (`TeamMatch`), the links to the other three players
/// (`TableLinks`) and what the 2v2 screen shows. Everything here runs on the main thread.
final class TeamTable: ObservableObject {
    @Published private(set) var match: TeamMatch
    @Published private(set) var linkStates: [String: TableLinks.LinkState] = [:]
    /// Players who went back to the lobby (or quit) on purpose.
    @Published private(set) var leftOnPurpose: Set<String> = []
    /// The reserve piece picked for a swap; the next click on one of our pieces swaps it in.
    @Published private(set) var swapRank: Rank? = nil
    /// The battle card shown over each board.
    @Published private(set) var battles: [BoardID: TeamBattleReport] = [:]
    /// A swap notice shown over each board.
    @Published private(set) var notices: [BoardID: String] = [:]
    /// Where our partner's last swap happened (we see their pieces face up).
    @Published private(set) var partnerSwapSquare: Square? = nil
    /// After the game: the turn shown on each board, or nil for the final position.
    @Published private(set) var viewPly: [BoardID: Int] = [:]
    @Published var showAllPieces = true
    @Published var reviewBoard: BoardID

    static let battleCardDuration: TimeInterval = 2.6
    static let noticeDuration: TimeInterval = 7
    static let challengeTimeout: TimeInterval = 60
    static let joinTimeout: TimeInterval = 30

    unowned let app: AppModel
    /// Nil for demo tables (UI snapshots) and for reviewing a finished game.
    let links: TableLinks?
    private let demoConnected: Bool
    private var battleExpiry: [BoardID: Date] = [:]
    private var noticeExpiry: [BoardID: Date] = [:]
    private var highlightExpiry: Date?
    /// Host only: guests whose challenge hasn't been answered yet, with when it was sent.
    private var pendingChallenges: [String: Date] = [:]
    private let openedAt = Date()
    private var lastLinkTick = Date.distantPast
    private var closed = false

    init(match: TeamMatch, app: AppModel, service: PeerService?, demoConnected: Bool = false) {
        self.match = match
        self.app = app
        self.demoConnected = demoConnected
        reviewBoard = match.localSeat.board
        if let service = service {
            let links = TableLinks(service: service, gameID: match.gameID, me: match.localPlayer, members: match.challenge.players)
            self.links = links
            links.delegate = self
            links.shouldAutoJoin = { [weak self] id in self?.pendingChallenges[id] == nil }
        } else {
            links = nil
        }
        refreshLinkStates()
    }

    var gameID: UUID { match.gameID }
    var localSeat: Seat { match.localSeat }

    func isMember(_ playerID: String) -> Bool { match.seat(ofPlayer: playerID) != nil && playerID != app.playerID }

    // MARK: - Connection state

    /// A finished game opened from the lobby: nothing to connect to.
    var isReviewOnly: Bool { links == nil && !demoConnected }

    /// All four Macs are linked: moves can be made and clocks run.
    var isLive: Bool { links?.allConnected ?? demoConnected }

    func linkState(of seat: Seat) -> TableLinks.LinkState {
        if seat == localSeat { return .connected }
        guard links != nil else { return demoConnected ? .connected : .disconnected }
        return linkStates[match.player(seat).id] ?? .disconnected
    }

    /// Players we aren't linked to.
    var missingSeats: [Seat] { Seat.all.filter { linkState(of: $0) != .connected } }

    var canMove: Bool { isLive && match.isLocalTurn && viewPly.isEmpty }
    var canSwap: Bool { canMove && match.canSwap }
    var canAct: Bool { isLive && match.hasStarted && !match.isOver }

    var revealsEverything: Bool { match.isOver && match.hasFullReveal && showAllPieces }

    func displayedPly(_ board: BoardID) -> Int {
        let last = match.board(board)?.ply ?? 0
        return min(viewPly[board] ?? last, last)
    }

    // MARK: - Starting

    /// Host: invites the three other players. `peers` maps their player IDs to nearby Macs.
    func inviteGuests(_ peers: [String: MCPeerID]) {
        guard let links = links, let context = try? Wire.encode(InvitationEnvelope(.teamChallenge(match.challenge))) else { return }
        let now = Date()
        for member in links.members {
            guard let peer = peers[member.id] else { continue }
            pendingChallenges[member.id] = now
            links.invite(member.id, peer: peer, context: context, timeout: TeamTable.challengeTimeout, now: now)
        }
        refreshLinkStates()
    }

    /// Guest: we're accepting an invitation from `playerID` (the host's challenge or a join).
    func expectLink(from playerID: String, peer: MCPeerID) {
        links?.expectLink(from: playerID, peer: peer)
        refreshLinkStates()
    }

    /// A `.teamJoin` invitation for this table.
    func answerJoin(from playerID: String, peer: MCPeerID, reply: @escaping (InvitationAnswer) -> Void) {
        guard let links = links else {
            reply(.decline)
            return
        }
        links.answerJoin(from: playerID, peer: peer, reply: reply)
        refreshLinkStates()
    }

    // MARK: - Local actions

    func lockSetup(_ setup: Setup) {
        guard isLive else { return }
        let now = Date()
        mutate { $0.lockSetup(setup, at: now) }
    }

    func play(_ move: Move) {
        guard canMove else { return }
        let now = Date()
        swapRank = nil
        mutate { $0.playLocalMove(move, at: now) }
    }

    func toggleSwapRank(_ rank: Rank) {
        guard canSwap else { return }
        swapRank = swapRank == rank ? nil : rank
    }

    func cancelSwap() { swapRank = nil }

    func swap(at square: Square) {
        guard canMove, let rank = swapRank, let piece = match.localBoard?.position[square]?.id else { return }
        let now = Date()
        swapRank = nil
        mutate { $0.swap(in: rank, for: piece, at: now) }
    }

    func explainBlockedMove(_ move: Move) {
        guard let board = match.localBoard, let restriction = Rules.restriction(on: move, in: board) else { return }
        app.playSound("Funk")
        app.showBanner(restriction.explanation)
    }

    func resign() {
        guard canAct else { return }
        let now = Date()
        mutate { $0.resign(at: now) }
    }

    func offerDraw() {
        guard canAct else { return }
        let now = Date()
        mutate { $0.offerDraw(at: now) }
    }

    func answerDraw(accept: Bool) {
        guard canAct else { return }
        let now = Date()
        mutate { $0.answerDrawOffer(accept: accept, at: now) }
    }

    func sendChat(_ text: String, teamOnly: Bool) {
        let now = Date()
        mutate { $0.sendChat(text, teamOnly: teamOnly, at: now) }
    }

    func dismissBattle(_ board: BoardID) {
        battles[board] = nil
        battleExpiry[board] = nil
    }

    func showPly(_ ply: Int, on board: BoardID) {
        guard match.isOver, let last = match.board(board)?.ply else { return }
        viewPly[board] = ply >= last ? nil : max(0, ply)
    }

    func showLive(_ board: BoardID) { viewPly[board] = nil }

    /// Back to the lobby. Before everyone has joined, this calls the table off for all.
    func leave() {
        guard !closed else { return }
        if match.isConfirmed {
            send(.leaving, to: .everyone)
        } else {
            send(.cancelled(reason: "\(match.localPlayer.name) left before the game started."), to: .everyone)
        }
        shutDown(delay: 0.5)
    }

    func prepareForTermination() {
        guard !closed else { return }
        if links?.connectedCount ?? 0 > 0 {
            send(.leaving, to: .everyone)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        shutDown(delay: 0)
    }

    /// iOS: the app is going to the background. Drops the links as if they were lost (clocks
    /// pause, and they come back on their own), rather than leaving the game.
    func suspendLinks() {
        guard !closed, let links = links else { return }
        links.suspend()
        refreshLinkStates()
        refreshClocks()
        persist()
    }

    private func shutDown(delay: TimeInterval) {
        closed = true
        match.pauseClocks(at: Date())
        persist()
        links?.close(after: delay)
    }

    /// Calls the table off (before it was confirmed) and tells whoever is connected.
    private func cancelTable(_ reason: String) {
        guard !closed, !match.isConfirmed else { return }
        send(.cancelled(reason: reason), to: .everyone)
        shutDown(delay: 0.5)
        app.closeTeamTable(banner: reason)
    }

    // MARK: - Ticking

    func tick(now: Date) {
        guard !closed else { return }
        if isLive, match.clocks[localSeat.board]?.running == localSeat.side,
           (match.clocks[localSeat.board]?.remaining(localSeat.side, at: now) ?? 1) <= 0 {
            mutate { $0.checkTimeout(at: now) }
        }
        for (board, expiry) in battleExpiry where now >= expiry { dismissBattle(board) }
        for (board, expiry) in noticeExpiry where now >= expiry {
            notices[board] = nil
            noticeExpiry[board] = nil
        }
        if let expiry = highlightExpiry, now >= expiry {
            partnerSwapSquare = nil
            highlightExpiry = nil
        }
        guard let links = links, now.timeIntervalSince(lastLinkTick) >= 1 else { return }
        lastLinkTick = now

        if match.isHost && !match.isConfirmed {
            for (id, sentAt) in pendingChallenges where now.timeIntervalSince(sentAt) > TeamTable.challengeTimeout + 8 {
                cancelTable("\(name(of: id)) didn't answer the invitation.")
                return
            }
        }
        if !match.isHost && !match.isConfirmed && !links.everConnected.contains(match.challenge.host.id)
            && now.timeIntervalSince(openedAt) > TeamTable.joinTimeout {
            shutDown(delay: 0)
            app.closeTeamTable(banner: "Couldn't connect to \(match.challenge.host.name). Ask them to invite you again.")
            return
        }
        // Finished games don't need the links any more.
        if !match.isOver || !match.hasFullReveal {
            var nearby: [String: MCPeerID] = [:]
            for player in app.nearby where player.isCompatible { nearby[player.id] = player.peerID }
            links.tick(now: now, nearby: nearby)
            refreshLinkStates()
        }
    }

    // MARK: - Internals

    private func mutate(_ body: (inout TeamMatch) -> TeamUpdate?) {
        var current = match
        let update = body(&current)
        match = current
        if let update = update { process(update) }
    }

    private func process(_ update: TeamUpdate) {
        for outgoing in update.outgoing { send(outgoing.message, to: outgoing.to) }
        for event in update.events { react(to: event) }
        refreshClocks()
        persist()
    }

    private func send(_ message: TeamMessage, to recipients: Recipients) {
        guard let links = links, let data = try? Wire.encode(TeamEnvelope(gameID: gameID, message: message)) else { return }
        switch recipients {
        case .everyone: links.sendToAll(data)
        case .partner: links.send(data, to: match.player(match.partnerSeat).id)
        }
    }

    private func refreshClocks() {
        let now = Date()
        if isLive { match.resumeClocks(at: now) } else { match.pauseClocks(at: now) }
    }

    private func refreshLinkStates() {
        guard let links = links else { return }
        if linkStates != links.states { linkStates = links.states }
    }

    func persist() {
        guard match.isConfirmed, links != nil else { return }
        app.saveTeamGame(match.snapshot(for: nil, at: Date()))
    }

    private func name(of playerID: String) -> String {
        match.challenge.players.first { $0.id == playerID }?.name ?? "A player"
    }

    private func react(to event: TeamEvent) {
        switch event {
        case .playerReady(let seat):
            if seat != localSeat { app.playSound("Morse") }
        case .confirmed:
            app.playSound("Hero")
            app.showBanner("Everyone has joined. Set up your army.")
        case .gameStarted:
            app.playSound("Hero")
            app.requestAttention()
            app.showBanner(localSeat.side == .red ? "All four armies are in place. You're Red: you move first."
                                                  : "All four armies are in place. Red moves first on both boards.")
        case let .acted(seat, _):
            if seat != localSeat { app.playSound("Tink") }
            if seat == localSeat.opponent { app.requestAttention() }
        case .battle(let report):
            battles[report.board] = report
            battleExpiry[report.board] = Date().addingTimeInterval(TeamTable.battleCardDuration)
            app.playSound(report.outcome == .bothLose ? "Bottle" : "Pop")
        case .swapped(let report):
            guard report.seat != localSeat else { break }
            notices[report.board] = TeamTable.noticeText(report, viewer: localSeat)
            noticeExpiry[report.board] = Date().addingTimeInterval(TeamTable.noticeDuration)
            app.playSound("Submarine")
        case .partnerSwapped(let piece):
            partnerSwapSquare = match.board(match.partnerSeat.board)?.position.pieces[piece]?.square
            highlightExpiry = Date().addingTimeInterval(TeamTable.noticeDuration)
        case .gameOver(let result):
            swapRank = nil
            if let winner = result.winner {
                app.playSound(winner == localSeat.team ? "Glass" : "Basso")
            } else {
                app.playSound("Glass")
            }
            app.requestAttention()
        case .drawOffered:
            app.playSound("Ping")
            app.requestAttention()
        case .drawDeclined(let seat):
            app.showBanner("\(match.player(seat).name) declined the draw.")
        case .chatReceived:
            app.playSound("Purr")
            app.requestAttention()
        case .resynced:
            break
        case .verificationFailed(let reason):
            app.showBanner("Setup check failed: \(reason)")
        }
    }

    /// "An opponent's General in your game was replaced by a Scout."
    static func noticeText(_ report: TeamSwapReport, viewer: Seat) -> String {
        let removed = report.removed.name
        let placed = report.placed.name
        if report.seat == viewer.opponent {
            return "An opponent's \(removed) in your game was replaced by a \(placed)."
        }
        if report.seat == viewer.otherOpponent {
            return "An opponent's \(removed) in the other game was replaced by a \(placed)."
        }
        return "Your teammate replaced their \(removed) with a \(placed)."
    }
}

// MARK: - TableLinksDelegate

extension TeamTable: TableLinksDelegate {
    func tableLinks(_ links: TableLinks, memberDidConnect memberID: String) {
        refreshLinkStates()
        leftOnPurpose.remove(memberID)
        pendingChallenges[memberID] = nil
        guard let seat = match.seat(ofPlayer: memberID) else { return }
        let now = Date()
        if match.isHost && !match.isConfirmed && links.members.allSatisfy({ links.everConnected.contains($0.id) }) {
            mutate { $0.confirm(at: now) }
        }
        send(.sync(match.snapshot(for: seat, at: now)), to: seat)
        refreshClocks()
        persist()
    }

    func tableLinks(_ links: TableLinks, memberDidDisconnect memberID: String) {
        let wasLive = linkStates.values.allSatisfy { $0 == .connected } && linkStates.count == 3
        refreshLinkStates()
        if pendingChallenges[memberID] != nil {
            cancelTable("\(name(of: memberID)) declined the invitation or didn't answer.")
            return
        }
        refreshClocks()
        persist()
        if wasLive && match.hasStarted && !match.isOver && !leftOnPurpose.contains(memberID) {
            app.playSound("Basso")
        }
    }

    func tableLinks(_ links: TableLinks, didReceive data: Data, from memberID: String) {
        guard let envelope = try? Wire.decode(TeamEnvelope.self, from: data),
              envelope.protocolVersion == Wire.protocolVersion, envelope.gameID == gameID,
              let seat = match.seat(ofPlayer: memberID)
        else { return }
        switch envelope.team {
        case .cancelled(let reason):
            guard !match.isConfirmed else { break }
            shutDown(delay: 0)
            app.closeTeamTable(banner: reason)
        case .leaving:
            leftOnPurpose.insert(memberID)
        default:
            leftOnPurpose.remove(memberID)
            let now = Date()
            mutate { $0.receive(envelope.team, from: seat, at: now) }
        }
    }

    private func send(_ message: TeamMessage, to seat: Seat) {
        guard let links = links, let data = try? Wire.encode(TeamEnvelope(gameID: gameID, message: message)) else { return }
        links.send(data, to: match.player(seat).id)
    }
}

#if DEBUG
extension TeamTable {
    /// Debug builds: puts the screen into a given state for UI snapshots.
    func showDemo(battle: TeamBattleReport? = nil, notice: (BoardID, String)? = nil, swapRank: Rank? = nil,
                  partnerSwap: Square? = nil, viewPly: [BoardID: Int] = [:]) {
        battles = [:]
        if let battle = battle { battles[battle.board] = battle }
        notices = [:]
        if let notice = notice { notices[notice.0] = notice.1 }
        self.swapRank = swapRank
        partnerSwapSquare = partnerSwap
        self.viewPly = viewPly
        battleExpiry = [:]
        noticeExpiry = [:]
        highlightExpiry = nil
    }
}
#endif
