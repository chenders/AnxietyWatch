import Foundation

/// Pure verdict + headline-text composer for the merged LastNightCard.
///
/// Breach rules:
/// - Sleep efficiency < 85% → breach.
/// - AHI >= 5 → breach.
/// - SpO₂ nadir < 92% → breach.
///
/// 0 breaches → "Solid night", 1 → "OK", 2+ → "Rough night".
nonisolated enum LastNightHeadline {
    struct Result: Equatable, Sendable {
        let verdict: String
        let text: String
    }

    static func compose(efficiencyPct: Double, ahi: Double?, nadirPct: Double?) -> Result {
        let effLow = efficiencyPct < 85
        let ahiHigh = (ahi ?? 0) >= 5
        let nadirLow = nadirPct.map { $0 < 92 } ?? false

        let breaches = [effLow, ahiHigh, nadirLow].filter { $0 }.count
        let verdict: String
        switch breaches {
        case 0: verdict = "Solid night"
        case 1: verdict = "OK"
        default: verdict = "Rough night"
        }

        var clauses: [String] = ["Sleep efficiency \(Int(efficiencyPct.rounded()))%"]
        if let ahi { clauses.append(String(format: "AHI %.1f", ahi)) }
        if let nadir = nadirPct { clauses.append("SpO₂ nadir \(Int(nadir.rounded()))%") }

        return Result(verdict: verdict, text: "\(verdict) · \(clauses.joined(separator: ", "))")
    }
}
