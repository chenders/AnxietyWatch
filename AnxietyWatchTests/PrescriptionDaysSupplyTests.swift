import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the daysSupply (PBM) code paths in PrescriptionSupplyCalculator.
/// The daysSupply field comes from pharmacy benefit managers and takes priority
/// over the quantity-based calculation. These paths were added after the initial
/// tests and need dedicated coverage.
struct PrescriptionDaysSupplyTests {

    private let calendar = Calendar.current
    private let referenceDate = Calendar.current.startOfDay(
        for: Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    )

    // MARK: - alertStalenessLimitDays with daysSupply

    @Test("Staleness limit uses daysSupply when available (90-day fill)")
    func stalenessLimitFromDaysSupply() {
        let rx = ModelFactory.prescription(
            quantity: 90,
            dateFilled: referenceDate,
            daysSupply: 90
        )
        // 90 * 2 = 180, which is > 60 (default)
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 180)
    }

    @Test("Staleness limit with daysSupply floors at default for short supplies")
    func stalenessLimitDaysSupplyFloor() {
        let rx = ModelFactory.prescription(
            quantity: 10,
            dateFilled: referenceDate,
            daysSupply: 10
        )
        // 10 * 2 = 20, but min is 60
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 60)
    }

    @Test("daysSupply takes priority over dailyDoseCount for staleness")
    func daysSupplyPriorityOverDailyDose() {
        let rx = ModelFactory.prescription(
            quantity: 90,
            dateFilled: referenceDate,
            daysSupply: 90
        )
        rx.dailyDoseCount = 1.0
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 180)
    }

    @Test("daysSupply of 0 falls through to dailyDoseCount")
    func zeroDaysSupplyFallsThrough() {
        let rx = ModelFactory.prescription(
            quantity: 60,
            dateFilled: referenceDate,
            daysSupply: 0
        )
        rx.dailyDoseCount = 2.0
        // daysSupply=0 skipped, dailyDoseCount: ceil(60/2)=30, max(30*2, 60) = 60
        #expect(PrescriptionSupplyCalculator.alertStalenessLimitDays(for: rx) == 60)
    }

    // MARK: - supplyStatus with daysSupply (effectiveRunOutDate priority)

    @Test("Supply status uses daysSupply to compute run-out date")
    func statusFromDaysSupply() {
        let rx = ModelFactory.prescription(
            quantity: 30,
            dateFilled: referenceDate,
            daysSupply: 30
        )
        let status = PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate)
        #expect(status == .good)
    }

    @Test("daysSupply run-out takes priority over estimatedRunOutDate")
    func daysSupplyOverridesEstimatedRunOut() {
        let staleRunOut = calendar.date(byAdding: .day, value: 3, to: referenceDate)!
        let rx = ModelFactory.prescription(
            quantity: 30,
            dateFilled: referenceDate,
            daysSupply: 30
        )
        rx.estimatedRunOutDate = staleRunOut
        // daysSupply takes priority: referenceDate + 30 = good (not low from staleRunOut)
        let status = PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate)
        #expect(status == .good)
    }

    @Test("daysSupply run-out takes priority over dailyDoseCount")
    func daysSupplyOverridesDailyDose() {
        let rx = ModelFactory.prescription(
            quantity: 30,
            dateFilled: referenceDate,
            daysSupply: 5
        )
        rx.dailyDoseCount = 1.0
        // daysSupply: referenceDate + 5 = low
        // dailyDoseCount would give: 30/1 = 30 days = good
        // daysSupply should win → low
        let status = PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate)
        #expect(status == .low)
    }

    @Test("daysSupply expired status")
    func daysSupplyExpired() {
        let oldFill = calendar.date(byAdding: .day, value: -40, to: referenceDate)!
        let rx = ModelFactory.prescription(
            quantity: 30,
            dateFilled: oldFill,
            daysSupply: 30
        )
        // Run-out = oldFill + 30 = referenceDate - 10 = expired
        let status = PrescriptionSupplyCalculator.supplyStatus(for: rx, now: referenceDate)
        #expect(status == .expired)
    }

    // MARK: - daysRemaining with daysSupply

    @Test("daysRemaining uses daysSupply when available")
    func daysRemainingFromDaysSupply() {
        let rx = ModelFactory.prescription(
            quantity: 30,
            dateFilled: referenceDate,
            daysSupply: 20
        )
        let remaining = PrescriptionSupplyCalculator.daysRemaining(for: rx, now: referenceDate)
        #expect(remaining == 20)
    }

    // MARK: - alertPrescriptions with lastFillDate

    @Test("alertPrescriptions uses lastFillDate for staleness when available")
    func alertUsesLastFillDate() {
        let oldFill = calendar.date(byAdding: .day, value: -90, to: referenceDate)!
        let recentRefill = calendar.date(byAdding: .day, value: -5, to: referenceDate)!
        let runOut = calendar.date(byAdding: .day, value: 3, to: referenceDate)!

        let rx = ModelFactory.prescription(
            quantity: 30,
            dateFilled: oldFill
        )
        rx.lastFillDate = recentRefill
        rx.estimatedRunOutDate = runOut

        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [rx], now: referenceDate)
        #expect(alerts.count == 1)
    }

    @Test("alertPrescriptions falls back to dateFilled when lastFillDate is nil")
    func alertFallsBackToDateFilled() {
        let recentFill = calendar.date(byAdding: .day, value: -5, to: referenceDate)!
        let runOut = calendar.date(byAdding: .day, value: 3, to: referenceDate)!

        let rx = ModelFactory.prescription(
            quantity: 30,
            dateFilled: recentFill
        )
        rx.estimatedRunOutDate = runOut

        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [rx], now: referenceDate)
        #expect(alerts.count == 1)
    }

    @Test("alertPrescriptions includes warning-status prescriptions")
    func alertIncludesWarning() {
        let runOut = calendar.date(byAdding: .day, value: 10, to: referenceDate)!
        let rx = ModelFactory.prescription(
            quantity: 30,
            dateFilled: referenceDate
        )
        rx.estimatedRunOutDate = runOut

        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: [rx], now: referenceDate)
        #expect(alerts.count == 1)
    }
}
