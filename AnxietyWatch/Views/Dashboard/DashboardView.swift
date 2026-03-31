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

    @State private var vm = DashboardViewModel()
    private let barometer = BarometerService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    baselineAlert
                    supplyAlertCard
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
                vm.loadSamples(from: modelContext)
                vm.computeSupplyAlerts(from: prescriptions)
                await vm.refreshSnapshot(context: modelContext)
                vm.computeBaselines(from: recentSnapshots)
                vm.sendStatsToWatch(
                    lastAnxiety: recentEntries.first?.severity,
                    todaySnapshot: vm.todaySnapshot(from: recentSnapshots)
                )
                await vm.autoSync(context: modelContext)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var baselineAlert: some View {
        if let baseline = vm.hrvBaseline,
           let recent = BaselineCalculator.recentAverage(from: recentSnapshots, days: 3, keyPath: \.hrvAvg),
           recent < baseline.lowerBound {
            baselineAlertCard(
                icon: "heart.fill",
                title: "HRV Below Baseline",
                message: "Your 3-day HRV average is below your 30-day baseline",
                color: .orange
            )
        }
        if let baseline = vm.sleepBaseline,
           let lastSleep = recentSnapshots.first?.sleepDurationMin.map(Double.init),
           lastSleep < baseline.lowerBound, baseline.mean > 0 {
            let pct = Int(((baseline.mean - lastSleep) / baseline.mean) * 100)
            baselineAlertCard(
                icon: "bed.double.fill",
                title: "Sleep Below Baseline",
                message: "Last night's sleep was \(pct)% below your 30-day average",
                color: .indigo
            )
        }
        if let baseline = vm.respiratoryBaseline,
           let lastRR = recentSnapshots.first?.respiratoryRate,
           lastRR > baseline.upperBound, baseline.mean > 0 {
            let pct = Int(((lastRR - baseline.mean) / baseline.mean) * 100)
            baselineAlertCard(
                icon: "lungs.fill",
                title: "Respiratory Rate Elevated",
                message: "Your respiratory rate is \(pct)% above your 30-day average",
                color: .teal
            )
        }
    }

    private func baselineAlertCard(icon: String, title: String, message: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(color.opacity(0.1), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var supplyAlertCard: some View {
        if vm.lowSupplyCount > 0 {
            let lowCount = vm.lowSupplyCount
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
                color: Color.severity(latest.severity)
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
        // Heart Rate — sparkline
        let hrType = HKQuantityTypeIdentifier.heartRate.rawValue
        if let latest = vm.latestSample(for: hrType) {
            LiveMetricCard(
                title: "Heart Rate",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: vm.trend(for: hrType),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .red,
                visualization: .sparkline(
                    segments: vm.sparklineSegments(for: hrType),
                    color: .red
                )
            )
        }

        // HRV — sparkline
        let hrvType = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        if let latest = vm.latestSample(for: hrvType) {
            LiveMetricCard(
                title: "HRV",
                value: String(format: "%.0f", latest.value),
                unitLabel: "ms",
                trend: vm.trend(for: hrvType),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: vm.baselineColor(value: latest.value, baseline: vm.hrvBaseline, higherIsBetter: true),
                visualization: .sparkline(
                    segments: vm.sparklineSegments(for: hrvType),
                    color: .blue
                )
            )
        }

        // Resting HR — recent bars
        let rhrType = HKQuantityTypeIdentifier.restingHeartRate.rawValue
        if let latest = vm.latestSample(for: rhrType) {
            LiveMetricCard(
                title: "Resting HR",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: vm.trend(for: rhrType),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: vm.baselineColor(value: latest.value, baseline: vm.rhrBaseline, higherIsBetter: false),
                visualization: .recentBars(values: vm.recentValues(for: rhrType), color: .red)
            )
        }

        // SpO2 — sparkline
        let spo2Type = HKQuantityTypeIdentifier.oxygenSaturation.rawValue
        if let latest = vm.latestSample(for: spo2Type) {
            LiveMetricCard(
                title: "Blood Oxygen",
                value: String(format: "%.0f", latest.value * 100),
                unitLabel: "%",
                trend: vm.trend(for: spo2Type),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .green,
                visualization: .sparkline(
                    segments: vm.sparklineSegments(for: spo2Type),
                    color: .green
                )
            )
        }

        // Respiratory Rate — sparkline
        let rrType = HKQuantityTypeIdentifier.respiratoryRate.rawValue
        if let latest = vm.latestSample(for: rrType) {
            LiveMetricCard(
                title: "Respiratory Rate",
                value: String(format: "%.0f", latest.value),
                unitLabel: "breaths/min",
                trend: vm.trend(for: rrType),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .mint,
                visualization: .sparkline(
                    segments: vm.sparklineSegments(for: rrType),
                    color: .mint
                )
            )
        }

        // VO2 Max — recent bars
        let vo2Type = HKQuantityTypeIdentifier.vo2Max.rawValue
        if let latest = vm.latestSample(for: vo2Type) {
            LiveMetricCard(
                title: "VO₂ Max",
                value: String(format: "%.1f", latest.value),
                unitLabel: "mL/kg/min",
                trend: vm.trend(for: vo2Type),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .indigo,
                visualization: .recentBars(values: vm.recentValues(for: vo2Type), color: .indigo)
            )
        }

        // Walking HR — recent bars
        let walkHRType = HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue
        if let latest = vm.latestSample(for: walkHRType) {
            LiveMetricCard(
                title: "Walking HR",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: vm.trend(for: walkHRType),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .orange,
                visualization: .recentBars(values: vm.recentValues(for: walkHRType), color: .orange)
            )
        }

        // Walking Steadiness — recent bars
        let steadyType = HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue
        if let latest = vm.latestSample(for: steadyType) {
            LiveMetricCard(
                title: "Walking Steadiness",
                value: String(format: "%.0f", latest.value * 100),
                unitLabel: "%",
                trend: vm.trend(for: steadyType),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .cyan,
                visualization: .recentBars(values: vm.recentValues(for: steadyType), color: .cyan)
            )
        }

        // AFib Burden — from daily snapshot
        if let (snapshot, isToday) = vm.lastSnapshotWith(\.atrialFibrillationBurden, from: recentSnapshots) {
            let burden = snapshot.atrialFibrillationBurden!
            LiveMetricCard(
                title: "AFib Burden",
                value: String(format: "%.1f", burden * 100),
                unitLabel: "%",
                trend: nil,
                freshness: isToday ? "today" : vm.staleLabel(snapshot.date),
                color: burden < 0.01 ? .green : .orange,
                visualization: .none
            )
        }

        // Sleep — stage breakdown
        if let (snapshot, isToday) = vm.lastSnapshotWith(\.sleepDurationMin, from: recentSnapshots) {
            let sleep = snapshot.sleepDurationMin!
            let hours = sleep / 60
            let mins = sleep % 60
            LiveMetricCard(
                title: "Sleep",
                value: "\(hours)h \(mins)m",
                unitLabel: "",
                trend: nil,
                freshness: isToday ? "last night" : vm.staleLabel(snapshot.date),
                color: isToday ? vm.sleepColor(minutes: sleep) : .secondary,
                visualization: .sleepStages(
                    deep: snapshot.sleepDeepMin ?? 0,
                    rem: snapshot.sleepREMMin ?? 0,
                    core: snapshot.sleepCoreMin ?? 0,
                    awake: snapshot.sleepAwakeMin ?? 0
                )
            )
        }

        // Steps — progress bar
        if let (snapshot, isToday) = vm.lastSnapshotWith(\.steps, from: recentSnapshots) {
            let steps = snapshot.steps!
            LiveMetricCard(
                title: "Steps",
                value: steps.formatted(),
                unitLabel: "",
                trend: nil,
                freshness: isToday ? "today" : vm.staleLabel(snapshot.date),
                color: isToday ? vm.stepsColor(steps) : .secondary,
                visualization: .progressBar(current: Double(steps), goal: 8000, color: vm.stepsColor(steps))
            )
        }

        // Active Calories — progress bar
        if let (snapshot, isToday) = vm.lastSnapshotWith(\.activeCalories, from: recentSnapshots) {
            let cals = snapshot.activeCalories!
            LiveMetricCard(
                title: "Active Calories",
                value: String(format: "%.0f", cals),
                unitLabel: "kcal",
                trend: nil,
                freshness: isToday ? "today" : vm.staleLabel(snapshot.date),
                color: isToday ? .orange : .secondary,
                visualization: .progressBar(current: cals, goal: 500, color: .orange)
            )
        }

        // Exercise — progress bar
        if let (snapshot, isToday) = vm.lastSnapshotWith(\.exerciseMinutes, from: recentSnapshots) {
            let mins = snapshot.exerciseMinutes!
            LiveMetricCard(
                title: "Exercise",
                value: "\(mins)",
                unitLabel: "min",
                trend: nil,
                freshness: isToday ? "today" : vm.staleLabel(snapshot.date),
                color: isToday ? .green : .secondary,
                visualization: .progressBar(current: Double(mins), goal: 30, color: .green)
            )
        }

        // Environmental Sound — sparkline
        let envType = HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue
        if let latest = vm.latestSample(for: envType) {
            LiveMetricCard(
                title: "Env. Sound",
                value: String(format: "%.0f", latest.value),
                unitLabel: "dBA",
                trend: vm.trend(for: envType),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .gray,
                visualization: .sparkline(
                    segments: vm.sparklineSegments(for: envType),
                    color: .gray
                )
            )
        }

        // Headphone Audio — sparkline
        let headType = HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue
        if let latest = vm.latestSample(for: headType) {
            LiveMetricCard(
                title: "Headphone Audio",
                value: String(format: "%.0f", latest.value),
                unitLabel: "dBA",
                trend: vm.trend(for: headType),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .teal,
                visualization: .sparkline(
                    segments: vm.sparklineSegments(for: headType),
                    color: .teal
                )
            )
        }

        // Blood Pressure
        let bpSysType = HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
        let bpDiaType = HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue
        if let sys = vm.latestSample(for: bpSysType),
           let dia = vm.latestSample(for: bpDiaType) {
            LiveMetricCard(
                title: "Blood Pressure",
                value: "\(String(format: "%.0f", sys.value))/\(String(format: "%.0f", dia.value))",
                unitLabel: "mmHg",
                trend: nil,
                freshness: vm.freshnessLabel(sys.timestamp),
                color: .pink,
                visualization: .none
            )
        }

        // Blood Glucose
        let bgType = HKQuantityTypeIdentifier.bloodGlucose.rawValue
        if let latest = vm.latestSample(for: bgType) {
            let todayCount = vm.todaySamples(for: bgType).count
            LiveMetricCard(
                title: "Blood Glucose",
                value: String(format: "%.0f", latest.value),
                unitLabel: "mg/dL",
                trend: vm.trend(for: bgType),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .purple,
                visualization: todayCount >= 3
                    ? .sparkline(segments: vm.sparklineSegments(for: bgType), color: .purple)
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
        let latestPerTest = vm.latestLabResultPerTest(from: recentLabResults)
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
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    DashboardView()
        .modelContainer(container)
}
#endif
