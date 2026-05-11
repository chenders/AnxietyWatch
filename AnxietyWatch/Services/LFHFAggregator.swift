import Foundation

/// Pure helpers for shaping `HRVReading` rows into the data structures the
/// Phase 3c LF/HF chart consumes.
///
/// HRVReading stores frequency-domain fields (`lfPower`, `hfPower`,
/// `lfHfRatio`) as non-optional `Double`. The HRVSessionRecorder pipeline
/// fills windows with fewer than 30 RR intervals as `0.0`, not `nil`. Every
/// helper here treats `lf == 0 || hf == 0` as the "no data" sentinel so the
/// chart never plots those windows as a collapsed-to-zero physiologic state.
enum LFHFAggregator {

    /// Single source of truth for what counts as an "overnight" sensor
    /// session for LF/HF aggregation — referenced from TrendsView and
    /// LFHFSessionsListView so the threshold can't drift between the
    /// trend card and the sessions list.
    nonisolated static let overnightThresholdSeconds: TimeInterval = 3 * 3600

    /// One point in the per-minute series for a single session.
    struct LFHFPoint: Identifiable {
        let id: UUID
        let timestamp: Date
        /// Nil when the source reading carried the zero sentinel (Swift Charts
        /// renders a line break, giving the user an honest gap).
        let lfPower: Double?
        let hfPower: Double?
        let lfHfRatio: Double?
    }

    /// One point in the multi-night trend series, anchored at a sensor session.
    struct NightlyMean: Identifiable {
        /// `sensorSessionID` of the originating SensorSession row.
        let id: UUID
        /// Timestamp of the earliest reading in the session — the natural
        /// x-axis anchor for plotting one mark per night.
        let night: Date
        let hfMean: Double?
        let lfMean: Double?
        let lfHfMean: Double?
        /// Count of readings with valid frequency-domain data. Zero means the
        /// session existed but every window was a sentinel — render this as a
        /// "no data" mark, not as zero.
        let validWindowCount: Int
    }

    nonisolated static func hasFrequencyData(_ reading: HRVReading) -> Bool {
        reading.lfPower > 0 && reading.hfPower > 0
    }

    nonisolated static func gappedPerMinutePoints(from readings: [HRVReading]) -> [LFHFPoint] {
        readings
            .sorted { $0.timestamp < $1.timestamp }
            .map(point(from:))
    }

    /// A robust upper y-axis bound for plotting `values`. Uses the 95th
    /// percentile of positive values with 15% headroom — a single freak window
    /// (motion artifact, ectopic beat, momentary pickup loss producing huge
    /// FFT power) can drive HRV frequency-domain readings 100x above the
    /// surrounding signal, and letting Swift Charts auto-scale to that
    /// maximum flattens the rest of the trace into the baseline. Returns 1
    /// when there is no positive data so the chart still has a non-zero
    /// domain.
    nonisolated static func robustUpperBound(of values: [Double]) -> Double {
        let positive = values.filter { $0 > 0 }
        guard !positive.isEmpty else { return 1 }
        let sorted = positive.sorted()
        // Below ~20 points there isn't enough data to statistically identify
        // an outlier; use the max with headroom so all data fits cleanly.
        // At/above 20 points, use a 95th-percentile index computed as
        // `(count - 1) * 0.95` so it can never round up to the last element
        // — `count * 0.95` does (e.g. count == 20 → 19), which would defeat
        // the clip when there are only 1–2 outliers in the sample.
        guard sorted.count >= 20 else {
            return (sorted.last ?? 1) * 1.15
        }
        let p95Index = min(Int(Double(sorted.count - 1) * 0.95), sorted.count - 1)
        return sorted[p95Index] * 1.15
    }

    /// Mean of positive `values` with extreme outliers trimmed via MAD (median
    /// absolute deviation, scaled to a normal-equivalent threshold). Same
    /// reasoning as `robustUpperBound` — one freak window can inflate the
    /// arithmetic mean by 50%+ and misrepresent the underlying signal.
    /// Returns nil when there is no positive data.
    nonisolated static func outlierTrimmedMean(of values: [Double]) -> Double? {
        let positive = values.filter { $0 > 0 }
        guard !positive.isEmpty else { return nil }
        let sorted = positive.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = positive.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        // 5 * MAD * 1.4826 ≈ 5σ — only flags true outliers. Floor at 3x the
        // median so a tight cluster (MAD == 0) doesn't reject everything.
        let madThreshold = 5 * mad * 1.4826
        let threshold = max(median + madThreshold, median * 3)
        let kept = positive.filter { $0 <= threshold }
        guard !kept.isEmpty else { return median }
        return kept.reduce(0, +) / Double(kept.count)
    }

    /// UI threshold for "latest session is meaningfully below baseline" — used
    /// to color the headline number and switch the subtitle status string.
    /// 15% is a deliberate threshold: tighter would fire on day-to-day noise,
    /// looser would miss real recovery deficits.
    nonisolated static let belowBaselineThreshold: Double = -0.15

    /// Day-aligned mean of overnight HF values from the last `lookbackDays`
    /// days ending at `anchor`. Returns nil when fewer than `minimumNights`
    /// sessions are available — a baseline computed from too few nights is
    /// noisy enough to mislead more than it helps. The cutoff uses
    /// `startOfDay` so a session that happens on the cutoff day is included
    /// regardless of time-of-day (matches BaselineCalculator's convention).
    nonisolated static func hfBaseline(
        from allMeans: [NightlyMean],
        anchor: Date,
        lookbackDays: Int = 30,
        minimumNights: Int = 3,
        calendar: Calendar = .current
    ) -> Double? {
        guard let daysAgo = calendar.date(byAdding: .day, value: -lookbackDays, to: anchor) else {
            return nil
        }
        let cutoff = calendar.startOfDay(for: daysAgo)
        let values = allMeans
            .filter { $0.night >= cutoff && $0.night <= anchor }
            .compactMap(\.hfMean)
        guard values.count >= minimumNights else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Signed fractional delta of `value` against `baseline` (e.g., `-0.18`
    /// for "18% below baseline"). Nil when `baseline` is non-positive — the
    /// comparison is meaningless and the headline should fall back to the
    /// raw value without a delta line.
    nonisolated static func relativeDelta(value: Double, baseline: Double) -> Double? {
        guard baseline > 0 else { return nil }
        return (value - baseline) / baseline
    }

    /// Group readings by sensor session and compute outlier-trimmed mean
    /// LF/HF values. `sessionStartTimes` is an optional map from session ID
    /// to the authoritative `SensorSession.startTime`; when provided the
    /// `night` anchor uses that bedtime instead of the earliest reading
    /// timestamp (per-minute readings can lag the session start by up to
    /// ~60s, which matters for sessions starting near midnight where the
    /// wrong calendar day would shift window inclusion).
    nonisolated static func nightlyMeans(
        from readings: [HRVReading],
        sessionStartTimes: [UUID: Date] = [:]
    ) -> [NightlyMean] {
        let grouped = Dictionary(grouping: readings.compactMap(sessionGrouping)) { $0.sessionID }
        let unordered: [NightlyMean] = grouped.map { sessionID, entries in
            let sessionReadings = entries.map(\.reading)
            let earliestReading = sessionReadings.map(\.timestamp).min() ?? .distantPast
            let earliest = sessionStartTimes[sessionID] ?? earliestReading
            let valid = sessionReadings.filter(hasFrequencyData)
            guard !valid.isEmpty else {
                return NightlyMean(
                    id: sessionID,
                    night: earliest,
                    hfMean: nil,
                    lfMean: nil,
                    lfHfMean: nil,
                    validWindowCount: 0
                )
            }
            return NightlyMean(
                id: sessionID,
                night: earliest,
                hfMean: outlierTrimmedMean(of: valid.map(\.hfPower)),
                lfMean: outlierTrimmedMean(of: valid.map(\.lfPower)),
                lfHfMean: outlierTrimmedMean(of: valid.map(\.lfHfRatio)),
                validWindowCount: valid.count
            )
        }
        // Sort ascending by night so LineMark draws left-to-right; tiebreak
        // by id to keep the order deterministic across runs.
        return unordered.sorted { lhs, rhs in
            if lhs.night != rhs.night { return lhs.night < rhs.night }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - Private

    nonisolated private static func point(from reading: HRVReading) -> LFHFPoint {
        let valid = hasFrequencyData(reading)
        return LFHFPoint(
            id: reading.id,
            timestamp: reading.timestamp,
            lfPower: valid ? reading.lfPower : nil,
            hfPower: valid ? reading.hfPower : nil,
            lfHfRatio: valid ? reading.lfHfRatio : nil
        )
    }

    nonisolated private struct SessionGrouping {
        let sessionID: UUID
        let reading: HRVReading
    }

    nonisolated private static func sessionGrouping(_ reading: HRVReading) -> SessionGrouping? {
        guard let sessionID = reading.sensorSessionID else { return nil }
        return SessionGrouping(sessionID: sessionID, reading: reading)
    }
}
