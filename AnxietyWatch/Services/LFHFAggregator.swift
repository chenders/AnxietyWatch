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

    // MARK: - Session coalescing

    /// One coalesced "logical night" formed by merging adjacent SensorSessions
    /// whose inter-session gaps are ≤ `gapTolerance`. Lets a fragmented Polar
    /// strap night (BLE drops + reconnects) count as one overnight reading.
    struct CoalescedNight: Identifiable, Equatable, Sendable {
        /// Stable group identifier — equal to the FIRST member session's UUID.
        /// Using a member's UUID instead of a fresh one keeps the chart datum
        /// identity stable across renders so SwiftUI Charts doesn't re-animate
        /// every body recompute.
        let id: UUID
        /// startTime of the earliest member session.
        let startTime: Date
        /// endTime of the latest member session.
        let endTime: Date
        /// Sum of (endTime - startTime) across MEMBER sessions. NOT
        /// (endTime - startTime) of the coalesced span — gap time (when the
        /// strap was disconnected) doesn't count as wear time.
        let wearTimeSeconds: TimeInterval
        /// Raw SensorSession IDs that contributed to this night, chronological.
        let memberSessionIDs: [UUID]
    }

    /// Coalesce raw SensorSessions into logical nights. Sessions with `nil`
    /// endTime (in-progress / never-finalized) are excluded. Sessions whose
    /// `startTime` is at most `gapTolerance` after the previous session's
    /// `endTime` get merged into the same night.
    ///
    /// Default gapTolerance: 45 minutes. Covers BLE drop+reconnect storms and
    /// short bathroom breaks; below the duration of any realistic daytime nap
    /// so two separate sleep events don't accidentally merge.
    nonisolated static func coalesce(
        sessions: [SensorSession],
        gapTolerance: TimeInterval = 45 * 60
    ) -> [CoalescedNight] {
        // Only finalized sessions (non-nil endTime) can contribute wear time.
        let finalized = sessions
            .filter { $0.endTime != nil }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard !finalized.isEmpty else { return [] }

        var nights: [CoalescedNight] = []
        // Seed with the first session.
        var groupID = finalized[0].id
        var groupStart = finalized[0].startTime
        var groupEnd = finalized[0].endTime! // safe: filtered above
        var groupWear: TimeInterval = groupEnd.timeIntervalSince(finalized[0].startTime)
        var groupMembers: [UUID] = [finalized[0].id]

        for session in finalized.dropFirst() {
            let gap = session.startTime.timeIntervalSince(groupEnd)
            if gap <= gapTolerance {
                // Merge into current night.
                let sessionEnd = session.endTime! // safe: filtered above
                if sessionEnd > groupEnd { groupEnd = sessionEnd }
                groupWear += session.endTime!.timeIntervalSince(session.startTime)
                groupMembers.append(session.id)
            } else {
                // Flush the current night and start a new one.
                nights.append(CoalescedNight(
                    id: groupID,
                    startTime: groupStart,
                    endTime: groupEnd,
                    wearTimeSeconds: groupWear,
                    memberSessionIDs: groupMembers
                ))
                groupID = session.id
                groupStart = session.startTime
                groupEnd = session.endTime! // safe: filtered above
                groupWear = session.endTime!.timeIntervalSince(session.startTime)
                groupMembers = [session.id]
            }
        }
        // Flush the final group.
        nights.append(CoalescedNight(
            id: groupID,
            startTime: groupStart,
            endTime: groupEnd,
            wearTimeSeconds: groupWear,
            memberSessionIDs: groupMembers
        ))
        return nights
    }

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

    /// Single-metric per-session aggregate, anchored at a sensor session.
    /// Sibling of `NightlyMean` for the time-domain trend charts (SDNN, RMSSD)
    /// where one number per night is the natural shape.
    struct NightlyValue: Identifiable {
        /// `sensorSessionID` of the originating SensorSession row.
        let id: UUID
        /// Bedtime anchor for the x-axis — the authoritative
        /// `SensorSession.startTime` when provided, otherwise the earliest
        /// reading timestamp in the session.
        let night: Date
        /// Outlier-trimmed mean across valid windows for the chosen metric.
        /// Nil when every reading carried the zero sentinel — render this as a
        /// "no data" mark, not as zero.
        let value: Double?
        /// Count of readings where the source metric was positive (i.e., not a
        /// zero sentinel from `<30 RR intervals`).
        let validWindowCount: Int
    }

    /// One point in the multi-night trend series, anchored at a sensor session.
    struct NightlyMean: Identifiable {
        /// `sensorSessionID` of the originating SensorSession row.
        let id: UUID
        /// Bedtime anchor for the x-axis — the authoritative
        /// `SensorSession.startTime` when provided via `sessionStartTimes`,
        /// otherwise the earliest reading timestamp in the session.
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

    /// Per-session outlier-trimmed mean of `rmssd` for the time-domain trend
    /// chart. Mirrors `nightlyMeans` but reads a single metric and follows the
    /// same `rmssd > 0` sentinel convention used elsewhere in the recorder.
    nonisolated static func nightlyRMSSD(
        from readings: [HRVReading],
        sessionStartTimes: [UUID: Date] = [:]
    ) -> [NightlyValue] {
        nightlyValues(
            from: readings,
            sessionStartTimes: sessionStartTimes,
            metric: \.rmssd
        )
    }

    /// Per-session outlier-trimmed mean of `sdnn` for the time-domain trend
    /// chart. Same shape as `nightlyRMSSD`; separate function for naming
    /// clarity at call sites.
    nonisolated static func nightlySDNN(
        from readings: [HRVReading],
        sessionStartTimes: [UUID: Date] = [:]
    ) -> [NightlyValue] {
        nightlyValues(
            from: readings,
            sessionStartTimes: sessionStartTimes,
            metric: \.sdnn
        )
    }

    /// Bundled per-session aggregates for the trend stack — groups
    /// `readings` by `sensorSessionID` ONCE and computes the
    /// frequency-domain `NightlyMean`, time-domain SDNN, and time-domain
    /// RMSSD series together. Equivalent to calling `nightlyMeans`,
    /// `nightlySDNN`, and `nightlyRMSSD` separately, but avoids three
    /// independent passes over the same per-minute reading set.
    nonisolated static func nightlyAggregates(
        from readings: [HRVReading],
        sessionStartTimes: [UUID: Date] = [:]
    ) -> (means: [NightlyMean], sdnn: [NightlyValue], rmssd: [NightlyValue]) {
        let grouped = Dictionary(grouping: readings.compactMap(sessionGrouping)) { $0.sessionID }
        var meansUnsorted: [NightlyMean] = []
        var sdnnUnsorted: [NightlyValue] = []
        var rmssdUnsorted: [NightlyValue] = []
        meansUnsorted.reserveCapacity(grouped.count)
        sdnnUnsorted.reserveCapacity(grouped.count)
        rmssdUnsorted.reserveCapacity(grouped.count)

        for (sessionID, groupedEntries) in grouped {
            let sessionReadings = groupedEntries.map(\.reading)
            let earliestReading = sessionReadings.map(\.timestamp).min() ?? .distantPast
            let anchor = sessionStartTimes[sessionID] ?? earliestReading

            // Frequency-domain
            let validFreq = sessionReadings.filter(hasFrequencyData)
            if validFreq.isEmpty {
                meansUnsorted.append(NightlyMean(
                    id: sessionID,
                    night: anchor,
                    hfMean: nil,
                    lfMean: nil,
                    lfHfMean: nil,
                    validWindowCount: 0
                ))
            } else {
                meansUnsorted.append(NightlyMean(
                    id: sessionID,
                    night: anchor,
                    hfMean: outlierTrimmedMean(of: validFreq.map(\.hfPower)),
                    lfMean: outlierTrimmedMean(of: validFreq.map(\.lfPower)),
                    lfHfMean: outlierTrimmedMean(of: validFreq.map(\.lfHfRatio)),
                    validWindowCount: validFreq.count
                ))
            }

            // SDNN
            let validSDNN = sessionReadings.map(\.sdnn).filter { $0 > 0 }
            sdnnUnsorted.append(NightlyValue(
                id: sessionID,
                night: anchor,
                value: validSDNN.isEmpty ? nil : outlierTrimmedMean(of: validSDNN),
                validWindowCount: validSDNN.count
            ))

            // RMSSD
            let validRMSSD = sessionReadings.map(\.rmssd).filter { $0 > 0 }
            rmssdUnsorted.append(NightlyValue(
                id: sessionID,
                night: anchor,
                value: validRMSSD.isEmpty ? nil : outlierTrimmedMean(of: validRMSSD),
                validWindowCount: validRMSSD.count
            ))
        }

        return (
            means: sortByNight(meansUnsorted, night: \.night, id: \.id),
            sdnn: sortByNight(sdnnUnsorted, night: \.night, id: \.id),
            rmssd: sortByNight(rmssdUnsorted, night: \.night, id: \.id)
        )
    }

    // MARK: - Coalesced-night overloads

    /// Bundled per-coalesced-night aggregates. Groups `readings` by the
    /// coalesced night that owns their `sensorSessionID`, computing the
    /// frequency-domain `NightlyMean`, time-domain SDNN, and time-domain
    /// RMSSD series in a single pass. Results are anchored at
    /// `coalescedNight.startTime` and keyed by `coalescedNight.id`.
    nonisolated static func nightlyAggregates(
        from readings: [HRVReading],
        coalescedNights: [CoalescedNight]
    ) -> (means: [NightlyMean], sdnn: [NightlyValue], rmssd: [NightlyValue]) {
        guard !coalescedNights.isEmpty else {
            return (means: [], sdnn: [], rmssd: [])
        }
        // Build a sessionID → CoalescedNight lookup so each reading can be
        // routed to its owning logical night in O(1).
        var sessionToNight: [UUID: CoalescedNight] = [:]
        for night in coalescedNights {
            for memberID in night.memberSessionIDs {
                sessionToNight[memberID] = night
            }
        }

        // Group readings by coalesced-night ID.
        var readingsByNight: [UUID: [HRVReading]] = [:]
        for reading in readings {
            guard let sessionID = reading.sensorSessionID,
                  let night = sessionToNight[sessionID] else { continue }
            readingsByNight[night.id, default: []].append(reading)
        }

        // Build a nightID → CoalescedNight lookup for anchor dates.
        let nightByID = Dictionary(uniqueKeysWithValues: coalescedNights.map { ($0.id, $0) })

        var meansUnsorted: [NightlyMean] = []
        var sdnnUnsorted: [NightlyValue] = []
        var rmssdUnsorted: [NightlyValue] = []
        meansUnsorted.reserveCapacity(coalescedNights.count)
        sdnnUnsorted.reserveCapacity(coalescedNights.count)
        rmssdUnsorted.reserveCapacity(coalescedNights.count)

        for (nightID, nightReadings) in readingsByNight {
            guard let night = nightByID[nightID] else { continue }
            let anchor = night.startTime

            // Frequency-domain
            let validFreq = nightReadings.filter(hasFrequencyData)
            if validFreq.isEmpty {
                meansUnsorted.append(NightlyMean(
                    id: nightID,
                    night: anchor,
                    hfMean: nil,
                    lfMean: nil,
                    lfHfMean: nil,
                    validWindowCount: 0
                ))
            } else {
                meansUnsorted.append(NightlyMean(
                    id: nightID,
                    night: anchor,
                    hfMean: outlierTrimmedMean(of: validFreq.map(\.hfPower)),
                    lfMean: outlierTrimmedMean(of: validFreq.map(\.lfPower)),
                    lfHfMean: outlierTrimmedMean(of: validFreq.map(\.lfHfRatio)),
                    validWindowCount: validFreq.count
                ))
            }

            // SDNN
            let validSDNN = nightReadings.map(\.sdnn).filter { $0 > 0 }
            sdnnUnsorted.append(NightlyValue(
                id: nightID,
                night: anchor,
                value: validSDNN.isEmpty ? nil : outlierTrimmedMean(of: validSDNN),
                validWindowCount: validSDNN.count
            ))

            // RMSSD
            let validRMSSD = nightReadings.map(\.rmssd).filter { $0 > 0 }
            rmssdUnsorted.append(NightlyValue(
                id: nightID,
                night: anchor,
                value: validRMSSD.isEmpty ? nil : outlierTrimmedMean(of: validRMSSD),
                validWindowCount: validRMSSD.count
            ))
        }

        return (
            means: sortByNight(meansUnsorted, night: \.night, id: \.id),
            sdnn: sortByNight(sdnnUnsorted, night: \.night, id: \.id),
            rmssd: sortByNight(rmssdUnsorted, night: \.night, id: \.id)
        )
    }

    /// Per-coalesced-night weighted-mean HR extracted from member session
    /// summaryJSON values. Each member's `hrMean` is weighted by its individual
    /// wear duration. Members with missing, unparseable, or zero `hrMean` are
    /// skipped. If ALL members in a night are unreadable, that night is omitted.
    nonisolated static func nightlyHRFromSummaries(
        from sessions: [SensorSession],
        coalescedNights: [CoalescedNight]
    ) -> [NightlyValue] {
        guard !coalescedNights.isEmpty else { return [] }
        // Build sessionID → session lookup for fast member resolution.
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        let unordered: [NightlyValue] = coalescedNights.compactMap { night in
            var weightedSum: Double = 0
            var totalWeight: Double = 0
            for memberID in night.memberSessionIDs {
                guard let session = sessionByID[memberID],
                      let end = session.endTime,
                      let summaryJSON = session.summaryJSON,
                      let data = summaryJSON.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let hrMean = dict["hrMean"] as? Double,
                      hrMean > 0 else { continue }
                let duration = end.timeIntervalSince(session.startTime)
                weightedSum += hrMean * duration
                totalWeight += duration
            }
            guard totalWeight > 0 else { return nil }
            return NightlyValue(
                id: night.id,
                night: night.startTime,
                value: weightedSum / totalWeight,
                validWindowCount: night.memberSessionIDs.count
            )
        }
        return unordered.sorted { lhs, rhs in
            if lhs.night != rhs.night { return lhs.night < rhs.night }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    nonisolated private static func sortByNight<T>(
        _ array: [T],
        night: (T) -> Date,
        id: (T) -> UUID
    ) -> [T] {
        array.sorted { lhs, rhs in
            if night(lhs) != night(rhs) { return night(lhs) < night(rhs) }
            return id(lhs).uuidString < id(rhs).uuidString
        }
    }

    /// Per-session mean HR extracted from each session's `summaryJSON`. Used
    /// to overlay an overnight-average source onto the HR trend chart.
    /// Sessions whose summary is missing, unparseable, lacks `hrMean`, or
    /// emits the `0` sentinel (orphan-recovered or legacy pre-Phase-4a rows)
    /// are skipped — real overnight HR is never 0.
    nonisolated static func nightlyHRFromSummaries(
        from sessions: [SensorSession]
    ) -> [NightlyValue] {
        let unordered: [NightlyValue] = sessions.compactMap { session in
            guard let summaryJSON = session.summaryJSON,
                  let data = summaryJSON.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hrMean = dict["hrMean"] as? Double,
                  hrMean > 0 else {
                return nil
            }
            return NightlyValue(
                id: session.id,
                night: session.startTime,
                value: hrMean,
                validWindowCount: 1
            )
        }
        return unordered.sorted { lhs, rhs in
            if lhs.night != rhs.night { return lhs.night < rhs.night }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - Private

    nonisolated private static func nightlyValues(
        from readings: [HRVReading],
        sessionStartTimes: [UUID: Date],
        metric: KeyPath<HRVReading, Double>
    ) -> [NightlyValue] {
        let grouped = Dictionary(grouping: readings.compactMap(sessionGrouping)) { $0.sessionID }
        let unordered: [NightlyValue] = grouped.map { sessionID, entries in
            let sessionReadings = entries.map(\.reading)
            let earliestReading = sessionReadings.map(\.timestamp).min() ?? .distantPast
            let anchor = sessionStartTimes[sessionID] ?? earliestReading
            let validValues = sessionReadings
                .map { $0[keyPath: metric] }
                .filter { $0 > 0 }
            guard !validValues.isEmpty else {
                return NightlyValue(
                    id: sessionID,
                    night: anchor,
                    value: nil,
                    validWindowCount: 0
                )
            }
            return NightlyValue(
                id: sessionID,
                night: anchor,
                value: outlierTrimmedMean(of: validValues),
                validWindowCount: validValues.count
            )
        }
        return unordered.sorted { lhs, rhs in
            if lhs.night != rhs.night { return lhs.night < rhs.night }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

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
