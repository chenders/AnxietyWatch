import Charts
import SwiftUI

struct SleepTrendChart: View {
    let snapshots: [HealthSnapshot]
    let dateRange: ClosedRange<Date>

    private var sleepSnapshots: [HealthSnapshot] {
        snapshots.filter { $0.sleepDurationMin != nil }
    }

    var body: some View {
        ChartCard(title: "Sleep", isEmpty: sleepSnapshots.isEmpty) {
            Chart(sleepSnapshots) { snapshot in
                if let deep = snapshot.sleepDeepMin {
                    BarMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("Minutes", deep)
                    )
                    .foregroundStyle(by: .value("Stage", "Deep"))
                }
                if let rem = snapshot.sleepREMMin {
                    BarMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("Minutes", rem)
                    )
                    .foregroundStyle(by: .value("Stage", "REM"))
                }
                if let core = snapshot.sleepCoreMin {
                    BarMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("Minutes", core)
                    )
                    .foregroundStyle(by: .value("Stage", "Core"))
                }
            }
            .chartXScale(domain: dateRange)
            .chartForegroundStyleScale([
                "Deep": Color.indigo,
                "REM": Color.cyan,
                "Core": Color.blue.opacity(0.5),
            ])
            .frame(height: 200)
        }
    }
}
