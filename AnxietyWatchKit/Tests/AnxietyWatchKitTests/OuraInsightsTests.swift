import Foundation
import Testing
@testable import AnxietyWatchKit

@Suite struct OuraInsightsTests {

    // MARK: - Snapshot building

    @Test func buildSnapshotFromEmptyResponses() {
        let snapshot = OuraInsightsSnapshot.build(
            stress: [],
            resilience: [],
            dateRange: "Jan 1 – Jan 5"
        )
        #expect(snapshot.days.isEmpty)
        #expect(snapshot.dateRange == "Jan 1 – Jan 5")
    }

    @Test func buildSnapshotMergesStressAndResilience() {
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

        let snapshot = OuraInsightsSnapshot.build(
            stress: [stressData],
            resilience: [resilienceData],
            dateRange: "Jan 15"
        )

        #expect(snapshot.days.count == 1)
        let day = snapshot.days[0]
        #expect(day.date == "2025-01-15")
        #expect(day.stressHigh == 120)
        #expect(day.recoveryHigh == 240)
        #expect(day.stressSummary == "restorative")
        #expect(day.resilienceLevel == "solid")
        #expect(day.resilienceSleepRecovery == 88)
        #expect(day.resilienceDaytimeRecovery == 72)
        #expect(day.resilienceStress == 35)
    }

    @Test func buildSnapshotStressOnly() {
        let stress = OuraStressData(
            id: "s1", day: "2025-02-01",
            stressHigh: 60, recoveryHigh: 300, daySummary: nil
        )

        let snapshot = OuraInsightsSnapshot.build(
            stress: [stress],
            resilience: [],
            dateRange: "Feb 1"
        )

        #expect(snapshot.days.count == 1)
        let day = snapshot.days[0]
        #expect(day.stressHigh == 60)
        #expect(day.recoveryHigh == 300)
        #expect(day.resilienceLevel == nil)
        #expect(day.resilienceSleepRecovery == nil)
    }

    @Test func buildSnapshotResilienceOnly() {
        let resilience = OuraResilienceData(
            id: "r1", day: "2025-03-10",
            level: "strong",
            contributors: nil
        )

        let snapshot = OuraInsightsSnapshot.build(
            stress: [],
            resilience: [resilience],
            dateRange: "Mar 10"
        )

        #expect(snapshot.days.count == 1)
        let day = snapshot.days[0]
        #expect(day.resilienceLevel == "strong")
        #expect(day.stressHigh == nil)
    }

    @Test func buildSnapshotMultipleDaysSorted() {
        let stressDays = [
            OuraStressData(id: "s2", day: "2025-01-02", stressHigh: 30, recoveryHigh: 400, daySummary: nil),
            OuraStressData(id: "s1", day: "2025-01-01", stressHigh: 90, recoveryHigh: 350, daySummary: nil),
        ]
        let resilienceDays = [
            OuraResilienceData(id: "r2", day: "2025-01-02", level: "adequate", contributors: nil),
            OuraResilienceData(id: "r1", day: "2025-01-01", level: "limited", contributors: nil),
        ]

        let snapshot = OuraInsightsSnapshot.build(
            stress: stressDays, resilience: resilienceDays, dateRange: "Jan 1–2"
        )

        #expect(snapshot.days.count == 2)
        // Should be sorted by date
        #expect(snapshot.days[0].date == "2025-01-01")
        #expect(snapshot.days[1].date == "2025-01-02")
    }

    // MARK: - Day defaults

    @Test func dayEmptyDefaults() {
        let day = OuraInsightsSnapshot.Day(date: "2025-06-01")
        #expect(day.date == "2025-06-01")
        #expect(day.stressHigh == nil)
        #expect(day.recoveryHigh == nil)
        #expect(day.stressSummary == nil)
        #expect(day.resilienceLevel == nil)
        #expect(day.resilienceSleepRecovery == nil)
        #expect(day.resilienceDaytimeRecovery == nil)
        #expect(day.resilienceStress == nil)
    }

    // MARK: - Codable round-trip for new models

    @Test func resilienceResponseCodable() throws {
        let json = """
        {
            "data": [{
                "id": "abc",
                "day": "2025-01-15",
                "level": "solid",
                "contributors": {
                    "sleep_recovery": 88,
                    "daytime_recovery": 72,
                    "stress": 35
                }
            }],
            "next_token": null
        }
        """

        let decoded = try JSONDecoder().decode(OuraResilienceResponse.self, from: Data(json.utf8))
        #expect(decoded.data.count == 1)
        #expect(decoded.data[0].level == "solid")
        #expect(decoded.data[0].contributors?.sleepRecovery == 88)
        #expect(decoded.data[0].contributors?.daytimeRecovery == 72)
        #expect(decoded.data[0].contributors?.stress == 35)
        #expect(decoded.nextToken == nil)
    }

    @Test func stressResponseCodable() throws {
        let json = """
        {
            "data": [{
                "id": "s1",
                "day": "2025-01-15",
                "stress_high": 120,
                "recovery_high": 240,
                "day_summary": "restorative"
            }],
            "next_token": null
        }
        """

        let decoded = try JSONDecoder().decode(OuraStressResponse.self, from: Data(json.utf8))
        #expect(decoded.data.count == 1)
        #expect(decoded.data[0].stressHigh == 120)
        #expect(decoded.data[0].recoveryHigh == 240)
        #expect(decoded.data[0].daySummary == "restorative")
    }
    
    // MARK: - New model tests
    
    @Test func cardiovascularAgeResponseCodable() throws {
        let json = """
        {
            "data": [{
                "id": "cva1",
                "day": "2025-01-15",
                "vascular_age": 45.2,
                "pulse_wave_velocity": 8.7
            }],
            "next_token": null
        }
        """

        let decoded = try JSONDecoder().decode(OuraCardiovascularAgeResponse.self, from: Data(json.utf8))
        #expect(decoded.data.count == 1)
        #expect(decoded.data[0].vascularAge == 45.2)
        #expect(decoded.data[0].pulseWaveVelocity == 8.7)
        #expect(decoded.nextToken == nil)
    }
    
    @Test func vo2MaxResponseCodable() throws {
        let json = """
        {
            "data": [{
                "id": "vo2max1",
                "day": "2025-01-15",
                "vo2_max": 42.5
            }],
            "next_token": null
        }
        """

        let decoded = try JSONDecoder().decode(OuraVO2MaxResponse.self, from: Data(json.utf8))
        #expect(decoded.data.count == 1)
        #expect(decoded.data[0].vo2Max == 42.5)
        #expect(decoded.nextToken == nil)
    }
    
    @Test func sleepDetailResponseCodable() throws {
        let json = """
        {
            "data": [{
                "id": "sleep1",
                "day": "2025-01-15",
                "average_heart_rate": 62.5,
                "average_hrv": 25.3,
                "time_in_bed": 27840,
                "awake_time": 1800,
                "deep_sleep_duration": 10800,
                "light_sleep_duration": 14400,
                "rem_sleep_duration": 2640,
                "total_sleep_duration": 27840,
                "efficiency": 92,
                "score": 85,
                "hypnogram": "333222111333222111",
                "hrv_series": [22.1, 25.3, 28.7, 24.2],
                "respiratory_rate": 15.2,
                "latency": 600
            }],
            "next_token": null
        }
        """

        let decoded = try JSONDecoder().decode(OuraSleepDetailResponse.self, from: Data(json.utf8))
        #expect(decoded.data.count == 1)
        #expect(decoded.data[0].hypnogram == "333222111333222111")
        #expect(decoded.data[0].hrvSeries?.count == 4)
        #expect(decoded.data[0].respiratoryRate == 15.2)
        #expect(decoded.data[0].latency == 600)
        #expect(decoded.nextToken == nil)
    }
    
    @Test func dailySpO2ResponseCodable() throws {
        let json = """
        {
            "data": [{
                "id": "spo2_1",
                "day": "2025-01-15",
                "average_spo2": 96.8,
                "breathing_disturbance_index": 2.3
            }],
            "next_token": null
        }
        """

        let decoded = try JSONDecoder().decode(OuraDailySpO2Response.self, from: Data(json.utf8))
        #expect(decoded.data.count == 1)
        #expect(decoded.data[0].averageSpO2 == 96.8)
        #expect(decoded.data[0].breathingDisturbanceIndex == 2.3)
        #expect(decoded.nextToken == nil)
    }
    
    @Test func dailyActivityResponseCodable() throws {
        let json = """
        {
            "data": [{
                "id": "activity1",
                "day": "2025-01-15",
                "met": 1.8,
                "steps": 8420,
                "class_5_min": [{
                    "activity": "walking",
                    "end_time": "2025-01-15T10:05:00Z",
                    "met": 3.5,
                    "start_time": "2025-01-15T10:00:00Z"
                }]
            }],
            "next_token": null
        }
        """

        let decoded = try JSONDecoder().decode(OuraDailyActivityResponse.self, from: Data(json.utf8))
        #expect(decoded.data.count == 1)
        #expect(decoded.data[0].met == 1.8)
        #expect(decoded.data[0].steps == 8420)
        #expect(decoded.data[0].activityClasses?.count == 1)
        #expect(decoded.data[0].activityClasses?[0].activity == "walking")
        #expect(decoded.nextToken == nil)
    }
}