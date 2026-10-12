import SwiftUI
import AppKit

/// Главное окно.
///
/// Раскладка:
///   слева  — список плейлистов
///   справа — waveform с маркерами обрезки, панель управления, список треков
struct ContentView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            PlaylistSidebar()
                .frame(minWidth: 210, idealWidth: 250, maxWidth: 340)

            VStack(spacing: 0) {
                WaveformPanel()
                Divider()
                TrackList()
            }
            .frame(minWidth: 620)
        }
        .frame(minWidth: 880, minHeight: 640)
    }
}

// MARK: - Верхняя часть: информация, waveform, управление

private struct WaveformPanel: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                trackInfo
                Spacer(minLength: 12)
                effectControls
            }

            WaveformView(
                peaks: model.audioEngine.waveform,
                currentTime: progressTime,
                duration: displayedDuration,
                accent: displayedAccent,
                trimStart: displayedTrimStart,
                trimEnd: displayedTrimEnd,
                onSeek: { time in
                    model.audioEngine.seek(to: time)
                },
                onTrimChange: { start, end in
                    guard let track = model.displayedTrack else { return }
                    model.setTrim(for: track.id, start: start, end: end)
                }
            )
            .frame(height: 96)

            transportBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Данные для waveform

    private var displayedTrack: Track? { model.displayedTrack }

    private var displayedDuration: TimeInterval {
        displayedTrack?.duration ?? 0
    }

    private var displayedTrimStart: TimeInterval {
        displayedTrack?.trimStart ?? 0
    }

    private var displayedTrimEnd: TimeInterval {
        guard let track = displayedTrack else { return 0 }
        return track.trimEnd ?? track.duration
    }

    private var displayedAccent: RGBAColor {
        displayedTrack?.color ?? model.selectedPlaylist?.color ?? RGBAColor(red: 0.2, green: 0.55, blue: 1.0)
    }

    /// Время для курсора: если играет этот трек — реальное, иначе 0.
    private var progressTime: TimeInterval {
        guard model.audioEngine.currentTrack?.id == displayedTrack?.id else { return 0 }
        return model.audioEngine.currentTime
    }

    // MARK: Информация о треке

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let track = displayedTrack {
                Text(track.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(model.audioEngine.currentTrack?.id == track.id
                         ? model.audioEngine.currentTime.timecode
                         : track.trimStart.timecode)
                    Text("/")
                    Text(track.effectiveDuration.timecode)

                    if model.audioEngine.isTransitioning {
                        Text("· переход…").foregroundStyle(Color.orange)
                    }
                    if track.trimStart > 0 || track.trimEnd != nil {
                        Text("· Start \(track.trimStart.timecode)  End \((track.trimEnd ?? track.duration).timecode)")
                            .foregroundStyle(Color.cyan)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            } else {
                Text("Ничего не выбрано")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Выберите трек в списке")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
    }

    // MARK: Эффекты

    private var effectControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Crossfade", isOn: Binding(
                    get: { model.state.settings.crossfadeEnabled },
                    set: { value in model.updateSettings { $0.crossfadeEnabled = value } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Плавный переход между треками")

                sliderRow(label: "переход",
                          value: model.state.settings.crossfadeDuration,
                          range: 0.5...15,
                          enabled: model.state.settings.crossfadeEnabled) { v in
                    model.updateSettings { $0.crossfadeDuration = v }
                }
            }

            Divider().frame(height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Toggle("High-cut", isOn: Binding(
                    get: { model.state.settings.highCutEnabled },
                    set: { value in model.updateSettings { $0.highCutEnabled = value } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Плавно уводит верхи у играющего трека, затем запускает следующий")

                sliderRow(label: "эффект",
                          value: model.state.settings.highCutDuration,
                          range: 0.3...10,
                          enabled: model.state.settings.highCutEnabled) { v in
                    model.updateSettings { $0.highCutDuration = v }
                }

                sliderRow(label: "пауза",
                          value: model.state.settings.highCutPauseAfter,
                          range: 0...10,
                          enabled: model.state.settings.highCutEnabled) { v in
                    model.updateSettings { $0.highCutPauseAfter = v }
                }
            }
        }
    }

    private func sliderRow(label: String,
                           value: Double,
                           range: ClosedRange<Double>,
                           enabled: Bool,
                           onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
                .frame(width: 80)
                .controlSize(.mini)
                .disabled(!enabled)

            Text(String(format: "%.1f", value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .frame(width: 28, alignment: .leading)
        }
    }

    // MARK: Панель управления и громкость

    private var transportBar: some View {
        HStack(spacing: 14) {
            // Предыдущий / Играть-пауза / Следующий / Стоп
            HStack(spacing: 8) {
                Button {
                    model.playPrevious()
                } label: {
                    Image(systemName: "backward.fill")
                        .frame(width: 22)
                }
                .help("Предыдущий трек")

                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.audioEngine.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 26)
                }
                .help(model.audioEngine.isPlaying ? "Пауза (Пробел)" : "Играть (Пробел)")

                Button {
                    model.playNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 22)
                }
                .help("Следующий трек")

                Button {
                    model.audioEngine.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 22)
                }
                .help("Стоп (Esc)")
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 22)

            // Зацикливание трека и плейлиста
            Toggle(isOn: Binding(
                get: { model.state.settings.loopTrackEnabled },
                set: { value in model.updateSettings { $0.loopTrackEnabled = value } }
            )) {
                Image(systemName: "repeat.1")
            }
            .toggleStyle(.button)
            .help("Зациклить текущий трек")

            Toggle(isOn: Binding(
                get: { model.selectedPlaylist?.loopEnabled ?? false },
                set: { model.setLoopPlaylist($0) }
            )) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Зациклить плейлист")

            Toggle(isOn: Binding(
                get: { model.selectedPlaylist?.autoplayEnabled ?? false },
                set: { model.setAutoplay($0) }
            )) {
                Image(systemName: "arrow.forward.to.line")
            }
            .toggleStyle(.button)
            .help("Автоматически переходить к следующему треку")

            Divider().frame(height: 22)

            // Громкость
            HStack(spacing: 6) {
                Image(systemName: volumeIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Slider(value: Binding(
                    get: { model.state.settings.volume },
                    set: { model.setVolume($0) }
                ), in: 0...1)
                .frame(width: 110)
                .controlSize(.small)

                Text("\(Int(model.state.settings.volume * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }

            Spacer()
        }
    }

    private var volumeIcon: String {
        let v = model.state.settings.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.4 { return "speaker.fill" }
        if v < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
