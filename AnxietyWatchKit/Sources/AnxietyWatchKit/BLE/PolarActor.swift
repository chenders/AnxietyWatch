import Foundation

/// A per-hardware-source actor wrapping the CoreBluetooth delegate side.
/// The Polar H10 heart-rate strap emits HR (int) + RR intervals (ms) frames.
///
/// Design: CoreBluetooth's CBCentralManagerDelegate lives on a serial
/// DispatchQueue set at CBCentralManager init and CANNOT be a Swift actor
/// executor. So the delegate serialises writes into an AsyncStream.Continuation
/// (order-preserving), and this actor consumes the stream. Callers observe
/// via `outboundHR` and control via connect/disconnect.
///
/// Backpressure (Spec §3.2): bufferingNewest(1000).
public actor PolarActor {
    public struct HRSample: Sendable, Equatable {
        public let timestamp: Double       // seconds since Unix epoch
        public let heartRate: Int          // BPM
        public let rrIntervals: [Int]      // milliseconds; may be empty
        
        public init(timestamp: Double, heartRate: Int, rrIntervals: [Int]) {
            self.timestamp = timestamp
            self.heartRate = heartRate
            self.rrIntervals = rrIntervals
        }
    }

    private var lastFrameAt: Double? = nil
    private let bufferSize: Int
    private let (stream, continuation): (AsyncStream<HRSample>, AsyncStream<HRSample>.Continuation)

    /// The producer surface — the future CBCentralManagerDelegate writes into
    /// this via `ingest(_:)`. Tests inject frames the same way.
    public func ingest(_ sample: HRSample) async {
        lastFrameAt = sample.timestamp
        continuation.yield(sample)
    }

    /// The consumer surface — CNS pipeline / UI ViewModel reads from this.
    public var outboundHR: AsyncStream<HRSample> { 
        return stream
    }

    /// True while ingest has produced anything within the last `idleAfterSeconds`.
    /// SensorRouter (T23) reads this to make the WK-refresh idle decision.
    public func isIdle(now: Double, idleAfterSeconds: TimeInterval = 60) async -> Bool {
        guard let lastFrameAt = lastFrameAt else {
            // No frames received yet, so it's idle
            return true
        }
        return (now - lastFrameAt) >= idleAfterSeconds
    }

    /// Timestamp of the most recent ingested frame; nil if none.
    public var lastFrameAtTimestamp: Double? { 
        return lastFrameAt
    }

    /// Helper method for testing - collect a specific number of samples from the stream
    public func collectSamples(count: Int) async -> [HRSample] {
        var samples: [HRSample] = []
        for await sample in stream {
            samples.append(sample)
            if samples.count >= count {
                break
            }
        }
        return samples
    }

    public init(bufferSize: Int = 1000) {
        self.bufferSize = bufferSize
        let bufferingPolicy = AsyncStream<HRSample>.Continuation.BufferingPolicy.bufferingNewest(bufferSize)
        let (stream, continuation) = AsyncStream<HRSample>.makeStream(of: HRSample.self, bufferingPolicy: bufferingPolicy)
        self.stream = stream
        self.continuation = continuation
    }
}