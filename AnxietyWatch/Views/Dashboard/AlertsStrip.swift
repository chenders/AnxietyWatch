import SwiftUI

/// Rolled-up alerts strip. Renders nothing when `alerts` is empty.
/// Single-line collapsed form by default; tap to expand inline up to 3 visible.
struct AlertsStrip: View {
    let alerts: [DashboardAlert]
    @State private var expanded = false

    var body: some View {
        if alerts.isEmpty {
            EmptyView()
        } else if alerts.count == 1, alerts[0].relatedCount == 0 {
            // Single alert — render directly, no roll-up affordance.
            row(alerts[0])
        } else {
            VStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack {
                        Image(systemName: dominantSeverityIcon).foregroundStyle(dominantSeverityColor)
                        Text("\(alerts.count) signal\(alerts.count == 1 ? "" : "s") worth a look")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(dominantSeverityColor.opacity(0.12), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(alerts.count) signal\(alerts.count == 1 ? "" : "s") worth a look")
                .accessibilityHint(expanded ? "Tap to collapse" : "Tap to expand alerts")
                if expanded {
                    ForEach(alerts.prefix(3)) { a in row(a) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ a: DashboardAlert) -> some View {
        let relatedSuffix = a.relatedCount > 0 ? " (\(a.relatedCount) related)" : ""
        HStack(spacing: 8) {
            Image(systemName: icon(for: a)).foregroundStyle(color(for: a))
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.subheadline.bold())
                Text(a.message).font(.caption).foregroundStyle(.secondary)
                if a.relatedCount > 0 {
                    Text("+\(a.relatedCount) related")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding()
        .background(color(for: a).opacity(0.1), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(a.title). \(a.message)\(relatedSuffix)")
    }

    private var dominantSeverityIcon: String {
        alerts.contains { $0.severity == .critical } ? "exclamationmark.triangle.fill" : "exclamationmark.circle"
    }

    private var dominantSeverityColor: Color {
        if alerts.contains(where: { $0.severity == .critical }) { return .red }
        if alerts.contains(where: { $0.severity == .warn }) { return .orange }
        return .secondary
    }

    private func color(for a: DashboardAlert) -> Color {
        switch a.severity {
        case .critical: .red
        case .warn: .orange
        case .info: .secondary
        }
    }

    private func icon(for a: DashboardAlert) -> String {
        switch a.category {
        case .autonomic: "heart.fill"
        case .sleep: "bed.double.fill"
        case .environment: "barometer"
        }
    }
}
