import HealthKit
import Testing

@testable import AnxietyWatch

/// Integration tests that run on a physical device with real HealthKit data.
/// Prerequisites: device must have Apple Watch paired with health data synced.
@Suite(.tags(.integration))
struct HealthKitManagerIntegrationTests {

    private let hk = HealthKitManager.shared

    @Test("oldestSampleDate returns a date in the past")
    func oldestSampleDateExists() async throws {
        let date = try await hk.oldestSampleDate()
        #expect(date != nil, "Expected HealthKit to have at least one HRV sample")
        if let date {
            #expect(date < Date.now, "Oldest sample should be in the past")
        }
    }

    @Test("HRV average for last 7 days is non-nil")
    func hrvAverageExists() async throws {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
        let avg = try await hk.averageQuantity(
            .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            start: start, end: end
        )
        #expect(avg != nil, "Expected HRV data from Apple Watch in last 7 days")
    }

    @Test("Sleep analysis for last 7 days returns data")
    func sleepAnalysisExists() async throws {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
        let sleep = try await hk.querySleepAnalysis(start: start, end: end)
        #expect(sleep.totalMinutes > 0, "Expected sleep data from Apple Watch in last 7 days")
    }

    @Test("Resting HR for last 7 days is in physiological range")
    func restingHRInRange() async throws {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
        let rhr = try await hk.averageQuantity(
            .restingHeartRate,
            unit: .count().unitDivided(by: .minute()),
            start: start, end: end
        )
        if let rhr {
            #expect(rhr >= 30 && rhr <= 120, "Resting HR \(rhr) outside physiological range")
        }
    }
}

extension Tag {
    @Tag static var integration: Self
}
