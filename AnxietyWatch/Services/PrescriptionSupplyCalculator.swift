import Foundation

/// Stateless helpers for computing prescription supply duration and status.
enum PrescriptionSupplyCalculator {

    /// Default staleness limit when a prescription's supply duration can't be determined.
    static let defaultStalenessLimitDays = 60

    /// Returns the staleness limit for a specific prescription — twice its supply
    /// duration, or the default if supply can't be calculated. A 90-day fill should
    /// not expire from alerts at 60 days.
    static func alertStalenessLimitDays(for prescription: Prescription) -> Int {
        // Prefer daysSupply from PBM over quantity-based calculation
        if let daysSupply = prescription.daysSupply, daysSupply > 0 {
            return max(daysSupply * 2, defaultStalenessLimitDays)
        }
        if let daily = prescription.dailyDoseCount, daily > 0 {
            let supplyDays = Int(ceil(Double(prescription.quantity) / daily))
            return max(supplyDays * 2, defaultStalenessLimitDays)
        }
        return defaultStalenessLimitDays
    }

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
    static func supplyStatus(for prescription: Prescription, now: Date = .now) -> SupplyStatus {
        guard let runOut = effectiveRunOutDate(for: prescription) else {
            return .unknown
        }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: now),
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
    static func daysRemaining(for prescription: Prescription, now: Date = .now) -> Int? {
        guard let runOut = effectiveRunOutDate(for: prescription) else {
            return nil
        }
        return Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: now),
            to: Calendar.current.startOfDay(for: runOut)
        ).day
    }

    // MARK: - Dose inference

    /// Infers the average daily dose count from logged doses within a recent window.
    /// Returns nil when fewer than 2 doses exist in the window (insufficient data).
    static func inferDailyDoseCount(
        for medicationName: String,
        doses: [MedicationDose],
        windowDays: Int = 14,
        now: Date = .now
    ) -> Double? {
        guard windowDays > 0 else { return nil }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -windowDays,
            to: now
        ) ?? .distantPast

        let matchingDoses = doses.filter {
            $0.medicationName == medicationName && $0.timestamp >= cutoff
        }
        guard matchingDoses.count >= 2 else { return nil }

        return Double(matchingDoses.count) / Double(windowDays)
    }

    // MARK: - Alert Filtering

    /// Filters prescriptions to those with supply alerts (low, warning, or expired).
    /// Only considers the most recent fill per medication (older fills are superseded
    /// by the newer fill and not actionable). Excludes stale prescriptions and inactive medications.
    /// Consolidates the filter logic used by Dashboard, MedicationsHub, and tests.
    static func alertPrescriptions(from prescriptions: [Prescription], now: Date = .now) -> [Prescription] {
        // Keep only the most recent fill per medication name
        let latestPerMed = latestPrescriptionPerMedication(from: prescriptions)

        return latestPerMed.filter { rx in
            let fillDate = rx.lastFillDate ?? rx.dateFilled
            let stalenessLimit = alertStalenessLimitDays(for: rx)
            let cutoff = Calendar.current.date(byAdding: .day, value: -stalenessLimit, to: now)
            if let cutoff, fillDate < cutoff { return false }
            if rx.medication?.isActive == false { return false }
            let status = supplyStatus(for: rx, now: now)
            return status == .low || status == .warning || status == .expired
        }
    }

    /// Returns the most recent prescription per medication name, by fill date.
    static func latestPrescriptionPerMedication(from prescriptions: [Prescription]) -> [Prescription] {
        var latest: [String: Prescription] = [:]
        for rx in prescriptions {
            let fillDate = rx.lastFillDate ?? rx.dateFilled
            if let existing = latest[rx.medicationName] {
                let existingDate = existing.lastFillDate ?? existing.dateFilled
                if fillDate > existingDate {
                    latest[rx.medicationName] = rx
                }
            } else {
                latest[rx.medicationName] = rx
            }
        }
        return Array(latest.values)
    }

    // MARK: - Private

    /// Resolves the best available run-out date. Prefers daysSupply from PBM
    /// (most authoritative), then stored estimatedRunOutDate, then quantity-based.
    private static func effectiveRunOutDate(for prescription: Prescription) -> Date? {
        // daysSupply from PBM is most authoritative — check first so stale
        // server-computed estimatedRunOutDate values don't override it
        if let daysSupply = prescription.daysSupply, daysSupply > 0 {
            return Calendar.current.date(
                byAdding: .day,
                value: daysSupply,
                to: prescription.dateFilled
            )
        }
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
