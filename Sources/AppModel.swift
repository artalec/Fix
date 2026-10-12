import Foundation
import SwiftUI
import Combine
import AppKit

/// Единая модель приложения: состояние (плейлисты, настройки), аудиодвижок и выделение.
final class AppModel: ObservableObject {

    static let shared = AppModel()

    @Published var state: AppState
    @Published var selectedPlaylistID: UUID?

    let audioEngine = AudioEngine()
    let selection = SelectionManager()

    private let storage = StorageManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var autosaveWorkItem: DispatchWorkItem?
    
    /// Подавляет автопереход, когда трек остановлен пользователем вручную.
    private init() {
        let loaded = storage.load()
        self.state = loaded
        self.selectedPlaylistID = loaded.selectedPlaylistID ?? loaded.playlists.first?.id

        audioEngine.settings = loaded.settings

        audioEngine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        selection.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        $state
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAutosave() }
            .store(in: &cancellables)

        $selectedPlaylistID
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAutosave() }
            .store(in: &cancellables)

        audioEngine.applyVolume()

        audioEngine.onTrackFinished = { [weak self] in
            self?.handleTrackFinished()
        }
    }

    // MARK: - Текущий плейлист

    var playlistsSorted: [Playlist] {
        state.playlists.sorted { $0.order < $1.order }
    }

    var selectedPlaylist: Playlist? {
        guard let id = selectedPlaylistID else { return nil }
        return state.playlists.first { $0.id == id }
    }

    var selectedPlaylistIndex: Int? {
        guard let id = selectedPlaylistID else { return nil }
        return state.playlists.firstIndex { $0.id == id }
    }

    func findTrack(_ id: UUID) -> Track? {
        for playlist in state.playlists {
            if let track = playlist.tracks.first(where: { $0.id == id }) { return track }
        }
        return nil
    }

    private func playlistContaining(trackID: UUID) -> Int? {
        state.playlists.firstIndex { $0.tracks.contains { $0.id == trackID } }
    }

    // MARK: - Трек, отображаемый на waveform

    /// Играющий трек; если ничего не играет — первый выделенный.
    var displayedTrack: Track? {
        if let id = audioEngine.currentTrack?.id, let playing = findTrack(id) {
            return playing
        }
        guard let playlist = selectedPlaylist else { return nil }
        return selection.selectedTracks(from: playlist.tracks).first
    }

    // MARK: - Плейлисты

    func addPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Плейлист \(state.playlists.count + 1)" : trimmed
        let nextOrder = (state.playlists.map(\.order).max() ?? -1) + 1
        let color = RGBAColor.palette[state.playlists.count % RGBAColor.palette.count]
        let playlist = Playlist(name: title, color: color, order: nextOrder)
        state.playlists.append(playlist)
        selectedPlaylistID = playlist.id
        selection.clear()
        save()
    }

    func renamePlaylist(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        state.playlists[index].name = trimmed
        save()
    }

    func setColor(_ color: RGBAColor, for id: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        state.playlists[index].color = color
        save()
    }

    func deletePlaylist(id: UUID) {
        audioEngine.stop()
        state.playlists.removeAll { $0.id == id }
        if state.playlists.isEmpty {
            state.playlists = [Playlist(name: "Плейлист 1", order: 0)]
        }
        reindexPlaylists()
        if selectedPlaylistID == id {
            selectedPlaylistID = playlistsSorted.first?.id
        }
        selection.clear()
        save()
    }

    func movePlaylists(from source: IndexSet, to destination: Int) {
        var sorted = playlistsSorted
        sorted.move(fromOffsets: source, toOffset: destination)
        for (index, playlist) in sorted.enumerated() {
            if let i = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
                state.playlists[i].order = index
            }
        }
        save()
    }

    private func reindexPlaylists() {
        let sorted = playlistsSorted
        for (index, playlist) in sorted.enumerated() {
            if let i = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
                state.playlists[i].order = index
            }
        }
    }

    // MARK: - Настройки плейлиста

    func setLoopPlaylist(_ enabled: Bool) {
        guard let index = selectedPlaylistIndex else { return }
        state.playlists[index].loopEnabled = enabled
        save()
    }

    func setAutoplay(_ enabled: Bool) {
        guard let index = selectedPlaylistIndex else { return }
        state.playlists[index].autoplayEnabled = enabled
        save()
    }

    // MARK: - Треки

    func addTracks(urls: [URL]) {
        guard let playlistID = selectedPlaylistID,
              let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }

        let existingPaths = Set(state.playlists[index].tracks.map(\.path))
        var added: [Track] = []

        for url in urls {
            let standardized = url.standardizedFileURL
            guard !existingPaths.contains(standardized.path) else { continue }
            added.append(Track(url: standardized))
        }

        guard !added.isEmpty else { return }
        state.playlists[index].tracks.append(contentsOf: added)
        save()

        Task { @MainActor [weak self] in
            for track in added {
                let result = await WaveformGenerator.load(for: track)
                self?.updateDuration(for: track.id, duration: result.duration)
            }
        }
    }

    private func updateDuration(for trackID: UUID, duration: TimeInterval) {
        guard duration > 0 else { return }
        for pIndex in state.playlists.indices {
            if let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) {
                state.playlists[pIndex].tracks[tIndex].duration = duration
                scheduleAutosave()
                return
            }
        }
    }

    func removeTracks(at offsets: IndexSet) {
        guard let index = selectedPlaylistIndex else { return }
        let removing = offsets.map { state.playlists[index].tracks[$0] }
        removeTracks(ids: removing.map(\.id))
    }

    func removeTrack(id: UUID) {
        removeTracks(ids: [id])
    }

    func removeSelectedTracks() {
        removeTracks(ids: Array(selection.selectedIDs))
    }

    func removeTracks(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        
        if let current = audioEngine.currentTrack, idSet.contains(current.id) {
            audioEngine.stop()
        }
        
        for pIndex in state.playlists.indices {
            state.playlists[pIndex].tracks.removeAll { idSet.contains($0.id) }
        }
        
        selection.clear()
        save()
    }

    func moveTracks(from source: IndexSet, to destination: Int) {
        guard let index = selectedPlaylistIndex else { return }
        state.playlists[index].tracks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Перемещение выделенных треков на позицию (для drag-n-drop).
    func moveTracks(ids: [UUID], to destinationIndex: Int) {
        guard let index = selectedPlaylistIndex, !ids.isEmpty else { return }
        let moving = Set(ids)
        var tracks = state.playlists[index].tracks
        
        let movingTracks = tracks.filter { moving.contains($0.id) }
        guard !movingTracks.isEmpty else { return }
        
        tracks.removeAll { moving.contains($0.id) }
        
        // Пересчитываем индекс вставки после удаления
        let removedBefore = state.playlists[index].tracks
            .prefix(max(0, min(destinationIndex, state.playlists[index].tracks.count)))
            .filter { moving.contains($0.id) }
            .count
        let insertAt = max(0, min(destinationIndex - removedBefore, tracks.count))
        
        tracks.insert(contentsOf: movingTracks, at: insertAt)
        state.playlists[index].tracks = tracks
        save()
    }

    // MARK: - Атрибуты треков

    func setTrackColor(_ color: RGBAColor?, for trackID: UUID) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        state.playlists[pIndex].tracks[tIndex].color = color
        syncEngineTrack(trackID)
        save()
    }

    func setColorForSelected(_ color: RGBAColor?) {
        for id in selection.selectedIDs {
            guard let pIndex = playlistContaining(trackID: id),
                  let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }) else { continue }
            state.playlists[pIndex].tracks[tIndex].color = color
        }
        save()
    }

    func toggleDeleteAfterPlay(for trackID: UUID) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        state.playlists[pIndex].tracks[tIndex].deleteAfterPlay.toggle()
        syncEngineTrack(trackID)
        save()
    }

    func toggleDeleteAfterPlayForSelected() {
        let ids = selection.selectedIDs
        guard !ids.isEmpty else { return }
        // Если хотя бы у одного выключено — включаем у всех, иначе выключаем.
        let anyOff = ids.contains { id in
            findTrack(id)?.deleteAfterPlay == false
        }
        for id in ids {
            guard let pIndex = playlistContaining(trackID: id),
                  let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }) else { continue }
            state.playlists[pIndex].tracks[tIndex].deleteAfterPlay = anyOff
        }
        save()
    }

    // MARK: - Audio Trim

    /// Устанавливает точки обрезки. Значения в секундах от начала файла.
    func setTrim(for trackID: UUID, start: TimeInterval?, end: TimeInterval?) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        var track = state.playlists[pIndex].tracks[tIndex]
        let total = track.duration
        
        if let start {
            track.trimStart = max(0, min(start, total > 0 ? total - 0.1 : start))
        }
        if let end {
            let clamped = max(0, min(end, total > 0 ? total : end))
            // Если точка совпадает с концом файла — храним nil (значит "до конца")
            if total > 0 && abs(clamped - total) < 0.05 {
                track.trimEnd = nil
            } else {
                track.trimEnd = clamped
            }
        }
        
        // Не даём точкам пересечься
        if let end = track.trimEnd, track.trimStart >= end {
            track.trimStart = max(0, end - 0.1)
        }
        
        state.playlists[pIndex].tracks[tIndex] = track
        syncEngineTrack(trackID)
        scheduleAutosave()
    }

    func resetTrim(for trackID: UUID) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        state.playlists[pIndex].tracks[tIndex].trimStart = 0
        state.playlists[pIndex].tracks[tIndex].trimEnd = nil
        syncEngineTrack(trackID)
        save()
    }

    private func syncEngineTrack(_ trackID: UUID) {
        guard audioEngine.currentTrack?.id == trackID, let track = findTrack(trackID) else { return }
        audioEngine.syncCurrentTrack(track)
    }

    // MARK: - Воспроизведение

    func play(track: Track) {
        audioEngine.play(track: track)
    }

    func playFirstTrackOfSelectedPlaylist() {
        guard let playlist = selectedPlaylist, let first = playlist.tracks.first else { return }
        play(track: first)
    }

    func togglePlayPause() {
        if audioEngine.isPlaying {
            audioEngine.pause()
        } else if audioEngine.currentTrack != nil {
            audioEngine.resume()
        } else {
            playFirstTrackOfSelectedPlaylist()
        }
    }

    /// Переход к следующему треку плейлиста (по кругу, если включено зацикливание).
    func playNext() {
        guard let playlist = selectedPlaylist, !playlist.tracks.isEmpty else { return }
        guard let currentID = audioEngine.currentTrack?.id,
              let currentIndex = playlist.tracks.firstIndex(where: { $0.id == currentID }) else {
            playFirstTrackOfSelectedPlaylist()
            return
        }
        let nextIndex = currentIndex + 1
        if nextIndex < playlist.tracks.count {
            play(track: playlist.tracks[nextIndex])
        } else if playlist.loopEnabled {
            play(track: playlist.tracks[0])
        } else {
            audioEngine.stop()
        }
    }

    /// Переход к предыдущему треку.
    func playPrevious() {
        guard let playlist = selectedPlaylist, !playlist.tracks.isEmpty else { return }
        guard let currentID = audioEngine.currentTrack?.id,
              let currentIndex = playlist.tracks.firstIndex(where: { $0.id == currentID }) else {
            playFirstTrackOfSelectedPlaylist()
            return
        }
        let previousIndex = currentIndex - 1
        if previousIndex >= 0 {
            play(track: playlist.tracks[previousIndex])
        } else if playlist.loopEnabled {
            play(track: playlist.tracks[playlist.tracks.count - 1])
        } else {
            // На первом треке — начинаем его заново
            audioEngine.seek(to: 0)
        }
    }

    // MARK: - Завершение трека

    private func handleTrackFinished() {
        guard let finished = audioEngine.currentTrack else { return }
        let finishedID = finished.id
        
        // 1. Зацикливание трека — играем его же сначала.
        if state.settings.loopTrackEnabled {
            let resumed: Track
            if let pIndex = playlistContaining(trackID: finishedID),
               let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == finishedID }) {
                resumed = state.playlists[pIndex].tracks[tIndex]
            } else {
                resumed = finished
            }
            audioEngine.play(track: resumed)
            return
        }
        
        guard let playlist = selectedPlaylist,
              let index = playlist.tracks.firstIndex(where: { $0.id == finishedID }) else {
            audioEngine.stop()
            return
        }
        
        // 2. Удаление после полного проигрывания.
        if playlist.tracks[index].deleteAfterPlay {
            removeTracks(ids: [finishedID])
            // После удаления список сдвинулся: играем трек, который встал на это место
            if let nextPlaylist = selectedPlaylist, index < nextPlaylist.tracks.count {
                play(track: nextPlaylist.tracks[index])
            } else if let nextPlaylist = selectedPlaylist, nextPlaylist.loopEnabled,
                      let first = nextPlaylist.tracks.first {
                play(track: first)
            } else {
                audioEngine.stop()
            }
            return
        }
        
        // 3. Автопереход на следующий трек.
        guard playlist.autoplayEnabled else {
            audioEngine.stop()
            return
        }
        
        let nextIndex = index + 1
        if nextIndex < playlist.tracks.count {
            play(track: playlist.tracks[nextIndex])
        } else if playlist.loopEnabled, let first = playlist.tracks.first {
            play(track: first)
        } else {
            audioEngine.stop()
        }
    }

    // MARK: - Настройки

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        transform(&state.settings)
        audioEngine.settings = state.settings
        audioEngine.applyVolume()
        scheduleAutosave()
    }

    func setVolume(_ value: Double) {
        updateSettings { $0.volume = max(0, min(value, 1)) }
    }

    // MARK: - Сохранение

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        autosaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    func save() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        state.selectedPlaylistID = selectedPlaylistID
        storage.save(state)
    }

    // MARK: - Экспорт / импорт

    func exportSelectedPlaylist(to url: URL) {
        guard let playlist = selectedPlaylist else { return }
        do { try storage.export(playlist, to: url) }
        catch { NSLog("DJPlayer: экспорт не удался — \(error.localizedDescription)") }
    }

    func importPlaylist(from url: URL) {
        do {
            var playlist = try storage.`import`(from: url)
            playlist.order = (state.playlists.map(\.order).max() ?? -1) + 1
            state.playlists.append(playlist)
            selectedPlaylistID = playlist.id
            save()
        } catch {
            NSLog("DJPlayer: импорт не удался — \(error.localizedDescription)")
        }
    }
}
