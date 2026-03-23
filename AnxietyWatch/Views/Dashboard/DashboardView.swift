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
                barometer.startMonitoring()
                saveBarometricReading()
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
                MetricCard(
                    title: "HRV",
                    value: String(format: "%.0f ms", hrv),
                    subtitle: "Today's average",
                    color: .blue
                )
            }
            if let rhr = snapshot.restingHR {
                MetricCard(
                    title: "Resting HR",
                    value: String(format: "%.0f bpm", rhr),
                    subtitle: "Today",
                    color: .red
                )
            }
            if let sleep = snapshot.sleepDurationMin {
                let hours = sleep / 60
                let mins = sleep % 60
                MetricCard(
                    title: "Sleep",
                    value: "\(hours)h \(mins)m",
                    subtitle: sleepBreakdown(snapshot),
                    color: .purple
                )
            }
            if let steps = snapshot.steps {
                MetricCard(
                    title: "Steps",
                    value: "\(steps.formatted())",
                    subtitle: "Today",
                    color: .orange
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
        let oneWeekAgo = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        )
        var seen = Set<String>()
        var results: [ClinicalLabResult] = []
        for result in recentLabResults {
            guard result.effectiveDate >= oneWeekAgo,
                  LabTestRegistry.isTracked(result.loincCode),
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

    private func saveBarometricReading() {
        guard let pressure = barometer.currentPressureKPa else { return }
        let reading = BarometricReading(
            pressureKPa: pressure,
            relativeAltitudeM: barometer.currentRelativeAltitude ?? 0
        )
        modelContext.insert(reading)
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
