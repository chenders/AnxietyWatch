import SwiftUI
import SwiftData
import HealthKit

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
    @Query(sort: \Prescription.dateFilled, order: .reverse)
    private var prescriptions: [Prescription]
    /// Manually fetched instead of @Query to avoid re-rendering on every
    /// HealthSample insert (13 anchored queries can fire hundreds of inserts on launch).
    @State private var samplesByType: [String: [HealthSample]] = [:]
    @State private var lowSupplyCount = 0
    @State private var hrvBaseline: BaselineCalculator.BaselineResult?
    @State private var rhrBaseline: BaselineCalculator.BaselineResult?

    private let barometer = BarometerService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    baselineAlert(hrvBaseline: hrvBaseline)
                    supplyAlertCard
                    anxietySection
                    healthSection(hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline)
                    labResultsSection
                    cpapSection
                    barometricSection
                    medicationSection
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .task {
                loadSamples()
                computeSupplyAlerts()
                await refreshSnapshot()
                computeBaselines()
                sendStatsToWatch()
                await autoSync()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func baselineAlert(hrvBaseline: BaselineCalculator.BaselineResult?) -> some View {
        if let baseline = hrvBaseline,
           let recent = BaselineCalculator.recentAverage(from: recentSnapshots, days: 3, keyPath: \.hrvAvg),
           recent < baseline.lowerBound {
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
    private var supplyAlertCard: some View {
        if lowSupplyCount > 0 {
            let lowCount = lowSupplyCount
            HStack(spacing: 8) {
                Image(systemName: "pills.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(lowCount) Prescription\(lowCount == 1 ? "" : "s") Running Low")
                        .font(.subheadline.bold())
                    Text("Check the Medications tab for details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(.red.opacity(0.1), in: .rect(cornerRadius: 12))
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
    private func healthSection(
        hrvBaseline: BaselineCalculator.BaselineResult?,
        rhrBaseline: BaselineCalculator.BaselineResult?
    ) -> some View {
        // Heart Rate — sparkline
        let hrType = HKQuantityTypeIdentifier.heartRate.rawValue
        if let latest = latestSample(for: hrType) {
            LiveMetricCard(
                title: "Heart Rate",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: trend(for: hrType),
                freshness: freshnessLabel(latest.timestamp),
                color: .red,
                visualization: .sparkline(
                    segments: sparklineSegments(for: hrType),
                    color: .red
                )
            )
        }

        // HRV — sparkline
        let hrvType = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        if let latest = latestSample(for: hrvType) {
            LiveMetricCard(
                title: "HRV",
                value: String(format: "%.0f", latest.value),
                unitLabel: "ms",
                trend: trend(for: hrvType),
                freshness: freshnessLabel(latest.timestamp),
                color: baselineColor(value: latest.value, baseline: hrvBaseline, higherIsBetter: true),
                visualization: .sparkline(
                    segments: sparklineSegments(for: hrvType),
                    color: .blue
                )
            )
        }

        // Resting HR — recent bars (usually 1/day)
        let rhrType = HKQuantityTypeIdentifier.restingHeartRate.rawValue
        if let latest = latestSample(for: rhrType) {
            LiveMetricCard(
                title: "Resting HR",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: trend(for: rhrType),
                freshness: freshnessLabel(latest.timestamp),
                color: baselineColor(value: latest.value, baseline: rhrBaseline, higherIsBetter: false),
                visualization: .recentBars(values: recentValues(for: rhrType), color: .red)
            )
        }

        // SpO2 — sparkline (sleep cluster)
        let spo2Type = HKQuantityTypeIdentifier.oxygenSaturation.rawValue
        if let latest = latestSample(for: spo2Type) {
            LiveMetricCard(
                title: "Blood Oxygen",
                value: String(format: "%.0f", latest.value * 100),
                unitLabel: "%",
                trend: trend(for: spo2Type),
                freshness: freshnessLabel(latest.timestamp),
                color: .green,
                visualization: .sparkline(
                    segments: sparklineSegments(for: spo2Type),
                    color: .green
                )
            )
        }

        // Respiratory Rate — sparkline (sleep cluster)
        let rrType = HKQuantityTypeIdentifier.respiratoryRate.rawValue
        if let latest = latestSample(for: rrType) {
            LiveMetricCard(
                title: "Respiratory Rate",
                value: String(format: "%.0f", latest.value),
                unitLabel: "breaths/min",
                trend: trend(for: rrType),
                freshness: freshnessLabel(latest.timestamp),
                color: .mint,
                visualization: .sparkline(
                    segments: sparklineSegments(for: rrType),
                    color: .mint
                )
            )
        }

        // VO2 Max — recent bars
        let vo2Type = HKQuantityTypeIdentifier.vo2Max.rawValue
        if let latest = latestSample(for: vo2Type) {
            LiveMetricCard(
                title: "VO₂ Max",
                value: String(format: "%.1f", latest.value),
                unitLabel: "mL/kg/min",
                trend: trend(for: vo2Type),
                freshness: freshnessLabel(latest.timestamp),
                color: .indigo,
                visualization: .recentBars(values: recentValues(for: vo2Type), color: .indigo)
            )
        }

        // Walking HR — recent bars
        let walkHRType = HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue
        if let latest = latestSample(for: walkHRType) {
            LiveMetricCard(
                title: "Walking HR",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: trend(for: walkHRType),
                freshness: freshnessLabel(latest.timestamp),
                color: .orange,
                visualization: .recentBars(values: recentValues(for: walkHRType), color: .orange)
            )
        }

        // Walking Steadiness — recent bars
        let steadyType = HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue
        if let latest = latestSample(for: steadyType) {
            LiveMetricCard(
                title: "Walking Steadiness",
                value: String(format: "%.0f", latest.value * 100),
                unitLabel: "%",
                trend: trend(for: steadyType),
                freshness: freshnessLabel(latest.timestamp),
                color: .cyan,
                visualization: .recentBars(values: recentValues(for: steadyType), color: .cyan)
            )
        }

        // AFib Burden — from daily snapshot (single value per day)
        if let (snapshot, isToday) = lastSnapshotWith(\.atrialFibrillationBurden) {
            let burden = snapshot.atrialFibrillationBurden!
            LiveMetricCard(
                title: "AFib Burden",
                value: String(format: "%.1f", burden * 100),
                unitLabel: "%",
                trend: nil,
                freshness: isToday ? "today" : staleLabel(snapshot.date),
                color: burden < 0.01 ? .green : .orange,
                visualization: .none
            )
        }

        // Sleep — stage breakdown (from HealthSnapshot, not sample cache)
        if let (snapshot, isToday) = lastSnapshotWith(\.sleepDurationMin) {
            let sleep = snapshot.sleepDurationMin!
            let hours = sleep / 60
            let mins = sleep % 60
            LiveMetricCard(
                title: "Sleep",
                value: "\(hours)h \(mins)m",
                unitLabel: "",
                trend: nil,
                freshness: isToday ? "last night" : staleLabel(snapshot.date),
                color: isToday ? sleepColor(minutes: sleep) : .secondary,
                visualization: .sleepStages(
                    deep: snapshot.sleepDeepMin ?? 0,
                    rem: snapshot.sleepREMMin ?? 0,
                    core: snapshot.sleepCoreMin ?? 0,
                    awake: snapshot.sleepAwakeMin ?? 0
                )
            )
        }

        // Steps — progress bar (from HealthSnapshot)
        if let (snapshot, isToday) = lastSnapshotWith(\.steps) {
            let steps = snapshot.steps!
            LiveMetricCard(
                title: "Steps",
                value: steps.formatted(),
                unitLabel: "",
                trend: nil,
                freshness: isToday ? "today" : staleLabel(snapshot.date),
                color: isToday ? stepsColor(steps) : .secondary,
                visualization: .progressBar(current: Double(steps), goal: 8000, color: stepsColor(steps))
            )
        }

        // Active Calories — progress bar (from HealthSnapshot)
        if let (snapshot, isToday) = lastSnapshotWith(\.activeCalories) {
            let cals = snapshot.activeCalories!
            LiveMetricCard(
                title: "Active Calories",
                value: String(format: "%.0f", cals),
                unitLabel: "kcal",
                trend: nil,
                freshness: isToday ? "today" : staleLabel(snapshot.date),
                color: isToday ? .orange : .secondary,
                visualization: .progressBar(current: cals, goal: 500, color: .orange)
            )
        }

        // Exercise — progress bar (from HealthSnapshot)
        if let (snapshot, isToday) = lastSnapshotWith(\.exerciseMinutes) {
            let mins = snapshot.exerciseMinutes!
            LiveMetricCard(
                title: "Exercise",
                value: "\(mins)",
                unitLabel: "min",
                trend: nil,
                freshness: isToday ? "today" : staleLabel(snapshot.date),
                color: isToday ? .green : .secondary,
                visualization: .progressBar(current: Double(mins), goal: 30, color: .green)
            )
        }

        // Environmental Sound — sparkline
        let envType = HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue
        if let latest = latestSample(for: envType) {
            LiveMetricCard(
                title: "Env. Sound",
                value: String(format: "%.0f", latest.value),
                unitLabel: "dBA",
                trend: trend(for: envType),
                freshness: freshnessLabel(latest.timestamp),
                color: .gray,
                visualization: .sparkline(
                    segments: sparklineSegments(for: envType),
                    color: .gray
                )
            )
        }

        // Headphone Audio — sparkline
        let headType = HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue
        if let latest = latestSample(for: headType) {
            LiveMetricCard(
                title: "Headphone Audio",
                value: String(format: "%.0f", latest.value),
                unitLabel: "dBA",
                trend: trend(for: headType),
                freshness: freshnessLabel(latest.timestamp),
                color: .teal,
                visualization: .sparkline(
                    segments: sparklineSegments(for: headType),
                    color: .teal
                )
            )
        }

        // Blood Pressure — latest value only
        let bpSysType = HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
        let bpDiaType = HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue
        if let sys = latestSample(for: bpSysType),
           let dia = latestSample(for: bpDiaType) {
            LiveMetricCard(
                title: "Blood Pressure",
                value: "\(String(format: "%.0f", sys.value))/\(String(format: "%.0f", dia.value))",
                unitLabel: "mmHg",
                trend: nil,
                freshness: freshnessLabel(sys.timestamp),
                color: .pink,
                visualization: .none
            )
        }

        // Blood Glucose — sparkline if dense, value only if sparse
        let bgType = HKQuantityTypeIdentifier.bloodGlucose.rawValue
        if let latest = latestSample(for: bgType) {
            let todayCount = todaySamples(for: bgType).count
            LiveMetricCard(
                title: "Blood Glucose",
                value: String(format: "%.0f", latest.value),
                unitLabel: "mg/dL",
                trend: trend(for: bgType),
                freshness: freshnessLabel(latest.timestamp),
                color: .purple,
                visualization: todayCount >= 3
                    ? .sparkline(segments: sparklineSegments(for: bgType), color: .purple)
                    : .none
            )
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
                color: .secondary
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

    /// Returns the most recent snapshot that has a non-nil value for the given key path,
    /// along with a Bool indicating whether the snapshot is from today.
    private func lastSnapshotWith<T>(_ keyPath: KeyPath<HealthSnapshot, T?>) -> (HealthSnapshot, Bool)? {
        guard let snapshot = recentSnapshots.first(where: { $0[keyPath: keyPath] != nil }) else {
            return nil
        }
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let isToday = snapshot.date == startOfDay
        return (snapshot, isToday)
    }

    /// A human-readable label for a stale snapshot date.
    private func staleLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month().day())
    }

    /// Compute HRV and resting HR baselines from recent snapshots.
    /// Called once on appear (after refreshSnapshot), not on every render.
    private func computeBaselines() {
        hrvBaseline = BaselineCalculator.hrvBaseline(from: recentSnapshots)
        rhrBaseline = BaselineCalculator.restingHRBaseline(from: recentSnapshots)
    }

    /// Compute supply alert count once, not on every render.
    private func computeSupplyAlerts() {
        let calendar = Calendar.current
        let now = Date.now
        lowSupplyCount = prescriptions.filter { rx in
            let fillDate = rx.lastFillDate ?? rx.dateFilled
            let stalenessLimit = PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx)
            let cutoff = calendar.date(byAdding: .day, value: -stalenessLimit, to: now)
            if let cutoff, fillDate < cutoff { return false }
            if rx.medication?.isActive == false { return false }
            let status = PrescriptionSupplyCalculator.supplyStatus(for: rx)
            return status == .low || status == .warning || status == .expired
        }.count
    }

    private func loadSamples() {
        let descriptor = FetchDescriptor<HealthSample>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        samplesByType = Dictionary(grouping: samples, by: \.type)
    }

    /// Get today's samples for a given HealthKit type identifier.
    private func todaySamples(for typeRawValue: String) -> [HealthSample] {
        let midnight = Calendar.current.startOfDay(for: .now)
        return (samplesByType[typeRawValue] ?? []).filter { $0.timestamp >= midnight }
    }

    /// Get the most recent sample for a given type (any day in the cache).
    private func latestSample(for typeRawValue: String) -> HealthSample? {
        samplesByType[typeRawValue]?.first
    }

    /// Get the last N values for a given type (for RecentBarsView).
    private func recentValues(for typeRawValue: String, count: Int = 7) -> [Double] {
        let samples = (samplesByType[typeRawValue] ?? []).prefix(count)
        return samples.reversed().map(\.value)
    }

    /// Build sparkline segments for a given type using today's samples.
    private func sparklineSegments(for typeRawValue: String) -> [[SparklinePoint]] {
        let samples = todaySamples(for: typeRawValue)
        let midnight = Calendar.current.startOfDay(for: .now)
        return SparklineData.segments(from: samples, midnight: midnight, now: .now)
    }

    /// Freshness label for a sample timestamp.
    private func freshnessLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: .now)
        if date >= midnight {
            return date.formatted(.relative(presentation: .named))
        }
        // Only say "last night" for overnight readings (6 PM or later)
        let hour = calendar.component(.hour, from: date)
        if let yesterdayMidnight = calendar.date(byAdding: .day, value: -1, to: midnight),
           date >= yesterdayMidnight && date < midnight && hour >= 18 {
            return "last night"
        }
        return date.formatted(.relative(presentation: .named))
    }

    /// Compute trend direction for a given type.
    private func trend(for typeRawValue: String) -> TrendCalculator.Direction? {
        let config = SampleTypeConfig.config(for: typeRawValue)
        let samples = todaySamples(for: typeRawValue)
        return TrendCalculator.direction(
            samples: samples,
            threshold: config?.trendThreshold ?? 3
        )
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
    /// Green = normal or better, yellow = slightly off, red = significantly off.
    /// - `higherIsBetter`: true for HRV (higher = calmer), false for RHR (lower = calmer)
    private func baselineColor(
        value: Double,
        baseline: BaselineCalculator.BaselineResult?,
        higherIsBetter: Bool
    ) -> Color {
        guard let baseline else { return .primary }

        if higherIsBetter {
            // HRV: higher is better, worry when it drops
            if value >= baseline.lowerBound { return .green }  // within or above normal
            if value >= baseline.lowerBound - baseline.standardDeviation { return .yellow }  // slightly low
            return .red  // significantly low
        } else {
            // RHR: lower is better, worry when it rises
            if value <= baseline.upperBound { return .green }  // within or below normal
            if value <= baseline.upperBound + baseline.standardDeviation { return .yellow }  // slightly high
            return .red  // significantly high
        }
    }

    private func baselineSubtitle(
        value: Double,
        baseline: BaselineCalculator.BaselineResult?
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
