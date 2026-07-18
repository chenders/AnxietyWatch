import Foundation

/// A per-hardware-source actor wrapping the CoreBluetooth delegate side.
/// The EMAY pulse oximeter emits SpO2, PR, and device-status frames.
///
/// Design: CoreBluetooth's CBCentralManagerDelegate lives on a serial
/// DispatchQueue set at CBCentralManager init and CANNOT be a Swift actor
/// executor. So the delegate serialises writes into an AsyncStream.Continuation
/// (order-preserving), and this actor consumes the stream. Callers observe
/// via `outboundOxygen` and control via connect/disconnect.
///
/// Backpressure (Spec §3.2): bufferingNewest(1000).
public actor EMAYActor {
    public struct OxygenSample: Sendable, Equatable {
        public let timestamp: Double
        public let spo2Percent: Int          // 0..100
        public let pulseRate: Int?           // BPM, optional
        public let signalQuality: Int        // 0..15 (EMAY-standard scale)
        public let batteryPercent: Int?
        
        public init(timestamp: Double, spo2Percent: Int, pulseRate: Int?, signalQuality: Int, batteryPercent: Int?) {
            self.timestamp = timestamp
            self.spo2Percent = spo2Percent
            self.pulseRate = pulseRate
            self.signalQuality = signalQuality
            self.batteryPercent = batteryPercent
        }
    }

    private var lastFrameAt: Double? = nil
    private let bufferSize: Int
    private let (stream, continuation): (AsyncStream<OxygenSample>, AsyncStream<OxygenSample>.Continuation)

    /// The producer surface — the future CBCentralManagerDelegate writes into
    /// this via `ingest(_:)`. Tests inject frames the same way.
    public func ingest(_ sample: OxygenSample) async {
        lastFrameAt = sample.timestamp
        continuation.yield(sample)
    }

    /// The consumer surface — CNS pipeline / UI ViewModel reads from this.
    public var outboundOxygen: AsyncStream<OxygenSample> { 
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
    public func collectSamples(count: Int) async -> [OxygenSample] {
        var samples: [OxygenSample] = []
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
        let bufferingPolicy = AsyncStream<OxygenSample>.Continuation.BufferingPolicy.bufferingNewest(bufferSize)
        let (stream, continuation) = AsyncStream<OxygenSample>.makeStream(of: OxygenSample.self, bufferingPolicy: bufferingPolicy)
        self.stream = stream
        self.continuation = continuation
    }
}