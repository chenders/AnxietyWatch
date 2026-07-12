import HealthKit
import Testing

@testable import AnxietyWatch

/// Guards the HealthKit read-authorization set against types HealthKit refuses
/// to authorize for *reading*.
///
/// Why assert on the set's shape rather than on `requestAuthorization()`'s
/// behavior: an illegal read type makes HealthKit raise an ObjC
/// `NSInvalidArgumentException`, which Swift's `try` cannot catch. The app dies
/// on signal 6 with no Swift error to inspect, so there is no failure path a
/// test could exercise. Validating the input set is the only available defense.
///
/// This is a regression suite for a real crash: `HKCorrelationType(.bloodPressure)`
/// was in the read set, and every fresh install aborted the moment the user
/// tapped "Allow" on the HealthKit prompt —
/// `'Authorization to read the following types is disallowed:
/// HKCorrelationTypeIdentifierBloodPressure'`. It was invisible for months
/// because HealthKit never re-prompts an already-authorized install; only a
/// first-run authorization reaches the call. A bundle-ID rename made every
/// existing user a first-run user and detonated it.
struct HealthKitManagerReadTypesTests {

    @Test("read set contains no HKCorrelationType — HealthKit disallows authorizing them for read")
    func readSetHasNoCorrelationTypes() {
        let offenders = HealthKitManager.allReadTypes
            .compactMap { $0 as? HKCorrelationType }
            .map(\.identifier)

        #expect(
            offenders.isEmpty,
            """
            HKCorrelationType is not authorizable for reading — requestAuthorization \
            raises NSInvalidArgumentException and the app aborts on signal 6. \
            Read access to a correlation comes from its constituent quantity types \
            (e.g. request .bloodPressureSystolic + .bloodPressureDiastolic, not \
            HKCorrelationType(.bloodPressure)). Offending types: \(offenders)
            """
        )
    }

    /// The positive half of the above: dropping the correlation type must not
    /// cost us blood-pressure access. The two quantity types are what actually
    /// confer it — and what `queryBloodPressure()`'s HKCorrelationQuery reads
    /// through.
    @Test("blood-pressure read access is still requested via its two quantity types")
    func bloodPressureQuantityTypesAreRequested() {
        let requested = HealthKitManager.allReadTypes

        #expect(requested.contains(HKQuantityType(.bloodPressureSystolic)))
        #expect(requested.contains(HKQuantityType(.bloodPressureDiastolic)))
    }

    /// Characteristic, category, and workout types ARE legal to request for
    /// reading, so the correlation ban must not be over-applied to them. This
    /// pins the distinction so a future "just remove the weird types" cleanup
    /// doesn't strip authorization the app genuinely needs.
    @Test("legal non-quantity read types are still present")
    func legalNonQuantityTypesSurvive() {
        let requested = HealthKitManager.allReadTypes

        #expect(requested.contains(HKCategoryType(.sleepAnalysis)))
        #expect(requested.contains(HKWorkoutType.workoutType()))
        #expect(requested.contains(HKCharacteristicType(.dateOfBirth)))
        #expect(requested.contains(HKCharacteristicType(.biologicalSex)))
    }
}
