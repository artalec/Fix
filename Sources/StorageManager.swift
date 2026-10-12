import Foundation

/// Сохранение состояния приложения и экспорт/импорт плейлистов.
struct StorageManager {

    static let shared = StorageManager()

    private let fileManager = FileManager.default

    private var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("DJPlayer", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var stateURL: URL {
        directory.appendingPathComponent("appstate.json")
    }

    // Путь можно вывести в консоль для отладки.
    var statePath: String { stateURL.path }

    // MARK: - Состояние приложения

    func save(_ state: AppState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("DJPlayer: не удалось сохранить состояние — \(error.localizedDescription)")
        }
    }

    func load() -> AppState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return AppState.fresh()
        }
        do {
            let data = try Data(contentsOf: stateURL)
            var state = try JSONDecoder().decode(AppState.self, from: data)
            if state.playlists.isEmpty {
                state = AppState.fresh()
            }
            return state
        } catch {
            NSLog("DJPlayer: не удалось прочитать состояние — \(error.localizedDescription)")
            return AppState.fresh()
        }
    }

    // MARK: - Экспорт / импорт плейлистов

    func export(_ playlist: Playlist, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(playlist)
        try data.write(to: url, options: .atomic)
    }

    func `import`(from url: URL) throws -> Playlist {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Playlist.self, from: data)
    }

    func resetAll() {
        try? fileManager.removeItem(at: stateURL)
    }
}
