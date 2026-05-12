// AnxietyWatch/Services/HRVSessionRecorder.swift
import Foundation
import SwiftData

/// Drives the per-minute HRV computation loop for a single sensor session.
/// Pure logic + a `ModelContext` for SwiftData writes — no Timer, no BLE.
/// The owning service calls `tick(at:)` on its 60s cadence and `finalize(at:)`
/// when the session ends.
@MainActor
final class HRVSessionRecorder {

    private let modelContext: ModelContext
    private let buffer: RRIntervalBuffer
    private let source: String
    /// Exposed read-only so the owning `PolarHRMService` can append
    /// `SensorInterruption` entries directly during the reconnect grace
    /// period. The reference is the SwiftData @Model row; mutating its
    /// `interruptions` array through the reference is fine, but the
    /// recorder itself owns the assignment of the property.
    private(set) var session: SensorSession?
    /// ID of the SensorSession currently being recorded (after `start(at:)`).
    /// Callers like `PolarHRMService` read this to derive matching filenames
    /// for per-session artifacts (e.g. the raw RR archive) so they don't end
    /// up orphaned from the SwiftData row.
    private(set) var sessionID: UUID?
    private(set) var rmssdValues: [Double] = []
    /// Per-window mean HR (BPM) from the same accepted ticks that populate
    /// `rmssdValues`. Sibling of `rmssdValues` so the session summary can
    /// emit a `hrMean` field without storing per-minute HR on `HRVReading`.
    private(set) var hrValues: [Double] = []
    private(set) var totalRRCount: Int = 0
    private(set) var skippedMinutes: Int = 0

    init(modelContext: ModelContext, buffer: RRIntervalBuffer, source: String) {
        self.modelContext = modelContext
        self.buffer = buffer
        self.source = source
    }

    /// Recovery initializer used when state restoration finds a SensorSession
    /// that's still open (endTime == nil) — wires the recorder to that
    /// existing row instead of inserting a new one. The recorder takes over
    /// reporting ticks against the recovered session.
    ///
    /// `priorRMSSDs`, `priorHRMeans`, and `priorRRCount` are rehydrated from
    /// the existing HRVReading children and the on-disk RR archive (size /
    /// record-size for the count; `rehydratedHRValues` replays the archive
    /// against each reading's 60s window for the HR series) so the final
    /// session summary reflects the entire session, not just the post-
    /// recovery minutes. Without this, a restart mid-overnight would compute
    /// the summary over a few late-night minutes only.
    init(
        modelContext: ModelContext,
        buffer: RRIntervalBuffer,
        source: String,
        existing: SensorSession,
        priorRMSSDs: [Double] = [],
        priorHRMeans: [Double] = [],
        priorRRCount: Int = 0
    ) {
        self.modelContext = modelContext
        self.buffer = buffer
        self.source = source
        self.session = existing
        self.sessionID = existing.id
        self.rmssdValues = priorRMSSDs
        self.hrValues = priorHRMeans
        self.totalRRCount = priorRRCount
    }

    /// Begin a session. `batteryAtStart` is the iPhone battery percentage
    /// at session start (0–100). Phase 1 has no BLE service feeding this
    /// value yet, so callers may pass 0 as a placeholder; Phase 2's owning
    /// service should pass the real percentage from `UIDevice`.
    func start(at timestamp: Date, batteryAtStart: Int = 0) throws {
        let session = SensorSession(startTime: timestamp, batteryAtStart: batteryAtStart)
        session.source = source
        modelContext.insert(session)
        try modelContext.save()
        self.session = session
        self.sessionID = session.id
    }

    /// Drains the trailing-minute window from the buffer, computes HRV, writes
    /// one `HRVReading` if the minute had usable data. Increments
    /// `skippedMinutes` and writes nothing when the window is too sparse or
    /// fully artifact-rejected.
    ///
    /// HRV math (`HRVCalculator.frequencyDomain` runs Accelerate FFT) is
    /// performed off-main via `Task.detached` so the live-session UI stays
    /// responsive. SwiftData writes happen back on the main actor.
    func tick(at now: Date) async throws {
        // Bail if the session has been finalized — without this guard, a tick
        // suspended on the FFT could resume after stopSession and write an
        // HRVReading that the session summary doesn't account for.
        guard let session, session.endTime == nil else { return }
        let intervals = await buffer.flush(at: now)
        let rrs = intervals.map(\.rrMs)
        guard rrs.count >= 2 else {
            skippedMinutes += 1
            return
        }
        // Artifact filter: drop any RR intervals outside physiological range.
        let filtered = rrs.filter { $0 >= 250 && $0 <= 2_000 }
        guard filtered.count >= 2 else {
            skippedMinutes += 1
            return
        }

        let td = await Task.detached(priority: .userInitiated) {
            HRVCalculator.timeDomain(rrIntervals: filtered)
        }.value
        // Re-check after the FFT await — stopSession may have finalized while
        // we were suspended. The unwrap matters: `self.session?.endTime == nil`
        // is true for a nil session, so optional-chained checks short-circuit
        // in exactly the direction we need to bail on.
        guard let active = self.session, active.endTime == nil else { return }
        guard let td else {
            skippedMinutes += 1
            return
        }
        let fd = await Task.detached(priority: .userInitiated) {
            HRVCalculator.frequencyDomain(rrIntervals: filtered)
        }.value
        // Same guard again after the second await; explicit unwrap so a
        // nil self.session can't slip through.
        guard let stillActive = self.session, stillActive.id == active.id, stillActive.endTime == nil else { return }

        let reading = HRVReading(
            timestamp: now,
            rmssd: td.rmssd,
            sdnn: td.sdnn,
            pnn50: td.pnn50,
            lfPower: fd?.lfPower ?? 0,
            hfPower: fd?.hfPower ?? 0,
            lfHfRatio: fd?.lfHfRatio ?? 0,
            sensorSessionID: session.id,
            source: source
        )
        modelContext.insert(reading)
        try modelContext.save()

        rmssdValues.append(td.rmssd)
        // Window-mean HR derived from the same artifact-filtered RR set used
        // for HRV math. Filtered already guarantees count >= 2 and that every
        // RR is in [250, 2000] ms, so this division is bounded and finite.
        let meanRR = filtered.reduce(0, +) / Double(filtered.count)
        hrValues.append(60_000.0 / meanRR)
        totalRRCount += filtered.count
    }

    func finalize(at timestamp: Date) throws {
        guard let session else { return }
        session.endTime = timestamp
        session.summaryJSON = sessionSummaryJSON(for: session)
        try modelContext.save()
        self.session = nil
        // Also clear sessionID so callers can't accidentally treat a
        // finalized recorder as still associated with the prior session.
        self.sessionID = nil
    }

    private func sessionSummaryJSON(for session: SensorSession) -> String {
        Self.buildSummaryJSON(
            rmssdValues: rmssdValues,
            hrValues: hrValues,
            totalRRCount: totalRRCount,
            skippedMinutes: skippedMinutes,
            session: session
        )
    }

    /// Reconstructs per-window mean HR for a recovered session by replaying
    /// the persisted HRVReading rows against the on-disk RR archive. Each
    /// returned value corresponds to one `priorReadings` row whose 60s
    /// window had at least two artifact-filtered RR samples in the archive.
    /// Mirrors the tick path's filter (`250...2000 ms`) and the same
    /// `60_000 / mean(filtered)` formula so a recovered session's `hrMean`
    /// reflects the entire session, not just the post-recovery minutes.
    ///
    /// `nonisolated` because the function is pure — declaring it
    /// main-actor-isolated by default (the containing class is
    /// `@MainActor`) would force every future off-main caller to hop
    /// through the main queue.
    ///
    /// Uses a two-pointer sweep over time-sorted inputs so the total cost
    /// is O(N + M) rather than the O(N × M) a per-reading `filter` pass
    /// would incur. A 5h overnight session has on the order of 17k RR
    /// samples × 300 reading rows; the naïve form is 5M comparisons and
    /// the sweep form is ~17k.
    nonisolated static func rehydratedHRValues(
        priorReadings: [HRVReading],
        samples: [RRIntervalSample]
    ) -> [Double] {
        guard !priorReadings.isEmpty, !samples.isEmpty else { return [] }
        let sortedReadings = priorReadings.sorted { $0.timestamp < $1.timestamp }
        let sortedSamples = samples.sorted { $0.timestamp < $1.timestamp }
        var result: [Double] = []
        result.reserveCapacity(sortedReadings.count)

        // `left` tracks the first sample whose timestamp is still inside the
        // current reading's window; `right` tracks the first sample past the
        // window's upper bound. Both indices advance monotonically across
        // readings, so each sample is touched O(1) times overall.
        var left = 0
        var right = 0
        for reading in sortedReadings {
            let windowStart = reading.timestamp.addingTimeInterval(-60)
            let windowEnd = reading.timestamp
            while left < sortedSamples.count, sortedSamples[left].timestamp < windowStart {
                left += 1
            }
            if right < left { right = left }
            while right < sortedSamples.count, sortedSamples[right].timestamp <= windowEnd {
                right += 1
            }
            var sum = 0.0
            var count = 0
            for index in left..<right {
                let rr = sortedSamples[index].rrMs
                if rr >= 250 && rr <= 2_000 {
                    sum += rr
                    count += 1
                }
            }
            if count >= 2 {
                result.append(60_000.0 / (sum / Double(count)))
            }
        }
        return result
    }

    /// Builds the session-summary JSON from explicit inputs rather than the
    /// recorder's in-memory state. Used by the recorder's own `finalize`
    /// path (which calls `sessionSummaryJSON(for:)` above) and by
    /// `PolarHRMService.finalizeOrphan` to back-fill a summary on an
    /// orphaned session whose recorder never got to run finalize.
    static func buildSummaryJSON(
        rmssdValues: [Double],
        hrValues: [Double],
        totalRRCount: Int,
        skippedMinutes: Int,
        session: SensorSession
    ) -> String {
        let mean = rmssdValues.isEmpty ? 0 : rmssdValues.reduce(0, +) / Double(rmssdValues.count)
        let mn = rmssdValues.min() ?? 0
        let mx = rmssdValues.max() ?? 0
        let hrMean = hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)
        let durationSec = session.endTime.map { $0.timeIntervalSince(session.startTime) } ?? 0
        let interruptions = session.interruptions.count
        // Sum the closed interruptions' durations (open ones get closed by
        // tearDownResources / finalizeOrphan before this runs, but we
        // defensively skip any that are still open).
        let gapSec = session.interruptions.reduce(0.0) { acc, gap in
            guard let end = gap.endTime else { return acc }
            return acc + max(0, end.timeIntervalSince(gap.startTime))
        }
        let gapFraction: Double = durationSec > 0 ? min(1.0, gapSec / durationSec) : 0
        let dict: [String: Any] = [
            "rmssdMean": mean,
            "rmssdMin": mn,
            "rmssdMax": mx,
            "hrMean": hrMean,
            "rrCount": totalRRCount,
            "durationSec": durationSec,
            "gapFraction": gapFraction,
            "interruptionCount": interruptions,
            "skippedMinutes": skippedMinutes,
        ]
        // If serialization fails (e.g. some upstream value becomes NaN/∞),
        // fall back to "{}" so summaryJSON is always valid JSON. An empty
        // string would be non-nil but un-parseable for downstream readers.
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
