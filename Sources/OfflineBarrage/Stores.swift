import BarrageCore
import Foundation

/// Where this copy of the app keeps its data.
///
/// Setting `OFFLINE_BARRAGE_PROFILE=<name>` gives a separate identity, settings and saved games,
/// so two copies can run side by side on one Mac for testing.
enum AppEnvironment {
    static let profile: String? = {
        let value = ProcessInfo.processInfo.environment["OFFLINE_BARRAGE_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = value, !value.isEmpty else { return nil }
        return String(value.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(20))
    }()

    static let defaults: UserDefaults = {
        guard let profile = profile, let suite = UserDefaults(suiteName: "local.offlinebarrage.profile.\(profile)") else {
            return .standard
        }
        return suite
    }()

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var directory = base.appendingPathComponent("OfflineBarrage", isDirectory: true)
        if let profile = profile {
            directory = directory.appendingPathComponent("Profiles/\(profile)", isDirectory: true)
        }
        return directory
    }()
}

/// Saves each game as JSON in ~/Library/Application Support/OfflineBarrage/Games.
///
/// A saved game holds our own full setup but only the opponent's commitments and revealed
/// ranks, so peeking at the file during a game doesn't give anything away.
final class GameStore {
    let directory: URL

    init() {
        directory = AppEnvironment.supportDirectory.appendingPathComponent("Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadAll() -> [MatchSnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in try? Wire.decode(MatchSnapshot.self, from: Data(contentsOf: url)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ snapshot: MatchSnapshot) {
        do {
            let data = try Wire.encode(snapshot)
            try data.write(to: url(for: snapshot.gameID), options: .atomic)
        } catch {
            NSLog("Offline Barrage: could not save game: \(error.localizedDescription)")
        }
    }

    func delete(_ gameID: UUID) {
        try? FileManager.default.removeItem(at: url(for: gameID))
    }

    private func url(for gameID: UUID) -> URL {
        directory.appendingPathComponent("\(gameID.uuidString).json")
    }
}

/// The player's library of named setups, in ~/Library/Application Support/OfflineBarrage/Setups.json.
final class SetupStore {
    private let file: URL

    init() {
        try? FileManager.default.createDirectory(at: AppEnvironment.supportDirectory, withIntermediateDirectories: true)
        file = AppEnvironment.supportDirectory.appendingPathComponent("Setups.json")
    }

    func load() -> [SavedSetup] {
        guard let data = try? Data(contentsOf: file),
              let setups = try? JSONDecoder().decode([SavedSetup].self, from: data)
        else { return [] }
        return setups
    }

    func save(_ setups: [SavedSetup]) {
        do {
            try JSONEncoder().encode(setups).write(to: file, options: .atomic)
        } catch {
            NSLog("Offline Barrage: could not save setups: \(error.localizedDescription)")
        }
    }
}

/// Saves each 2v2 game as JSON in ~/Library/Application Support/OfflineBarrage/TeamGames.
///
/// A saved 2v2 game holds our own ranks (every commitment epoch) and our partner's ranks, but
/// only commitments and revealed ranks of the opponents.
final class TeamGameStore {
    let directory: URL

    init() {
        directory = AppEnvironment.supportDirectory.appendingPathComponent("TeamGames", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadAll() -> [TeamSnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in try? Wire.decode(TeamSnapshot.self, from: Data(contentsOf: url)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ snapshot: TeamSnapshot) {
        do {
            let data = try Wire.encode(snapshot)
            try data.write(to: url(for: snapshot.gameID), options: .atomic)
        } catch {
            NSLog("Offline Barrage: could not save 2v2 game: \(error.localizedDescription)")
        }
    }

    func delete(_ gameID: UUID) {
        try? FileManager.default.removeItem(at: url(for: gameID))
    }

    private func url(for gameID: UUID) -> URL {
        directory.appendingPathComponent("\(gameID.uuidString).json")
    }
}
