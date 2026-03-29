import HealthKit

/// Maps HealthKit quantity type identifiers to their canonical units, display names,
/// and trend thresholds. Used by the anchored query pipeline and dashboard cards.
struct SampleTypeConfig {
    let identifier: HKQuantityTypeIdentifier
    let unit: HKUnit
    let displayName: String
    let unitLabel: String
    /// Absolute change from 1h rolling average that counts as "rising" or "dropping"
    let trendThreshold: Double

    /// All types that get individual sample caching via HKAnchoredObjectQuery.
    static let anchoredTypes: [SampleTypeConfig] = [
        SampleTypeConfig(
            identifier: .heartRate,
            unit: .count().unitDivided(by: .minute()),
            displayName: "Heart Rate",
            unitLabel: "bpm",
            trendThreshold: 3
        ),
        SampleTypeConfig(
            identifier: .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            displayName: "HRV",
            unitLabel: "ms",
            trendThreshold: 5
        ),
        SampleTypeConfig(
            identifier: .oxygenSaturation,
            unit: .percent(),
            displayName: "Blood Oxygen",
            unitLabel: "%",
            trendThreshold: 0.01
        ),
        SampleTypeConfig(
            identifier: .respiratoryRate,
            unit: .count().unitDivided(by: .minute()),
            displayName: "Respiratory Rate",
            unitLabel: "breaths/min",
            trendThreshold: 1
        ),
        SampleTypeConfig(
            identifier: .restingHeartRate,
            unit: .count().unitDivided(by: .minute()),
            displayName: "Resting HR",
            unitLabel: "bpm",
            trendThreshold: 3
        ),
        SampleTypeConfig(
            identifier: .vo2Max,
            unit: HKUnit(from: "mL/kg*min"),
            displayName: "VO₂ Max",
            unitLabel: "mL/kg/min",
            trendThreshold: 1
        ),
        SampleTypeConfig(
            identifier: .walkingHeartRateAverage,
            unit: .count().unitDivided(by: .minute()),
            displayName: "Walking HR",
            unitLabel: "bpm",
            trendThreshold: 3
        ),
        SampleTypeConfig(
            identifier: .appleWalkingSteadiness,
            unit: .percent(),
            displayName: "Walking Steadiness",
            unitLabel: "%",
            trendThreshold: 0.02
        ),
        SampleTypeConfig(
            identifier: .bloodPressureSystolic,
            unit: .millimeterOfMercury(),
            displayName: "BP Systolic",
            unitLabel: "mmHg",
            trendThreshold: 5
        ),
        SampleTypeConfig(
            identifier: .bloodPressureDiastolic,
            unit: .millimeterOfMercury(),
            displayName: "BP Diastolic",
            unitLabel: "mmHg",
            trendThreshold: 3
        ),
        SampleTypeConfig(
            identifier: .bloodGlucose,
            unit: .gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)),
            displayName: "Blood Glucose",
            unitLabel: "mg/dL",
            trendThreshold: 10
        ),
        SampleTypeConfig(
            identifier: .environmentalAudioExposure,
            unit: .decibelAWeightedSoundPressureLevel(),
            displayName: "Env. Sound",
            unitLabel: "dBA",
            trendThreshold: 5
        ),
        SampleTypeConfig(
            identifier: .headphoneAudioExposure,
            unit: .decibelAWeightedSoundPressureLevel(),
            displayName: "Headphone Audio",
            unitLabel: "dBA",
            trendThreshold: 5
        ),
    ]

    /// Look up config by raw identifier string (as stored in HealthSample.type).
    static func config(for rawIdentifier: String) -> SampleTypeConfig? {
        anchoredTypes.first { $0.identifier.rawValue == rawIdentifier }
    }
}
