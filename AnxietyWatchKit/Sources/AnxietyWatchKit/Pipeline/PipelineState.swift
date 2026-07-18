import Foundation

/// CNS detection thresholds (Spec §4.1). Value semantics; Codable so the
/// coordinator can persist/restore them.
public struct CNSThresholds: Sendable, Equatable, Codable {
    public var hrMin: Int = 40
    public var hrMax: Int = 180
    public var spo2Warn: Int = 90
    public var spo2Alert: Int = 88
    public var accelSumHigh: Double = 12.0
    public var breathRateMin: Double = 8.0
    public var breathRateMax: Double = 30.0
    public var hrvLowSDNN: Double = 15.0

    public init() {}
}

/// A single timestamped scalar inside a pipeline ring. `tMs` comes from the
/// injected clock at the event boundary — never from wall-clock reads inside
/// the pure core.
public struct PipelineSample: Sendable, Equatable {
    public let tMs: Int64   // ms since a fixed epoch — from clock.now at ingest
    public let value: Double

    public init(tMs: Int64, value: Double) {
        self.tMs = tMs
        self.value = value
    }
}

/// Input alphabet of the pure pipeline step function.
public enum SensorEvent: Sendable, Equatable {
    case hr(tMs: Int64, bpm: Int)
    case spo2(tMs: Int64, percent: Int, signalQuality: Int)
    case hrv(tMs: Int64, sdnnMs: Double)
    case accel(tMs: Int64, magnitude: Double)   // vector magnitude sum
    case dataGap(range: ClosedRange<Int64>)
    case tick(tMs: Int64)                       // for staleness-based transitions
}

public enum AlertTier: String, Sendable, Codable, Equatable {
    case normal
    case advisory
    case warning
    case critical
}

/// Output alphabet: deterministic commands for the (impure) coordinator to
/// interpret (T27). The pure core never touches notification/haptic APIs.
public enum AlertCommand: Sendable, Equatable {
    case notify(tier: AlertTier, message: String)
    case haptic(pattern: HapticPattern)
    case watchMessage(text: String)

    public enum HapticPattern: String, Sendable, Codable {
        case singleTap
        case doubleTap
        case tripleTap
        case failure
    }
}

/// The full state threaded through `PipelineStep.step`. Pure value type —
/// no references, no hidden clocks.
public struct PipelineState: Sendable, Equatable {
    public var thresholds: CNSThresholds
    // Ring buffers ~60 s at each source's cadence; sized generously.
    public var hrRing: RingBuffer<PipelineSample>
    public var spo2Ring: RingBuffer<PipelineSample>
    public var hrvRing: RingBuffer<PipelineSample>
    public var accelRing: RingBuffer<PipelineSample>
    /// End (ms) of the most recent data gap. Purely local marker — never
    /// synced across nodes, so it's a plain scalar, not an HLC.
    public var lastGapEndMs: Int64?
    public var currentAlertTier: AlertTier
    /// When `currentAlertTier` was last changed (ms, event time). Downgrades
    /// require 30 s past this anchor.
    public var hysteresisAnchorMs: Int64?

    public init(thresholds: CNSThresholds = CNSThresholds(),
                hrCapacity: Int = 120,
                spo2Capacity: Int = 60,
                hrvCapacity: Int = 60,
                accelCapacity: Int = 200) {
        self.thresholds = thresholds
        self.hrRing = RingBuffer(capacity: hrCapacity)
        self.spo2Ring = RingBuffer(capacity: spo2Capacity)
        self.hrvRing = RingBuffer(capacity: hrvCapacity)
        self.accelRing = RingBuffer(capacity: accelCapacity)
        self.lastGapEndMs = nil
        self.currentAlertTier = .normal
        self.hysteresisAnchorMs = nil
    }
}
