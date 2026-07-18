import Foundation
import Testing
@testable import AnxietyWatchKit

@Suite struct OuraHealthDashboardTests {
    
    @Test func buildDashboardSnapshotFromEmptyResponses() {
        let snapshot = OuraHealthDashboardSnapshot.build(
            stress: [],
            resilience: [],
            cardiovascularAge: [],
            vo2Max: [],
            sleepDetail: [],
            dailySpO2: [],
            dailyActivity: [],
            dateRange: "Jan 1 – Jan 5"
        )
        #expect(snapshot.days.isEmpty)
        #expect(snapshot.dateRange == "Jan 1 – Jan 5")
    }
    
    @Test func buildDashboardSnapshotWithAllData() {
        let stressData = OuraStressData(
            id: "s1", day: "2025-01-15",
            stressHigh: 120, recoveryHigh: 240, daySummary: "restorative"
        )
        let resilienceData = OuraResilienceData(
            id: "r1", day: "2025-01-15",
            level: "solid",
            contributors: OuraResilienceContributors(
                sleepRecovery: 88, daytimeRecovery: 72, stress: 35
            )
        )
        let cardiovascularAgeData = OuraCardiovascularAgeData(
            id: "cva1", day: "2025-01-15",
            vascularAge: 45.2, pulseWaveVelocity: 8.7
        )
        let vo2MaxData = OuraVO2MaxData(
            id: "vo2max1", day: "2025-01-15",
            vo2Max: 42.5
        )
        let sleepDetailData = OuraSleepDetailData(
            id: "sleep1", day: "2025-01-15",
            averageHeartRate: 62.5,
            averageHrv: 25.3,
            timeInBed: 27840,
            awakeTime: 1800,
            deepSleepDuration: 10800,
            lightSleepDuration: 14400,
            remSleepDuration: 2640,
            totalSleepDuration: 27840,
            efficiency: 92,
            score: 85,
            hypnogram: "333222111333222111",
            hrvSeries: [22.1, 25.3, 28.7, 24.2],
            respiratoryRate: 15.2,
            latency: 600
        )
        let dailySpO2Data = OuraDailySpO2Data(
            id: "spo2_1", day: "2025-01-15",
            averageSpO2: 96.8,
            breathingDisturbanceIndex: 2.3
        )
        let dailyActivityData = OuraDailyActivityData(
            id: "activity1", day: "2025-01-15",
            met: 1.8,
            steps: 8420,
            activityClasses: [
                OuraActivityClass(
                    activity: "walking",
                    endTime: "2025-01-15T10:05:00Z",
                    met: 3.5,
                    startTime: "2025-01-15T10:00:00Z"
                )
            ]
        )

        let snapshot = OuraHealthDashboardSnapshot.build(
            stress: [stressData],
            resilience: [resilienceData],
            cardiovascularAge: [cardiovascularAgeData],
            vo2Max: [vo2MaxData],
            sleepDetail: [sleepDetailData],
            dailySpO2: [dailySpO2Data],
            dailyActivity: [dailyActivityData],
            dateRange: "Jan 15"
        )

        #expect(snapshot.days.count == 1)
        let day = snapshot.days[0]
        #expect(day.date == "2025-01-15")
        
        // Stress & Resilience
        #expect(day.stressHigh == 120)
        #expect(day.recoveryHigh == 240)
        #expect(day.stressSummary == "restorative")
        #expect(day.resilienceLevel == "solid")
        #expect(day.resilienceSleepRecovery == 88)
        #expect(day.resilienceDaytimeRecovery == 72)
        #expect(day.resilienceStress == 35)
        
        // Cardiovascular
        #expect(day.vascularAge == 45.2)
        #expect(day.pulseWaveVelocity == 8.7)
        
        // Fitness
        #expect(day.vo2Max == 42.5)
        
        // Sleep
        #expect(day.sleepHypnogram == "333222111333222111")
        #expect(day.sleepEfficiency == 92)
        #expect(day.sleepLatency == 600)
        #expect(day.respiratoryRate == 15.2)
        
        // Oxygen
        #expect(day.averageSpO2 == 96.8)
        #expect(day.breathingDisturbanceIndex == 2.3)
        
        // Activity
        #expect(day.steps == 8420)
        #expect(day.met == 1.8)
    }
    
    @Test func dashboardDayEmptyDefaults() {
        let day = OuraHealthDashboardSnapshot.Day(date: "2025-06-01")
        #expect(day.date == "2025-06-01")
        
        // Stress & Resilience
        #expect(day.stressHigh == nil)
        #expect(day.recoveryHigh == nil)
        #expect(day.stressSummary == nil)
        #expect(day.resilienceLevel == nil)
        #expect(day.resilienceSleepRecovery == nil)
        #expect(day.resilienceDaytimeRecovery == nil)
        #expect(day.resilienceStress == nil)
        
        // Cardiovascular
        #expect(day.vascularAge == nil)
        #expect(day.pulseWaveVelocity == nil)
        
        // Fitness
        #expect(day.vo2Max == nil)
        
        // Sleep
        #expect(day.sleepHypnogram == nil)
        #expect(day.sleepEfficiency == nil)
        #expect(day.sleepLatency == nil)
        #expect(day.respiratoryRate == nil)
        
        // Oxygen
        #expect(day.averageSpO2 == nil)
        #expect(day.breathingDisturbanceIndex == nil)
        
        // Activity
        #expect(day.steps == nil)
        #expect(day.met == nil)
    }
}