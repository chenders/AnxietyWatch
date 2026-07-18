import SwiftUI
import AnxietyWatchKit

public struct DashboardMonitoringCard: View {
    private var monitor: MonitoringViewModel

    public init(monitor: MonitoringViewModel) {
        self.monitor = monitor
    }

    public var body: some View {
        HStack(spacing: 16) {
            // Vitals Section
            VStack(alignment: .leading, spacing: 12) {
                vitalRow(
                    icon: "heart.fill",
                    color: .red,
                    value: monitor.latestHR,
                    unit: "bpm"
                )

                vitalRow(
                    icon: "lungs.fill",
                    color: .blue,
                    value: monitor.latestSpO2,
                    unit: "%"
                )
            }
            .frame(width: 80, alignment: .leading)

            Divider()

            // Tier and Fusion section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("STATUS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    tierBadge(tier: monitor.alertTier, isIdle: monitor.isIdle)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("RISK SCORE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(monitor.fusionScore * 100))%")
                            .font(.caption.bold())
                            .contentTransition(.numericText())
                    }

                    ProgressView(value: monitor.fusionScore, total: 1.0)
                        .tint(progressColor(for: monitor.fusionScore))
                        .animation(.spring(response: 0.3), value: monitor.fusionScore)
                }
            }
        }
        .padding(16)
        .frame(height: 120)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                #if os(iOS)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                #else
                .fill(Color.gray.opacity(0.2))
                #endif
        }
    }

    @ViewBuilder
    private func vitalRow(icon: String, color: Color, value: Int?, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
                .frame(width: 16)

            if let value = value, !monitor.isIdle {
                Text("\(value)")
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("--")
                    .font(.headline)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.default, value: value)
    }

    @ViewBuilder
    private func tierBadge(tier: AlertTier, isIdle: Bool) -> some View {
        Text(verbatim: isIdle ? "IDLE" : String(describing: tier))
            .font(.caption2.bold())
            .foregroundStyle(.gray)
    }

    private func progressColor(for score: Double) -> Color {
        if monitor.isIdle { return .gray.opacity(0.5) }
        if score < 0.3 { return .green }
        if score < 0.7 { return .yellow }
        if score < 0.9 { return .orange }
        return .red
    }
}
