import SwiftUI
import AnxietyWatchKit

public struct DashboardMonitoringCard: View {
    private var monitor: MonitoringViewModel

    public init(monitor: MonitoringViewModel) {
        self.monitor = monitor
    }

    public var body: some View {
        HStack(spacing: 16) {
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

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("STATUS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(verbatim: monitor.isIdle ? "IDLE" : "LIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(monitor.isIdle ? Color.secondary : Color.green)
                }

                if let hrv = monitor.latestHRV, !monitor.isIdle {
                    HStack {
                        Text("HRV")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(hrv.rounded())) ms")
                            .font(.caption.bold())
                            .contentTransition(.numericText())
                    }
                } else {
                    Text("Live vitals from connected sensors")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
}
