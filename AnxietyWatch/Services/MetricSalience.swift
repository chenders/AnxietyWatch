import Foundation

/// Pure salience verdicts: should this metric be surfaced on the dashboard
/// or demoted into the Environment & background disclosure?
///
/// Each per-metric function captures the rule from the design spec. Add new
/// metrics as static functions — keep them pure and testable. The view layer
/// asks for a verdict; it does not know the rule.
nonisolated enum MetricSalience {
    enum Verdict: Equatable, Sendable { case surface, demote }

    /// VO₂ Max: surface if no baseline yet (informational) OR drop > 10% from
    /// 90-day baseline (real deconditioning). Otherwise demote.
    static func vo2MaxVerdict(latest: Double, baseline90d: Double?) -> Verdict {
        guard let baseline = baseline90d, baseline > 0 else { return .surface }
        return latest < baseline * 0.9 ? .surface : .demote
    }

    /// Walking HR: surface if recent avg > baseline + 1σ.
    static func walkingHRVerdict(recentAvg: Double, baselineMean: Double, baselineSD: Double) -> Verdict {
        recentAvg > baselineMean + baselineSD ? .surface : .demote
    }

    /// Walking Steadiness: surface on any state transition into Low / Very Low.
    /// `currentRatio` and `previousRatio` are 0.0–1.0 from Apple's category.
    static func walkingSteadinessVerdict(currentRatio: Double, previousRatio: Double?) -> Verdict {
        guard let previous = previousRatio else { return currentRatio < 0.6 ? .surface : .demote }
        // Transition into the Low/Very-Low band (Apple's thresholds: 0.4 / 0.6).
        return (previous >= 0.6 && currentRatio < 0.6) ? .surface : .demote
    }

    /// AFib burden: any nonzero value surfaces; week-over-week increase surfaces.
    static func afibBurdenVerdict(burden: Double, weekDelta: Double) -> Verdict {
        (burden > 0 || weekDelta > 0) ? .surface : .demote
    }

    /// Barometric pressure: surface if 24h Δ > 0.5 kPa in absolute value.
    static func barometricVerdict(deltaKPa24h: Double) -> Verdict {
        abs(deltaKPa24h) > 0.5 ? .surface : .demote
    }

    /// Audio exposure (Env or Headphone): surface if 7-day TWA > 80 dBA, OR any
    /// single reading > 85 dBA in the last 24h.
    static func audioExposureVerdict(twa7dayDBA: Double, max24hDBA: Double?) -> Verdict {
        if twa7dayDBA > 80 { return .surface }
        if let m = max24hDBA, m > 85 { return .surface }
        return .demote
    }

    /// Blood pressure: surface if last 3 readings out of normal range, OR reading > 7 days old.
    static func bloodPressureVerdict(
        last3Systolic: [Double],
        last3Diastolic: [Double],
        ageDays: Double
    ) -> Verdict {
        if ageDays > 7 { return .surface }
        let allOutOfRange = zip(last3Systolic, last3Diastolic).allSatisfy { sys, dia in
            sys > 130 || sys < 90 || dia > 80 || dia < 60
        }
        return (last3Systolic.count >= 3 && allOutOfRange) ? .surface : .demote
    }

    /// Blood glucose: surface if any reading > 180 OR fasting > 100.
    static func glucoseVerdict(latest: Double, fasting: Double?) -> Verdict {
        if latest > 180 { return .surface }
        if let f = fasting, f > 100 { return .surface }
        return .demote
    }
}
