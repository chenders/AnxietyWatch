import SwiftUI
import SwiftData

struct EnergyMetricsDebugView: View, Equatable {
    @Query(sort: \EnergyMetricPayload.timestamp, order: .reverse) private var payloads: [EnergyMetricPayload]

    static func == (lhs: EnergyMetricsDebugView, rhs: EnergyMetricsDebugView) -> Bool {
        return true
    }

    var body: some View {
        List {
            ForEach(payloads.prefix(7)) { payload in
                VStack(alignment: .leading, spacing: 4) {
                    Text(payload.timestamp, format: .dateTime)
                        .font(.headline)
                    Text("CPU Time: \(String(format: "%.1f", payload.cumulativeCPUTime))s")
                    Text("Wake Count: \(payload.backgroundWakeCount)")
                }
            }
        }
        .navigationTitle("Energy Metrics")
    }
}
