import HealthKit
import Testing

@testable import AnxietyWatch

/// Tests for SampleTypeConfig — lookup and anchored type registry.
struct SampleTypeConfigTests {

    // MARK: - config(for:) lookup

    @Test("Lookup heart rate by raw identifier")
    func lookupHeartRate() {
        let config = SampleTypeConfig.config(for: HKQuantityTypeIdentifier.heartRate.rawValue)
        #expect(config != nil)
        #expect(config?.displayName == "Heart Rate")
        #expect(config?.unitLabel == "bpm")
    }

    @Test("Lookup HRV by raw identifier")
    func lookupHRV() {
        let config = SampleTypeConfig.config(for: HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue)
        #expect(config != nil)
        #expect(config?.displayName == "HRV")
        #expect(config?.unitLabel == "ms")
    }

    @Test("Lookup blood oxygen by raw identifier")
    func lookupBloodOxygen() {
        let config = SampleTypeConfig.config(for: HKQuantityTypeIdentifier.oxygenSaturation.rawValue)
        #expect(config != nil)
        #expect(config?.displayName == "Blood Oxygen")
        #expect(config?.unitLabel == "%")
    }

    @Test("Lookup respiratory rate by raw identifier")
    func lookupRespiratoryRate() {
        let config = SampleTypeConfig.config(for: HKQuantityTypeIdentifier.respiratoryRate.rawValue)
        #expect(config != nil)
        #expect(config?.displayName == "Respiratory Rate")
        #expect(config?.unitLabel == "breaths/min")
    }

    @Test("Lookup blood pressure systolic")
    func lookupBPSystolic() {
        let config = SampleTypeConfig.config(for: HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue)
        #expect(config != nil)
        #expect(config?.displayName == "BP Systolic")
        #expect(config?.unitLabel == "mmHg")
    }

    @Test("Lookup blood pressure diastolic")
    func lookupBPDiastolic() {
        let config = SampleTypeConfig.config(for: HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue)
        #expect(config != nil)
        #expect(config?.displayName == "BP Diastolic")
        #expect(config?.unitLabel == "mmHg")
    }

    @Test("Lookup blood glucose")
    func lookupBloodGlucose() {
        let config = SampleTypeConfig.config(for: HKQuantityTypeIdentifier.bloodGlucose.rawValue)
        #expect(config != nil)
        #expect(config?.displayName == "Blood Glucose")
        #expect(config?.unitLabel == "mg/dL")
    }

    @Test("Lookup returns nil for unknown identifier")
    func lookupUnknownReturnsNil() {
        let config = SampleTypeConfig.config(for: "HKQuantityTypeIdentifierFakeMetric")
        #expect(config == nil)
    }

    @Test("Lookup returns nil for empty string")
    func lookupEmptyReturnsNil() {
        let config = SampleTypeConfig.config(for: "")
        #expect(config == nil)
    }

    // MARK: - Anchored types registry

    @Test("Anchored types list is not empty")
    func anchoredTypesNotEmpty() {
        #expect(!SampleTypeConfig.anchoredTypes.isEmpty)
    }

    @Test("All anchored types have non-empty display names")
    func allHaveDisplayNames() {
        for config in SampleTypeConfig.anchoredTypes {
            #expect(!config.displayName.isEmpty, "\(config.identifier.rawValue) missing display name")
        }
    }

    @Test("All anchored types have non-empty unit labels")
    func allHaveUnitLabels() {
        for config in SampleTypeConfig.anchoredTypes {
            #expect(!config.unitLabel.isEmpty, "\(config.identifier.rawValue) missing unit label")
        }
    }

    @Test("All anchored types have positive trend thresholds")
    func allHavePositiveThresholds() {
        for config in SampleTypeConfig.anchoredTypes {
            #expect(config.trendThreshold > 0, "\(config.identifier.rawValue) needs positive threshold")
        }
    }

    @Test("No duplicate identifiers in anchored types")
    func noDuplicateIdentifiers() {
        let identifiers = SampleTypeConfig.anchoredTypes.map(\.identifier.rawValue)
        #expect(Set(identifiers).count == identifiers.count, "Duplicate identifiers found")
    }

    @Test("Anchored types contains expected count of metrics")
    func expectedMetricCount() {
        // 13 types: HR, HRV, SpO2, RR, resting HR, VO2Max, walking HR,
        // walking steadiness, BP systolic, BP diastolic, blood glucose,
        // env sound, headphone audio
        #expect(SampleTypeConfig.anchoredTypes.count == 13)
    }
}
