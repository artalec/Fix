import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Левая колонка: список плейлистов с изменением порядка перетаскиванием.
struct PlaylistSidebar: View {

    @EnvironmentObject private var model: AppModel

    @State private var isAdding = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @State private var coloring: Playlist?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $isAdding) { addSheet }
        .sheet(item: $renaming) { playlist in renameSheet(playlist) }
        .sheet(item: $coloring) { playlist in colorSheet(playlist) }
    }

    // MARK: - Секции

    private var header: some View {
        HStack {
            Text("Плейлисты")
                .font(.headline)
            Spacer()
            Button {
                newName = ""
                isAdding = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Создать плейлист")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var list: some View {
        List {
            ForEach(model.playlistsSorted) { playlist in
                PlaylistRow(
                    playlist: playlist,
                    isSelected: playlist.id == model.selectedPlaylistID,
                    isPlayingHere: model.audioEngine.currentTrack.map { track in
                        playlist.tracks.contains { $0.id == track.id }
                    } ?? false,
                    onRename: {
                        renameText = playlist.name
                        renaming = playlist
                    },
                    onRecolor: { coloring = playlist },
                    onDelete: { model.deletePlaylist(id: playlist.id) }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedPlaylistID = playlist.id
                    model.selection.clear()
                }
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            }
            // Перетаскивание для изменения порядка плейлистов
            .onMove { source, destination in
                model.movePlaylists(from: source, to: destination)
            }
        }
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                importPlaylist()
            } label: {
                Label("Загрузить", systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Button {
                exportPlaylist()
            } label: {
                Label("Сохранить", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedPlaylist == nil)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Модальные окна

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новый плейлист").font(.headline)
            TextField("Название", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Отмена") { isAdding = false }
                    .keyboardShortcut(.cancelAction)
                Button("Создать") {
                    model.addPlaylist(named: newName)
                    isAdding = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func renameSheet(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Переименовать плейлист").font(.headline)
            TextField("Название", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Отмена") { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    model.renamePlaylist(id: playlist.id, to: renameText)
                    renaming = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func colorSheet(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Цвет плейлиста").font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 10), count: 5), spacing: 10) {
                ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { item in
                    Circle()
                        .fill(item.element.swiftUIColor)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().stroke(
                                Color.primary.opacity(item.element == playlist.color ? 0.9 : 0.12),
                                lineWidth: item.element == playlist.color ? 2 : 1
                            )
                        )
                        .onTapGesture {
                            model.setColor(item.element, for: playlist.id)
                            coloring = nil
                        }
                }
            }

            HStack {
                Spacer()
                Button("Закрыть") { coloring = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Диалоги файлов

    private func exportPlaylist() {
        guard let playlist = model.selectedPlaylist else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(playlist.name).djplaylist.json"
        panel.allowedContentTypes = [.json]
        panel.title = "Сохранить плейлист"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportSelectedPlaylist(to: url)
        }
    }

    private func importPlaylist() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.title = "Загрузить плейлист"
        if panel.runModal() == .OK, let url = panel.url {
            model.importPlaylist(from: url)
        }
    }
}

// MARK: - Строка плейлиста

private struct PlaylistRow: View {

    let playlist: Playlist
    let isSelected: Bool
    let isPlayingHere: Bool
    let onRename: () -> Void
    let onRecolor: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(playlist.color.swiftUIColor)
                .frame(width: 4, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    if isPlayingHere {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(playlist.color.swiftUIColor)
                    }
                }

                HStack(spacing: 4) {
                    Text("\(playlist.tracks.count) трек(ов)")
                    if playlist.loopEnabled {
                        Image(systemName: "repeat").font(.system(size: 8))
                    }
                    if playlist.autoplayEnabled {
                        Image(systemName: "arrow.forward.to.line").font(.system(size: 8))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if isHovering {
                Menu {
                    Button("Переименовать", action: onRename)
                    Button("Изменить цвет", action: onRecolor)
                    Divider()
                    Button("Удалить", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? playlist.color.swiftUIColor.opacity(0.22) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}
