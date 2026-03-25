import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AnxietyEntry.timestamp, order: .reverse)
    private var recentEntries: [AnxietyEntry]
    @Query(sort: \MedicationDose.timestamp, order: .reverse)
    private var recentDoses: [MedicationDose]
    @Query(sort: \HealthSnapshot.date, order: .reverse)
    private var recentSnapshots: [HealthSnapshot]
    @Query(sort: \CPAPSession.date, order: .reverse)
    private var recentCPAP: [CPAPSession]
    @Query(sort: \ClinicalLabResult.effectiveDate, order: .reverse)
    private var recentLabResults: [ClinicalLabResult]

    private let barometer = BarometerService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    baselineAlert
                    anxietySection
                    healthSection
                    labResultsSection
                    cpapSection
                    barometricSection
                    medicationSection
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .task {
                await refreshSnapshot()
                sendStatsToWatch()
                await autoSync()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var baselineAlert: some View {
        if BaselineCalculator.isHRVBelowBaseline(snapshots: recentSnapshots) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HRV Below Baseline")
                        .font(.subheadline.bold())
                    Text("Your 3-day HRV average is below your 30-day baseline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var anxietySection: some View {
        if let latest = recentEntries.first {
            MetricCard(
                title: "Last Anxiety",
                value: "\(latest.severity)/10",
                subtitle: latest.timestamp.formatted(.relative(presentation: .named)),
                color: severityColor(latest.severity)
            )
        } else {
            MetricCard(
                title: "Anxiety",
                value: "—",
                subtitle: "No entries yet",
                color: .secondary
            )
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        if let snapshot = todaySnapshot {
            if let hrv = snapshot.hrvAvg {
                let baseline = BaselineCalculator.hrvBaseline(from: recentSnapshots)
                MetricCard(
                    title: "HRV",
                    value: String(format: "%.0f ms", hrv),
                    subtitle: baselineSubtitle(value: hrv, baseline: baseline, higherIsBetter: true),
                    color: baselineColor(value: hrv, baseline: baseline, higherIsBetter: true)
                )
            }
            if let rhr = snapshot.restingHR {
                let baseline = BaselineCalculator.restingHRBaseline(from: recentSnapshots)
                MetricCard(
                    title: "Resting HR",
                    value: String(format: "%.0f bpm", rhr),
                    subtitle: baselineSubtitle(value: rhr, baseline: baseline, higherIsBetter: false),
                    color: baselineColor(value: rhr, baseline: baseline, higherIsBetter: false)
                )
            }
            if let sleep = snapshot.sleepDurationMin {
                let hours = sleep / 60
                let mins = sleep % 60
                MetricCard(
                    title: "Sleep",
                    value: "\(hours)h \(mins)m",
                    subtitle: sleepBreakdown(snapshot),
                    color: sleepColor(minutes: sleep)
                )
            }
            if let steps = snapshot.steps {
                MetricCard(
                    title: "Steps",
                    value: "\(steps.formatted())",
                    subtitle: "Today",
                    color: stepsColor(steps)
                )
            }
        }
    }

    @ViewBuilder
    private var cpapSection: some View {
        if let lastSession = recentCPAP.first {
            MetricCard(
                title: "Last CPAP",
                value: String(format: "AHI %.1f", lastSession.ahi),
                subtitle: String(format: "%dh %dm — %@",
                    lastSession.totalUsageMinutes / 60,
                    lastSession.totalUsageMinutes % 60,
                    lastSession.date.formatted(.dateTime.month().day())),
                color: lastSession.ahi < 5 ? .green : lastSession.ahi < 15 ? .yellow : .orange
            )
        }
    }

    @ViewBuilder
    private var barometricSection: some View {
        if let pressure = barometer.currentPressureKPa {
            MetricCard(
                title: "Barometric Pressure",
                value: String(format: "%.1f kPa", pressure),
                subtitle: "Current",
                color: .gray
            )
        }
    }

    @ViewBuilder
    private var medicationSection: some View {
        if let lastDose = recentDoses.first {
            MetricCard(
                title: "Last Medication",
                value: lastDose.medicationName,
                subtitle: String(format: "%.0fmg — %@", lastDose.doseMg,
                    lastDose.timestamp.formatted(.relative(presentation: .named))),
                color: .green
            )
        }
    }

    @ViewBuilder
    private var labResultsSection: some View {
        let latestPerTest = latestLabResultPerTest
        if !latestPerTest.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink {
                    LabResultsView()
                } label: {
                    HStack {
                        Text("Lab Results")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                ForEach(latestPerTest, id: \.loincCode) { result in
                    if let def = LabTestRegistry.definition(for: result.loincCode) {
                        LabResultMetricCard(
                            testName: def.shortName,
                            value: result.value,
                            unit: result.unit,
                            normalRangeLow: result.referenceRangeLow ?? def.normalRangeLow,
                            normalRangeHigh: result.referenceRangeHigh ?? def.normalRangeHigh
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Returns the most recent lab result for each unique test from the last 7 days, limited to 4 for dashboard space.
    private var latestLabResultPerTest: [ClinicalLabResult] {
        let calendar = Calendar.current
        let weekAgoBase = calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
        let oneWeekAgo = calendar.startOfDay(for: weekAgoBase)
        var seen = Set<String>()
        var results: [ClinicalLabResult] = []
        for result in recentLabResults {
            // Sorted descending by effectiveDate — once we hit an older result, we're done
            if result.effectiveDate < oneWeekAgo { break }
            guard LabTestRegistry.isTracked(result.loincCode),
                  !seen.contains(result.loincCode) else { continue }
            seen.insert(result.loincCode)
            results.append(result)
            if results.count >= 4 { break }
        }
        return results
    }

    private var todaySnapshot: HealthSnapshot? {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return recentSnapshots.first { $0.date == startOfDay }
    }

    private func refreshSnapshot() async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: modelContext
        )
        try? await aggregator.aggregateDay(.now)
    }

    private func sleepBreakdown(_ snapshot: HealthSnapshot) -> String {
        var parts: [String] = []
        if let deep = snapshot.sleepDeepMin { parts.append("Deep \(deep)m") }
        if let rem = snapshot.sleepREMMin { parts.append("REM \(rem)m") }
        if let core = snapshot.sleepCoreMin { parts.append("Core \(core)m") }
        return parts.isEmpty ? "Last night" : parts.joined(separator: " · ")
    }

    private func autoSync() async {
        let sync = SyncService.shared
        guard sync.autoSyncEnabled, sync.isConfigured else { return }
        await sync.sync(modelContext: modelContext)
    }

    private func sendStatsToWatch() {
        PhoneConnectivityManager.shared.sendStatsToWatch(
            lastAnxiety: recentEntries.first?.severity,
            hrvAvg: todaySnapshot?.hrvAvg,
            restingHR: todaySnapshot?.restingHR
        )
    }

    private func severityColor(_ severity: Int) -> Color {
        switch severity {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }

    /// Color a metric based on personal baseline deviation.
    /// - `higherIsBetter`: true for HRV (higher = calmer), false for RHR (lower = calmer)
    private func baselineColor(
        value: Double,
        baseline: BaselineCalculator.BaselineResult?,
        higherIsBetter: Bool
    ) -> Color {
        guard let baseline else {
            // No baseline yet — fall back to neutral
            return .primary
        }
        if higherIsBetter {
            // HRV: above mean = good, below lower bound = bad
            if value >= baseline.mean { return .green }
            if value >= baseline.lowerBound { return .yellow }
            return .red
        } else {
            // RHR: below mean = good, above upper bound = bad
            if value <= baseline.mean { return .green }
            if value <= baseline.upperBound { return .yellow }
            return .red
        }
    }

    private func baselineSubtitle(
        value: Double,
        baseline: BaselineCalculator.BaselineResult?,
        higherIsBetter: Bool
    ) -> String {
        guard let baseline else { return "Today" }
        let diff = value - baseline.mean
        let direction = diff >= 0 ? "above" : "below"
        return String(format: "%.0f %@ avg", abs(diff), direction)
    }

    private func sleepColor(minutes: Int) -> Color {
        switch minutes {
        case 420...: return .green      // 7+ hours
        case 360..<420: return .yellow  // 6–7 hours
        default: return .red            // <6 hours
        }
    }

    private func stepsColor(_ steps: Int) -> Color {
        switch steps {
        case 8000...: return .green
        case 5000..<8000: return .yellow
        default: return .red
        }
    }
}

// MARK: - MetricCard

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }
}
