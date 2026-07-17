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
}
