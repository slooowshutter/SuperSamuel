import SwiftUI

/// Columns of segments lit from the bottom by the voice. Each column averages an equal
/// share of the newest samples.
struct EqualizerView: View {
    let samples: [CGFloat]
    let isActive: Bool

    private let columns = 32
    private let rows = 4

    var body: some View {
        let share = max(1, samples.count / columns)
        let levels = (0..<columns).map { column -> CGFloat in
            let group = samples.suffix(columns * share).dropFirst(column * share).prefix(share)
            return group.isEmpty ? 0 : group.reduce(0, +) / CGFloat(group.count)
        }
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<columns, id: \.self) { column in
                let lit = isActive ? Int((min(levels[column] * 1.25, 1) * CGFloat(rows)).rounded(.up)) : 0
                VStack(spacing: 3) {
                    ForEach((0..<rows).reversed(), id: \.self) { row in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(
                                row < lit
                                    ? Color.primary.opacity(0.55 + Double(row) / Double(rows) * 0.45)
                                    : Color.primary.opacity(0.08)
                            )
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: samples.last)
    }
}

/// Three sine waves whose height follows the voice. They drift slowly over time.
struct LineWaveView: View {
    let samples: [CGFloat]
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let recent = samples.suffix(6)
                let average = recent.isEmpty ? 0 : recent.reduce(0, +) / CGFloat(recent.count)
                let amplitude = isActive ? max(0.06, average) : 0.04
                for (index, wave) in [(1.0, 1.0), (0.6, 1.6), (0.35, 2.3)].enumerated() {
                    var path = Path()
                    let steps = 120
                    for step in 0...steps {
                        let progress = CGFloat(step) / CGFloat(steps)
                        let envelope = sin(progress * .pi)
                        let phase = time * (1.4 + Double(index) * 0.5)
                        let y = size.height / 2
                            + CGFloat(sin(Double(progress) * 2 * .pi * wave.1 * 2 + phase))
                            * envelope * amplitude * size.height * 0.5 * wave.0 * 1.6
                        let point = CGPoint(x: progress * size.width, y: y)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    canvas.stroke(
                        path,
                        with: .color(Color.primary.opacity(wave.0)),
                        lineWidth: index == 0 ? 2 : 1.2
                    )
                }
            }
        }
    }
}

/// Bars around a circle: the newest sample at the top, older ones going clockwise.
struct RadialWaveformView: View {
    let samples: [CGFloat]

    var body: some View {
        Canvas { canvas, size in
            let recent = Array(samples.suffix(56))
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let inner = min(size.width, size.height) * 0.3
            let outer = min(size.width, size.height) * 0.48
            for (index, sample) in recent.reversed().enumerated() {
                let angle = Double(index) / Double(recent.count) * 2 * .pi - .pi / 2
                let length = 3 + (outer - inner - 3) * pow(min(max(sample, 0), 1), 1.4)
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                var path = Path()
                path.move(to: CGPoint(x: center.x + direction.x * inner, y: center.y + direction.y * inner))
                path.addLine(to: CGPoint(
                    x: center.x + direction.x * (inner + length),
                    y: center.y + direction.y * (inner + length)
                ))
                canvas.stroke(
                    path,
                    with: .color(Color.primary.opacity(0.35 + sample * 0.6)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
            }
        }
    }
}
