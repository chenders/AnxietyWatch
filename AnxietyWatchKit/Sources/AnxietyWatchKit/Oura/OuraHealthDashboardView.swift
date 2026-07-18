import Foundation
import SwiftUI

// MARK: - OuraHealthDashboardSnapshot

/// Immutable snapshot of Oura Ring comprehensive health metrics for a date range.
/// The app layer fetches data from `OuraService` and hands this to the view.
public struct OuraHealthDashboardSnapshot: Sendable, Equatable {
    public var days: [Day]
    public var dateRange: String

    public struct Day: Sendable, Equatable, Identifiable {
        public var id: String { date }
        public var date: String
        
        // Existing stress/resilience data
        public var stressHigh: Int?
        public var recoveryHigh: Int?
        public var stressSummary: String?
        public var resilienceLevel: String?
        public var resilienceSleepRecovery: Int?
        public var resilienceDaytimeRecovery: Int?
        public var resilienceStress: Int?
        
        // New cardiovascular metrics
        public var vascularAge: Double?
        public var pulseWaveVelocity: Double?
        
        // New fitness metrics
        public var vo2Max: Double?
        
        // New sleep details
        public var sleepHypnogram: String?
        public var sleepEfficiency: Int?
        public var sleepLatency: Int?
        public var respiratoryRate: Double?
        
        // New oxygen metrics
        public var averageSpO2: Double?
        public var breathingDisturbanceIndex: Double?
        
        // New activity metrics
        public var steps: Int?
        public var met: Double?
        
        public init(
            date: String,
            stressHigh: Int? = nil,
            recoveryHigh: Int? = nil,
            stressSummary: String? = nil,
            resilienceLevel: String? = nil,
            resilienceSleepRecovery: Int? = nil,
            resilienceDaytimeRecovery: Int? = nil,
            resilienceStress: Int? = nil,
            vascularAge: Double? = nil,
            pulseWaveVelocity: Double? = nil,
            vo2Max: Double? = nil,
            sleepHypnogram: String? = nil,
            sleepEfficiency: Int? = nil,
            sleepLatency: Int? = nil,
            respiratoryRate: Double? = nil,
            averageSpO2: Double? = nil,
            breathingDisturbanceIndex: Double? = nil,
            steps: Int? = nil,
            met: Double? = nil
        ) {
            self.date = date
            self.stressHigh = stressHigh
            self.recoveryHigh = recoveryHigh
            self.stressSummary = stressSummary
            self.resilienceLevel = resilienceLevel
            self.resilienceSleepRecovery = resilienceSleepRecovery
            self.resilienceDaytimeRecovery = resilienceDaytimeRecovery
            self.resilienceStress = resilienceStress
            self.vascularAge = vascularAge
            self.pulseWaveVelocity = pulseWaveVelocity
            self.vo2Max = vo2Max
            self.sleepHypnogram = sleepHypnogram
            self.sleepEfficiency = sleepEfficiency
            self.sleepLatency = sleepLatency
            self.respiratoryRate = respiratoryRate
            self.averageSpO2 = averageSpO2
            self.breathingDisturbanceIndex = breathingDisturbanceIndex
            self.steps = steps
            self.met = met
        }
    }

    public init(days: [Day] = [], dateRange: String = "") {
        self.days = days
        self.dateRange = dateRange
    }

    /// Build a snapshot from all Oura API responses.
    public static func build(
        stress: [OuraStressData],
        resilience: [OuraResilienceData],
        cardiovascularAge: [OuraCardiovascularAgeData],
        vo2Max: [OuraVO2MaxData],
        sleepDetail: [OuraSleepDetailData],
        dailySpO2: [OuraDailySpO2Data],
        dailyActivity: [OuraDailyActivityData],
        dateRange: String
    ) -> OuraHealthDashboardSnapshot {
        var allDates = Set<String>()
        var stressMap: [String: OuraStressData] = [:]
        var resilienceMap: [String: OuraResilienceData] = [:]
        var cardiovascularAgeMap: [String: OuraCardiovascularAgeData] = [:]
        var vo2MaxMap: [String: OuraVO2MaxData] = [:]
        var sleepDetailMap: [String: OuraSleepDetailData] = [:]
        var dailySpO2Map: [String: OuraDailySpO2Data] = [:]
        var dailyActivityMap: [String: OuraDailyActivityData] = [:]

        for s in stress {
            allDates.insert(s.day)
            stressMap[s.day] = s
        }
        for r in resilience {
            allDates.insert(r.day)
            resilienceMap[r.day] = r
        }
        for c in cardiovascularAge {
            allDates.insert(c.day)
            cardiovascularAgeMap[c.day] = c
        }
        for v in vo2Max {
            allDates.insert(v.day)
            vo2MaxMap[v.day] = v
        }
        for sd in sleepDetail {
            allDates.insert(sd.day)
            sleepDetailMap[sd.day] = sd
        }
        for ds in dailySpO2 {
            allDates.insert(ds.day)
            dailySpO2Map[ds.day] = ds
        }
        for da in dailyActivity {
            allDates.insert(da.day)
            dailyActivityMap[da.day] = da
        }

        let sorted = allDates.sorted()
        let days: [Day] = sorted.map { date in
            let s = stressMap[date]
            let r = resilienceMap[date]
            let c = cardiovascularAgeMap[date]
            let v = vo2MaxMap[date]
            let sd = sleepDetailMap[date]
            let ds = dailySpO2Map[date]
            let da = dailyActivityMap[date]
            
            return Day(
                date: date,
                stressHigh: s?.stressHigh,
                recoveryHigh: s?.recoveryHigh,
                stressSummary: s?.daySummary,
                resilienceLevel: r?.level,
                resilienceSleepRecovery: r?.contributors?.sleepRecovery,
                resilienceDaytimeRecovery: r?.contributors?.daytimeRecovery,
                resilienceStress: r?.contributors?.stress,
                vascularAge: c?.vascularAge,
                pulseWaveVelocity: c?.pulseWaveVelocity,
                vo2Max: v?.vo2Max,
                sleepHypnogram: sd?.hypnogram,
                sleepEfficiency: sd?.efficiency,
                sleepLatency: sd?.latency,
                respiratoryRate: sd?.respiratoryRate,
                averageSpO2: ds?.averageSpO2,
                breathingDisturbanceIndex: ds?.breathingDisturbanceIndex,
                steps: da?.steps,
                met: da?.met
            )
        }

        return OuraHealthDashboardSnapshot(days: days, dateRange: dateRange)
    }
}

// MARK: - OuraHealthDashboardView

/// SwiftUI view displaying comprehensive Oura Ring health metrics.
///
/// Takes an `OuraHealthDashboardSnapshot` — the app is responsible for fetching
/// data from `OuraService` and building the snapshot. The view never
/// touches any actor directly.
public struct OuraHealthDashboardView: View {
    public let snapshot: OuraHealthDashboardSnapshot

    public init(snapshot: OuraHealthDashboardSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider().padding(.vertical, 4)

                if snapshot.days.isEmpty {
                    emptyState
                } else {
                    ForEach(snapshot.days.reversed()) { day in
                        dayCard(day)
                        Divider().padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Oura Health Dashboard")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Comprehensive Health Metrics")
                .font(.headline)
            Text(snapshot.dateRange)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.dashed")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No Oura data available")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Connect your Oura Ring and pull to refresh.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Day card

    @ViewBuilder
    private func dayCard(_ day: OuraHealthDashboardSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Date header
            Text(formatDate(day.date))
                .font(.subheadline)
                .fontWeight(.semibold)

            // Stress & Resilience (existing)
            stressAndResilienceSection(day)
            
            // Cardiovascular Health
            cardiovascularSection(day)
            
            // Fitness Metrics
            fitnessSection(day)
            
            // Sleep Details
            sleepSection(day)
            
            // Oxygen Metrics
            oxygenSection(day)
            
            // Activity Metrics
            activitySection(day)
        }
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Stress & Resilience Section

    @ViewBuilder
    private func stressAndResilienceSection(_ day: OuraHealthDashboardSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stress & Resilience")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            HStack(alignment: .top, spacing: 16) {
                // Stress column
                VStack(alignment: .leading, spacing: 2) {
                    if let stressHigh = day.stressHigh {
                        HStack(spacing: 4) {
                            Text("High Stress:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(stressHigh) min")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }

                    if let recoveryHigh = day.recoveryHigh {
                        HStack(spacing: 4) {
                            Text("Recovery:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(recoveryHigh) min")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }

                    if let summary = day.stressSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Resilience column
                VStack(alignment: .leading, spacing: 2) {
                    if let level = day.resilienceLevel {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(resilienceColor(level))
                                .frame(width: 8, height: 8)
                            Text(level.capitalized)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }

                    if let sleep = day.resilienceSleepRecovery {
                        HStack(spacing: 4) {
                            Text("Sleep:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(sleep)%")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }

                    if let daytime = day.resilienceDaytimeRecovery {
                        HStack(spacing: 4) {
                            Text("Daytime:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(daytime)%")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if day.stressHigh == nil && day.recoveryHigh == nil && day.stressSummary == nil &&
                day.resilienceLevel == nil && day.resilienceSleepRecovery == nil && day.resilienceDaytimeRecovery == nil {
                Text("No stress/resilience data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Cardiovascular Section

    @ViewBuilder
    private func cardiovascularSection(_ day: OuraHealthDashboardSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cardiovascular Health")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.red)
            
            HStack(alignment: .top, spacing: 16) {
                if let vascularAge = day.vascularAge {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vascular Age")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", vascularAge)) years")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                if let pulseWaveVelocity = day.pulseWaveVelocity {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pulse Wave Velocity")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", pulseWaveVelocity)) m/s")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
            if day.vascularAge == nil && day.pulseWaveVelocity == nil {
                Text("No cardiovascular data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Fitness Section

    @ViewBuilder
    private func fitnessSection(_ day: OuraHealthDashboardSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Fitness Metrics")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.blue)
            
            if let vo2Max = day.vo2Max {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VO₂ Max")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(String(format: "%.1f", vo2Max)) ml/kg/min")
                        .font(.caption)
                        .monospacedDigit()
                }
            } else {
                Text("No VO₂ max data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Sleep Section

    @ViewBuilder
    private func sleepSection(_ day: OuraHealthDashboardSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sleep Details")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.purple)
            
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if let efficiency = day.sleepEfficiency {
                        HStack(spacing: 4) {
                            Text("Efficiency:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(efficiency)%")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                    
                    if let latency = day.sleepLatency {
                        HStack(spacing: 4) {
                            Text("Latency:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(latency / 60) min")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    if let respiratoryRate = day.respiratoryRate {
                        HStack(spacing: 4) {
                            Text("Respiratory Rate:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(String(format: "%.1f", respiratoryRate)) breaths/min")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                    
                    if let hypnogram = day.sleepHypnogram {
                        HStack(spacing: 4) {
                            Text("Stages:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(hypnogramVisualizer(hypnogram))
                                .font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if day.sleepEfficiency == nil && day.sleepLatency == nil && 
                day.respiratoryRate == nil && day.sleepHypnogram == nil {
                Text("No sleep detail data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Oxygen Section

    @ViewBuilder
    private func oxygenSection(_ day: OuraHealthDashboardSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Oxygen Metrics")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.green)
            
            HStack(alignment: .top, spacing: 16) {
                if let averageSpO2 = day.averageSpO2 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avg SpO₂")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", averageSpO2))%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                if let bdi = day.breathingDisturbanceIndex {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Breathing Disturbance Index")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", bdi))")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
            if day.averageSpO2 == nil && day.breathingDisturbanceIndex == nil {
                Text("No oxygen data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Activity Section

    @ViewBuilder
    private func activitySection(_ day: OuraHealthDashboardSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity Metrics")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.orange)
            
            HStack(alignment: .top, spacing: 16) {
                if let steps = day.steps {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Steps")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(steps)")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                if let met = day.met {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MET")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", met))")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
            if day.steps == nil && day.met == nil {
                Text("No activity data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ iso: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "EEEE, MMM d"
        return out.string(from: date)
    }

    private func resilienceColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "exceptional": return .purple
        case "strong":      return .blue
        case "solid":       return .green
        case "adequate":    return .yellow
        case "limited":     return .orange
        default:            return .gray
        }
    }
    
    private func hypnogramVisualizer(_ hypnogram: String) -> String {
        // Convert hypnogram stages to visual representation
        // 1=deep, 2=light, 3=REM, 4=awake
        var result = ""
        for char in hypnogram.prefix(20) { // Limit to 20 characters for display
            switch char {
            case "1": result += "●" // Deep sleep
            case "2": result += "○" // Light sleep
            case "3": result += "⊕" // REM sleep
            case "4": result += "○" // Awake
            default: result += "○"
            }
        }
        return result + (hypnogram.count > 20 ? "..." : "")
    }
}