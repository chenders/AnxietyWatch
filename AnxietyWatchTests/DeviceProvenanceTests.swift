import Foundation
import Testing

@testable import AnxietyWatch

@Suite("DeviceProvenance bundle-ID classification")
struct DeviceProvenanceClassificationTests {
    @Test("Stelo classified as continuous glucose monitor")
    func steloIsCGM() {
        #expect(DeviceProvenance.isContinuousGlucoseMonitor("com.dexcom.stelo") == true)
    }

    @Test("Dexcom G7 classified as continuous glucose monitor")
    func dexcomG7IsCGM() {
        #expect(DeviceProvenance.isContinuousGlucoseMonitor("com.dexcom.G7") == true)
    }

    @Test("Apple Health is not a CGM")
    func appleHealthNotCGM() {
        #expect(DeviceProvenance.isContinuousGlucoseMonitor("com.apple.health") == false)
    }

    @Test("EMAY SleepO2 classified as overnight pulse oximeter")
    func emayIsOvernight() {
        #expect(DeviceProvenance.isOvernightPulseOximeter("com.emay.sleepo2") == true)
    }

    @Test("Apple Health is not an overnight pulse oximeter")
    func appleHealthNotOvernight() {
        #expect(DeviceProvenance.isOvernightPulseOximeter("com.apple.health") == false)
    }

    @Test("Apple Health classified as Apple ecosystem source")
    func appleHealthIsAppleEcosystem() {
        #expect(DeviceProvenance.isAppleEcosystemSource("com.apple.health") == true)
    }

    @Test("Stelo is not an Apple ecosystem source")
    func steloNotAppleEcosystem() {
        #expect(DeviceProvenance.isAppleEcosystemSource("com.dexcom.stelo") == false)
    }

    @Test("Withings classified as medical-grade BP cuff")
    func withingsIsMedicalBP() {
        #expect(DeviceProvenance.isMedicalGradeBPCuff("com.withings.wiscale2") == true)
    }

    @Test("Apple Health is not a medical-grade BP cuff")
    func appleHealthNotMedicalBP() {
        #expect(DeviceProvenance.isMedicalGradeBPCuff("com.apple.health") == false)
    }

    @Test("EMAY HealthKit bundle classified as overnight pulse oximeter")
    func emayHealthKitBundleIsOvernight() {
        // `com.emay.oximeter` is what the EMAY iOS companion app stamps onto
        // samples it writes into HealthKit (vs. `com.emay.SleepO2` for our
        // own CSV imports). Both routes are the same device class and must
        // be classified the same way so source-precedence sees them as
        // high-fidelity.
        #expect(DeviceProvenance.isOvernightPulseOximeter("com.emay.oximeter") == true)
    }

    @Test("Polar Flow bundle classified as chest strap HR monitor")
    func polarFlowIsChestStrap() {
        #expect(DeviceProvenance.isChestStrapHRMonitor("fi.polar.polarflow") == true)
    }

    @Test("polar_h10 typed label classified as chest strap HR monitor")
    func polarH10TypedLabelIsChestStrap() {
        // The app's own BLE pipeline stamps `polar_h10` (not a bundle ID
        // shape) onto `SensorSession` / `HRVReading` rows — verify it's
        // recognized alongside the Polar Flow HealthKit-side bundle.
        #expect(DeviceProvenance.isChestStrapHRMonitor("polar_h10") == true)
    }

    @Test("Apple Health is not a chest strap HR monitor")
    func appleHealthNotChestStrap() {
        #expect(DeviceProvenance.isChestStrapHRMonitor("com.apple.health") == false)
    }
}

@Suite("DeviceProvenance.partition source-precedence")
struct DeviceProvenancePartitionTests {
    private func sample(_ bundle: String, value: Double = 0.95, metric: String) -> QuantityHealthSample {
        QuantityHealthSample(
            timestamp: Date.ref(0),
            metricType: metric,
            value: value,
            unitString: "%",
            sourceBundleID: bundle,
            sourceName: bundle
        )
    }

    @Test("SpO2 partition: EMAY samples → preferred, Apple Watch → opportunistic")
    func spo2EmaySplit() {
        let metric = "HKQuantityTypeIdentifierOxygenSaturation"
        let samples = [
            sample("com.emay.SleepO2", value: 0.92, metric: metric),
            sample("com.emay.oximeter", value: 0.93, metric: metric),
            sample("com.apple.health", value: 0.78, metric: metric),
            sample("com.apple.Health", value: 0.84, metric: metric),
        ]
        let parts = DeviceProvenance.partition(samples: samples, metricType: metric)
        #expect(parts.preferred.count == 2)
        #expect(parts.opportunistic.count == 2)
        #expect(parts.preferred.allSatisfy { DeviceProvenance.isOvernightPulseOximeter($0.sourceBundleID) })
        #expect(parts.opportunistic.allSatisfy { DeviceProvenance.isAppleEcosystemSource($0.sourceBundleID) })
    }

    @Test("HR partition: Polar samples → preferred, Apple Watch → opportunistic")
    func hrPolarSplit() {
        let metric = "HKQuantityTypeIdentifierHeartRate"
        let samples = [
            sample("fi.polar.polarflow", value: 62, metric: metric),
            sample("polar_h10", value: 64, metric: metric),
            sample("com.apple.health", value: 88, metric: metric),
        ]
        let parts = DeviceProvenance.partition(samples: samples, metricType: metric)
        #expect(parts.preferred.count == 2)
        #expect(parts.opportunistic.count == 1)
    }

    @Test("HRV partition: Polar samples → preferred, Apple Watch → opportunistic")
    func hrvPolarSplit() {
        let metric = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
        let samples = [
            sample("fi.polar.polarflow", value: 45.0, metric: metric),
            sample("com.apple.health", value: 28.0, metric: metric),
        ]
        let parts = DeviceProvenance.partition(samples: samples, metricType: metric)
        #expect(parts.preferred.count == 1)
        #expect(parts.opportunistic.count == 1)
    }

    @Test("RestingHR partition: Polar samples → preferred")
    func restingHRPolarSplit() {
        let metric = "HKQuantityTypeIdentifierRestingHeartRate"
        let samples = [
            sample("fi.polar.polarflow", value: 58, metric: metric),
            sample("com.apple.health", value: 65, metric: metric),
        ]
        let parts = DeviceProvenance.partition(samples: samples, metricType: metric)
        #expect(parts.preferred.count == 1)
        #expect(parts.opportunistic.count == 1)
    }

    @Test("Glucose partition: no high-fidelity tier defined → everything opportunistic")
    func glucoseNoPreferredTier() {
        // CGMs have their own classifier (`Reliability.glucoseDaily`) — the
        // partition helper intentionally returns nil for metrics without a
        // defined high-fidelity vs Apple Watch overlap, so callers naturally
        // fall back to the opportunistic subset (= all samples).
        let metric = "HKQuantityTypeIdentifierBloodGlucose"
        let samples = [
            sample("com.dexcom.stelo", value: 90, metric: metric),
            sample("com.apple.health", value: 110, metric: metric),
        ]
        let parts = DeviceProvenance.partition(samples: samples, metricType: metric)
        #expect(parts.preferred.isEmpty)
        #expect(parts.opportunistic.count == 2)
    }

    @Test("Empty input → both subsets empty")
    func emptyInput() {
        let parts = DeviceProvenance.partition(
            samples: [],
            metricType: "HKQuantityTypeIdentifierOxygenSaturation"
        )
        #expect(parts.preferred.isEmpty)
        #expect(parts.opportunistic.isEmpty)
    }
}

@Suite("DeviceProvenance display names")
struct DeviceProvenanceDisplayNameTests {
    @Test("Stelo display name")
    func steloDisplayName() {
        #expect(DeviceProvenance.displayName(for: "com.dexcom.stelo") == "Stelo")
    }

    @Test("EMAY SleepO2 display name")
    func emayDisplayName() {
        #expect(DeviceProvenance.displayName(for: "com.emay.sleepo2") == "EMAY SleepO2")
    }

    @Test("Apple Health display name maps to Apple Watch")
    func appleHealthDisplayName() {
        #expect(DeviceProvenance.displayName(for: "com.apple.health") == "Apple Watch")
    }

    @Test("Unknown bundle falls back to bundle ID")
    func unknownDisplayNameFallback() {
        #expect(DeviceProvenance.displayName(for: "com.unknown.weird") == "com.unknown.weird")
    }
}

// MARK: - Helpers for sample fixtures

private extension Date {
    /// Build a Date by adding `seconds` to a fixed reference point. Avoids `Date.now`.
    static func ref(_ seconds: TimeInterval) -> Date {
        // 2026-01-01T00:00:00Z (deterministic anchor)
        Date(timeIntervalSince1970: 1_767_225_600).addingTimeInterval(seconds)
    }
}

/// Build N evenly-spaced samples spanning `coverageHours`, all from the given bundle.
private func evenSamples(
    count: Int,
    bundle: String,
    coverageHours: Double,
    metricType: String = "HKQuantityTypeIdentifierBloodGlucose",
    unitString: String = "mg/dL",
    value: Double = 100,
    startOffsetSeconds: TimeInterval = 0
) -> [QuantityHealthSample] {
    guard count > 0 else { return [] }
    let totalSeconds = coverageHours * 3600
    let step = count > 1 ? totalSeconds / Double(count - 1) : 0
    return (0..<count).map { i in
        QuantityHealthSample(
            timestamp: Date.ref(startOffsetSeconds + Double(i) * step),
            metricType: metricType,
            value: value,
            unitString: unitString,
            sourceBundleID: bundle,
            sourceName: DeviceProvenance.displayName(for: bundle)
        )
    }
}

@Suite("Reliability.glucoseDaily")
struct GlucoseDailyReliabilityTests {
    @Test("250 Stelo samples over 20h → high")
    func steloHigh() {
        let samples = evenSamples(count: 250, bundle: "com.dexcom.stelo", coverageHours: 20)
        #expect(Reliability.glucoseDaily(samples: samples) == .high)
    }

    @Test("50 Stelo samples over 14h → medium (CGM dominates 12-18h)")
    func steloMedium() {
        let samples = evenSamples(count: 50, bundle: "com.dexcom.stelo", coverageHours: 14)
        #expect(Reliability.glucoseDaily(samples: samples) == .medium)
    }

    @Test("5 manual fingerstick samples → low")
    func manualLow() {
        let samples = evenSamples(count: 5, bundle: "com.apple.health", coverageHours: 8)
        #expect(Reliability.glucoseDaily(samples: samples) == .low)
    }

    @Test("0 samples → insufficient")
    func emptyInsufficient() {
        #expect(Reliability.glucoseDaily(samples: []) == .insufficient)
    }
}

@Suite("Reliability.spo2Overnight")
struct SpO2OvernightReliabilityTests {
    @Test("300 EMAY samples over 7h → high")
    func emayHigh() {
        let samples = evenSamples(
            count: 300,
            bundle: "com.emay.sleepo2",
            coverageHours: 7,
            metricType: "HKQuantityTypeIdentifierOxygenSaturation",
            unitString: "%",
            value: 0.96
        )
        #expect(Reliability.spo2Overnight(samples: samples) == .high)
    }

    @Test("80 EMAY samples over 4h → medium (dedicated dominant, partial coverage)")
    func emayMedium() {
        let samples = evenSamples(
            count: 80,
            bundle: "com.emay.sleepo2",
            coverageHours: 4,
            metricType: "HKQuantityTypeIdentifierOxygenSaturation",
            unitString: "%",
            value: 0.95
        )
        #expect(Reliability.spo2Overnight(samples: samples) == .medium)
    }

    @Test("30 Apple Watch samples → low")
    func appleWatchLow() {
        let samples = evenSamples(
            count: 30,
            bundle: "com.apple.health",
            coverageHours: 6,
            metricType: "HKQuantityTypeIdentifierOxygenSaturation",
            unitString: "%",
            value: 0.97
        )
        #expect(Reliability.spo2Overnight(samples: samples) == .low)
    }

    @Test("0 samples → insufficient")
    func emptyInsufficient() {
        #expect(Reliability.spo2Overnight(samples: []) == .insufficient)
    }
}

@Suite("Reliability.heartRate")
struct HeartRateReliabilityTests {
    @Test("100 Apple Watch samples → high")
    func appleWatchHigh() {
        let samples = evenSamples(
            count: 100,
            bundle: "com.apple.health",
            coverageHours: 12,
            metricType: "HKQuantityTypeIdentifierHeartRate",
            unitString: "count/min",
            value: 70
        )
        #expect(Reliability.heartRate(samples: samples) == .high)
    }

    @Test("10 Apple Watch samples → medium (reduced)")
    func appleWatchMedium() {
        let samples = evenSamples(
            count: 10,
            bundle: "com.apple.health",
            coverageHours: 6,
            metricType: "HKQuantityTypeIdentifierHeartRate",
            unitString: "count/min",
            value: 70
        )
        #expect(Reliability.heartRate(samples: samples) == .medium)
    }

    @Test("5 manual/unknown samples → low")
    func manualLow() {
        let samples = evenSamples(
            count: 5,
            bundle: "com.unknown.tracker",
            coverageHours: 6,
            metricType: "HKQuantityTypeIdentifierHeartRate",
            unitString: "count/min",
            value: 72
        )
        #expect(Reliability.heartRate(samples: samples) == .low)
    }

    @Test("0 samples → insufficient")
    func emptyInsufficient() {
        #expect(Reliability.heartRate(samples: []) == .insufficient)
    }
}

@Suite("Reliability.hrv")
struct HRVReliabilityTests {
    @Test("3 Apple Watch HRV samples → high (boundary)")
    func appleWatchAtThresholdHigh() {
        let samples = evenSamples(
            count: 3,
            bundle: "com.apple.health",
            coverageHours: 8,
            metricType: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            unitString: "ms",
            value: 45
        )
        #expect(Reliability.hrv(samples: samples) == .high)
    }

    @Test("2 Apple Watch HRV samples → medium (just under threshold)")
    func appleWatchUnderThresholdMedium() {
        let samples = evenSamples(
            count: 2,
            bundle: "com.apple.health",
            coverageHours: 8,
            metricType: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            unitString: "ms",
            value: 45
        )
        #expect(Reliability.hrv(samples: samples) == .medium)
    }

    @Test("Manual HRV entries → low")
    func manualLow() {
        let samples = evenSamples(
            count: 5,
            bundle: "com.unknown.tracker",
            coverageHours: 8,
            metricType: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            unitString: "ms",
            value: 40
        )
        #expect(Reliability.hrv(samples: samples) == .low)
    }

    @Test("0 samples → insufficient")
    func emptyInsufficient() {
        #expect(Reliability.hrv(samples: []) == .insufficient)
    }
}

@Suite("Reliability.restingHR")
struct RestingHRReliabilityTests {
    @Test("Single Apple Watch RHR sample → high (presence-only metric)")
    func appleWatchPresenceHigh() {
        let samples = evenSamples(
            count: 1,
            bundle: "com.apple.health",
            coverageHours: 0,
            metricType: "HKQuantityTypeIdentifierRestingHeartRate",
            unitString: "count/min",
            value: 60
        )
        #expect(Reliability.restingHR(samples: samples) == .high)
    }

    @Test("Single manual RHR sample → low")
    func manualLow() {
        let samples = evenSamples(
            count: 1,
            bundle: "com.unknown.tracker",
            coverageHours: 0,
            metricType: "HKQuantityTypeIdentifierRestingHeartRate",
            unitString: "count/min",
            value: 60
        )
        #expect(Reliability.restingHR(samples: samples) == .low)
    }

    @Test("0 samples → insufficient")
    func emptyInsufficient() {
        #expect(Reliability.restingHR(samples: []) == .insufficient)
    }
}

@Suite("Reliability.respiratoryRate")
struct RespiratoryRateReliabilityTests {
    @Test("5 Apple Watch RR samples → high (boundary)")
    func appleWatchAtThresholdHigh() {
        let samples = evenSamples(
            count: 5,
            bundle: "com.apple.health",
            coverageHours: 8,
            metricType: "HKQuantityTypeIdentifierRespiratoryRate",
            unitString: "count/min",
            value: 14
        )
        #expect(Reliability.respiratoryRate(samples: samples) == .high)
    }

    @Test("4 Apple Watch RR samples → medium (just under threshold)")
    func appleWatchUnderThresholdMedium() {
        let samples = evenSamples(
            count: 4,
            bundle: "com.apple.health",
            coverageHours: 8,
            metricType: "HKQuantityTypeIdentifierRespiratoryRate",
            unitString: "count/min",
            value: 14
        )
        #expect(Reliability.respiratoryRate(samples: samples) == .medium)
    }

    @Test("Manual RR samples → low")
    func manualLow() {
        let samples = evenSamples(
            count: 5,
            bundle: "com.unknown.tracker",
            coverageHours: 8,
            metricType: "HKQuantityTypeIdentifierRespiratoryRate",
            unitString: "count/min",
            value: 16
        )
        #expect(Reliability.respiratoryRate(samples: samples) == .low)
    }

    @Test("0 samples → insufficient")
    func emptyInsufficient() {
        #expect(Reliability.respiratoryRate(samples: []) == .insufficient)
    }
}

@Suite("Reliability.wristTemperature")
struct WristTemperatureReliabilityTests {
    @Test("1 Apple Watch wrist-temp sample → high")
    func appleWatchAtThresholdHigh() {
        let samples = evenSamples(
            count: 1,
            bundle: "com.apple.health",
            coverageHours: 0,
            metricType: "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
            unitString: "degC",
            value: 36.0
        )
        #expect(Reliability.wristTemperature(samples: samples) == .high)
    }

    @Test("Manual wrist-temp samples → low")
    func manualLow() {
        let samples = evenSamples(
            count: 2,
            bundle: "com.unknown.tracker",
            coverageHours: 0,
            metricType: "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
            unitString: "degC",
            value: 36.1
        )
        #expect(Reliability.wristTemperature(samples: samples) == .low)
    }

    @Test("0 samples → insufficient")
    func emptyInsufficient() {
        #expect(Reliability.wristTemperature(samples: []) == .insufficient)
    }
}

@Suite("Reliability.bloodPressure")
struct BloodPressureReliabilityTests {
    private func bp(_ bundle: String) -> QuantityHealthSample {
        QuantityHealthSample(
            timestamp: Date.ref(0),
            metricType: "HKQuantityTypeIdentifierBloodPressureSystolic",
            value: 128,
            unitString: "mmHg",
            sourceBundleID: bundle,
            sourceName: DeviceProvenance.displayName(for: bundle)
        )
    }

    @Test("Withings reading → high")
    func withingsHigh() {
        let samples = [bp("com.withings.wiscale2")]
        #expect(Reliability.bloodPressure(samples: samples) == .high)
    }

    @Test("Unknown source treated as medium (unknown medical device)")
    func unknownMedium() {
        let samples = [bp("com.unknown.cuff")]
        #expect(Reliability.bloodPressure(samples: samples) == .medium)
    }

    @Test("Manual entry from Apple Health → low")
    func manualLow() {
        let samples = [bp("com.apple.health")]
        #expect(Reliability.bloodPressure(samples: samples) == .low)
    }

    @Test("0 samples → insufficient")
    func emptyInsufficient() {
        #expect(Reliability.bloodPressure(samples: []) == .insufficient)
    }
}
