// AnxietyWatch/Services/RRIntervalBuffer.swift
import Foundation

/// A single RR interval timestamped at the moment of arrival.
struct RRIntervalSample: Sendable, Equatable {
    let timestamp: Date
    let rrMs: Double
}

/// Trailing-window buffer for RR intervals. Actor-isolated so multiple
/// CoreBluetooth callbacks can append concurrently with the recorder
/// flushing on its minute timer.
actor RRIntervalBuffer {
    private let window: TimeInterval
    private var samples: [RRIntervalSample] = []

    init(window: TimeInterval = 60) {
        self.window = window
    }

    func append(timestamp: Date, rrMs: Double) {
        samples.append(RRIntervalSample(timestamp: timestamp, rrMs: rrMs))
    }

    /// Returns all samples currently within `[now - window, now]` and
    /// evicts anything outside that window. Future-timestamp samples (which
    /// can occur if BLE arrival timing skews ahead of the recorder's clock)
    /// are dropped on the same pass to honor the documented contract.
    /// Non-destructive for samples still in window — callers can flush
    /// repeatedly without losing in-window data.
    func flush(at now: Date) -> [RRIntervalSample] {
        let cutoff = now.addingTimeInterval(-window)
        samples.removeAll { $0.timestamp < cutoff || $0.timestamp > now }
        return samples
    }
}
