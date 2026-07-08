import Foundation

/// Pure verdict + headline-text composer for the merged LastNightCard.
///
/// Breach rules:
/// - Sleep efficiency < 85% → breach (only when the efficiency was actually
///   measured — see below).
/// - AHI >= 5 → breach.
/// - SpO₂ nadir < 92% → breach.
///
/// 0 breaches → "Solid night", 1 → "OK", 2+ → "Rough night".
///
/// An *estimated* efficiency (missing/partial inBed coverage pins the value
/// at exactly 100% — see `SleepEfficiencyCalculator.isBedTimeEstimated`) is
/// not a measurement: it can neither breach nor certify. It is excluded
/// from the breach count, and a night whose efficiency couldn't be measured
/// caps at "OK" — claiming "Solid night" off a pinned artifact would pass
/// missing data off as a clean bill (F-024).
nonisolated enum LastNightHeadline {
    struct Result: Equatable, Sendable {
        let verdict: String
        let text: String
    }

    static func compose(
        efficiencyPct: Double,
        efficiencyEstimated: Bool = false,
        ahi: Double?,
        nadirPct: Double?
    ) -> Result {
        let effMeasured = !efficiencyEstimated
        let effLow = effMeasured && efficiencyPct < 85
        let ahiHigh = (ahi ?? 0) >= 5
        let nadirLow = nadirPct.map { $0 < 92 } ?? false

        let breaches = [effLow, ahiHigh, nadirLow].filter { $0 }.count
        let verdict: String
        switch breaches {
        case 0: verdict = effMeasured ? "Solid night" : "OK"
        case 1: verdict = "OK"
        default: verdict = "Rough night"
        }

        // "~" marks an estimated efficiency (incomplete inBed coverage pins
        // the value at exactly 100%) so the headline can't pass an artifact
        // of missing data off as a measured 100%.
        let effPrefix = efficiencyEstimated ? "~" : ""
        var clauses: [String] = ["Sleep efficiency \(effPrefix)\(Int(efficiencyPct.rounded()))%"]
        if let ahi { clauses.append(String(format: "AHI %.1f", ahi)) }
        if let nadir = nadirPct { clauses.append("SpO₂ nadir \(Int(nadir.rounded()))%") }

        return Result(verdict: verdict, text: "\(verdict) · \(clauses.joined(separator: ", "))")
    }
}
