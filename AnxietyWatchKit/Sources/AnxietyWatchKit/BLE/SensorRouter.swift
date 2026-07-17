import Foundation

/// Fan-in for BLE + HK actors. Consumers subscribe to `outbound` for a merged
/// stream; the compaction/downsample scheduler reads `isIdle` to decide when
/// TRUNCATE-checkpoints and on-demand downsampling are safe (Spec §1.5).
public actor SensorRouter {

    public enum AnySensorSample: Sendable, Equatable {
        case polar(PolarActor.HRSample)
        case emay(EMAYActor.OxygenSample)
        case healthkit(HealthKitAdapterActor.HKSample)
        case oura(OuraIBISample)

        /// An individual Oura IBI reading, normalized for the pipeline.
        public struct OuraIBISample: Sendable, Equatable {
            /// Unix timestamp (seconds since epoch).
            public var timestamp: Double
            /// Interbeat interval in milliseconds.
            public var ibiMs: Int
            /// Instantaneous heart rate derived from IBI (bpm).
            public var instantHR: Double
            /// Oura validity flag (nil = unknown).
            public var validity: OuraDataValidity?

            public init(timestamp: Double, ibiMs: Int, validity: OuraDataValidity?) {
                self.timestamp = timestamp
                self.ibiMs = ibiMs
                self.instantHR = ibiMs > 0 ? 60_000.0 / Double(ibiMs) : 0
                self.validity = validity
            }
        }

        public var timestamp: Double {
            switch self {
            case .polar(let sample):
                return sample.timestamp
            case .emay(let sample):
                return sample.timestamp
            case .healthkit(let sample):
                return sample.timestamp
            case .oura(let sample):
                return sample.timestamp
            }
        }
        
        /// The (source, type) code pair used by SamplesStore. Fully cross-referenced.
        public var storageCoordinates: (source: Int32, type: Int32) {
            switch self {
            case .polar:
                return (source: 1, type: 1) // Polar=1, HR=1
            case .emay:
                return (source: 0, type: 2) // EMAY=0, SpO2=2
            case .healthkit(let sample):
                // HK=2, map quantity types to specific types
                let type: Int32
                switch sample.quantityType {
                case .heartRate:
                    type = 1 // HR=1 (matches SamplesStore.healthKitOwnedTypes)
                case .heartRateVariability:
                    type = 4 // HRV=4 (matches SamplesStore.healthKitOwnedTypes)
                case .respiratoryRate:
                    type = 5 // RR=5
                }
                return (source: 2, type: type) // HealthKit=2
            case .oura:
                return (source: 3, type: 4) // Oura=3, IBI→HRV=4
            }
        }
    }

    public struct SourceIdleState: Sendable {
        public let sourceName: String
        public let lastFrameAt: Double?
        public func isIdle(now: Double, idleAfterSeconds: TimeInterval) -> Bool {
            guard let lastFrameAt = lastFrameAt else {
                return true // No frames received yet, so it's idle
            }
            return (now - lastFrameAt) >= idleAfterSeconds
        }
    }

    private let polar: PolarActor?
    private let emay: EMAYActor?
    private let healthKit: HealthKitAdapterActor?
    private let bleIdleAfterSeconds: TimeInterval
    private let hkIdleAfterSeconds: TimeInterval
    private let (stream, continuation): (AsyncStream<AnySensorSample>, AsyncStream<AnySensorSample>.Continuation)

    public init(
        polar: PolarActor?,
        emay: EMAYActor?,
        healthKit: HealthKitAdapterActor?,
        idleAfterSeconds: TimeInterval = 60
    ) {
        self.polar = polar
        self.emay = emay
        self.healthKit = healthKit
        self.bleIdleAfterSeconds = idleAfterSeconds
        self.hkIdleAfterSeconds = 300 // HK uses longer window per spec
        let bufferingPolicy = AsyncStream<AnySensorSample>.Continuation.BufferingPolicy.bufferingNewest(1000)
        let (stream, continuation) = AsyncStream<AnySensorSample>.makeStream(of: AnySensorSample.self, bufferingPolicy: bufferingPolicy)
        self.stream = stream
        self.continuation = continuation
    }
    
    /// Lazy-start guard so `outbound` getter or any consumer sees a bridged stream.
    private var bridgingStarted = false

    /// Starts bridging upstream sources into `outbound`. Idempotent — safe to
    /// call from tests or a startup wiring layer. Also auto-invoked lazily by
    /// the `outbound` getter so callers who forget still get correct behavior.
    public func startBridging() async {
        guard !bridgingStarted else { return }
        bridgingStarted = true
        // Bridge each attached upstream's outbound stream. `outboundHR` and
        // friends are actor-isolated getters so we must `await` to read the
        // underlying AsyncStream. Once the stream is in hand, iteration itself
        // happens off the source actor.
        if let polar = polar {
            let stream = await polar.outboundHR
            Task {
                for await sample in stream {
                    await self.ingest(.polar(sample))
                }
            }
        }

        if let emay = emay {
            let stream = await emay.outboundOxygen
            Task {
                for await sample in stream {
                    await self.ingest(.emay(sample))
                }
            }
        }

        if let healthKit = healthKit {
            let stream = await healthKit.outboundHK
            Task {
                for await sample in stream {
                    await self.ingest(.healthkit(sample))
                }
            }
        }
    }

    private func ingest(_ sample: AnySensorSample) async {
        continuation.yield(sample)
    }

    /// Direct ingest for polling-based sources (Oura). Unlike BLE/HK actors
    /// which have their own AsyncStreams bridged in `startBridging()`,
    /// polling-based sources push samples through this method.
    public func push(_ sample: AnySensorSample) async {
        continuation.yield(sample)
    }

    /// Merged AsyncStream of AnySensorSample from all attached sources.
    /// Single-consumer (SensorRouter is the point of fan-in; downstream
    /// consumers get one merged view). Lazily starts bridging so callers who
    /// don't manually call `startBridging()` still see upstream samples.
    public var outbound: AsyncStream<AnySensorSample> {
        get async {
            await startBridging()
            return stream
        }
    }

    /// True iff ALL attached upstream actors are idle. HK uses its own longer
    /// window (300s default per T22).
    public func isIdle(now: Double) async -> Bool {
        // Check Polar actor
        if let polar = polar {
            let isIdle = await polar.isIdle(now: now, idleAfterSeconds: bleIdleAfterSeconds)
            if !isIdle {
                return false
            }
        }
        // Nil upstreams are treated as idle (no data flowing)
        
        // Check EMAY actor
        if let emay = emay {
            let isIdle = await emay.isIdle(now: now, idleAfterSeconds: bleIdleAfterSeconds)
            if !isIdle {
                return false
            }
        }
        // Nil upstreams are treated as idle (no data flowing)
        
        // Check HealthKit actor
        if let healthKit = healthKit {
            let isIdle = await healthKit.isIdle(now: now, idleAfterSeconds: hkIdleAfterSeconds)
            if !isIdle {
                return false
            }
        }
        // Nil upstreams are treated as idle (no data flowing)
        
        return true // All upstreams are idle (or nil)
    }

    /// Per-source idle snapshots for diagnostics.
    public func idleStates(now: Double) async -> [SourceIdleState] {
        var states: [SourceIdleState] = []
        
        // Polar state
        if let polar = polar {
            let lastFrameAt = await polar.lastFrameAtTimestamp
            states.append(SourceIdleState(sourceName: "Polar", lastFrameAt: lastFrameAt))
        }
        
        // EMAY state
        if let emay = emay {
            let lastFrameAt = await emay.lastFrameAtTimestamp
            states.append(SourceIdleState(sourceName: "EMAY", lastFrameAt: lastFrameAt))
        }
        
        // HealthKit state
        if let healthKit = healthKit {
            let lastFrameAt = await healthKit.lastFrameAt
            states.append(SourceIdleState(sourceName: "HealthKit", lastFrameAt: lastFrameAt))
        }
        
        return states
    }
    
    /// Helper method for testing - collect a specific number of samples from the stream
    public func collectSamples(count: Int) async -> [AnySensorSample] {
        var samples: [AnySensorSample] = []
        for await sample in stream {
            samples.append(sample)
            if samples.count >= count {
                break
            }
        }
        return samples
    }
}