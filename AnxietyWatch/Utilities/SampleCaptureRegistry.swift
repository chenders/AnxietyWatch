import Foundation
import HealthKit

/// Single source of truth for which HealthKit metrics get sample-level local mirroring.
///
/// Each entry corresponds to one date-anchored mirroring pass run by
/// `HealthDataCoordinator.mirrorHealthKitSamples()`. The anchor is a `Date`
/// persisted in `UserDefaults` per metric (key `sampleAnchor.<rawIdentifier>`).
/// Each pass queries `(max(anchor - mirrorLookbackInterval, epoch), now)` via
/// `quantitySamplesWithSource(...)` and advances the anchor to `now` only after
/// the SwiftData save succeeds. This is NOT `HKAnchoredObjectQuery` — sleep
/// stages and quantity metrics both use the same date-window pull pattern with
/// idempotent UUID-keyed upserts.
///
/// The rolling look-back exists because HealthKit allows retroactive
/// corrections to existing samples (CGM backfill, recalibration that adjusts
/// yesterday's values, sleep edits the next day). Without it, once the anchor
/// advances past a sample, later corrections to that sample would never be
/// re-fetched. The UUID-keyed upsert logic already handles "same UUID, updated
/// fields" — the look-back simply ensures those updated samples are visible to
/// the query.
enum SampleCaptureRegistry {
    static let quantityMetrics: [(HKQuantityTypeIdentifier, HKUnit)] = [
        (.heartRate, HKUnit.count().unitDivided(by: HKUnit.minute())),
        (.heartRateVariabilitySDNN, .secondUnit(with: .milli)),
        (.restingHeartRate, HKUnit.count().unitDivided(by: HKUnit.minute())),
        (.respiratoryRate, HKUnit.count().unitDivided(by: HKUnit.minute())),
        (.oxygenSaturation, .percent()),
        (.bloodGlucose, HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))),
        (.bodyTemperature, .degreeCelsius()),
        (.appleSleepingWristTemperature, .degreeCelsius()),
        (.bloodPressureSystolic, .millimeterOfMercury()),
        (.bloodPressureDiastolic, .millimeterOfMercury()),
        (.bodyMass, .gramUnit(with: .kilo))
    ]

    static let captureSleep: Bool = true

    /// Rolling look-back applied to every mirror query window so retroactive
    /// HealthKit corrections within the past 48 hours are picked up. Each pass
    /// queries `(max(anchor - mirrorLookbackInterval, epoch), now)` while the
    /// anchor still advances to `now` after a successful save — so we don't
    /// re-fetch from origin every pass, but do reach back far enough to catch
    /// CGM/HK retroactive corrections (Dexcom backfill, recalibration affecting
    /// yesterday's timestamps/values, sleep edits applied the next day).
    /// 48 hours covers the common cases without inflating per-pass data volume.
    static let mirrorLookbackInterval: TimeInterval = 48 * 3600
}
