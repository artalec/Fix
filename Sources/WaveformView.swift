import SwiftUI
import AppKit

/// Waveform трека: клик для перемотки, перетаскиваемые маркеры Start Time / End Time.
///
/// Маркеры выглядят как серые треугольники по краям области обрезки.
/// Значения сохраняются в модели трека и применяются при следующих запусках.
struct WaveformView: View {

    let peaks: [Float]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let accent: RGBAColor

    /// Точки обрезки в секундах от начала файла.
    let trimStart: TimeInterval
    let trimEnd: TimeInterval

    /// Позиция воспроизведения (относительно trimStart) — для клика по waveform.
    let onSeek: (TimeInterval) -> Void
    let onTrimChange: (TimeInterval, TimeInterval) -> Void

    @State private var draggingHandle: Handle?
    @State private var dragStartX: CGFloat = 0
    @State private var dragStartValues: (start: TimeInterval, end: TimeInterval) = (0, 0)

    private enum Handle { case start, end }

    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1
    private let handleWidth: CGFloat = 14
    private let handleHitArea: CGFloat = 22

    private var safeDuration: TimeInterval { max(duration, 0.001) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.18))

                // Затемнённые области вне сегмента обрезки
                trimmedOverlay(width: width, height: height)

                // Волна
                waveformBars(width: width, height: height)

                // Курсор воспроизведения
                if duration > 0 {
                    let x = xPosition(forFileTime: trimStart + currentTime, width: width)
                    Rectangle()
                        .fill(Color.red.opacity(0.9))
                        .frame(width: 2, height: height)
                        .offset(x: x)
                }

                // Маркеры Start / End
                if duration > 0 {
                    trimHandle(.start, width: width, height: height)
                    trimHandle(.end, width: width, height: height)
                }
            }
            .contentShape(Rectangle())
            // Клик или перетаскивание по свободному месту — перемотка
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard draggingHandle == nil, duration > 0 else { return }
                        seekToX(value.location.x, width: width)
                    }
            )
        }
    }

    // MARK: - Позиции

    /// X для времени в файле (0...duration).
    private func xPosition(forFileTime time: TimeInterval, width: CGFloat) -> CGFloat {
        let ratio = min(max(time / safeDuration, 0), 1)
        return CGFloat(ratio) * width
    }

    /// Время в файле для координаты X.
    private func fileTime(forX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        let ratio = min(max(x / width, 0), 1)
        return Double(ratio) * safeDuration
    }

    /// Перемотка: клик задаёт позицию относительно trimStart.
    private func seekToX(_ x: CGFloat, width: CGFloat) {
        let absolute = fileTime(forX: x, width: width)
        let relative = absolute - trimStart
        onSeek(max(0, min(relative, max(0, trimEnd - trimStart))))
    }

    // MARK: - Отрисовка

    private func trimmedOverlay(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            let startX = xPosition(forFileTime: trimStart, width: width)
            let endX = xPosition(forFileTime: trimEnd, width: width)

            // Область до Start
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: max(0, startX), height: height)

            // Область после End
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: max(0, width - endX), height: height)
                .offset(x: endX)
        }
        .allowsHitTesting(false)
    }

    private func waveformBars(width: CGFloat, height: CGFloat) -> some View {
        let capacity = max(1, Int(width / (barWidth + barSpacing)))
        let values = downsample(peaks, to: capacity)

        // Границы сегмента в индексах массива
        let startRatio = min(max(trimStart / safeDuration, 0), 1)
        let endRatio = min(max(trimEnd / safeDuration, 0), 1)
        let playedRatio = min(max((trimStart + currentTime) / safeDuration, 0), 1)

        return ZStack(alignment: .leading) {
            if values.isEmpty {
                Text("Waveform появится при запуске трека")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: height)
            } else {
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(Array(values.enumerated()), id: \.offset) { item in
                        let ratio = Double(item.offset) / Double(max(1, values.count - 1))
                        let inSegment = ratio >= startRatio && ratio <= endRatio
                        let played = ratio <= playedRatio

                        RoundedRectangle(cornerRadius: 1)
                            .fill(barColor(inSegment: inSegment, played: played))
                            .frame(width: barWidth, height: max(2, CGFloat(item.element) * (height - 16)))
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }

    private func barColor(inSegment: Bool, played: Bool) -> Color {
        if !inSegment {
            return Color.secondary.opacity(0.25)
        }
        return played ? accent.swiftUIColor : Color.secondary.opacity(0.5)
    }

    /// Серый треугольный маркер, перетаскивается мышью.
    private func trimHandle(_ handle: Handle, width: CGFloat, height: CGFloat) -> some View {
        let time = handle == .start ? trimStart : trimEnd
        let x = xPosition(forFileTime: time, width: width)

        return ZStack {
            // Треугольник
            Triangle()
                .fill(Color.gray.opacity(0.95))
                .frame(width: handleWidth, height: 10)
                .overlay(
                    Triangle()
                        .stroke(Color.black.opacity(0.5), lineWidth: 1)
                        .frame(width: handleWidth, height: 10)
                )
                .offset(y: handle == .start ? -height / 2 + 6 : height / 2 - 6)

            // Тонкая вертикальная линия границы
            Rectangle()
                .fill(Color.gray.opacity(0.9))
                .frame(width: 1.5, height: height)
        }
        .frame(width: handleHitArea, height: height)
        .contentShape(Rectangle())
        .offset(x: x - handleHitArea / 2)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if draggingHandle == nil {
                        draggingHandle = handle
                        dragStartX = value.startLocation.x
                        dragStartValues = (trimStart, trimEnd)
                    }
                    let newAbs = fileTime(forX: value.location.x, width: width)

                    switch handle {
                    case .start:
                        // Start не может зайти за End (минимум 0.2 с сегмента)
                        let upper = min(dragStartValues.end, safeDuration)
                        let clamped = max(0, min(newAbs, upper - 0.2))
                        onTrimChange(clamped, dragStartValues.end)
                    case .end:
                        let lower = max(0, dragStartValues.start)
                        let clamped = min(safeDuration, max(newAbs, lower + 0.2))
                        onTrimChange(dragStartValues.start, clamped)
                    }
                }
                .onEnded { _ in
                    draggingHandle = nil
                }
        )
        .help(handle == .start ? "Start Time — потяните, чтобы задать начало" : "End Time — потяните, чтобы задать конец")
    }

    private func downsample(_ source: [Float], to count: Int) -> [Float] {
        guard !source.isEmpty, count > 0 else { return [] }
        if source.count <= count { return source }

        var result: [Float] = []
        result.reserveCapacity(count)
        let ratio = Double(source.count) / Double(count)

        for i in 0..<count {
            let start = Int(Double(i) * ratio)
            let end = min(source.count, max(start + 1, Int(Double(i + 1) * ratio)))
            var peak: Float = 0
            for j in start..<end { peak = max(peak, source[j]) }
            result.append(peak)
        }
        return result
    }
}

/// Треугольник для маркеров обрезки.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
