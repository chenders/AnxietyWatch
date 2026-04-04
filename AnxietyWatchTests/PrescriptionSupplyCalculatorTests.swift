import Foundation
import Testing

@testable import AnxietyWatch

struct PrescriptionSupplyCalculatorTests {

    private let calendar = Calendar.current
    /// Fixed reference date for deterministic tests — avoids .now race conditions.
    private let referenceDate = Calendar.current.startOfDay(
        for: Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    )

    private func makeRx(
        dateFilled: Date? = nil,
        quantity: Int = 30,
        dailyDoseCount: Double? = nil,
        estimatedRunOutDate: Date? = nil
    ) throws -> Prescription {
        Prescription(
            rxNumber: "TEST-001",
            medicationName: "Test Drug",
            doseMg: 10.0,
            quantity: quantity,
            dateFilled: dateFilled ?? referenceDate,
            estimatedRunOutDate: estimatedRunOutDate,
            dailyDoseCount: dailyDoseCount
        )
    }

    // MARK: - alertStalenessLimitDays

    @Test("Staleness limit is 2x supply for 30-day fill (1/day)")
    func stalenessLimit30Day() throws {
        let rx = try makeRx(quantity: 30, dailyDoseCount: 1.0)
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 60)
    }

    @Test("Staleness limit is 2x supply for 90-day fill (1/day)")
    func stalenessLimit90Day() throws {
        let rx = try makeRx(quantity: 90, dailyDoseCount: 1.0)
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 180)
    }

    @Test("Staleness limit floors at default (60) for short fills")
    func stalenessLimitFloor() throws {
        // 10 pills / 1 per day = 10-day supply, 2x = 20, but min is 60
        let rx = try makeRx(quantity: 10, dailyDoseCount: 1.0)
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 60)
    }

    @Test("Staleness limit returns default when dailyDoseCount is nil")
    func stalenessLimitNilDose() throws {
        let rx = try makeRx(quantity: 30, dailyDoseCount: nil)
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 60)
    }

    @Test("Staleness limit returns default when dailyDoseCount is zero")
    func stalenessLimitZeroDose() throws {
        let rx = try makeRx(quantity: 30, dailyDoseCount: 0)
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 60)
    }

    @Test("Staleness limit returns default when dailyDoseCount is negative")
    func stalenessLimitNegativeDose() throws {
        let rx = try makeRx(quantity: 30, dailyDoseCount: -1.0)
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 60)
    }

    @Test("Staleness limit rounds up fractional supply days")
    func stalenessLimitFractional() throws {
        // 30 pills / 0.5 per day = 60-day supply, 2x = 120
        let rx = try makeRx(quantity: 30, dailyDoseCount: 0.5)
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 120)
    }

    // MARK: - estimateRunOutDate

    @Test("Run-out date calculated from quantity and daily dose")
    func estimateRunOutDate() {
        let filled = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let result = PrescriptionSupplyCalculator.estimateRunOutDate(
            dateFilled: filled, quantity: 30, dailyDoseCount: 1.0
        )
        let expected = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        #expect(result == expected)
    }

    @Test("Run-out date nil when daily dose is zero")
    func estimateRunOutDateZeroDose() {
        let result = PrescriptionSupplyCalculator.estimateRunOutDate(
            dateFilled: referenceDate, quantity: 30, dailyDoseCount: 0
        )
        #expect(result == nil)
    }

    @Test("Run-out date nil when daily dose is negative")
    func estimateRunOutDateNegativeDose() {
        let result = PrescriptionSupplyCalculator.estimateRunOutDate(
            dateFilled: referenceDate, quantity: 30, dailyDoseCount: -1
        )
        #expect(result == nil)
    }

    @Test("Fractional daily dose rounds up days")
    func estimateRunOutDateFractional() {
        let filled = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        // 30 pills / 0.5 per day = 60 days
        let result = PrescriptionSupplyCalculator.estimateRunOutDate(
            dateFilled: filled, quantity: 30, dailyDoseCount: 0.5
        )
        let expected = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!
        #expect(result == expected)
    }

    // MARK: - supplyStatus

    @Test("Status is .unknown when no run-out date available")
    func statusUnknown() throws {
        let rx = try makeRx()
        #expect(PrescriptionSupplyCalculator.supplyStatus(for: rx) == .unknown)
    }

    @Test("Status is .good when >14 days remaining")
    func statusGood() throws {
        let futureDate = calendar.date(byAdding: .day, value: 30, to: referenceDate)!
        let rx = try makeRx(estimatedRunOutDate: futureDate)
        #expect(PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate) == .good)
    }

    @Test("Status is .warning at exactly 14 days")
    func statusWarning14() throws {
        let futureDate = calendar.date(byAdding: .day, value: 14, to: referenceDate)!
        let rx = try makeRx(estimatedRunOutDate: futureDate)
        #expect(PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate) == .warning)
    }

    @Test("Status is .warning at 7 days")
    func statusWarning7() throws {
        let futureDate = calendar.date(byAdding: .day, value: 7, to: referenceDate)!
        let rx = try makeRx(estimatedRunOutDate: futureDate)
        #expect(PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate) == .warning)
    }

    @Test("Status is .low at 6 days")
    func statusLow() throws {
        let futureDate = calendar.date(byAdding: .day, value: 6, to: referenceDate)!
        let rx = try makeRx(estimatedRunOutDate: futureDate)
        #expect(PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate) == .low)
    }

    @Test("Status is .low at 0 days (today)")
    func statusLowToday() throws {
        let rx = try makeRx(estimatedRunOutDate: referenceDate)
        #expect(PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate) == .low)
    }

    @Test("Status is .expired when past run-out")
    func statusExpired() throws {
        let past = calendar.date(byAdding: .day, value: -1, to: referenceDate)!
        let rx = try makeRx(estimatedRunOutDate: past)
        #expect(PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate) == .expired)
    }

    // MARK: - daysRemaining

    @Test("Days remaining nil when no run-out date")
    func daysRemainingNil() throws {
        let rx = try makeRx()
        #expect(PrescriptionSupplyCalculator.daysRemaining(for: rx, now: referenceDate) == nil)
    }

    @Test("Days remaining positive for future date")
    func daysRemainingPositive() throws {
        let futureDate = calendar.date(byAdding: .day, value: 10, to: referenceDate)!
        let rx = try makeRx(estimatedRunOutDate: futureDate)
        let remaining = PrescriptionSupplyCalculator.daysRemaining(for: rx, now: referenceDate)
        #expect(remaining == 10)
    }

    @Test("Days remaining negative for past date")
    func daysRemainingNegative() throws {
        let past = calendar.date(byAdding: .day, value: -3, to: referenceDate)!
        let rx = try makeRx(estimatedRunOutDate: past)
        let remaining = PrescriptionSupplyCalculator.daysRemaining(for: rx, now: referenceDate)
        #expect(remaining == -3)
    }

    // MARK: - inferDailyDoseCount

    @Test("Infer daily dose from logged doses")
    func inferDailyDoseCount() {
        let doses = (0..<7).map { i in
            MedicationDose(
                timestamp: calendar.date(byAdding: .day, value: -i, to: referenceDate)!,
                medicationName: "TestMed",
                doseMg: 10.0
            )
        }
        let result = PrescriptionSupplyCalculator.inferDailyDoseCount(
            for: "TestMed", doses: doses, windowDays: 14, now: referenceDate
        )
        #expect(result == 0.5)
    }

    @Test("Infer returns nil with fewer than 2 doses")
    func inferTooFewDoses() {
        let doses = [MedicationDose(medicationName: "TestMed", doseMg: 10.0)]
        let result = PrescriptionSupplyCalculator.inferDailyDoseCount(
            for: "TestMed", doses: doses, windowDays: 14
        )
        #expect(result == nil)
    }

    // MARK: - alertPrescriptions

    @Test("Alert includes low-supply prescription")
    func alertIncludesLow() throws {
        let runOut = calendar.date(byAdding: .day, value: 3, to: referenceDate)!
        let rx = try makeRx(dateFilled: referenceDate, dailyDoseCount: 1.0, estimatedRunOutDate: runOut)
        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [rx], now: referenceDate)
        #expect(alerts.count == 1)
    }

    @Test("Alert excludes good-supply prescription")
    func alertExcludesGood() throws {
        let runOut = calendar.date(byAdding: .day, value: 30, to: referenceDate)!
        let rx = try makeRx(dateFilled: referenceDate, dailyDoseCount: 1.0, estimatedRunOutDate: runOut)
        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [rx], now: referenceDate)
        #expect(alerts.isEmpty)
    }

    @Test("Alert excludes unknown-status prescription (no run-out date)")
    func alertExcludesUnknown() throws {
        let rx = try makeRx(dateFilled: referenceDate)
        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [rx], now: referenceDate)
        #expect(alerts.isEmpty)
    }

    @Test("Alert includes expired prescription")
    func alertIncludesExpired() throws {
        let pastRunOut = calendar.date(byAdding: .day, value: -5, to: referenceDate)!
        let rx = try makeRx(dateFilled: calendar.date(byAdding: .day, value: -35, to: referenceDate)!,
                            dailyDoseCount: 1.0, estimatedRunOutDate: pastRunOut)
        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [rx], now: referenceDate)
        #expect(alerts.count == 1)
    }

    @Test("Alert excludes stale prescription past staleness limit")
    func alertExcludesStale() throws {
        // 30 pills / 1 per day = 30-day supply, staleness = max(60, 60) = 60
        // Fill 90 days ago → well past the 60-day staleness limit
        let oldFill = calendar.date(byAdding: .day, value: -90, to: referenceDate)!
        let pastRunOut = calendar.date(byAdding: .day, value: -60, to: referenceDate)!
        let rx = try makeRx(dateFilled: oldFill, quantity: 30, dailyDoseCount: 1.0, estimatedRunOutDate: pastRunOut)
        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [rx], now: referenceDate)
        #expect(alerts.isEmpty)
    }

    @Test("Alert only considers most recent fill per medication")
    func alertDeduplicatesByMedication() throws {
        // Old fill: expired (run out 30 days ago)
        let oldFill = calendar.date(byAdding: .day, value: -60, to: referenceDate)!
        let oldRunOut = calendar.date(byAdding: .day, value: -30, to: referenceDate)!
        let oldRx = Prescription(
            rxNumber: "OLD-001",
            medicationName: "Test Drug",
            doseMg: 10.0,
            quantity: 30,
            dateFilled: oldFill,
            estimatedRunOutDate: oldRunOut,
            dailyDoseCount: 1.0
        )

        // New fill: good supply (run out in 20 days)
        let newRunOut = calendar.date(byAdding: .day, value: 20, to: referenceDate)!
        let newRx = Prescription(
            rxNumber: "NEW-001",
            medicationName: "Test Drug",
            doseMg: 10.0,
            quantity: 30,
            dateFilled: referenceDate,
            estimatedRunOutDate: newRunOut,
            dailyDoseCount: 1.0
        )

        // Both fills together — should only alert on the newest (which is good supply)
        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [oldRx, newRx], now: referenceDate)
        #expect(alerts.isEmpty, "Old expired fill should not trigger alert when newer fill has good supply")
    }

    @Test("latestPrescriptionPerMedication keeps newest fill")
    func latestPerMedication() {
        let old = Prescription(rxNumber: "OLD", medicationName: "DrugA", doseMg: 10, quantity: 30,
                               dateFilled: calendar.date(byAdding: .day, value: -30, to: referenceDate)!)
        let new1 = Prescription(rxNumber: "NEW", medicationName: "DrugA", doseMg: 10, quantity: 30,
                                dateFilled: referenceDate)
        let other = Prescription(rxNumber: "OTHER", medicationName: "DrugB", doseMg: 5, quantity: 60,
                                 dateFilled: referenceDate)

        let result = PrescriptionSupplyCalculator.latestPrescriptionPerMedication(from: [old, new1, other])
        #expect(result.count == 2)
        let drugA = result.first { $0.medicationName == "DrugA" }
        #expect(drugA?.rxNumber == "NEW")
    }

    @Test("Alert excludes prescription for inactive medication")
    func alertExcludesInactiveMedication() throws {
        let runOut = calendar.date(byAdding: .day, value: 3, to: referenceDate)!
        let rx = try makeRx(dateFilled: referenceDate, dailyDoseCount: 1.0, estimatedRunOutDate: runOut)
        let med = MedicationDefinition(name: "Test Drug", defaultDoseMg: 10.0, category: "test", isActive: false)
        rx.medication = med
        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [rx], now: referenceDate)
        #expect(alerts.isEmpty)
    }
}
