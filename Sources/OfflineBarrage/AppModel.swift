import BarrageCore
#if os(macOS)
import CoreWLAN
#else
import UIKit
#endif
import Foundation
import MultipeerConnectivity
import PeerKit

struct NearbyPlayer: Identifiable, Hashable {
    let id: String  // player ID
    let name: String
    let peerID: MCPeerID
    let isCompatible: Bool
    /// "mac", "iphone" or "ipad" (nil from builds that don't say).
    var device: String? = nil
}

enum SideChoice: String, CaseIterable, Identifiable {
    case red, random, blue
    var id: String { rawValue }
    var label: String {
        switch self {
        case .red: return "Red"
        case .random: return "Random"
        case .blue: return "Blue"
        }
    }
}

enum Screen {
    case lobby
    case game
    /// A 2v2 table (see `AppModel.teamTable`).
    case teamGame
}

enum LinkStatus: Equatable {
    /// Reviewing a game; no opponent involved.
    case offline
    case connecting
    case connected
    /// The link dropped unexpectedly; retrying automatically.
    case reconnecting
    /// The opponent left (or stopped answering); resume manually.
    case waiting
}

struct IncomingInvite: Identifiable {
    let id = UUID()
    let invitation: Invitation
    let from: PlayerInfo
    let expiresAt: Date
    /// Our copy of the game, for resume requests.
    let savedGame: MatchSnapshot?
    let reply: (Bool) -> Void
    /// 2v2: the inviting Mac, and our copy of the game for resume requests.
    var peerID: MCPeerID? = nil
    var savedTeamGame: TeamSnapshot? = nil
}

struct OutgoingInvite {
    let invitation: Invitation
    let to: PlayerInfo
    let sentAt: Date

    var isChallenge: Bool {
        if case .challenge = invitation { return true }
        return false
    }
}

/// App state and the glue between the UI, `Match` (rules/protocol) and `PeerService` (transport).
/// Everything here runs on the main thread.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    static let challengeTimeout: TimeInterval = 60
    static let resumeTimeout: TimeInterval = 30
    static let battleCardDuration: TimeInterval = 2.6

    private enum Keys {
        static let playerID = "playerID"
        static let playerName = "playerName"
        static let sounds = "soundsEnabled"
        static let lastSetup = "lastSetup"
    }

    let playerID: String
    @Published private(set) var playerName: String
    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Keys.sounds) }
    }

    @Published private(set) var nearby: [NearbyPlayer] = []
    @Published private(set) var savedGames: [MatchSnapshot] = []
    @Published private(set) var wifiPoweredOff = false

    @Published internal(set) var screen: Screen = .lobby
    @Published private(set) var match: Match? = nil {
        didSet {
            if oldValue?.gameID != match?.gameID { prepareSetupDraft() }
        }
    }
    /// The 2v2 table on screen (instead of `match`).
    @Published internal(set) var teamTable: TeamTable? = nil
    @Published internal(set) var savedTeamGames: [TeamSnapshot] = []
    /// Drives the "new 2v2 game" sheet.
    @Published var showingTeamSheet = false
    @Published private(set) var linkStatus: LinkStatus = .offline
    @Published private(set) var opponentLeftOnPurpose = false
    /// The move number being viewed, or nil to follow the live position.
    @Published private(set) var viewPly: Int? = nil
    /// After the game: show every piece's rank on the board.
    @Published var showAllPieces = true

    /// The setup being arranged (before it is locked in).
    @Published internal(set) var setupDraft = Setup(side: .red)
    @Published private(set) var savedSetups: [SavedSetup] = []

    /// The battle card currently shown over the board.
    @Published private(set) var battle: BattleReport? = nil

    /// Setting this to nil (or replacing it) declines the invitation unless it was already answered.
    @Published var incomingInvite: IncomingInvite? = nil {
        didSet {
            if let old = oldValue, old.id != incomingInvite?.id { old.reply(false) }
        }
    }
    @Published private(set) var outgoingInvite: OutgoingInvite? = nil
    /// Drives the "challenge this player" sheet.
    @Published var challengeTarget: NearbyPlayer? = nil

    @Published private(set) var rematchOfferIn: Challenge? = nil
    @Published private(set) var rematchOfferOut: Challenge? = nil

    @Published private(set) var banner: String? = nil

    let launchedAt = Date()

    private let defaults = AppEnvironment.defaults
    let peerService: PeerService
    private let store = GameStore()
    let teamStore = TeamGameStore()
    var declinedTeamResumes: [UUID: Date] = [:]
    private let setupStore = SetupStore()
    private var timer: Timer?
    private var bannerExpiry: Date?
    private var battleExpiry: Date?
    private var lastWiFiCheck = Date.distantPast
    /// False only while a just-accepted challenge hasn't connected yet (such games are not saved).
    private var linkEverConnected = false
    private var disconnectedAt: Date?
    private var lastReconnectAttempt: Date?
    private var reconnectFailures = 0
    private var declinedResumes: [UUID: Date] = [:]
    /// iOS: the app went to the background and its links were dropped.
    private var linksSuspended = false

    init() {
        if let id = defaults.string(forKey: Keys.playerID) {
            playerID = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: Keys.playerID)
            playerID = id
        }
        let name = PeerService.sanitize(defaults.string(forKey: Keys.playerName) ?? AppModel.defaultPlayerName())
        playerName = name
        soundsEnabled = defaults.object(forKey: Keys.sounds) as? Bool ?? true
        peerService = PeerService(displayName: name, playerID: playerID, deviceKind: Device.kind, defaults: defaults)

        savedGames = store.loadAll()
        savedTeamGames = teamStore.loadAll()
        savedSetups = setupStore.load()
        peerService.delegate = self
        if !AppModel.isSnapshotMode { peerService.start() }

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkWiFi()
    }

    /// Debug builds can render UI snapshots instead of going online (see DemoSnapshots).
    static var isSnapshotMode: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["OFFLINE_BARRAGE_SNAPSHOTS"] != nil
        #else
        return false
        #endif
    }

    static func defaultPlayerName() -> String {
        var name = Device.defaultPlayerName()
        if let profile = AppEnvironment.profile { name += " (\(profile))" }
        return name
    }

    // MARK: - Derived state

    var localInfo: PlayerInfo { PlayerInfo(id: playerID, name: playerName) }

    var unfinishedGames: [MatchSnapshot] {
        savedGames.filter { $0.result == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var finishedGames: [MatchSnapshot] {
        savedGames.filter { $0.result != nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func nearbyPlayer(_ id: String) -> NearbyPlayer? {
        nearby.first { $0.id == id }
    }

    /// The ply shown on the board.
    var displayedPly: Int {
        guard let game = match?.game else { return 0 }
        return min(viewPly ?? game.ply, game.ply)
    }

    var canMove: Bool {
        guard let match = match else { return false }
        return linkStatus == .connected && match.isLocalTurn && viewPly == nil
    }

    var canAct: Bool {
        guard let match = match else { return false }
        return linkStatus == .connected && !match.isOver
    }

    /// The setup can still be rearranged: the game hasn't started and we haven't locked in.
    var canEditSetup: Bool {
        if let table = teamTable { return table.match.phase == .setup && !table.match.isLocalReady }
        guard let match = match else { return false }
        return match.phase == .setup && !match.isLocalReady
    }

    var canLockSetup: Bool {
        if let table = teamTable { return canEditSetup && setupDraft.isComplete && table.isLive }
        return canEditSetup && setupDraft.isComplete && linkStatus == .connected
    }

    /// Ranks are shown for every piece: after the game, once both armies are revealed.
    var revealsEverything: Bool {
        guard let match = match else { return false }
        return match.isOver && match.hasFullReveal && showAllPieces
    }

    var isWaitingForChallengeAnswer: Bool { outgoingInvite?.isChallenge == true }

    // MARK: - Lobby actions

    func rename(_ newName: String) {
        let clean = PeerService.sanitize(String(newName.prefix(40)))
        guard clean != playerName, screen == .lobby, outgoingInvite == nil else { return }
        playerName = clean
        defaults.set(clean, forKey: Keys.playerName)
        peerService.restart(displayName: clean)
    }

    func sendChallenge(to player: NearbyPlayer, side: SideChoice, timeControl: TimeControl) {
        guard outgoingInvite == nil, screen == .lobby else { return }
        let mySide: Side
        switch side {
        case .red: mySide = .red
        case .blue: mySide = .blue
        case .random: mySide = Bool.random() ? .red : .blue
        }
        let challenge = Challenge(challenger: localInfo, challengerSide: mySide, timeControl: timeControl)
        invite(player.peerID, to: PlayerInfo(id: player.id, name: player.name),
               invitation: .challenge(challenge), timeout: AppModel.challengeTimeout)
    }

    func cancelChallenge() {
        guard isWaitingForChallengeAnswer else { return }
        outgoingInvite = nil
        peerService.disconnect()
    }

    func acceptIncomingInvite() {
        guard let invite = incomingInvite else { return }
        let newMatch: Match
        let isResume: Bool
        switch invite.invitation {
        case .challenge(let challenge):
            newMatch = Match(challenge: challenge, accepter: localInfo, localPlayerID: playerID, now: Date())
            isResume = false
        case .resume:
            guard let saved = invite.savedGame, let restored = Match(snapshot: saved, localPlayerID: playerID) else {
                incomingInvite = nil
                return
            }
            newMatch = restored
            isResume = true
        case .teamChallenge, .teamJoin:
            acceptTeamInvite(invite)
            return
        }
        closeCurrentGame(notifyOpponent: true)
        outgoingInvite = nil
        match = newMatch
        linkEverConnected = isResume
        linkStatus = .connecting
        resetViewState()
        screen = .game
        invite.reply(true)
        incomingInvite = nil
    }

    func declineIncomingInvite() {
        guard let invite = incomingInvite else { return }
        if case .resume(let gameID, _) = invite.invitation {
            declinedResumes[gameID] = Date()  // don't keep re-asking for a while
        }
        if case .teamJoin(let gameID, _) = invite.invitation {
            declinedTeamResumes[gameID] = Date()
        }
        invite.reply(false)
        incomingInvite = nil
    }

    /// Opens a saved game: finished games for review, unfinished ones to resume with the opponent.
    func openSavedGame(_ snapshot: MatchSnapshot) {
        guard let restored = Match(snapshot: snapshot, localPlayerID: playerID) else {
            showBanner("This saved game couldn't be opened.")
            return
        }
        if isWaitingForChallengeAnswer { cancelChallenge() }
        closeCurrentGame(notifyOpponent: false)
        match = restored
        linkEverConnected = true
        resetViewState()
        screen = .game
        if restored.isOver {
            linkStatus = .offline
        } else {
            linkStatus = .reconnecting
            disconnectedAt = .distantPast
            attemptReconnect()
        }
    }

    func deleteSavedGame(_ gameID: UUID) {
        store.delete(gameID)
        savedGames.removeAll { $0.gameID == gameID }
    }

    // MARK: - Setup

    func placeFromTray(_ rank: Rank, at square: Square) {
        guard canEditSetup else { return }
        if setupDraft.place(rank, at: square) { playSound("Tink") }
    }

    func moveSetupPiece(from: Square, to: Square) {
        guard canEditSetup else { return }
        if setupDraft.move(from: from, to: to) { playSound("Tink") }
    }

    func removeSetupPiece(at square: Square) {
        guard canEditSetup else { return }
        setupDraft.remove(at: square)
    }

    func randomizeSetup() {
        guard canEditSetup else { return }
        setupDraft = Setup.random(side: setupDraft.side)
    }

    func clearSetup() {
        guard canEditSetup else { return }
        setupDraft.clear()
    }

    func loadSetup(_ saved: SavedSetup) {
        guard canEditSetup else { return }
        setupDraft = Setup(side: setupDraft.side, slots: saved.slots)
    }

    /// Saves the current arrangement under `name`, replacing a setup with the same name.
    func saveSetup(named name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty, setupDraft.isComplete else { return }
        let setup = SavedSetup(name: clean, slots: setupDraft.slots, savedAt: Date())
        savedSetups.removeAll { $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }
        savedSetups.append(setup)
        savedSetups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        setupStore.save(savedSetups)
        showBanner("Saved setup \u{201C}\(clean)\u{201D}.")
    }

    func deleteSetup(_ saved: SavedSetup) {
        savedSetups.removeAll { $0.id == saved.id }
        setupStore.save(savedSetups)
    }

    func lockSetup() {
        guard canLockSetup else { return }
        let draft = setupDraft
        let now = Date()
        if let table = teamTable {
            table.lockSetup(draft)
        } else {
            mutateMatch { $0.lockSetup(draft, at: now) }
        }
        if let data = try? JSONEncoder().encode(draft.slots) {
            defaults.set(data, forKey: Keys.lastSetup)
        }
    }

    private func prepareSetupDraft() {
        guard let match = match else { return }
        prepareSetupDraft(side: match.localSide, locked: match.localSetup)
    }

    func prepareSetupDraft(side: Side, locked: Setup?) {
        if let locked = locked {
            setupDraft = locked
        } else if let data = defaults.data(forKey: Keys.lastSetup),
                  let slots = try? JSONDecoder().decode([SetupSlot].self, from: data) {
            setupDraft = Setup(side: side, slots: slots)
        } else {
            setupDraft = Setup(side: side)
        }
    }

    // MARK: - Game actions

    func play(_ move: Move) {
        guard canMove else { return }
        let now = Date()
        mutateMatch { $0.playLocalMove(move, at: now) }
        viewPly = nil
    }

    /// The player tried a move the repetition rules forbid.
    func explainBlockedMove(_ move: Move) {
        guard let game = match?.game, let restriction = Rules.restriction(on: move, in: game) else { return }
        playSound("Funk")
        showBanner(restriction.explanation)
    }

    func resign() {
        guard canAct else { return }
        let now = Date()
        mutateMatch { $0.resign(at: now) }
    }

    func offerDraw() {
        guard canAct else { return }
        let now = Date()
        mutateMatch { $0.offerDraw(at: now) }
    }

    func respondToDraw(accept: Bool) {
        guard canAct else { return }
        let now = Date()
        mutateMatch { $0.respondToDrawOffer(accept: accept, at: now) }
    }

    func sendChat(_ text: String) {
        guard linkStatus == .connected else { return }
        let now = Date()
        mutateMatch { $0.sendChat(text, at: now) }
    }

    func offerRematch() {
        guard let match = match, match.isOver, linkStatus == .connected, rematchOfferOut == nil else { return }
        if rematchOfferIn != nil {
            respondToRematch(accept: true)
            return
        }
        let offer = Challenge(challenger: localInfo, challengerSide: match.localSide.opposite, timeControl: match.timeControl)
        rematchOfferOut = offer
        send(.rematchOffer(offer))
    }

    func respondToRematch(accept: Bool) {
        guard let offer = rematchOfferIn else { return }
        rematchOfferIn = nil
        send(accept ? .rematchAccepted(gameID: offer.gameID) : .rematchDeclined)
        if accept { startRematch(offer) }
    }

    /// Manual retry after the opponent left or stopped answering.
    func askToResume() {
        guard let match = match, linkStatus == .waiting || linkStatus == .reconnecting,
              outgoingInvite == nil, let peer = nearbyPlayer(match.opponent.id)
        else { return }
        reconnectFailures = 0
        sendResumeInvite(to: peer, match: match)
    }

    /// Closes any 1v1 game before a 2v2 table opens.
    func leaveSoloGame() {
        guard match != nil || outgoingInvite != nil else { return }
        closeCurrentGame(notifyOpponent: true)
        resetViewState()
    }

    func leaveGame() {
        closeCurrentGame(notifyOpponent: true)
        resetViewState()
        screen = .lobby
    }

    func dismissBattle() {
        battle = nil
        battleExpiry = nil
    }

    // MARK: - Board navigation

    func showPly(_ ply: Int) {
        guard let game = match?.game else { return }
        viewPly = ply >= game.ply ? nil : max(0, ply)
    }

    func showLive() { viewPly = nil }

    // MARK: - Banner

    func showBanner(_ text: String) {
        banner = text
        bannerExpiry = Date().addingTimeInterval(6)
    }

    func dismissBanner() {
        banner = nil
        bannerExpiry = nil
    }

    // MARK: - App lifecycle

    func prepareForTermination() {
        teamTable?.prepareForTermination()
        if linkStatus == .connected {
            send(.leaving)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        if var match = match {
            match.pauseClock(at: Date())
            self.match = match
            persist()
        }
        peerService.disconnect()
        peerService.stopDiscovery()
    }

    #if os(iOS)
    /// iOS suspends a backgrounded app and MultipeerConnectivity drops its links. Rather than let
    /// the other players find out from a timeout, drop them right away (as a lost connection, not
    /// as leaving: the game stays open, clocks pause, and it reconnects on return).
    func didEnterBackground() {
        guard !linksSuspended else { return }
        linksSuspended = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "Pause games")
        let now = Date()
        incomingInvite = nil  // declines it
        if isWaitingForChallengeAnswer { cancelChallenge() }
        if let table = teamTable {
            if table.match.isConfirmed {
                table.suspendLinks()
            } else {
                // Nobody can wait for a game that hasn't been agreed yet.
                table.leave()
                closeTeamTable(banner: "The 2v2 game was called off because Offline Barrage went to the background before it started.")
            }
        }
        suspendSoloLink(at: now)
        peerService.stopDiscovery()
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    /// Back in the foreground: look for the other players again; open games reconnect by themselves.
    func willEnterForeground() {
        guard linksSuspended else { return }
        linksSuspended = false
        peerService.start()
    }

    private func suspendSoloLink(at now: Date) {
        guard var current = match, linkStatus == .connected || linkStatus == .connecting else { return }
        outgoingInvite = nil
        peerService.disconnect()
        rematchOfferIn = nil
        rematchOfferOut = nil
        guard linkEverConnected else {
            // We had just accepted a challenge that never connected.
            match = nil
            linkStatus = .offline
            screen = .lobby
            return
        }
        current.pauseClock(at: now)
        match = current
        persist()
        linkStatus = current.isOver ? .waiting : .reconnecting
        disconnectedAt = now
        lastReconnectAttempt = nil
        reconnectFailures = 0
    }
    #endif

    // MARK: - Internals

    private func mutateMatch(_ body: (inout Match) -> MatchUpdate?) {
        guard var current = match else { return }
        let update = body(&current)
        match = current
        if let update = update { process(update) }
    }

    private func process(_ update: MatchUpdate) {
        for message in update.outgoing { send(message) }
        for event in update.events { react(to: event) }
        persist()
    }

    private func send(_ message: GameMessage) {
        guard let match = match, linkStatus == .connected,
              let data = try? Wire.encode(WireEnvelope(gameID: match.gameID, message: message))
        else { return }
        peerService.send(data)
    }

    private func persist() {
        guard let match = match, linkEverConnected else { return }
        let snapshot = match.snapshot(at: Date())
        store.save(snapshot)
        if let index = savedGames.firstIndex(where: { $0.gameID == snapshot.gameID }) {
            savedGames[index] = snapshot
        } else {
            savedGames.insert(snapshot, at: 0)
        }
    }

    private func resetViewState() {
        viewPly = nil
        showAllPieces = true
        battle = nil
        battleExpiry = nil
    }

    private func closeCurrentGame(notifyOpponent: Bool) {
        let wasConnected = linkStatus == .connected
        if notifyOpponent && wasConnected { send(.leaving) }
        if var current = match {
            current.pauseClock(at: Date())
            match = current
            persist()
        }
        peerService.disconnect(after: wasConnected ? 0.5 : 0)
        match = nil
        linkStatus = .offline
        opponentLeftOnPurpose = false
        rematchOfferIn = nil
        rematchOfferOut = nil
        disconnectedAt = nil
        lastReconnectAttempt = nil
        reconnectFailures = 0
    }

    private func invite(_ peerID: MCPeerID, to player: PlayerInfo, invitation: Invitation, timeout: TimeInterval) {
        guard let data = try? Wire.encode(InvitationEnvelope(invitation)) else { return }
        outgoingInvite = OutgoingInvite(invitation: invitation, to: player, sentAt: Date())
        peerService.invite(peerID, context: data, timeout: timeout)
    }

    private func sendResumeInvite(to peer: NearbyPlayer, match: Match) {
        lastReconnectAttempt = Date()
        linkStatus = .connecting
        invite(peer.peerID, to: match.opponent, invitation: .resume(gameID: match.gameID, player: localInfo),
               timeout: AppModel.resumeTimeout)
    }

    /// Automatic reconnection while a live game's link is down. The player with the lower ID
    /// invites right away; the other waits a few seconds so the two invitations don't cross.
    private func attemptReconnect(now: Date = Date()) {
        guard screen == .game, linkStatus == .reconnecting, outgoingInvite == nil, incomingInvite == nil,
              let match = match, !match.isOver,
              let peer = nearbyPlayer(match.opponent.id), peer.isCompatible
        else { return }
        if let last = lastReconnectAttempt, now.timeIntervalSince(last) < 8 { return }
        if playerID > match.opponent.id, let since = disconnectedAt, now.timeIntervalSince(since) < 4 { return }
        sendResumeInvite(to: peer, match: match)
    }

    private func startRematch(_ offer: Challenge) {
        guard let current = match else { return }
        let accepter = offer.challenger.id == playerID ? current.opponent : localInfo
        rematchOfferIn = nil
        rematchOfferOut = nil
        match = Match(challenge: offer, accepter: accepter, localPlayerID: playerID, now: Date())
        linkEverConnected = true
        resetViewState()
        persist()
        playSound("Hero")
        showBanner("Rematch! Set up your army. You play \(match?.localSide.name ?? "").")
    }

    private func receiveRematchOffer(_ offer: Challenge) {
        guard let match = match, match.isOver else { return }
        if let mine = rematchOfferOut {
            // Both offered at the same time: both sides pick the same offer.
            startRematch(mine.gameID.uuidString < offer.gameID.uuidString ? mine : offer)
            return
        }
        rematchOfferIn = offer
        playSound("Ping")
        requestAttention()
    }

    private func tick() {
        let now = Date()
        teamTable?.tick(now: now)
        if linkStatus == .connected, let match = match, !match.isOver, let clock = match.clock,
           clock.running == match.localSide, clock.remaining(match.localSide, at: now) <= 0 {
            mutateMatch { $0.checkTimeout(at: now) }
        }
        if let invite = incomingInvite, now >= invite.expiresAt {
            incomingInvite = nil
        }
        if let expiry = bannerExpiry, now >= expiry {
            dismissBanner()
        }
        if let expiry = battleExpiry, now >= expiry {
            dismissBattle()
        }
        if let out = outgoingInvite, now.timeIntervalSince(out.sentAt) > AppModel.challengeTimeout + 5 {
            // Safety net in case MultipeerConnectivity never reports the outcome.
            peerService.disconnect()
            outgoingInvite = nil
            if out.isChallenge {
                showBanner("\(out.to.name) didn't answer the challenge.")
            } else if linkStatus == .connecting {
                linkStatus = .reconnecting
            }
        }
        attemptReconnect(now: now)
        if now.timeIntervalSince(lastWiFiCheck) > 3 { checkWiFi() }
    }

    /// The Mac can tell when Wi-Fi is switched off; iOS doesn't let apps check.
    private func checkWiFi() {
        lastWiFiCheck = Date()
        #if os(macOS)
        let interfaces = CWWiFiClient.shared().interfaces() ?? []
        let off = !interfaces.isEmpty && interfaces.allSatisfy { !$0.powerOn() }
        if off != wifiPoweredOff { wifiPoweredOff = off }
        #endif
    }

    private func react(to event: MatchEvent) {
        guard let match = match else { return }
        let opponentName = match.opponent.name
        switch event {
        case .opponentReady:
            playSound("Morse")
            if !match.isLocalReady { requestAttention() }
        case .gameStarted:
            playSound("Hero")
            requestAttention()
            showBanner(match.localSide == .red ? "Both armies are in place. You're Red: you move first."
                                               : "Both armies are in place. Red moves first.")
        case .moved(let byLocalPlayer):
            playSound("Tink")
            if !byLocalPlayer { requestAttention() }
        case .battle(let report):
            viewPly = nil
            battle = report
            battleExpiry = Date().addingTimeInterval(AppModel.battleCardDuration)
            playSound(report.outcome == .bothLose ? "Bottle" : "Pop")
        case .stuck(let side):
            if side == match.localSide {
                showBanner("You have no legal move left.")
            }
        case .gameOver(let result):
            if let winner = result.winner {
                playSound(winner == match.localSide ? "Glass" : "Basso")
            } else {
                playSound("Glass")
            }
            requestAttention()
        case .drawOffered:
            playSound("Ping")
            requestAttention()
        case .drawDeclined:
            showBanner("\(opponentName) declined your draw offer.")
        case .chatReceived:
            playSound("Purr")
            requestAttention()
        case .resynced:
            break
        case .verificationFailed(let reason):
            showBanner("Setup check failed: \(reason)")
        }
    }

    func playSound(_ name: String) {
        guard soundsEnabled else { return }
        Feedback.play(name)
    }

    func requestAttention() {
        Feedback.requestAttention()
    }
}

// MARK: - PeerServiceDelegate

extension AppModel: PeerServiceDelegate {
    func peerService(_ service: PeerService, didUpdateNearby peers: [DiscoveredPeer]) {
        nearby = peers
            .map { NearbyPlayer(id: $0.playerID, name: $0.name, peerID: $0.peerID,
                                isCompatible: $0.protocolVersion == Wire.protocolVersion, device: $0.deviceKind) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        attemptReconnect()
    }

    func peerService(_ service: PeerService, didReceiveInvitation context: Data?, from peerID: MCPeerID,
                     reply answer: @escaping (InvitationAnswer) -> Void) {
        let reply: (Bool) -> Void = { answer($0 ? .accept : .decline) }
        guard let context = context,
              let envelope = try? Wire.decode(InvitationEnvelope.self, from: context),
              envelope.protocolVersion == Wire.protocolVersion
        else {
            reply(false)
            return
        }
        let now = Date()
        let busy = ((linkStatus == .connected || linkStatus == .connecting) && match?.isOver == false) || teamTable != nil

        switch envelope.invitation {
        case .challenge(let challenge):
            guard !busy, incomingInvite == nil else {
                reply(false)
                return
            }
            challengeTarget = nil  // close our own challenge sheet so this prompt can be shown
            incomingInvite = IncomingInvite(invitation: envelope.invitation, from: challenge.challenger,
                                            expiresAt: now.addingTimeInterval(AppModel.challengeTimeout - 2),
                                            savedGame: nil, reply: reply)
            playSound("Ping")
            requestAttention()

        case let .resume(gameID, player):
            // The game on screen is waiting for exactly this opponent: reconnect without asking.
            if let match = match, match.gameID == gameID, screen == .game,
               [LinkStatus.reconnecting, .waiting, .connecting].contains(linkStatus) {
                if let out = outgoingInvite, out.to.id == player.id {
                    // Invitations crossed: the lower player ID's invitation wins.
                    if playerID < player.id {
                        reply(false)
                        return
                    }
                    outgoingInvite = nil
                }
                linkStatus = .connecting
                reply(true)
                return
            }
            if busy || incomingInvite != nil {
                reply(false)
                return
            }
            if let declined = declinedResumes[gameID], now.timeIntervalSince(declined) < 120 {
                reply(false)
                return
            }
            guard let saved = savedGames.first(where: { $0.gameID == gameID }), saved.side(of: player.id) != nil else {
                reply(false)
                return
            }
            challengeTarget = nil
            incomingInvite = IncomingInvite(invitation: envelope.invitation, from: player,
                                            expiresAt: now.addingTimeInterval(AppModel.resumeTimeout - 2),
                                            savedGame: saved, reply: reply)
            playSound("Ping")
            requestAttention()

        case .teamChallenge, .teamJoin:
            receiveTeamInvitation(envelope.invitation, from: peerID, reply: answer)
        }
    }

    func peerService(_ service: PeerService, linkDidChange state: PeerLinkState, peer: MCPeerID) {
        if let table = teamTable {
            table.links?.linkDidChange(state, peer: peer)
            return
        }
        switch state {
        case .connecting: break
        case .connected: linkDidConnect()
        case .disconnected: linkDidDrop()
        }
    }

    func peerService(_ service: PeerService, didReceive data: Data, from peerID: MCPeerID) {
        if let table = teamTable {
            table.links?.didReceive(data, from: peerID)
            return
        }
        guard let envelope = try? Wire.decode(WireEnvelope.self, from: data),
              envelope.protocolVersion == Wire.protocolVersion,
              var current = match, envelope.gameID == current.gameID
        else { return }
        let now = Date()
        switch envelope.message {
        case .leaving:
            opponentLeftOnPurpose = true
        case .rematchOffer(let offer):
            receiveRematchOffer(offer)
        case .rematchDeclined:
            if rematchOfferOut != nil {
                rematchOfferOut = nil
                showBanner("\(current.opponent.name) declined the rematch.")
            }
        case .rematchAccepted(let gameID):
            if let offer = rematchOfferOut, offer.gameID == gameID { startRematch(offer) }
        case .sync:
            let update = current.receive(envelope.message, at: now)
            current.resumeClock(at: now)
            match = current
            process(update)
        default:
            let update = current.receive(envelope.message, at: now)
            match = current
            process(update)
        }
    }

    private func linkDidConnect() {
        let now = Date()
        if let out = outgoingInvite {
            outgoingInvite = nil
            if case .challenge(let challenge) = out.invitation {
                match = Match(challenge: challenge, accepter: out.to, localPlayerID: playerID, now: now)
                resetViewState()
            }
        }
        guard let current = match else {
            peerService.disconnect()
            return
        }
        linkEverConnected = true
        linkStatus = .connected
        opponentLeftOnPurpose = false
        disconnectedAt = nil
        lastReconnectAttempt = nil
        reconnectFailures = 0
        incomingInvite = nil  // declines anything else that was pending
        screen = .game
        send(.sync(current.publicSnapshot(at: now)))
        persist()
    }

    private func linkDidDrop() {
        let now = Date()
        if let out = outgoingInvite {
            outgoingInvite = nil
            if out.isChallenge {
                showBanner("\(out.to.name) declined the challenge or didn't answer.")
            } else {
                reconnectFailures += 1
                linkStatus = reconnectFailures >= 3 ? .waiting : .reconnecting
            }
            return
        }
        guard var current = match else {
            linkStatus = .offline
            return
        }
        rematchOfferIn = nil
        rematchOfferOut = nil
        if !linkEverConnected {
            // We accepted a challenge, but the connection never came up.
            match = nil
            linkStatus = .offline
            screen = .lobby
            showBanner("Couldn't connect to \(current.opponent.name). Ask them to challenge you again.")
            return
        }
        current.pauseClock(at: now)
        match = current
        persist()

        let wasConnected = linkStatus == .connected
        if current.isOver || opponentLeftOnPurpose {
            linkStatus = .waiting
        } else if wasConnected {
            linkStatus = .reconnecting
            disconnectedAt = now
            lastReconnectAttempt = nil
            reconnectFailures = 0
            playSound("Basso")
        } else {
            // An accepted reconnection attempt failed before it came up.
            reconnectFailures += 1
            linkStatus = reconnectFailures >= 3 ? .waiting : .reconnecting
        }
    }
}


#if DEBUG
extension AppModel {
    /// Puts the app into a given state for UI snapshots (debug builds only).
    func showDemo(match: Match?, linkStatus: LinkStatus, draft: Setup? = nil, battle: BattleReport? = nil,
                  nearby: [NearbyPlayer] = [], savedGames: [MatchSnapshot] = [], banner: String? = nil,
                  viewPly: Int? = nil) {
        self.match = match
        screen = match == nil ? .lobby : .game
        self.linkStatus = linkStatus
        if let draft = draft { setupDraft = draft }
        self.battle = battle
        battleExpiry = nil
        self.nearby = nearby
        self.savedGames = savedGames
        self.banner = banner
        bannerExpiry = nil
        self.viewPly = viewPly
        showAllPieces = true
    }
}
#endif
