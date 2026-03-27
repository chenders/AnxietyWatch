import Foundation

/// Stateless helpers for computing prescription supply duration and status.
enum PrescriptionSupplyCalculator {

    /// Prescriptions filled more than this many days ago are excluded from supply alerts.
    static let alertStalenessLimitDays = 60

    enum SupplyStatus {
        case good     // >14 days remaining
        case warning  // 7–14 days remaining
        case low      // <7 days remaining
        case expired  // past estimated run-out date
        case unknown  // no run-out date available
    }

    // MARK: - Run-out date

    /// Returns the estimated run-out date, or nil when dailyDoseCount is invalid.
    static func estimateRunOutDate(
        dateFilled: Date,
        quantity: Int,
        dailyDoseCount: Double
    ) -> Date? {
        guard dailyDoseCount > 0 else { return nil }
        let daysOfSupply = Double(quantity) / dailyDoseCount
        return Calendar.current.date(
            byAdding: .day,
            value: Int(ceil(daysOfSupply)),
            to: dateFilled
        )
    }

    // MARK: - Status

    /// Computes the supply status for a prescription based on its estimated run-out date.
    /// Returns `.unknown` when no run-out date can be determined.
    static func supplyStatus(for prescription: Prescription) -> SupplyStatus {
        guard let runOut = effectiveRunOutDate(for: prescription) else {
            return .unknown
        }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: .now),
            to: Calendar.current.startOfDay(for: runOut)
        ).day ?? 0

        switch days {
        case ..<0:
            return .expired
        case 0..<7:
            return .low
        case 7...14:
            return .warning
        default:
            return .good
        }
    }

    // MARK: - Days remaining

    /// Days between today and the estimated run-out date. Negative values mean overdue.
    /// Returns nil when no estimate is available.
    static func daysRemaining(for prescription: Prescription) -> Int? {
        guard let runOut = effectiveRunOutDate(for: prescription) else {
            return nil
        }
        return Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: .now),
            to: Calendar.current.startOfDay(for: runOut)
        ).day
    }

    // MARK: - Dose inference

    /// Infers the average daily dose count from logged doses within a recent window.
    /// Returns nil when fewer than 2 doses exist in the window (insufficient data).
    static func inferDailyDoseCount(
        for medicationName: String,
        doses: [MedicationDose],
        windowDays: Int = 14
    ) -> Double? {
        guard windowDays > 0 else { return nil }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -windowDays,
            to: .now
        ) ?? .distantPast

        let matchingDoses = doses.filter {
            $0.medicationName == medicationName && $0.timestamp >= cutoff
        }
        guard matchingDoses.count >= 2 else { return nil }

        return Double(matchingDoses.count) / Double(windowDays)
    }

    // MARK: - Private

    /// Resolves the best available run-out date: the stored value, or one computed
    /// from quantity and dailyDoseCount.
    private static func effectiveRunOutDate(for prescription: Prescription) -> Date? {
        if let stored = prescription.estimatedRunOutDate {
            return stored
        }
        guard let daily = prescription.dailyDoseCount else { return nil }
        return estimateRunOutDate(
            dateFilled: prescription.dateFilled,
            quantity: prescription.quantity,
            dailyDoseCount: daily
        )
    }
}
