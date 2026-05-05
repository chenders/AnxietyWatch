import SwiftUI

/// Compact summary of last night's overnight SpO₂ stats. Shown on the
/// Dashboard between Vitals and Activity sections when the most recent
/// snapshot with any overnight SpO₂ field exists.
struct LastNightCard: View {
    let snapshot: HealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last Night")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(freshnessLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                statColumn(
                    label: "SpO₂ Nadir",
                    value: snapshot.spo2NadirOvernight.map { String(format: "%.0f%%", $0) } ?? "—",
                    color: snapshot.spo2NadirOvernight
                        .map { ClinicalSeverity.spo2NadirSeverity($0).color } ?? .secondary
                )
                statColumn(
                    label: "T90",
                    value: snapshot.spo2TimeBelow90Min.map { "\($0) min" } ?? "—",
                    color: snapshot.spo2TimeBelow90Min
                        .map { ClinicalSeverity.t90Severity($0).color } ?? .secondary
                )
                statColumn(
                    label: "Desats",
                    value: snapshot.spo2DesatsCount.map { "\($0)" } ?? "—",
                    color: snapshot.spo2DesatsCount
                        .map { ClinicalSeverity.desatCountSeverity($0).color } ?? .secondary
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }

    private func statColumn(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var freshnessLabel: String {
        DashboardViewModel.nightFreshnessLabel(for: snapshot.date)
    }
}
