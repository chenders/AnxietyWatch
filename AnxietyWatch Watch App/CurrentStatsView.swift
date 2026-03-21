import SwiftUI

struct CurrentStatsView: View {
    private let connectivity = WatchConnectivityManager.shared

    var body: some View {
        List {
            if let anxiety = connectivity.lastAnxiety {
                StatRow(
                    title: "Last Anxiety",
                    value: "\(anxiety)/10",
                    color: severityColor(anxiety)
                )
            }

            if let hrv = connectivity.hrvAvg {
                StatRow(
                    title: "HRV",
                    value: String(format: "%.0f ms", hrv),
                    color: .blue
                )
            }

            if let hr = connectivity.restingHR {
                StatRow(
                    title: "Resting HR",
                    value: String(format: "%.0f bpm", hr),
                    color: .red
                )
            }

            if connectivity.lastAnxiety == nil
                && connectivity.hrvAvg == nil
                && connectivity.restingHR == nil
            {
                Text("Open Anxiety Watch on iPhone to sync stats")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Stats")
    }

    private func severityColor(_ severity: Int) -> Color {
        switch severity {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}

struct StatRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
        }
    }
}
