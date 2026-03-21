import Charts
import SwiftUI

struct ActivityTrendChart: View {
    let snapshots: [HealthSnapshot]

    private var stepSnapshots: [HealthSnapshot] {
        snapshots.filter { $0.steps != nil }
    }

    var body: some View {
        ChartCard(title: "Steps", isEmpty: stepSnapshots.isEmpty) {
            Chart(stepSnapshots) { snapshot in
                BarMark(
                    x: .value("Date", snapshot.date, unit: .day),
                    y: .value("Steps", snapshot.steps!)
                )
                .foregroundStyle(.orange.gradient)
            }
            .frame(height: 180)
        }
    }
}
