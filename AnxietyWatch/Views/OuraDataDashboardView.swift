// swiftlint:disable line_length
import SwiftUI
import AnxietyWatchKit

/// Complete, read-only presentation of the Oura metrics consumed by Anxiety Watch.
/// Values are normalized into a display snapshot so the same UI works with API
/// responses and deterministic simulator data.
struct OuraDataDashboardView: View {
    let service: OuraService

    @State private var snapshot: Snapshot?
    @State private var isRefreshing = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if let snapshot {
                    provenanceHeader(snapshot)
                    scoreSection(snapshot)
                    sleepSection(snapshot)
                    recoverySection(snapshot)
                    stressSection(snapshot)
                    activitySection(snapshot)
                    respiratorySection(snapshot)
                    cardiovascularSection(snapshot)
                    liveSection(snapshot)
                } else {
                    ProgressView("Loading Oura data…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                }
            }
            .padding()
        }
#if DEBUG
        .demoAutoScroll("oura", stops: 4, initialDelay: .seconds(4), pause: .seconds(2.5), step: 500)
#endif
        .navigationTitle("Oura Ring Data")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func provenanceHeader(_ s: Snapshot) -> some View {
        HStack(spacing: 10) {
            Label("Oura Cloud", systemImage: "checkmark.icloud.fill")
                .foregroundStyle(.cyan)
            Spacer()
#if targetEnvironment(simulator)
            Label("Demo Data", systemImage: "sparkles")
                .foregroundStyle(.yellow)
#endif
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func scoreSection(_ s: Snapshot) -> some View {
        card("Daily Oura Scores", icon: "circle.hexagongrid.fill", tint: .cyan) {
            HStack(spacing: 12) {
                score("Readiness", s.readiness, .teal)
                score("Sleep", s.sleepScore, .indigo)
                score("Activity", s.activityScore, .orange)
            }
            Text("Oura scores are wellness summaries, not medical assessments.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func sleepSection(_ s: Snapshot) -> some View {
        card("Sleep", icon: "moon.stars.fill", tint: .indigo) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TOTAL SLEEP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(s.totalSleep).font(.largeTitle.bold().monospacedDigit()).foregroundStyle(.indigo)
                }
                Spacer()
                metric(("Efficiency", "\(s.sleepEfficiency)%"), tint: .indigo)
            }
            sleepStageBar(s)
            stageLegend(s)
            Divider()
            metricGrid([
                ("Time in Bed", s.timeInBed), ("Latency", "\(s.sleepLatency) min"),
                ("Awake", s.awakeTime), ("Avg Sleep HR", "\(s.sleepHR) bpm"),
                ("Avg HRV", "\(s.sleepHRV) ms"), ("Respiratory Rate", String(format: "%.1f/min", s.respiratoryRate))
            ], tint: .indigo)
        }
    }

    private func recoverySection(_ s: Snapshot) -> some View {
        card("Recovery & Resilience", icon: "battery.75percent", tint: .teal) {
            HStack {
                metric(("Oura Classification", s.resilience.capitalized), tint: .teal)
                Spacer()
                metric(("From Personal Baseline", String(format: "%+.1f °C", s.temperatureDeviation)), tint: s.temperatureDeviation < 0 ? .blue : .orange)
            }
            contributorBar("Sleep recovery", s.sleepRecovery, .indigo)
            contributorBar("Daytime recovery", s.daytimeRecovery, .cyan)
            contributorBar("Stress contributor", s.stressBalance, .teal)
        }
    }

    private func stressSection(_ s: Snapshot) -> some View {
        card("Daytime Stress", icon: "waveform.path.ecg", tint: .orange) {
            durationBar("High stress", minutes: s.stressHigh, maximum: max(s.stressHigh, s.recoveryHigh), color: .orange)
            durationBar("Restorative time", minutes: s.recoveryHigh, maximum: max(s.stressHigh, s.recoveryHigh), color: .teal)
            Label(s.stressSummary, systemImage: "quote.opening")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityLabel("Oura summary: \(s.stressSummary)")
        }
    }

    private func activitySection(_ s: Snapshot) -> some View {
        card("Activity", icon: "figure.walk", tint: .orange) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.steps.formatted()).font(.largeTitle.bold().monospacedDigit()).foregroundStyle(.orange)
                Text("steps").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                metric(("MET", String(format: "%.1f", s.met)), tint: .orange)
            }
            metricGrid([
                ("Active Calories", "\(s.activeCalories) kcal"), ("Walking", "\(s.walkingMinutes) min"),
                ("Training", "\(s.trainingMinutes) min"), ("Inactivity", "\(s.inactiveMinutes) min")
            ], tint: .orange)
        }
    }

    private func respiratorySection(_ s: Snapshot) -> some View {
        card("Breathing & Blood Oxygen", icon: "lungs.fill", tint: .cyan) {
            HStack(spacing: 12) {
                featuredMetric("Average SpO₂", String(format: "%.1f%%", s.spo2), .cyan)
                featuredMetric("Respiratory Rate", String(format: "%.1f/min", s.respiratoryRate), .blue)
            }
            metricGrid([
                ("Breathing Disturbance Index", String(format: "%.1f", s.breathingDisturbance)),
                ("Lowest SpO₂", String(format: "%.0f%%", s.lowestSpO2))
            ], tint: .cyan)
            Text("Ring measurements may be affected by fit, motion, circulation, and signal quality.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func cardiovascularSection(_ s: Snapshot) -> some View {
        card("Cardiovascular Estimates", icon: "heart.fill", tint: .pink) {
            HStack(spacing: 12) {
                featuredMetric("Cardiovascular Age", String(format: "%.0f years", s.vascularAge), .pink)
                featuredMetric("VO₂ Max", String(format: "%.1f", s.vo2Max), .purple, unit: "mL/kg/min")
            }
            metricGrid([
                ("Pulse Wave Velocity", String(format: "%.1f m/s", s.pulseWaveVelocity)),
                ("Average Sleep HR", "\(s.restingHR) bpm")
            ], tint: .pink)
            Text("Oura estimates; not a diagnosis.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func liveSection(_ s: Snapshot) -> some View {
        card("Device & Live Signal", icon: "dot.radiowaves.left.and.right", tint: .mint) {
            HStack {
                Label(s.ringConnection, systemImage: "checkmark.circle.fill").foregroundStyle(.mint)
                Spacer()
                Label("\(s.battery)%", systemImage: "battery.75percent").foregroundStyle(.secondary)
            }.font(.subheadline.weight(.semibold))
            metricGrid([
                ("Heart Rate", "\(s.liveHR) bpm"), ("Interbeat Interval", "\(s.ibi) ms"),
                ("Signal Quality", s.signalQuality), ("Last Update", s.lastUpdate)
            ], tint: .mint)
            Text("Bluetooth live signal is separate from daily Oura Cloud summaries.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(_ title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.25), lineWidth: 1) }
    }

    private func score(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 7)
                Circle().trim(from: 0, to: Double(value) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(value)").font(.title3.bold().monospacedDigit())
            }.frame(width: 68, height: 68)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func metricGrid(_ values: [(String, String)], tint: Color) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                ForEach(values.indices, id: \.self) { metric(values[$0], tint: tint) }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: values.count, by: 2)), id: \.self) { index in
                    GridRow {
                        metric(values[index], tint: tint)
                        if index + 1 < values.count { metric(values[index + 1], tint: tint) }
                        else { Color.clear }
                    }
                }
            }
        }
    }

    private func metric(_ value: (String, String), tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.0).font(.footnote).foregroundStyle(.secondary)
            Text(value.1).font(.subheadline.weight(.semibold)).foregroundStyle(tint).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func featuredMetric(_ label: String, _ value: String, _ color: Color, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(color)
            if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func contributorBar(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 5) {
            HStack { Text(label); Spacer(); Text("\(value)/100").monospacedDigit() }
                .font(.footnote.weight(.semibold))
            ProgressView(value: Double(value), total: 100).tint(color)
        }
        .accessibilityElement(children: .combine)
    }

    private func durationBar(_ label: String, minutes: Int, maximum: Int, color: Color) -> some View {
        VStack(spacing: 5) {
            HStack { Text(label); Spacer(); Text("\(minutes) min").monospacedDigit() }
                .font(.footnote.weight(.semibold))
            ProgressView(value: Double(minutes), total: Double(max(1, maximum))).tint(color)
        }
        .accessibilityElement(children: .combine)
    }

    private func sleepStageBar(_ s: Snapshot) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                stageSegment(weight: 84, color: .indigo, width: proxy.size.width)
                stageSegment(weight: 112, color: .purple, width: proxy.size.width)
                stageSegment(weight: 266, color: .blue, width: proxy.size.width)
                stageSegment(weight: 29, color: .gray, width: proxy.size.width)
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .accessibilityLabel("Sleep stages: deep \(s.deepSleep), REM \(s.remSleep), light \(s.lightSleep), awake \(s.awakeTime)")
    }

    private func stageSegment(weight: CGFloat, color: Color, width: CGFloat) -> some View {
        color.frame(width: max(2, width * weight / 491))
    }

    private func stageLegend(_ s: Snapshot) -> some View {
        HStack(spacing: 10) {
            stageKey("Deep", s.deepSleep, .indigo)
            stageKey("REM", s.remSleep, .purple)
            stageKey("Light", s.lightSleep, .blue)
        }
    }

    private func stageKey(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.semibold)).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func load() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
#if targetEnvironment(simulator)
        snapshot = .demo
#else
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
        async let sleep = service.fetchSleepDetail(startDate: start, endDate: end)
        async let readiness = service.fetchReadiness(startDate: start, endDate: end)
        async let stress = service.fetchStress(startDate: start, endDate: end)
        async let resilience = service.fetchResilience(startDate: start, endDate: end)
        async let all = service.fetchAllNewData(startDate: start, endDate: end)
        snapshot = Snapshot(
            sleep: await sleep, readiness: await readiness, stress: await stress,
            resilience: await resilience, newData: await all
        )
#endif
    }
}

private struct Snapshot {
    var readiness = 84, sleepScore = 88, activityScore = 79
    var totalSleep = "7h 42m", timeInBed = "8h 11m", sleepEfficiency = 94, sleepLatency = 12
    var deepSleep = "1h 24m", remSleep = "1h 52m", lightSleep = "4h 26m", awakeTime = "29 min"
    var sleepHR = 57, sleepHRV = 48
    var resilience = "strong", temperatureDeviation = -0.1, sleepRecovery = 86, daytimeRecovery = 74
    var stressBalance = 78, hrvBalance = "Optimal", stressHigh = 76, recoveryHigh = 128
    var stressSummary = "Balanced day with sustained restorative time in the afternoon."
    var steps = 8_432, activeCalories = 487, walkingMinutes = 74, trainingMinutes = 32
    var met = 1.7, inactiveMinutes = 421
    var spo2 = 97.2, breathingDisturbance = 1.4, respiratoryRate = 14.1, lowestSpO2 = 93.0
    var vascularAge = 34.0, pulseWaveVelocity = 6.4, vo2Max = 42.6, restingHR = 58
    var ringConnection = "Connected", battery = 82, liveHR = 72, ibi = 833
    var signalQuality = "Good", lastUpdate = "Just now"

    static let demo = Snapshot()

    init() {}

    init(
        sleep: [OuraSleepDetailData], readiness: [OuraReadinessData],
        stress: [OuraStressData], resilience: [OuraResilienceData],
        newData: (
            cardiovascularAge: [OuraCardiovascularAgeData], vo2Max: [OuraVO2MaxData],
            sleepDetail: [OuraSleepDetailData], dailySpO2: [OuraDailySpO2Data],
            dailyActivity: [OuraDailyActivityData]
        )
    ) {
        self.init()
        if let v = readiness.last { self.readiness = v.score ?? self.readiness; temperatureDeviation = v.temperatureDeviation ?? temperatureDeviation }
        if let v = sleep.last ?? newData.sleepDetail.last {
            sleepScore = v.score ?? sleepScore; sleepEfficiency = v.efficiency ?? sleepEfficiency
            sleepHR = Int(v.averageHeartRate ?? Double(sleepHR)); sleepHRV = Int(v.averageHrv ?? Double(sleepHRV))
            totalSleep = Self.duration(v.totalSleepDuration); timeInBed = Self.duration(v.timeInBed)
            deepSleep = Self.duration(v.deepSleepDuration); remSleep = Self.duration(v.remSleepDuration)
            lightSleep = Self.duration(v.lightSleepDuration); awakeTime = Self.duration(v.awakeTime)
            sleepLatency = (v.latency ?? sleepLatency * 60) / 60
            respiratoryRate = v.respiratoryRate ?? respiratoryRate
        }
        if let v = stress.last { stressHigh = v.stressHigh ?? stressHigh; recoveryHigh = v.recoveryHigh ?? recoveryHigh; stressSummary = v.daySummary ?? stressSummary }
        if let v = resilience.last {
            self.resilience = v.level; sleepRecovery = v.contributors?.sleepRecovery ?? sleepRecovery
            daytimeRecovery = v.contributors?.daytimeRecovery ?? daytimeRecovery; stressBalance = v.contributors?.stress ?? stressBalance
        }
        if let v = newData.dailySpO2.last { spo2 = v.averageSpO2 ?? spo2; breathingDisturbance = v.breathingDisturbanceIndex ?? breathingDisturbance }
        if let v = newData.dailyActivity.last { steps = v.steps ?? steps; met = v.met ?? met }
        if let v = newData.cardiovascularAge.last { vascularAge = v.vascularAge ?? vascularAge; pulseWaveVelocity = v.pulseWaveVelocity ?? pulseWaveVelocity }
        if let v = newData.vo2Max.last { vo2Max = v.vo2Max ?? vo2Max }
        ringConnection = "Cloud synced"; signalQuality = "Waiting for BLE"; lastUpdate = "Recently"
    }

    private static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}

// swiftlint:enable line_length
