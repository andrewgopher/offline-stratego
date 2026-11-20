import BarrageCore
import Foundation
import MultipeerConnectivity
import PeerKit

/// 2v2: starting, joining, resuming and closing team tables.
extension AppModel {
    var unfinishedTeamGames: [TeamSnapshot] {
        savedTeamGames.filter { $0.result == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var finishedTeamGames: [TeamSnapshot] {
        savedTeamGames.filter { $0.result != nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var compatibleNearby: [NearbyPlayer] { nearby.filter(\.isCompatible) }

    /// Host: creates the table and invites the other three players. `seats` maps each seat to a
    /// player ID (ours included).
    func startTeamGame(seats: [Seat: String], timeControl: TimeControl) {
        guard screen == .lobby, outgoingInvite == nil, teamTable == nil else { return }
        var players: [Seat: PlayerInfo] = [:]
        var peers: [String: MCPeerID] = [:]
        for (seat, id) in seats {
            if id == playerID {
                players[seat] = localInfo
                continue
            }
            guard let peer = nearbyPlayer(id), peer.isCompatible else {
                showBanner("One of the players is no longer nearby.")
                return
            }
            players[seat] = PlayerInfo(id: id, name: peer.name)
            peers[id] = peer.peerID
        }
        let challenge = TeamChallenge(host: localInfo, players: players, timeControl: timeControl)
        guard let match = TeamMatch(challenge: challenge, localPlayerID: playerID, now: Date()) else { return }
        let table = TeamTable(match: match, app: self, service: peerService)
        openTeamTable(table)
        table.inviteGuests(peers)
    }

    func receiveTeamInvitation(_ invitation: Invitation, from peerID: MCPeerID,
                               reply: @escaping (InvitationAnswer) -> Void) {
        let now = Date()
        let busyWithSolo = (linkStatus == .connected || linkStatus == .connecting) && match?.isOver == false
        switch invitation {
        case .teamChallenge(let challenge):
            guard teamTable == nil, !busyWithSolo, incomingInvite == nil, outgoingInvite == nil,
                  challenge.isValid, challenge.seat(of: playerID) != nil
            else {
                reply(.decline)
                return
            }
            challengeTarget = nil
            showingTeamSheet = false
            incomingInvite = IncomingInvite(invitation: invitation, from: challenge.host,
                                            expiresAt: now.addingTimeInterval(TeamTable.challengeTimeout - 2),
                                            savedGame: nil, reply: { reply($0 ? .acceptAlongside : .decline) },
                                            peerID: peerID)
            playSound("Ping")
            requestAttention()

        case let .teamJoin(gameID, player):
            if let table = teamTable {
                if table.gameID == gameID && table.isMember(player.id) {
                    table.answerJoin(from: player.id, peer: peerID, reply: reply)
                } else {
                    reply(.decline)
                }
                return
            }
            // Not at that table: offer to resume our saved copy of the game.
            guard !busyWithSolo, incomingInvite == nil, outgoingInvite == nil,
                  let saved = savedTeamGames.first(where: { $0.gameID == gameID }),
                  saved.seat(of: player.id) != nil, saved.result == nil
            else {
                reply(.decline)
                return
            }
            if let declined = declinedTeamResumes[gameID], now.timeIntervalSince(declined) < 120 {
                reply(.decline)
                return
            }
            challengeTarget = nil
            showingTeamSheet = false
            incomingInvite = IncomingInvite(invitation: invitation, from: player,
                                            expiresAt: now.addingTimeInterval(TableLinks.joinTimeout - 2),
                                            savedGame: nil, reply: { reply($0 ? .acceptAlongside : .decline) },
                                            peerID: peerID, savedTeamGame: saved)
            playSound("Ping")
            requestAttention()

        case .challenge, .resume:
            reply(.decline)
        }
    }

    func acceptTeamInvite(_ invite: IncomingInvite) {
        let now = Date()
        var opened: TeamMatch?
        var inviterID = invite.from.id
        switch invite.invitation {
        case .teamChallenge(let challenge):
            opened = TeamMatch(challenge: challenge, localPlayerID: playerID, now: now)
            inviterID = challenge.host.id
        case .teamJoin:
            opened = invite.savedTeamGame.flatMap { TeamMatch(snapshot: $0, localPlayerID: playerID) }
        case .challenge, .resume:
            break
        }
        guard let match = opened, let peer = invite.peerID else {
            incomingInvite = nil
            showBanner("This game couldn't be opened.")
            return
        }
        if isWaitingForChallengeAnswer { cancelChallenge() }
        leaveSoloGame()
        let table = TeamTable(match: match, app: self, service: peerService)
        openTeamTable(table)
        table.expectLink(from: inviterID, peer: peer)
        invite.reply(true)
        incomingInvite = nil
    }

    /// Opens a saved 2v2 game: finished ones for review, unfinished ones to resume with the others.
    func openSavedTeamGame(_ snapshot: TeamSnapshot) {
        guard teamTable == nil, let restored = TeamMatch(snapshot: snapshot, localPlayerID: playerID) else {
            showBanner("This saved game couldn't be opened.")
            return
        }
        if isWaitingForChallengeAnswer { cancelChallenge() }
        leaveSoloGame()
        let finished = restored.isOver && restored.hasFullReveal
        openTeamTable(TeamTable(match: restored, app: self, service: finished ? nil : peerService))
    }

    func deleteSavedTeamGame(_ gameID: UUID) {
        teamStore.delete(gameID)
        savedTeamGames.removeAll { $0.gameID == gameID }
    }

    func saveTeamGame(_ snapshot: TeamSnapshot) {
        teamStore.save(snapshot)
        if let index = savedTeamGames.firstIndex(where: { $0.gameID == snapshot.gameID }) {
            savedTeamGames[index] = snapshot
        } else {
            savedTeamGames.insert(snapshot, at: 0)
        }
    }

    func leaveTeamTable() {
        teamTable?.leave()
        closeTeamTable()
    }

    /// Back to the lobby (the table has already shut its links).
    func closeTeamTable(banner: String? = nil) {
        teamTable = nil
        if screen == .teamGame { screen = .lobby }
        if let banner = banner { showBanner(banner) }
    }

    func openTeamTable(_ table: TeamTable) {
        teamTable = table
        prepareSetupDraft(side: table.localSeat.side, locked: table.match.localSetup)
        screen = .teamGame
    }

    #if DEBUG
    /// Debug builds: shows a demo table for UI snapshots.
    func showTeamDemo(_ table: TeamTable?, draft: Setup? = nil) {
        teamTable = table
        screen = table == nil ? .lobby : .teamGame
        if let draft = draft { setupDraft = draft }
    }
    #endif
}
