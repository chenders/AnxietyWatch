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
    private var session: SensorSession?
    private(set) var rmssdValues: [Double] = []
    private(set) var totalRRCount: Int = 0
    private(set) var skippedMinutes: Int = 0

    init(modelContext: ModelContext, buffer: RRIntervalBuffer, source: String) {
        self.modelContext = modelContext
        self.buffer = buffer
        self.source = source
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
        guard let session else { return }
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
        guard let td else {
            skippedMinutes += 1
            return
        }
        let fd = await Task.detached(priority: .userInitiated) {
            HRVCalculator.frequencyDomain(rrIntervals: filtered)
        }.value

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
        totalRRCount += filtered.count
    }

    func finalize(at timestamp: Date) throws {
        guard let session else { return }
        session.endTime = timestamp
        session.summaryJSON = sessionSummaryJSON(for: session)
        try modelContext.save()
        self.session = nil
    }

    private func sessionSummaryJSON(for session: SensorSession) -> String {
        let mean = rmssdValues.isEmpty ? 0 : rmssdValues.reduce(0, +) / Double(rmssdValues.count)
        let mn = rmssdValues.min() ?? 0
        let mx = rmssdValues.max() ?? 0
        let durationSec = session.endTime.map { $0.timeIntervalSince(session.startTime) } ?? 0
        let interruptions = session.interruptions.count
        // gapFraction populated when interruption tracking lands with the
        // CoreBluetooth wiring in Phase 2.
        let gapFraction: Double = 0
        let dict: [String: Any] = [
            "rmssdMean": mean,
            "rmssdMin": mn,
            "rmssdMax": mx,
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
