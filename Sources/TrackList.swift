import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Список треков плейлиста: выделение, drag-n-drop файлов, перетаскивание порядка.
struct TrackList: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if let playlist = model.selectedPlaylist {
                if playlist.tracks.isEmpty {
                    emptyState
                } else {
                    trackListView(playlist)
                }
            } else {
                VStack {
                    Text("Плейлист не выбран")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Приём аудиофайлов, перетащенных из Finder
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
    }

    // MARK: - Панель над списком

    private var topBar: some View {
        HStack(spacing: 10) {
            if let playlist = model.selectedPlaylist {
                RoundedRectangle(cornerRadius: 3)
                    .fill(playlist.color.swiftUIColor)
                    .frame(width: 10, height: 10)
                Text(playlist.name).font(.headline)
            }

            Spacer()

            if model.selection.count > 0 {
                Text("\(model.selection.count) выделено")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    model.removeSelectedTracks()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Удалить выделенные")
            }

            Text("клик · ⌘+клик · ⇧+клик для диапазона")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button {
                model.playFirstTrackOfSelectedPlaylist()
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Запустить первый трек")
            .disabled(model.selectedPlaylist?.tracks.isEmpty ?? true)

            Button {
                addTracks()
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            .disabled(model.selectedPlaylist == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Список

    private func trackListView(_ playlist: Playlist) -> some View {
        List {
            ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { item in
                TrackRow(
                    track: item.element,
                    isCurrent: model.audioEngine.currentTrack?.id == item.element.id,
                    isSelected: model.selection.isSelected(item.element.id),
                    playlistColor: playlist.color,
                    onClick: { modifiers in
                        handleTrackClick(item.element.id, modifiers: modifiers, tracks: playlist.tracks)
                    }
                )
                .contextMenu {
                    trackContextMenu(item.element)
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .onDrag {
                    makeDragProvider(for: item.element)
                }
            }
            .onInsert(of: [UTType.utf8PlainText.identifier]) { index, providers in
                handleTrackReorder(at: index, providers: providers)
            }
            .onDelete { offsets in
                model.removeTracks(at: offsets)
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("В плейлисте пока нет треков")
                .foregroundStyle(.secondary)
            Text("Перетащите аудиофайлы сюда или нажмите «Добавить»")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Добавить треки") { addTracks() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Выделение

    private func handleTrackClick(_ id: UUID, modifiers: EventModifiers, tracks: [Track]) {
        let orderedIDs = tracks.map(\.id)

        if modifiers.contains(.command) {
            model.selection.toggle(id)
        } else if modifiers.contains(.shift) {
            model.selection.selectRange(to: id, in: orderedIDs)
        } else {
            model.selection.selectSingle(id)
        }
    }

    // MARK: - Контекстное меню

    @ViewBuilder
    private func trackContextMenu(_ track: Track) -> some View {
        Button("Воспроизвести") {
            model.play(track: track)
        }

        Divider()

        Menu("Изменить цвет") {
            ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { item in
                Button {
                    if model.selection.isSelected(track.id) && model.selection.count > 1 {
                        model.setColorForSelected(item.element)
                    } else {
                        model.setTrackColor(item.element, for: track.id)
                    }
                } label: {
                    HStack {
                        Circle()
                            .fill(item.element.swiftUIColor)
                            .frame(width: 12, height: 12)
                        Text("Цвет \(item.offset + 1)")
                    }
                }
            }
            Divider()
            Button("Сбросить цвет") {
                if model.selection.isSelected(track.id) && model.selection.count > 1 {
                    model.setColorForSelected(nil)
                } else {
                    model.setTrackColor(nil, for: track.id)
                }
            }
        }

        Button(track.deleteAfterPlay ? "Не удалять после проигрывания" : "Удалять после проигрывания") {
            if model.selection.isSelected(track.id) && model.selection.count > 1 {
                model.toggleDeleteAfterPlayForSelected()
            } else {
                model.toggleDeleteAfterPlay(for: track.id)
            }
        }

        Button("Сбросить обрезку") {
            model.resetTrim(for: track.id)
        }

        Divider()

        Button("Удалить трек", role: .destructive) {
            if model.selection.isSelected(track.id) && model.selection.count > 1 {
                model.removeSelectedTracks()
            } else {
                model.removeTrack(id: track.id)
            }
        }
    }

    // MARK: - Drag and drop файлов

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileType = UTType.fileURL.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(fileType) }
        guard !matching.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            for provider in matching {
                if let data = try? await provider.loadItem(forTypeIdentifier: fileType) as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   Self.isAudioFile(url) {
                    urls.append(url)
                }
            }
            let collected = urls
            if !collected.isEmpty {
                await MainActor.run {
                    model.addTracks(urls: collected)
                }
            }
        }
        return true
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "wav", "m4a", "aac", "flac", "aiff", "aif", "ogg", "alac"].contains(ext)
    }

    // MARK: - Перетаскивание порядка треков

    /// Провайдер для перетаскивания: передаём список идентификаторов строкой,
    /// чтобы не зависеть от NSSecureCoding у NSData.
    private func makeDragProvider(for track: Track) -> NSItemProvider {
        let ids: [UUID]
        if model.selection.isSelected(track.id) {
            ids = Array(model.selection.selectedIDs)
        } else {
            ids = [track.id]
        }
        let joined = ids.map(\.uuidString).joined(separator: ",")
        return NSItemProvider(object: joined as NSString)
    }

    private func handleTrackReorder(at index: Int, providers: [NSItemProvider]) {
        let textType = UTType.utf8PlainText.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(textType) }
        guard !matching.isEmpty else { return }

        Task {
            for provider in matching {
                guard let item = try? await provider.loadItem(forTypeIdentifier: textType),
                      let text = item as? String else { continue }

                let ids = text
                    .split(separator: ",")
                    .compactMap { UUID(uuidString: String($0)) }
                guard !ids.isEmpty else { continue }

                await MainActor.run {
                    model.moveTracks(ids: ids, to: index)
                }
            }
        }
    }

    private func addTracks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.title = "Выберите аудиофайлы"
        if panel.runModal() == .OK {
            model.addTracks(urls: panel.urls)
        }
    }
}

// MARK: - Строка трека

private struct TrackRow: View {

    let track: Track
    let isCurrent: Bool
    let isSelected: Bool
    let playlistColor: RGBAColor
    let onClick: (EventModifiers) -> Void

    @State private var isHovering = false

    private var effectiveColor: RGBAColor {
        track.color ?? playlistColor
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(isCurrent ? effectiveColor.swiftUIColor : Color.secondary)
                .frame(width: 16)

            RoundedRectangle(cornerRadius: 2)
                .fill(effectiveColor.swiftUIColor)
                .frame(width: 3, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(track.exists ? Color.secondary : Color.red)

                    if track.deleteAfterPlay {
                        Text("• удалить после проигрывания")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                    }

                    if track.trimStart > 0 || track.trimEnd != nil {
                        Text("• обрезка")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.cyan)
                    }
                }
                .lineLimit(1)
            }

            Spacer()

            Text(track.effectiveDuration.timecode)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onClick(currentModifiers())
        }
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return effectiveColor.swiftUIColor.opacity(0.25)
        }
        return isHovering ? Color.secondary.opacity(0.08) : Color.clear
    }

    private var detail: String {
        track.exists ? track.url.deletingLastPathComponent().lastPathComponent : "файл не найден"
    }

    /// NSEvent.ModifierFlags и SwiftUI EventModifiers — разные типы,
    /// поэтому переносим флаги вручную.
    private func currentModifiers() -> EventModifiers {
        let flags = NSEvent.modifierFlags
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}
