import Foundation
import AVFoundation

/// Считает пики для отрисовки waveform и уточняет длительность файла.
/// Работает полностью в фоне, вызывается через async/await.
enum WaveformGenerator {

    struct WaveformData {
        var peaks: [Float]
        var duration: TimeInterval
    }

    static let targetPeakCount = 900

    static func load(for track: Track) async -> WaveformData {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: compute(path: track.path))
            }
        }
    }

    private static func compute(path: String) -> WaveformData {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            return WaveformData(peaks: [], duration: 0)
        }

        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, format.sampleRate > 0 else {
            return WaveformData(peaks: [], duration: 0)
        }

        let duration = Double(totalFrames) / format.sampleRate

        // Читаем файл блоками, чтобы не держать в памяти целый трек.
        let framesPerPeak = max(1, Int(totalFrames) / targetPeakCount)
        let bufferSize: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
            return WaveformData(peaks: [], duration: duration)
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(targetPeakCount + 1)

        var framesInCurrentPeak = 0
        var currentPeak: Float = 0
        var remaining = totalFrames

        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(Int64(bufferSize), remaining))
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                break
            }

            let framesRead = Int(buffer.frameLength)
            if framesRead == 0 { break }

            guard let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)

            for frame in 0..<framesRead {
                var amplitude: Float = 0
                for ch in 0..<channelCount {
                    amplitude = max(amplitude, abs(channels[ch][frame]))
                }
                currentPeak = max(currentPeak, amplitude)
                framesInCurrentPeak += 1

                if framesInCurrentPeak >= framesPerPeak {
                    peaks.append(currentPeak)
                    currentPeak = 0
                    framesInCurrentPeak = 0
                }
            }

            remaining -= Int64(framesRead)
        }

        if framesInCurrentPeak > 0 {
            peaks.append(currentPeak)
        }

        // Нормализация, чтобы тихие треки тоже были читаемы на графике.
        if let maxPeak = peaks.max(), maxPeak > 0.0001 {
            peaks = peaks.map { min(1.0, $0 / maxPeak) }
        }

        return WaveformData(peaks: peaks, duration: duration)
    }
}
