// AnxietyWatch/Services/RRTimestampBackprojection.swift
import Foundation

/// Distributes a packet of RR intervals across the time window leading up to
/// the packet's arrival, so each interval lands in the recorder's buffer at
/// its approximate beat completion time rather than collapsed at the
/// arrival instant.
///
/// Polar H10 emits 0–2 RR intervals per packet at ~1 Hz; each interval
/// corresponds to a beat that completed since the previous packet, in order.
/// The last interval ended at packet arrival; earlier ones ended that-many-
/// milliseconds before. Without back-projection the buffer's per-minute
/// flush would group multi-second batches at the same instant.
///
/// Declared `nonisolated` so CoreBluetooth callbacks (running off the main
/// actor) can invoke it directly.
nonisolated enum RRTimestampBackprojection {

    /// Returns one `(timestamp, rrMs)` pair per input interval — each
    /// timestamp marks the beat completion that ended its RR interval.
    /// The last pair's timestamp equals `arrival`; consecutive timestamps
    /// differ by the **later** interval's duration (since each RR interval
    /// is the time from the previous beat to the beat it terminates).
    /// Empty input returns empty output.
    static func project(
        arrival: Date,
        rrIntervalsMs: [Double]
    ) -> [(timestamp: Date, rrMs: Double)] {
        guard !rrIntervalsMs.isEmpty else { return [] }
        let totalSeconds = rrIntervalsMs.reduce(0, +) / 1000
        var cursor = arrival.addingTimeInterval(-totalSeconds)
        return rrIntervalsMs.map { rr in
            cursor = cursor.addingTimeInterval(rr / 1000)
            return (cursor, rr)
        }
    }
}
