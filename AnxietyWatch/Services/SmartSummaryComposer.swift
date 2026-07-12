import Foundation

/// Deterministic "what changed today" composer. Pure data → 1-2 sentence
/// summary text. No LLM, no rendering. The view layer is a thin shell.
///
/// Selection: rank candidate signals by absolute z-score against their
/// 30-day baseline; pick top 1-3 with |z| > 1.0. Tie-break toward downward
/// direction (anxiety bias is asymmetric — "worse" matters more than "better").
nonisolated enum SmartSummaryComposer {

    struct Metric: Sendable {
        /// nil when the metric wasn't recorded (e.g. morning open before the
        /// Watch writes today's resting HR). A nil value produces no
        /// candidate — substituting 0 fabricated extreme "below baseline"
        /// headlines from missing data (F-010).
        let value: Double?
        let baseline: BaselineCalculator.BaselineResult?
    }

    struct Input: Sendable {
        let hrv: Metric
        let restingHR: Metric
        /// nil when last night has no sleep events — the candidate is
        /// skipped rather than reported as a fabricated 0% (F-011).
        let sleepEfficiencyPct: Double?
        let sleepEfficiencyBaseline: Double
        let ahi: Double?
        let ahiBaseline: BaselineCalculator.BaselineResult?
        let anxietyLast24h: Int?
    }

    enum Kind: Equatable, Sendable { case summary, quiet }

    struct Output: Equatable, Sendable {
        let kind: Kind
        let text: String
    }

    private struct Candidate {
        let label: String
        let zScore: Double
        let phrase: String
    }

    static func compose(input: Input) -> Output {
        var candidates: [Candidate] = []

        if let value = input.hrv.value, let b = input.hrv.baseline, b.standardDeviation > 0 {
            let z = (value - b.mean) / b.standardDeviation
            let pct = b.mean > 0 ? Int(abs(value - b.mean) / b.mean * 100) : 0
            candidates.append(.init(
                label: "HRV",
                zScore: z,
                phrase: "\(pct)% \(z < 0 ? "below" : "above") your baseline"
            ))
        }
        if let value = input.restingHR.value, let b = input.restingHR.baseline, b.standardDeviation > 0 {
            let z = (value - b.mean) / b.standardDeviation
            let delta = Int(abs(value - b.mean).rounded())
            candidates.append(.init(
                label: "Resting HR",
                zScore: z,
                phrase: "\(z >= 0 ? "up" : "down") \(delta) bpm"
            ))
        }
        if let efficiencyPct = input.sleepEfficiencyPct, input.sleepEfficiencyBaseline > 0 {
            let delta = efficiencyPct - input.sleepEfficiencyBaseline
            // Approximate σ for sleep efficiency is ~10 percentage points, consistent
            // with population norms; keeps the z-scale comparable to HRV/HR z-scores.
            let z = delta / 10.0
            candidates.append(.init(
                label: "Sleep efficiency",
                zScore: z,
                phrase: "was \(Int(efficiencyPct))% (typical \(Int(input.sleepEfficiencyBaseline))%)"
            ))
        }
        if let ahi = input.ahi, let b = input.ahiBaseline, b.standardDeviation > 0 {
            let z = (ahi - b.mean) / b.standardDeviation
            if abs(z) > 1.0 {
                candidates.append(.init(
                    label: "AHI",
                    zScore: z,
                    phrase: String(format: "%.1f (typical %.1f)", ahi, b.mean)
                ))
            }
        }

        let notable = candidates
            .filter { abs($0.zScore) > 1.0 }
            .sorted { lhs, rhs in
                if abs(lhs.zScore) != abs(rhs.zScore) { return abs(lhs.zScore) > abs(rhs.zScore) }
                return lhs.zScore < rhs.zScore
            }
            .prefix(3)

        let isQuiet = notable.isEmpty
            && (input.anxietyLast24h ?? 0) < 5

        if isQuiet {
            return Output(kind: .quiet, text: "Nothing unusual today.")
        }

        // Note: isQuiet has already been checked above and returned .quiet.
        // Reaching this point means we should produce a summary; pick the best
        // available shape.
        if notable.isEmpty {
            if let sev = input.anxietyLast24h, sev >= 5 {
                return Output(
                    kind: .summary,
                    text: "You logged anxiety at \(sev)/10 in the last day — no other signals stand out today."
                )
            }
            // Defensive fallback. Shouldn't be reachable given the isQuiet check.
            return Output(kind: .quiet, text: "Nothing unusual today.")
        }

        let clauses = notable.map { "\($0.label) \($0.phrase)" }
        let joined = englishJoin(clauses).appending(".")
        let text = joined.prefix(1).uppercased() + joined.dropFirst()
        return Output(kind: .summary, text: text)
    }

    private static func englishJoin(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default:
            return parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
    }
}
