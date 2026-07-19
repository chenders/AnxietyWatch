import Foundation
import Testing

@testable import AnxietyWatch

struct HealthKitGraceGateTests {
    private let now: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
    }()

    private func isolatedDefaults(_ function: String = #function) -> UserDefaults {
        let suite = "HealthKitGraceGateTests-\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("nil timestamp has not elapsed")
    func nilNotElapsed() {
        #expect(!HealthKitGraceGate.hasElapsed(firstAuthorizedAt: nil, now: now))
    }

    @Test("just under 48h has not elapsed")
    func justUnderNotElapsed() {
        let first = now.addingTimeInterval(-47 * 60 * 60)
        #expect(!HealthKitGraceGate.hasElapsed(firstAuthorizedAt: first, now: now))
    }

    @Test("just over 48h has elapsed")
    func justOverElapsed() {
        let first = now.addingTimeInterval(-49 * 60 * 60)
        #expect(HealthKitGraceGate.hasElapsed(firstAuthorizedAt: first, now: now))
    }

    @Test("recordFirstAuthorizedIfNeeded stamps once and is idempotent")
    func recordIsIdempotent() {
        let defaults = isolatedDefaults()
        let first = HealthKitGraceGate.recordFirstAuthorizedIfNeeded(now: now, defaults: defaults)
        #expect(abs(first.timeIntervalSince(now)) < 0.001)
        let later = now.addingTimeInterval(100 * 60 * 60)
        let second = HealthKitGraceGate.recordFirstAuthorizedIfNeeded(now: later, defaults: defaults)
        #expect(abs(second.timeIntervalSince(now)) < 0.001)
    }
}
