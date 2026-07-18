import Foundation

/// Adapts HealthKit HR / HRV / respiratory-rate deliveries into the same
/// stream shape BLE actors use (Spec §3.3). In production a
/// HKAnchoredObjectQuery callback calls `ingest(_:)`; tests inject directly.
///
/// Per Spec §3.3: empty HK query results DO NOT emit data_gap events — the
/// pipeline handles HK staleness via its internal ring-buffer timestamps.
/// Ops note: Watch off-wrist looks identical to steady-state from this
/// actor's perspective.
///
/// Type safety: `HKSample.QuantityType` is a closed enum of exactly the
/// HK-owned kinds (Spec §1.7), so data flowing through this adapter can never
/// reach `SamplesStore.insert`'s HK-owned trap — the compiler refuses any
/// other (source, type) at ingest. This is an extra defense on top of the
/// store-level trap.
///
/// Backpressure (Spec §3.2): bufferingNewest — HK cadence is low, so the
/// default buffer is 500 (vs 1000 for BLE).
public actor HealthKitAdapterActor {
    public struct HKSample: Sendable, Equatable {
        public let timestamp: Double        // seconds since Unix epoch
        public let quantityType: QuantityType
        public let value: Double

        public init(timestamp: Double, quantityType: QuantityType, value: Double) {
            self.timestamp = timestamp
            self.quantityType = quantityType
            self.value = value
        }

        public enum QuantityType: String, Sendable, Codable, CaseIterable {
            case heartRate            // BPM
            case heartRateVariability // ms (SDNN)
            case respiratoryRate      // breaths per minute
        }
    }

    private var _lastFrameAt: Double? = nil
    private var anchor: Data? = nil
    private let bufferSize: Int
    private let (stream, continuation): (AsyncStream<HKSample>, AsyncStream<HKSample>.Continuation)

    public init(bufferSize: Int = 500) {
        self.bufferSize = bufferSize
        let (stream, continuation) = AsyncStream.makeStream(
            of: HKSample.self,
            bufferingPolicy: .bufferingNewest(bufferSize)
        )
        self.stream = stream
        self.continuation = continuation
    }

    /// The producer surface — the future HKAnchoredObjectQuery driver writes
    /// into this. Tests inject samples the same way. An empty HK result batch
    /// simply never calls this (no data_gap emission per Spec §3.3).
    public func ingest(_ sample: HKSample) async {
        _lastFrameAt = sample.timestamp
        continuation.yield(sample)
    }

    /// The consumer surface — SensorRouter / CNS pipeline reads from this.
    public var outboundHK: AsyncStream<HKSample> {
        stream
    }

    /// Timestamp of the most recent ingested sample; nil if none.
    public var lastFrameAt: Double? {
        _lastFrameAt
    }

    /// True while ingest has produced nothing within the last
    /// `idleAfterSeconds`. Default is 300 s (NOT the BLE actors' 60 s):
    /// HealthKit sampling cadence is much lower than BLE streaming, so a
    /// 60 s window would flap idle/active constantly.
    public func isIdle(now: Double, idleAfterSeconds: TimeInterval = 300) async -> Bool {
        guard let last = _lastFrameAt else {
            // No samples received yet — idle.
            return true
        }
        return (now - last) >= idleAfterSeconds
    }

    // MARK: - Anchor round-trip

    /// The HKAnchoredObjectQuery driver (a future integration layer) persists
    /// the anchor between wakes (App Group UserDefaults per Spec §3.3). This
    /// actor exposes anchor state so the driver can round-trip it.
    public var currentAnchor: Data? {
        anchor
    }

    public func setAnchor(_ anchor: Data?) async {
        self.anchor = anchor
    }

    /// Test helper — collect `count` samples from the stream.
    public func collectSamples(count: Int) async -> [HKSample] {
        var samples: [HKSample] = []
        for await sample in stream {
            samples.append(sample)
            if samples.count >= count {
                break
            }
        }
        return samples
    }
}
