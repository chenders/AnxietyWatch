import Charts
import SwiftData
import SwiftUI

struct CorrelationChartView: View {
    let correlation: PhysiologicalCorrelation
    @Query(sort: \HealthSnapshot.date) private var snapshots: [HealthSnapshot]
    @Query(sort: \AnxietyEntry.timestamp) private var entries: [AnxietyEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(correlation.displayName)
                .font(.title3.bold())

            Text("\(correlation.strength) \(correlation.direction) correlation (r = \(correlation.correlation, specifier: "%.2f"))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if pairedData.isEmpty {
                ContentUnavailableView("No Paired Data", systemImage: "chart.dots.scatter")
            } else {
                Chart(pairedData, id: \.date) { point in
                    PointMark(
                        x: .value(correlation.displayName, point.signalValue),
                        y: .value("Severity", point.severity)
                    )
                    .foregroundStyle(.blue.opacity(0.6))
                }
                .chartYScale(domain: 1...10)
                .chartYAxisLabel("Anxiety Severity")
                .chartXAxisLabel(correlation.displayName)
                .frame(height: 250)
            }

            if let abnormal = correlation.meanSeverityWhenAbnormal,
               let normal = correlation.meanSeverityWhenNormal {
                HStack(spacing: 16) {
                    StatBox(label: "Normal days", value: String(format: "%.1f", normal), color: .green)
                    StatBox(label: "Abnormal days", value: String(format: "%.1f", abnormal), color: .red)
                }
            }

            Text("Based on \(correlation.sampleCount) paired days  ·  p = \(correlation.pValue, specifier: "%.3f")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .navigationTitle("Correlation Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct PairedPoint {
        let date: Date
        let signalValue: Double
        let severity: Double
    }

    private var pairedData: [PairedPoint] {
        let calendar = Calendar.current
        let entriesByDate = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.timestamp) }

        return snapshots.compactMap { snap in
            guard let dayEntries = entriesByDate[snap.date], !dayEntries.isEmpty else { return nil }
            let avgSeverity = Double(dayEntries.map(\.severity).reduce(0, +)) / Double(dayEntries.count)
            guard let value = signalValue(from: snap) else { return nil }
            return PairedPoint(date: snap.date, signalValue: value, severity: avgSeverity)
        }
    }

    private func signalValue(from snap: HealthSnapshot) -> Double? {
        switch correlation.signalName {
        case "hrv_avg": return snap.hrvAvg
        case "resting_hr": return snap.restingHR
        case "sleep_duration_min": return snap.sleepDurationMin.map(Double.init)
        case "sleep_quality_ratio":
            guard let d = snap.sleepDurationMin, d > 0 else { return nil }
            return Double((snap.sleepDeepMin ?? 0) + (snap.sleepREMMin ?? 0)) / Double(d)
        case "steps": return snap.steps.map(Double.init)
        case "cpap_ahi": return snap.cpapAHI
        case "barometric_pressure_change_kpa": return snap.barometricPressureChangeKPa
        default: return nil
        }
    }
}

private struct StatBox: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}
