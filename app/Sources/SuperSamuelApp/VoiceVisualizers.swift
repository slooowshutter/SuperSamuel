import SwiftUI

/// A grid of small lights for the latest microphone levels: one column per reading,
/// newest on the right, lit from the bottom. Readings arrive 20 times per second and
/// show without smoothing or animation, so the grid follows the voice at once.
struct LevelGrid: View {
    let samples: [CGFloat]
    let isActive: Bool

    private let columns = 72
    private let rows = 8

    var body: some View {
        let recent = Array(samples.suffix(columns))
        let padding = Array(repeating: CGFloat(0), count: columns - recent.count)
        let levels = padding + recent
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<columns, id: \.self) { column in
                let lit = isActive ? Int((min(levels[column] * 1.25, 1) * CGFloat(rows)).rounded(.up)) : 0
                VStack(spacing: 2) {
                    ForEach((0..<rows).reversed(), id: \.self) { row in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(
                                row < lit
                                    ? Color.primary.opacity(0.5 + Double(row) / Double(rows) * 0.5)
                                    : Color.primary.opacity(0.08)
                            )
                    }
                }
            }
        }
    }
}
