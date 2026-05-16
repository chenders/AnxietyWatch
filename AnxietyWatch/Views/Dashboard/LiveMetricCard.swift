import SwiftUI

/// Visualization type for the right side of a LiveMetricCard.
enum MetricVisualization {
    case sparkline(segments: [[SparklinePoint]], color: Color)
    case progressBar(current: Double, goal: Double, color: Color)
    case recentBars(values: [Double], color: Color)
    case sleepStages(deep: Int, rem: Int, core: Int, awake: Int)
    case miniGrid(items: [MiniGridItem])
    /// Inline pill showing a baseline-deviation snippet (e.g., "↓ 28% vs 30d")
    /// instead of a chart. Right viz for metrics with too few samples to draw
    /// a sparkline meaningfully (HRV, Walking HR, BP, etc.).
    case baselineChip(deltaText: String, color: Color)
    case none
}

/// One labelled value cell in a 2×2 mini-grid for compact secondary metrics.
struct MiniGridItem: Sendable {
    let label: String
    let value: String
    let color: Color
}

/// Side-by-side metric card: value stack on the left, visualization on the right.
struct LiveMetricCard: View {
    let title: String
    let value: String
    let unitLabel: String
    let trend: TrendCalculator.Direction?
    let freshness: String
    let color: Color
    let visualization: MetricVisualization
    var sourceChip: DeviceChip.Source? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Left: value stack
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let sourceChip {
                        DeviceChip(source: sourceChip)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.title2.bold())
                        .foregroundStyle(color)
                    Text(unitLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let trend {
                    Text("\(trend.symbol) \(trend.label)")
                        .font(.caption2)
                        .foregroundStyle(trendColor(trend))
                }
                Text(freshness)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            // Right: visualization
            visualizationView
                .frame(maxWidth: .infinity, maxHeight: 50)
        }
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = ["\(title). \(value) \(unitLabel)"]
        if let trend {
            parts.append(trend.label)
        }
        parts.append(freshness)
        if case .baselineChip(let deltaText, _) = visualization {
            parts.append("Compared to your baseline: \(deltaText)")
        }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private var visualizationView: some View {
        switch visualization {
        case .sparkline(let segments, let sparkColor):
            VStack(spacing: 2) {
                SparklineView(segments: segments, color: sparkColor)
                HStack {
                    Text("12a")
                    Spacer()
                    Text("6a")
                    Spacer()
                    Text("12p")
                    Spacer()
                    Text("Now")
                }
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
            }
        case .progressBar(let current, let goal, let barColor):
            ProgressBarView(current: current, goal: goal, color: barColor)
        case .recentBars(let values, let barColor):
            RecentBarsView(values: values, color: barColor)
        case .sleepStages(let deep, let rem, let core, let awake):
            SleepStagesView(deep: deep, rem: rem, core: core, awake: awake)
        case .miniGrid(let items):
            // 2×2 grid in the same 50pt slot used by the sparkline. Each cell
            // is a label + value stack; lineLimit + minimumScaleFactor keep
            // larger Dynamic Type sizes from clipping the bottom row.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 2) {
                ForEach(items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(items[i].label)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(items[i].value)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(items[i].color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        case .baselineChip(let text, let chipColor):
            Text(text)
                .font(.caption.bold())
                .foregroundStyle(chipColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(chipColor.opacity(0.15), in: .capsule)
                .accessibilityLabel("Compared to your baseline: \(text)")
        case .none:
            EmptyView()
        }
    }

    private func trendColor(_ trend: TrendCalculator.Direction) -> Color {
        switch trend {
        case .rising: .orange
        case .stable: .green
        case .dropping: .blue
        }
    }
}

/// Compact sleep stage breakdown bar with legend.
struct SleepStagesView: View {
    let deep: Int
    let rem: Int
    let core: Int
    let awake: Int

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let total = Double(deep + rem + core + awake)
                if total > 0 {
                    HStack(spacing: 0) {
                        stageBar(minutes: deep, total: total, color: .indigo, width: geo.size.width)
                        stageBar(minutes: rem, total: total, color: .purple, width: geo.size.width)
                        stageBar(minutes: core, total: total, color: .cyan, width: geo.size.width)
                        stageBar(minutes: awake, total: total, color: .gray, width: geo.size.width)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(height: 14)

            HStack(spacing: 8) {
                if deep > 0 { stageLabel("Deep", deep, .indigo) }
                if rem > 0 { stageLabel("REM", rem, .purple) }
                if core > 0 { stageLabel("Core", core, .cyan) }
            }
            .font(.system(size: 8))
        }
    }

    private func stageBar(minutes: Int, total: Double, color: Color, width: CGFloat) -> some View {
        color.frame(width: width * Double(minutes) / total)
    }

    private func stageLabel(_ name: String, _ minutes: Int, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(name) \(minutes)m").foregroundStyle(.secondary)
        }
    }
}
