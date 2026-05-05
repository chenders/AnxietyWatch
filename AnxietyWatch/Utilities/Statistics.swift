import Foundation

/// Time-bounded sample with a single value. Used for sample-by-sample stats
/// (e.g., time-below-threshold and desaturation event detection).
struct QuantitySample: Sendable, Equatable {
    let start: Date
    let end: Date
    let value: Double
}

enum Statistics {
    /// Population standard deviation. nil for empty input, 0 for a single value.
    static func stdDev(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
        return variance.squareRoot()
    }

    /// Coefficient of variation as a percent (SD / mean × 100).
    /// nil when input is empty or mean ≤ 0 (CV undefined for non-positive means).
    static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0, let sd = stdDev(values) else { return nil }
        return (sd / mean) * 100.0
    }

    /// Total minutes covered by samples whose value is strictly below the threshold.
    /// Overlapping intervals are merged (via `SleepIntervalMerger`) so concurrent
    /// SpO2 writes from multiple HealthKit sources — e.g., Apple Watch + a pulse
    /// oximeter — are not double-counted.
    static func timeBelowThresholdMinutes(
        _ samples: [QuantitySample],
        threshold: Double
    ) -> Int {
        let intervals = samples
            .filter { $0.value < threshold }
            .map { ($0.start, $0.end) }
        return SleepIntervalMerger.mergedMinutes(intervals)
    }

    /// Collapses overlapping samples into a piecewise-constant timeline using
    /// a sweep-line algorithm. At each sub-interval bounded by sample start
    /// and end events, the value is the minimum of all samples currently
    /// active during that sub-interval. Sub-intervals with the same value
    /// that are time-contiguous get coalesced.
    ///
    /// This fixes the bug in the previous "union-min" implementation: a 0.97
    /// sample from 00:00–02:00 overlapping a 0.92 sample from 01:00–03:00
    /// previously collapsed to a single 00:00–03:00 sample at 0.92, smearing
    /// the brief low reading across times where the other source was still
    /// normal and erasing the actual drop/recovery. Now produces:
    /// (00:00–01:00, 0.97), (01:00–03:00, 0.92).
    static func collapseOverlaps(_ samples: [QuantitySample]) -> [QuantitySample] {
        guard !samples.isEmpty else { return [] }

        enum EventKind { case start, end }
        struct Event {
            let time: Date
            let kind: EventKind
            let value: Double
        }

        var events: [Event] = []
        for s in samples where s.end > s.start {
            events.append(Event(time: s.start, kind: .start, value: s.value))
            events.append(Event(time: s.end, kind: .end, value: s.value))
        }
        // Ends fire before starts at equal times so a sample ending exactly
        // when another starts isn't treated as overlapping.
        events.sort {
            if $0.time != $1.time { return $0.time < $1.time }
            switch ($0.kind, $1.kind) {
            case (.end, .start): return true
            default: return false
            }
        }

        var active: [Double] = []
        var result: [QuantitySample] = []
        var lastTime: Date?

        for event in events {
            if let last = lastTime, event.time > last, !active.isEmpty,
               let minVal = active.min() {
                if let lastResult = result.last,
                   lastResult.value == minVal,
                   lastResult.end == last {
                    result[result.count - 1] = QuantitySample(
                        start: lastResult.start, end: event.time, value: minVal
                    )
                } else {
                    result.append(QuantitySample(
                        start: last, end: event.time, value: minVal
                    ))
                }
            }
            switch event.kind {
            case .start:
                active.append(event.value)
            case .end:
                if let idx = active.firstIndex(of: event.value) {
                    active.remove(at: idx)
                }
            }
            lastTime = event.time
        }
        return result
    }

    /// Rough ODI-style desaturation event count.
    /// Walks samples in time order with a rolling baseline (max value among
    /// samples that still **overlap** the lookback window — i.e., whose end
    /// is after `currentSample.start - baselineWindowSeconds`). Triggers an
    /// event when the current value drops by `dropThreshold` below the
    /// baseline. After an event, suppresses further events until the value
    /// recovers to within `recoveryThreshold` of the current baseline.
    ///
    /// Overlapping samples are collapsed first (`collapseOverlaps`) so concurrent
    /// SpO2 writes from multiple HealthKit sources cannot double-count a single
    /// physiologic event. The window is measured in **time**, not sample count,
    /// so the metric is comparable across sources with very different cadences.
    /// The inner loop uses a monotonic deque (sliding-maximum) so the algorithm
    /// is amortized O(n) — important for overnight 1 Hz traces (~30k samples).
    /// Not clinical-grade ODI4 — manufacturer apps are authoritative; this is
    /// for trending only.
    static func countDesatEvents(
        _ samples: [QuantitySample],
        dropThreshold: Double,
        recoveryThreshold: Double,
        baselineWindowSeconds: TimeInterval = 120
    ) -> Int {
        let sorted = collapseOverlaps(samples)
        guard sorted.count >= 2 else { return 0 }

        // Monotonic deque (sliding-maximum): indices into `sorted`, kept
        // decreasing by value. Front (`deque[head]`) is the max value in the
        // current time window. We use a head index instead of `removeFirst()`
        // because Swift's `Array.removeFirst()` is O(n) — it shifts the rest.
        // With the head index, popFront is true O(1), giving an amortized
        // O(n) total: each sample is pushed once and popped once.
        var deque: [Int] = []
        var head = 0
        var events = 0
        var inEvent = false

        for i in 1..<sorted.count {
            // (a) Push index (i-1) onto the deque, evicting smaller tail values
            //     to maintain decreasing-value ordering.
            let candidate = i - 1
            while head < deque.count, sorted[deque[deque.count - 1]].value <= sorted[candidate].value {
                deque.removeLast()
            }
            deque.append(candidate)

            // (b) Evict front elements whose end is at or before the window
            //     cutoff — only those don't overlap the lookback window at
            //     all. Evicting by start would prematurely discard a long
            //     segment that's still active during the lookback (e.g., a
            //     5-hour 0.97 baseline followed by a 0.92 sample: the
            //     segment's start ages out long before its end does).
            let cutoff = sorted[i].start.addingTimeInterval(-baselineWindowSeconds)
            while head < deque.count, sorted[deque[head]].end <= cutoff {
                head += 1
            }

            let baseline = head < deque.count ? sorted[deque[head]].value : sorted[i].value
            let v = sorted[i].value
            if !inEvent && v <= baseline - dropThreshold {
                events += 1
                inEvent = true
            } else if inEvent && v >= baseline - recoveryThreshold {
                inEvent = false
            }
        }
        return events
    }
}
