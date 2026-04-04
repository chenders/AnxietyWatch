import SwiftUI

struct CorrelationCardView: View {
    let correlation: PhysiologicalCorrelation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(correlation.displayName)
                    .font(.headline)
                Spacer()
                Text("\(correlation.strength) \(correlation.direction)")
                    .font(.caption)
                    .foregroundStyle(strengthColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(strengthColor.opacity(0.15), in: .capsule)
            }

            if let abnormal = correlation.meanSeverityWhenAbnormal,
               let normal = correlation.meanSeverityWhenNormal {
                Text(insightText(abnormal: abnormal, normal: normal))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("r = \(correlation.correlation, specifier: "%.2f")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Based on \(correlation.sampleCount) days")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        .opacity(correlation.isSignificant ? 1.0 : 0.5)
        .overlay(alignment: .topTrailing) {
            if !correlation.isSignificant {
                Text("Insufficient data")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(6)
            }
        }
    }

    private var strengthColor: Color {
        let absR = abs(correlation.correlation)
        if absR > 0.5 { return .red }
        if absR > 0.3 { return .orange }
        return .gray
    }

    private func insightText(abnormal: Double, normal: Double) -> String {
        let signalLabel: String
        switch correlation.signalName {
        case "hrv_avg": signalLabel = "low HRV"
        case "resting_hr": signalLabel = "elevated heart rate"
        case "sleep_duration_min": signalLabel = "poor sleep"
        case "sleep_quality_ratio": signalLabel = "low sleep quality"
        case "steps": signalLabel = "low activity"
        case "cpap_ahi": signalLabel = "high AHI"
        case "barometric_pressure_change_kpa": signalLabel = "pressure changes"
        default: signalLabel = "abnormal \(correlation.displayName)"
        }
        return String(
            format: "Anxiety averages %.1f on days with %@ vs %.1f normally",
            abnormal, signalLabel, normal
        )
    }
}
