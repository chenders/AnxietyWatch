import Foundation
@testable import AnxietyWatch

/// Factory methods for creating test model instances with sensible defaults.
/// Every parameter has a default so tests only override what they're testing.
/// All default values use obviously fictional data per project conventions.
enum ModelFactory {

    /// Counter for generating unique but deterministic test identifiers.
    private static var _counter = 0
    private static func nextID() -> String {
        _counter += 1
        return "test-\(_counter)"
    }

    // MARK: - Reference date

    /// Fixed reference date for deterministic tests. Use this instead of Date.now
    /// to prevent flakiness when tests run across midnight.
    static let referenceDate = Date(timeIntervalSince1970: 1_711_929_600) // 2024-04-01 00:00:00 UTC

    /// Fixed Gregorian calendar in UTC for deterministic date arithmetic in tests.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Returns a date N days before the reference date.
    static func daysAgo(_ n: Int, from base: Date = referenceDate) -> Date {
        utcCalendar.date(byAdding: .day, value: -n, to: base)!
    }

    // MARK: - Journal

    static func anxietyEntry(
        timestamp: Date = referenceDate,
        severity: Int = 5,
        notes: String = "",
        tags: [String] = [],
        triggerDose: MedicationDose? = nil,
        isFollowUp: Bool = false
    ) -> AnxietyEntry {
        AnxietyEntry(
            timestamp: timestamp,
            severity: severity,
            notes: notes,
            tags: tags,
            triggerDose: triggerDose,
            isFollowUp: isFollowUp
        )
    }

    // MARK: - Health

    static func healthSnapshot(
        date: Date = referenceDate,
        hrvAvg: Double? = 42.0,
        hrvMin: Double? = nil,
        restingHR: Double? = 62.0,
        sleepDurationMin: Int? = 420,
        sleepDeepMin: Int? = 60,
        sleepREMMin: Int? = 90,
        sleepCoreMin: Int? = 270,
        sleepAwakeMin: Int? = 20,
        steps: Int? = 8500,
        activeCalories: Double? = 350.0,
        exerciseMinutes: Int? = 30,
        spo2Avg: Double? = 97.0,
        respiratoryRate: Double? = 14.0,
        bpSystolic: Double? = nil,
        bpDiastolic: Double? = nil,
        timeInDaylightMin: Int? = nil,
        physicalEffortAvg: Double? = nil
    ) -> HealthSnapshot {
        let snapshot = HealthSnapshot(date: date)
        snapshot.hrvAvg = hrvAvg
        snapshot.hrvMin = hrvMin
        snapshot.restingHR = restingHR
        snapshot.sleepDurationMin = sleepDurationMin
        snapshot.sleepDeepMin = sleepDeepMin
        snapshot.sleepREMMin = sleepREMMin
        snapshot.sleepCoreMin = sleepCoreMin
        snapshot.sleepAwakeMin = sleepAwakeMin
        snapshot.steps = steps
        snapshot.activeCalories = activeCalories
        snapshot.exerciseMinutes = exerciseMinutes
        snapshot.spo2Avg = spo2Avg
        snapshot.respiratoryRate = respiratoryRate
        snapshot.bpSystolic = bpSystolic
        snapshot.bpDiastolic = bpDiastolic
        snapshot.timeInDaylightMin = timeInDaylightMin
        snapshot.physicalEffortAvg = physicalEffortAvg
        return snapshot
    }

    static func healthSample(
        type: String = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        value: Double = 42.0,
        timestamp: Date = referenceDate,
        source: String? = "Test Apple Watch"
    ) -> HealthSample {
        HealthSample(type: type, value: value, timestamp: timestamp, source: source)
    }

    // MARK: - Medications

    static func medicationDefinition(
        name: String = "Test Medication 50mg",
        defaultDoseMg: Double = 50.0,
        category: String = "SSRI",
        isActive: Bool = true,
        promptAnxietyOnLog: Bool = false
    ) -> MedicationDefinition {
        MedicationDefinition(
            name: name,
            defaultDoseMg: defaultDoseMg,
            category: category,
            isActive: isActive,
            promptAnxietyOnLog: promptAnxietyOnLog
        )
    }

    static func medicationDose(
        timestamp: Date = referenceDate,
        medicationName: String = "Test Medication 50mg",
        doseMg: Double = 50.0,
        notes: String? = nil,
        isPRN: Bool = true,
        medication: MedicationDefinition? = nil
    ) -> MedicationDose {
        MedicationDose(
            timestamp: timestamp,
            medicationName: medicationName,
            doseMg: doseMg,
            notes: notes,
            isPRN: isPRN,
            medication: medication
        )
    }

    // MARK: - CPAP

    static func cpapSession(
        date: Date = referenceDate,
        ahi: Double = 2.5,
        totalUsageMinutes: Int = 420,
        leakRate95th: Double? = 18.0,
        pressureMin: Double = 6.0,
        pressureMax: Double = 12.0,
        pressureMean: Double = 9.5,
        obstructiveEvents: Int = 3,
        centralEvents: Int = 1,
        hypopneaEvents: Int = 2,
        importSource: String = "csv"
    ) -> CPAPSession {
        CPAPSession(
            date: date,
            ahi: ahi,
            totalUsageMinutes: totalUsageMinutes,
            leakRate95th: leakRate95th,
            pressureMin: pressureMin,
            pressureMax: pressureMax,
            pressureMean: pressureMean,
            obstructiveEvents: obstructiveEvents,
            centralEvents: centralEvents,
            hypopneaEvents: hypopneaEvents,
            importSource: importSource
        )
    }

    // MARK: - Barometric

    static func barometricReading(
        timestamp: Date = referenceDate,
        pressureKPa: Double = 101.3,
        relativeAltitudeM: Double = 0.0
    ) -> BarometricReading {
        BarometricReading(
            timestamp: timestamp,
            pressureKPa: pressureKPa,
            relativeAltitudeM: relativeAltitudeM
        )
    }

    // MARK: - Clinical

    static func clinicalLabResult(
        loincCode: String = "2093-3",
        testName: String = "Total Cholesterol",
        value: Double = 180.0,
        unit: String = "mg/dL",
        effectiveDate: Date = referenceDate,
        referenceRangeLow: Double? = nil,
        referenceRangeHigh: Double? = 200.0,
        interpretation: String? = nil,
        sourceName: String? = "Test Provider",
        healthKitSampleUUID: String = nextID()
    ) -> ClinicalLabResult {
        ClinicalLabResult(
            loincCode: loincCode,
            testName: testName,
            value: value,
            unit: unit,
            effectiveDate: effectiveDate,
            referenceRangeLow: referenceRangeLow,
            referenceRangeHigh: referenceRangeHigh,
            interpretation: interpretation,
            sourceName: sourceName,
            healthKitSampleUUID: healthKitSampleUUID
        )
    }

    // MARK: - Pharmacy

    static func pharmacy(
        name: String = "Test Pharmacy #12345",
        address: String = "100 Example Blvd, Anytown, ST 00000",
        phoneNumber: String = "555-0100",
        isActive: Bool = true
    ) -> Pharmacy {
        Pharmacy(
            name: name,
            address: address,
            phoneNumber: phoneNumber,
            isActive: isActive
        )
    }

    static func prescription(
        rxNumber: String = "9999999-00001",
        medicationName: String = "Test Medication 50mg",
        doseMg: Double = 50.0,
        quantity: Int = 30,
        refillsRemaining: Int = 3,
        dateFilled: Date = referenceDate,
        pharmacyName: String = "Test Pharmacy #12345",
        prescriberName: String = "Jane Smith MD",
        importSource: String = "manual",
        medication: MedicationDefinition? = nil,
        pharmacy: Pharmacy? = nil,
        daysSupply: Int? = nil,
        patientPay: Double? = nil,
        planPay: Double? = nil,
        dosageForm: String = "",
        drugType: String = ""
    ) -> Prescription {
        Prescription(
            rxNumber: rxNumber,
            medicationName: medicationName,
            doseMg: doseMg,
            quantity: quantity,
            refillsRemaining: refillsRemaining,
            dateFilled: dateFilled,
            pharmacyName: pharmacyName,
            prescriberName: prescriberName,
            importSource: importSource,
            daysSupply: daysSupply,
            patientPay: patientPay,
            planPay: planPay,
            dosageForm: dosageForm,
            drugType: drugType,
            medication: medication,
            pharmacy: pharmacy
        )
    }

    static func pharmacyCallLog(
        timestamp: Date = referenceDate,
        direction: String = "outgoing",
        pharmacyName: String = "Test Pharmacy #12345",
        notes: String = "",
        durationSeconds: Int? = 120,
        pharmacy: Pharmacy? = nil
    ) -> PharmacyCallLog {
        PharmacyCallLog(
            timestamp: timestamp,
            direction: direction,
            pharmacyName: pharmacyName,
            notes: notes,
            durationSeconds: durationSeconds,
            pharmacy: pharmacy
        )
    }
}
