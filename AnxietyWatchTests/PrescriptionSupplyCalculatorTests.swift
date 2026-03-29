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
}
