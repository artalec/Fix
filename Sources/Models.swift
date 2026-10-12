import Foundation

// MARK: - Track

struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var duration: TimeInterval
    
    // Новые поля для расширенного функционала
    var color: RGBAColor?              // Цвет выделения трека (nil = цвет плейлиста)
    var trimStart: TimeInterval        // Точка начала воспроизведения (Audio Trim)
    var trimEnd: TimeInterval?         // Точка окончания (nil = до конца файла)
    var deleteAfterPlay: Bool          // Удалить трек после полного проигрывания
    
    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    
    // Эффективная длительность с учётом trim
    var effectiveDuration: TimeInterval {
        let end = trimEnd ?? duration
        return max(0, end - trimStart)
    }
    
    /// Декодер с значениями по умолчанию: файл состояния, сохранённый
    /// предыдущей версией приложения, не содержит новых полей.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color)
        trimStart = try c.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(TimeInterval.self, forKey: .trimEnd)
        deleteAfterPlay = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterPlay) ?? false
    }

    init(id: UUID = UUID(),
         name: String,
         path: String,
         duration: TimeInterval = 0,
         color: RGBAColor? = nil,
         trimStart: TimeInterval = 0,
         trimEnd: TimeInterval? = nil,
         deleteAfterPlay: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.duration = duration
        self.color = color
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.deleteAfterPlay = deleteAfterPlay
    }

    init(url: URL, duration: TimeInterval = 0) {
        self.id = UUID()
        self.name = url.deletingPathExtension().lastPathComponent
        self.path = url.path
        self.duration = duration
        self.color = nil
        self.trimStart = 0
        self.trimEnd = nil
        self.deleteAfterPlay = false
    }
}

// MARK: - Playlist

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var tracks: [Track]
    var color: RGBAColor
    var order: Int
    
    // Новые поля для расширенного функционала
    var loopEnabled: Bool              // Зацикливание плейлиста
    var autoplayEnabled: Bool          // Автопереход на следующий трек

    init(id: UUID = UUID(),
         name: String,
         tracks: [Track] = [],
         color: RGBAColor = RGBAColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1.0),
         order: Int = 0,
         loopEnabled: Bool = false,
         autoplayEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.color = color
        self.order = order
        self.loopEnabled = loopEnabled
        self.autoplayEnabled = autoplayEnabled
    }
}

// MARK: - Codable color

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    static let palette: [RGBAColor] = [
        RGBAColor(red: 0.20, green: 0.55, blue: 1.00),
        RGBAColor(red: 1.00, green: 0.27, blue: 0.35),
        RGBAColor(red: 0.15, green: 0.80, blue: 0.45),
        RGBAColor(red: 1.00, green: 0.65, blue: 0.10),
        RGBAColor(red: 0.65, green: 0.35, blue: 0.95),
        RGBAColor(red: 0.10, green: 0.75, blue: 0.85),
        RGBAColor(red: 0.95, green: 0.45, blue: 0.75),
        RGBAColor(red: 0.40, green: 0.40, blue: 0.40),
        RGBAColor(red: 0.95, green: 0.95, blue: 0.20),
        RGBAColor(red: 0.85, green: 0.45, blue: 0.25)
    ]
}

// MARK: - Settings

struct AppSettings: Codable {
    var crossfadeEnabled: Bool = false
    var crossfadeDuration: Double = 3.0
    var highCutEnabled: Bool = false
    var highCutDuration: Double = 2.0
    var highCutPauseAfter: Double = 0.0    // Пауза после high-cut перед запуском следующего
    var volume: Double = 1.0               // Громкость 0...1
    var loopTrackEnabled: Bool = false     // Зацикливание текущего трека

    init() {}

    init(crossfadeEnabled: Bool,
         crossfadeDuration: Double,
         highCutEnabled: Bool,
         highCutDuration: Double,
         highCutPauseAfter: Double = 0.0,
         volume: Double = 1.0) {
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeDuration = crossfadeDuration
        self.highCutEnabled = highCutEnabled
        self.highCutDuration = highCutDuration
        self.highCutPauseAfter = highCutPauseAfter
        self.volume = volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
        crossfadeDuration = try c.decodeIfPresent(Double.self, forKey: .crossfadeDuration) ?? 3.0
        highCutEnabled = try c.decodeIfPresent(Bool.self, forKey: .highCutEnabled) ?? false
        highCutDuration = try c.decodeIfPresent(Double.self, forKey: .highCutDuration) ?? 2.0
        highCutPauseAfter = try c.decodeIfPresent(Double.self, forKey: .highCutPauseAfter) ?? 0.0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
    }
}

// MARK: - Persisted application state

struct AppState: Codable {
    var playlists: [Playlist]
    var settings: AppSettings
    var selectedPlaylistID: UUID?

    init(playlists: [Playlist], settings: AppSettings, selectedPlaylistID: UUID?) {
        self.playlists = playlists
        self.settings = settings
        self.selectedPlaylistID = selectedPlaylistID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlists = try c.decodeIfPresent([Playlist].self, forKey: .playlists) ?? [Playlist(name: "Плейлист 1", order: 0)]
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        selectedPlaylistID = try c.decodeIfPresent(UUID.self, forKey: .selectedPlaylistID)
    }

    static func fresh() -> AppState {
        let first = Playlist(name: "Плейлист 1", order: 0)
        return AppState(playlists: [first], settings: AppSettings(), selectedPlaylistID: first.id)
    }
}
