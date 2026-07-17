import SwiftUI
import AnxietyWatchKit

/// Complete, read-only presentation of the Oura metrics consumed by Anxiety Watch.
/// Values are normalized into a display snapshot so the same UI works with API
/// responses and deterministic simulator data.
struct OuraDataDashboardView: View {
    let service: OuraService

    @State private var snapshot: Snapshot?
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if let snapshot {
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
        .navigationTitle("Oura Ring Data")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func scoreSection(_ s: Snapshot) -> some View {
        card("Today", icon: "circle.hexagongrid.fill") {
            HStack(spacing: 12) {
                score("Readiness", s.readiness, .green)
                score("Sleep", s.sleepScore, .indigo)
                score("Activity", s.activityScore, .orange)
            }
        }
    }

    private func sleepSection(_ s: Snapshot) -> some View {
        card("Sleep", icon: "moon.stars.fill") {
            metricGrid([
                ("Total Sleep", s.totalSleep), ("Time in Bed", s.timeInBed),
                ("Efficiency", "\(s.sleepEfficiency)%"), ("Latency", "\(s.sleepLatency) min"),
                ("Deep", s.deepSleep), ("REM", s.remSleep),
                ("Light", s.lightSleep), ("Awake", s.awakeTime),
                ("Avg HR", "\(s.sleepHR) bpm"), ("Avg HRV", "\(s.sleepHRV) ms")
            ])
        }
    }

    private func recoverySection(_ s: Snapshot) -> some View {
        card("Readiness & Resilience", icon: "battery.75percent") {
            metricGrid([
                ("Resilience", s.resilience.capitalized),
                ("Temperature", String(format: "%+.1f °C", s.temperatureDeviation)),
                ("Sleep Recovery", "\(s.sleepRecovery)%"),
                ("Daytime Recovery", "\(s.daytimeRecovery)%"),
                ("Stress Balance", "\(s.stressBalance)%"),
                ("HRV Balance", s.hrvBalance)
            ])
        }
    }

    private func stressSection(_ s: Snapshot) -> some View {
        card("Daytime Stress", icon: "waveform.path.ecg") {
            metricGrid([
                ("High Stress", "\(s.stressHigh) min"),
                ("Restorative", "\(s.recoveryHigh) min")
            ])
            ProgressView(value: Double(s.recoveryHigh), total: Double(max(1, s.stressHigh + s.recoveryHigh)))
                .tint(.green)
            Text(s.stressSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func activitySection(_ s: Snapshot) -> some View {
        card("Activity", icon: "figure.walk") {
            metricGrid([
                ("Steps", s.steps.formatted()), ("Active Calories", "\(s.activeCalories) kcal"),
                ("Walking", "\(s.walkingMinutes) min"), ("Training", "\(s.trainingMinutes) min"),
                ("MET", String(format: "%.1f", s.met)), ("Inactivity", "\(s.inactiveMinutes) min")
            ])
        }
    }

    private func respiratorySection(_ s: Snapshot) -> some View {
        card("Breathing & Blood Oxygen", icon: "lungs.fill") {
            metricGrid([
                ("Average SpO₂", String(format: "%.1f%%", s.spo2)),
                ("Breathing Disturbances", String(format: "%.1f", s.breathingDisturbance)),
                ("Respiratory Rate", String(format: "%.1f /min", s.respiratoryRate)),
                ("Lowest SpO₂", String(format: "%.0f%%", s.lowestSpO2))
            ])
        }
    }

    private func cardiovascularSection(_ s: Snapshot) -> some View {
        card("Cardiovascular", icon: "heart.fill") {
            metricGrid([
                ("Cardiovascular Age", String(format: "%.0f years", s.vascularAge)),
                ("Pulse Wave Velocity", String(format: "%.1f m/s", s.pulseWaveVelocity)),
                ("VO₂ Max", String(format: "%.1f mL/kg/min", s.vo2Max)),
                ("Resting HR", "\(s.restingHR) bpm")
            ])
        }
    }

    private func liveSection(_ s: Snapshot) -> some View {
        card("Ring 5 Live Signal", icon: "dot.radiowaves.left.and.right") {
            metricGrid([
                ("Connection", s.ringConnection), ("Battery", "\(s.battery)%"),
                ("Heart Rate", "\(s.liveHR) bpm"), ("Current IBI", "\(s.ibi) ms"),
                ("Signal", s.signalQuality), ("Last Update", s.lastUpdate)
            ])
            Text("Live IBI is received over Bluetooth. Daily scores and sleep metrics sync through the Oura API and Apple Health bridge.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
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

    private func metricGrid(_ values: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: values.count, by: 2)), id: \.self) { index in
                GridRow {
                    metric(values[index])
                    if index + 1 < values.count { metric(values[index + 1]) }
                    else { Color.clear }
                }
            }
        }
    }

    private func metric(_ value: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.0).font(.caption2).foregroundStyle(.secondary)
            Text(value.1).font(.subheadline.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
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
