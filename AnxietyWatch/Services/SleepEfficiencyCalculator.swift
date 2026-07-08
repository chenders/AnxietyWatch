import Foundation

/// Pure computation of sleep efficiency and WASO from a single night's
/// `SleepStageEvent` stream. Stage strings follow `HKCategoryValueSleepAnalysis`
/// naming: `inBed`, `awake`, `asleepCore`, `asleepREM`, `asleepDeep`, `asleepUnspecified`.
///
/// Why this lives here and not in `SnapshotAggregator`: efficiency / WASO are
/// derived from the event stream every time the dashboard renders. Keeping the
/// math pure makes it testable and lets the view layer call it without
/// touching SwiftData.
nonisolated enum SleepEfficiencyCalculator {
    struct Result: Equatable, Sendable {
        let inBedMinutes: Int
        let asleepMinutes: Int
        let wasoMinutes: Int
        let efficiencyPct: Double
        /// `true` when the asleep span was used as the denominator — either
        /// because no explicit `inBed` events were present at all, or because
        /// partial `inBed` coverage summed to less than the asleep span (in
        /// which case efficiency pins at exactly 100%). Callers must surface
        /// a visual cue (e.g. "~" prefix) so the estimated value can't be
        /// mistaken for a measured one.
        let isBedTimeEstimated: Bool
    }

    static func compute(from events: [SleepStageEvent]) -> Result {
        guard !events.isEmpty else {
            return Result(inBedMinutes: 0, asleepMinutes: 0, wasoMinutes: 0, efficiencyPct: 0,
                          isBedTimeEstimated: false)
        }

        let asleepIntervals = events
            .filter { $0.stage.hasPrefix("asleep") }
            .map { (start: $0.startTime, end: $0.endTime) }
        // gapTolerance: 0 — preserve exact boundaries for efficiency math.
        // (The merger's 5-min default would absorb short awakenings into adjacent
        //  asleep intervals, hiding real WASO.)
        let asleepMerged = SleepIntervalMerger.coalesce(asleepIntervals, gapTolerance: 0)
        let asleepSeconds = asleepMerged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        let asleepMinutes = Int(asleepSeconds / 60)

        let inBedIntervals = events
            .filter { $0.stage == "inBed" }
            .map { (start: $0.startTime, end: $0.endTime) }
        // gapTolerance: 0 — preserve exact boundaries for efficiency math.
        let inBedMerged = SleepIntervalMerger.coalesce(inBedIntervals, gapTolerance: 0)
        let inBedSeconds = inBedMerged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        let inBedFromEvents = Int(inBedSeconds / 60)
        // Fallback when no explicit inBed events exist, OR when partial
        // inBed coverage produces a denominator smaller than the asleep
        // span (Apple Watch and EMAY frequently log asleep stages without
        // a wrapping `inBed` event, or only partial inBed coverage).
        // Without the `max`, efficiency degenerates to >100% in the
        // partial-inBed case, which is physically nonsensical (you cannot
        // sleep longer than you are in bed). Using the asleep span as a
        // floor pins the worst case to 100%.
        let inBedMinutes = max(inBedFromEvents, asleepMinutes)
        let isBedTimeEstimated = inBedFromEvents == 0 || inBedFromEvents < asleepMinutes

        // WASO = awake intervals that fall BETWEEN the first asleep onset
        // and the last asleep offset. Awake before onset (sleep latency) and
        // awake after final wake do not count.
        let wasoMinutes: Int
        if let firstAsleep = asleepMerged.first?.start,
           let lastAsleep = asleepMerged.last?.end {
            let awakeIntervals = events
                .filter { $0.stage == "awake" }
                .map { (start: $0.startTime, end: $0.endTime) }
                .compactMap { iv -> (start: Date, end: Date)? in
                    let clampedStart = max(iv.start, firstAsleep)
                    let clampedEnd = min(iv.end, lastAsleep)
                    return clampedStart < clampedEnd ? (start: clampedStart, end: clampedEnd) : nil
                }
            // gapTolerance: 0 — preserve exact boundaries for efficiency math.
            let wasoSeconds = SleepIntervalMerger.coalesce(awakeIntervals, gapTolerance: 0)
                .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            wasoMinutes = Int(wasoSeconds / 60)
        } else {
            wasoMinutes = 0
        }

        let efficiency = inBedMinutes > 0 ? Double(asleepMinutes) / Double(inBedMinutes) * 100.0 : 0
        return Result(
            inBedMinutes: inBedMinutes,
            asleepMinutes: asleepMinutes,
            wasoMinutes: wasoMinutes,
            efficiencyPct: efficiency,
            isBedTimeEstimated: isBedTimeEstimated
        )
    }
}
