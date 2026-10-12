import Foundation
import AVFoundation
import Combine

/// Аудиодвижок с поддержкой trim, seek, громкости, автоперехода на следующий трек.
///
/// Два независимых канала (A и B) для честного кроссфейда. У каждого канала своя
/// цепочка player → EQ → mainMixer. EQ реализует эффект High-cut (плавное закрытие верхов).
final class AudioEngine: ObservableObject {

    // MARK: - Публикуемое состояние

    @Published private(set) var isPlaying = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var waveform: [Float] = []

    // MARK: - Настройки и колбеки

    var settings = AppSettings()
    
    /// Вызывается при завершении трека (дошёл до trimEnd или до конца файла).
    /// AppModel решает: запустить следующий, зациклить, удалить.
    var onTrackFinished: (() -> Void)?

    // MARK: - Внутренние узлы

    private final class Channel {
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        var file: AVAudioFile?
        var generation = 0
    }

    private let engine = AVAudioEngine()
    private var channels: [Channel] = []
    private var activeIndex = 0
    
    /// Время начала воспроизводимого сегмента относительно файла (учитывает trimStart).
    private var activeFileOffset: TimeInterval = 0

    private var rampTimer: Timer?
    private var timeTimer: Timer?
    private var rampGeneration = 0

    private let lowPassOpenFrequency: Float = 20000
    private let lowPassClosedFrequency: Float = 180
    private let rampStepsPerSecond: Double = 30

    // MARK: - Инициализация

    init() {
        channels = [Channel(), Channel()]

        for channel in channels {
            engine.attach(channel.player)
            engine.attach(channel.eq)

            let band = channel.eq.bands[0]
            band.filterType = .lowPass
            band.frequency = lowPassOpenFrequency
            band.bypass = true
            channel.eq.bypass = false

            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
            engine.connect(channel.player, to: channel.eq, format: format)
            engine.connect(channel.eq, to: engine.mainMixerNode, format: nil)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("DJPlayer: не удалось запустить аудиодвижок — \(error.localizedDescription)")
        }
        applyVolume()
    }

    // MARK: - Основное управление

    func play(track: Track) {
        guard track.exists else {
            NSLog("DJPlayer: файл не найден — \(track.path)")
            return
        }

        if isPlaying && currentTrack != nil {
            if settings.highCutEnabled {
                transitionWithHighCut(to: track)
            } else if settings.crossfadeEnabled {
                transitionWithCrossfade(to: track)
            } else {
                hardSwitch(to: track)
            }
        } else {
            hardSwitch(to: track)
        }
    }

    func stop() {
        cancelRamp()
        for channel in channels {
            channel.generation += 1
            channel.player.stop()
            channel.player.volume = 1.0
            resetLowPass(channel)
            channel.file = nil
        }
        stopTimeTimer()
        isPlaying = false
        isTransitioning = false
        currentTime = 0
        currentTrack = nil
        waveform = []
        activeFileOffset = 0
    }

    func pause() {
        guard isPlaying, !isTransitioning else { return }
        channels[activeIndex].player.pause()
        stopTimeTimer()
        isPlaying = false
    }

    func resume() {
        guard !isPlaying, currentTrack != nil, !isTransitioning else { return }
        let channel = channels[activeIndex]
        guard channel.file != nil else { return }
        channel.player.play()
        isPlaying = true
        startTimeTimer()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if currentTrack != nil {
            resume()
        }
    }

    // MARK: - Seek (перемотка по времени трека, относительно trimStart)

    /// Перематывает трек на указанную позицию (0 = начало trimStart, effectiveDuration = trimEnd).
    /// Работает и во время воспроизведения, и на паузе.
    func seek(to time: TimeInterval) {
        guard let track = currentTrack else { return }
        let wasPlaying = isPlaying
        
        // Останавливаем активный канал
        let channel = channels[activeIndex]
        channel.player.stop()
        stopTimeTimer()
        isPlaying = false
        
        // Перезапускаем с новой позиции
        let position = max(0, min(time, track.effectiveDuration))
        if startSegment(track: track, onChannel: activeIndex, position: position) {
            if wasPlaying {
                isPlaying = true
                startTimeTimer()
            }
        }
    }

    // MARK: - Синхронизация изменённого трека

    /// Обновляет данные играющего трека (цвет, trim-точки, флаги) без перезапуска.
    /// Если изменились trim-точки — пересчитывает позицию, чтобы воспроизведение
    /// продолжалось с того же места в новом сегменте.
    func syncCurrentTrack(_ track: Track) {
        guard let old = currentTrack, old.id == track.id else { return }
        let wasPlaying = isPlaying
        let position = currentTime

        currentTrack = track

        // Границы сегмента изменились — надо перепланировать воспроизведение.
        if old.trimStart != track.trimStart || old.trimEnd != track.trimEnd {
            let clamped = max(0, min(position, track.effectiveDuration))
            if startSegment(track: track, onChannel: activeIndex, position: clamped) {
                if wasPlaying {
                    isPlaying = true
                    startTimeTimer()
                }
            }
        }
    }

    // MARK: - Громкость

    func applyVolume() {
        engine.mainMixerNode.outputVolume = Float(max(0, min(settings.volume, 1)))
    }

    // MARK: - Переключение треков

    private func hardSwitch(to track: Track) {
        cancelRamp()

        for channel in channels {
            channel.generation += 1
            channel.player.stop()
            channel.player.volume = 1.0
            resetLowPass(channel)
        }

        let index = 0
        activeIndex = index
        if startSegment(track: track, onChannel: index, position: 0) {
            isPlaying = true
        }
    }

    private func transitionWithCrossfade(to track: Track) {
        let oldIndex = activeIndex
        let newIndex = 1 - activeIndex
        cancelRamp()

        guard startSegment(track: track, onChannel: newIndex, position: 0, startVolume: 0) else { return }

        activeIndex = newIndex
        isTransitioning = true
        isPlaying = true

        let duration = max(0.3, settings.crossfadeDuration)
        let steps = max(2, Int(duration * rampStepsPerSecond))
        let interval = duration / Double(steps)
        rampGeneration += 1
        let generation = rampGeneration
        var step = 0

        let oldChannel = channels[oldIndex]
        let newChannel = channels[newIndex]

        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            step += 1
            let progress = Float(min(step, steps)) / Float(steps)

            oldChannel.player.volume = 1 - progress
            newChannel.player.volume = progress

            if step >= steps {
                timer.invalidate()
                self.rampTimer = nil
                oldChannel.generation += 1
                oldChannel.player.stop()
                oldChannel.player.volume = 1.0
                oldChannel.file = nil
                self.isTransitioning = false
            }
        }
    }

    private func transitionWithHighCut(to track: Track) {
        cancelRamp()

        let oldIndex = activeIndex
        let oldChannel = channels[oldIndex]

        isTransitioning = true
        isPlaying = true

        let duration = max(0.2, settings.highCutDuration)
        let steps = max(2, Int(duration * rampStepsPerSecond))
        let interval = duration / Double(steps)
        rampGeneration += 1
        let generation = rampGeneration
        var step = 0

        if let band = oldChannel.eq.bands.first {
            band.bypass = false
            band.frequency = lowPassOpenFrequency
        }

        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            step += 1
            let progress = Float(min(step, steps)) / Float(steps)

            if let band = oldChannel.eq.bands.first {
                let curve = pow(progress, 1.5)
                band.frequency = self.lowPassOpenFrequency * pow(self.lowPassClosedFrequency / self.lowPassOpenFrequency, curve)
            }
            oldChannel.player.volume = max(0, 1 - progress * 0.6)

            if step >= steps {
                timer.invalidate()
                self.rampTimer = nil

                oldChannel.generation += 1
                oldChannel.player.stop()
                oldChannel.player.volume = 1.0
                oldChannel.file = nil
                self.resetLowPass(oldChannel)

                // Пауза после high-cut перед запуском следующего
                let pauseAfter = self.settings.highCutPauseAfter
                if pauseAfter > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pauseAfter) { [weak self] in
                        guard let self else { return }
                        let newIndex = 1 - oldIndex
                        self.activeIndex = newIndex
                        if self.startSegment(track: track, onChannel: newIndex, position: 0) {
                            self.isPlaying = true
                        }
                        self.isTransitioning = false
                    }
                } else {
                    let newIndex = 1 - oldIndex
                    self.activeIndex = newIndex
                    if self.startSegment(track: track, onChannel: newIndex, position: 0) {
                        self.isPlaying = true
                    }
                    self.isTransitioning = false
                }
            }
        }
    }

    /// Запускает сегмент трека с trimStart до trimEnd (или до конца файла).
    /// `position` — время относительно trimStart (0 = начало trimStart).
    @discardableResult
    private func startSegment(track: Track, onChannel index: Int, position: TimeInterval = 0, startVolume: Float = 1.0) -> Bool {
        guard index >= 0, index < channels.count else { return false }
        let channel = channels[index]

        do {
            let file = try AVAudioFile(forReading: track.url)
            let format = file.processingFormat
            let rate = format.sampleRate
            let totalFrames = file.length
            
            guard rate > 0, totalFrames > 0 else { return false }

            // Позиция в файле = trimStart + position
            let startSec = max(0, track.trimStart + position)
            let startFrame = AVAudioFramePosition(startSec * rate)
            
            let endSec = track.trimEnd ?? (Double(totalFrames) / rate)
            let endFrame = min(totalFrames, AVAudioFramePosition(endSec * rate))
            let frameCount = max(0, AVAudioFrameCount(endFrame - startFrame))

            guard frameCount > 0 else {
                // Сегмент пустой — трек считается законченным
                DispatchQueue.main.async { [weak self] in
                    self?.onTrackFinished?()
                }
                return false
            }

            channel.generation += 1
            let generation = channel.generation

            channel.player.stop()
            channel.player.volume = startVolume
            resetLowPass(channel)

            engine.disconnectNodeOutput(channel.player)
            engine.disconnectNodeOutput(channel.eq)
            engine.connect(channel.player, to: channel.eq, format: format)
            engine.connect(channel.eq, to: engine.mainMixerNode, format: nil)

            if !engine.isRunning {
                try engine.start()
            }

            channel.file = file
            
            // Планируем воспроизведение сегмента от startFrame на frameCount кадров
            channel.player.scheduleSegment(file,
                                           startingFrame: startFrame,
                                           frameCount: frameCount,
                                           at: nil) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard channel.generation == generation else { return }
                    if self.activeIndex == index && !self.isTransitioning {
                        self.stopTimeTimer()
                        self.isPlaying = false
                        self.currentTime = track.effectiveDuration
                        self.onTrackFinished?()
                    }
                }
            }
            channel.player.play()

            currentTrack = track
            currentTime = position
            activeFileOffset = startSec
            startTimeTimer()
            if track.duration > 0 {
                loadWaveform(for: track)
            } else {
                Task { await self.ensureDurationAndWaveform(for: track) }
            }
            return true
        } catch {
            NSLog("DJPlayer: не удалось открыть файл \(track.path) — \(error.localizedDescription)")
            return false
        }
    }

    private func resetLowPass(_ channel: Channel) {
        if let band = channel.eq.bands.first {
            band.frequency = lowPassOpenFrequency
            band.bypass = true
        }
    }

    private func cancelRamp() {
        rampGeneration += 1
        rampTimer?.invalidate()
        rampTimer = nil
    }

    // MARK: - Отсчёт времени

    private func startTimeTimer() {
        stopTimeTimer()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimeTimer() {
        timeTimer?.invalidate()
        timeTimer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        guard let track = currentTrack else { return }
        let channel = channels[activeIndex]
        guard let nodeTime = channel.player.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = channel.player.playerTime(forNodeTime: nodeTime) else {
            return
        }
        let rate = channel.file?.processingFormat.sampleRate ?? 44100
        guard rate > 0 else { return }
        
        // Текущая позиция в файле
        let fileTime = activeFileOffset + Double(playerTime.sampleTime) / rate
        
        // Текущее время относительно trimStart
        let relativeTime = fileTime - track.trimStart
        currentTime = max(0, min(track.effectiveDuration, relativeTime))
    }

    // MARK: - Длительность и waveform

    private func ensureDurationAndWaveform(for track: Track) async {
        let updated = await WaveformGenerator.load(for: track)
        await MainActor.run {
            var trackWithDuration = track
            trackWithDuration.duration = updated.duration
            self.currentTrack = trackWithDuration
            self.waveform = updated.peaks
        }
    }

    private func loadWaveform(for track: Track) {
        Task { @MainActor [weak self] in
            let result = await WaveformGenerator.load(for: track)
            guard let self else { return }
            if self.currentTrack?.path == track.path {
                self.waveform = result.peaks
            }
        }
    }
}
