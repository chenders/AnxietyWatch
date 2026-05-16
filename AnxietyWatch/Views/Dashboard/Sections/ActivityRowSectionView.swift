import SwiftUI

/// Single card containing three thin progress bars: Steps · Active Calories ·
/// Exercise. Replaces three full-width progress-bar cards that previously
/// stacked under the Vitals section. Calories drops the arbitrary 500 kcal
/// goal — uses the user's 7-day average as the comparison anchor instead.
struct ActivityRowSectionView: View {
    let vm: DashboardViewModel
    let snapshots: [HealthSnapshot]

    var body: some View {
        let today = vm.todaySnapshot(from: snapshots)
        let stepsValue = today?.steps.map { $0.formatted() } ?? "—"
        let stepsAvg = vm.sevenDayAverage(\.steps, from: snapshots)
        let stepsComparison = stepsAvg.map { "vs \(Int($0).formatted()) avg" }
        let calsValue = today?.activeCalories.map { String(format: "%.0f", $0) } ?? "—"
        let calsAvg = vm.sevenDayAverage(\.activeCalories, from: snapshots)
        let calsComparison = calsAvg.map { String(format: "vs %.0f avg", $0) }
        let exerciseValue = today?.exerciseMinutes.map { "\($0)" } ?? "—"
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity · Today").font(.caption).foregroundStyle(.secondary)
            row(label: "Steps",
                value: stepsValue,
                progress: today.flatMap { $0.steps.map { Double($0) } } ?? 0,
                cap: 8000, tint: .red,
                comparison: stepsComparison)
            row(label: "Active cal",
                value: calsValue,
                progress: today?.activeCalories ?? 0,
                cap: calsAvg ?? 500,
                tint: .orange,
                comparison: calsComparison)
            row(label: "Exercise",
                value: today?.exerciseMinutes.map { "\($0) min" } ?? "—",
                progress: today.flatMap { $0.exerciseMinutes.map { Double($0) } } ?? 0,
                cap: 30, tint: .green, comparison: "of 30 goal")
        }
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activityAccessibilityLabel(
            stepsValue: stepsValue,
            stepsComparison: stepsComparison,
            calsValue: calsValue,
            calsComparison: calsComparison,
            exerciseValue: exerciseValue
        ))
    }

    private func activityAccessibilityLabel(
        stepsValue: String,
        stepsComparison: String?,
        calsValue: String,
        calsComparison: String?,
        exerciseValue: String
    ) -> String {
        var parts = ["Activity today"]
        parts.append("Steps \(stepsValue)\(stepsComparison.map { ", \($0)" } ?? "")")
        parts.append("Active calories \(calsValue)\(calsComparison.map { ", \($0)" } ?? "")")
        parts.append("Exercise \(exerciseValue) of 30 minutes goal")
        return parts.joined(separator: ". ")
    }

    private func row(label: String, value: String, progress: Double, cap: Double, tint: Color, comparison: String?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            ProgressBarView(current: progress, goal: max(cap, 1), color: tint)
                .frame(height: 6)
            Text(value).font(.caption.weight(.semibold)).frame(width: 60, alignment: .trailing)
            if let comparison {
                Text(comparison).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}
