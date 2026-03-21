import SwiftUI

/// Compact card showing a single lab result with color-coded status.
/// Matches the existing MetricCard pattern used on the Dashboard.
struct LabResultMetricCard: View {
    let testName: String
    let value: Double
    let unit: String
    let normalRangeLow: Double
    let normalRangeHigh: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(testName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formattedValue)
                .font(.title2.bold())
                .foregroundStyle(statusColor)
            Text("\(formattedRange) \(unit)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }

    private var formattedValue: String {
        if value == value.rounded() && value < 10000 {
            return String(format: "%.0f %@", value, unit)
        }
        return String(format: "%.1f %@", value, unit)
    }

    private var formattedRange: String {
        String(format: "%.1f–%.1f", normalRangeLow, normalRangeHigh)
    }

    private var statusColor: Color {
        if value < normalRangeLow {
            return .orange
        } else if value > normalRangeHigh {
            return .red
        }
        return .green
    }
}
