import Foundation

/// Fan-in for BLE + HK actors. Consumers subscribe to `outbound` for a merged
/// stream; the compaction/downsample scheduler reads `isIdle` to decide when
/// TRUNCATE-checkpoints and on-demand downsampling are safe (Spec §1.5).
///
/// Throttled snapshots (Spec §3.2, §3.4): call `throttled(rate:)` to get a
/// per-consumer AsyncStream<ViewModelSnapshot> throttled to at most `rate` Hz.
/// The coordinator installs itself via `setCoordinatorSnapshotProvider(_:)`
/// to inject alertTier and fusionScore into each snapshot.
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
            case .polar(let sample):    return sample.timestamp
            case .emay(let sample):     return sample.timestamp
            case .healthkit(let sample): return sample.timestamp
            case .oura(let sample):     return sample.timestamp
            }
        }

        /// The (source, type) code pair used by SamplesStore.
        public var storageCoordinates: (source: Int32, type: Int32) {
            switch self {
            case .polar:     return (source: 1, type: 1)  // Polar=1, HR=1
            case .emay:      return (source: 0, type: 2)  // EMAY=0, SpO2=2
            case .healthkit(let sample):
                let type: Int32
                switch sample.quantityType {
                case .heartRate:             type = 1  // HR
                case .heartRateVariability:  type = 4  // HRV
                case .respiratoryRate:       type = 5  // RR
                }
                return (source: 2, type: type)  // HealthKit=2
            case .oura:      return (source: 3, type: 4)  // Oura=3, IBI→HRV=4
            }
        }
    }

    public struct SourceIdleState: Sendable {
        public let sourceName: String
        public let lastFrameAt: Double?
        public func isIdle(now: Double, idleAfterSeconds: TimeInterval) -> Bool {
            guard let lastFrameAt else { return true }
            return (now - lastFrameAt) >= idleAfterSeconds
        }
    }

    // MARK: - Properties

    private let polar: PolarActor?
    private let emay: EMAYActor?
    private let healthKit: HealthKitAdapterActor?
    private let bleIdleAfterSeconds: TimeInterval
    private let hkIdleAfterSeconds: TimeInterval
    private let (stream, continuation): (AsyncStream<AnySensorSample>, AsyncStream<AnySensorSample>.Continuation)

    // Snapshot broadcast
    private var coordinatorSnapshotProvider: (@Sendable () async -> (tier: AlertTier, fusion: Double)?)?
    private struct SnapshotSubscriber {
        let continuation: AsyncStream<ViewModelSnapshot>.Continuation
        let minimumInterval: Duration
        var lastEmission: ContinuousClock.Instant?
    }

    private var snapshotSubscribers: [UUID: SnapshotSubscriber] = [:]
    private var latestHR: Int?
    private var latestSpO2: Int?
    private var latestHRV: Double?

    // MARK: - Init

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
        self.hkIdleAfterSeconds = 300
        let policy = AsyncStream<AnySensorSample>.Continuation.BufferingPolicy.bufferingNewest(1000)
        let (s, c) = AsyncStream<AnySensorSample>.makeStream(of: AnySensorSample.self, bufferingPolicy: policy)
        self.stream = s
        self.continuation = c
    }

    // MARK: - Bridging

    private var bridgingStarted = false

    public func startBridging() async {
        guard !bridgingStarted else { return }
        bridgingStarted = true

        if let polar {
            let s = await polar.outboundHR
            Task { for await sample in s { await self.ingest(.polar(sample)) } }
        }
        if let emay {
            let s = await emay.outboundOxygen
            Task { for await sample in s { await self.ingest(.emay(sample)) } }
        }
        if let healthKit {
            let s = await healthKit.outboundHK
            Task { for await sample in s { await self.ingest(.healthkit(sample)) } }
        }
    }

    // MARK: - Ingest

    private func ingest(_ sample: AnySensorSample) async {
        continuation.yield(sample)
        await publishSnapshot(for: sample)
    }

    public func push(_ sample: AnySensorSample) async {
        continuation.yield(sample)
        await publishSnapshot(for: sample)
    }

    // MARK: - Coordinator wiring

    /// Installs the pipeline-state reader used when constructing UI snapshots.
    public func setCoordinatorSnapshotProvider(
        _ provider: (@Sendable () async -> (tier: AlertTier, fusion: Double)?)?
    ) {
        coordinatorSnapshotProvider = provider
    }

    // MARK: - Throttled snapshot stream (Spec §3.2, §3.4)

    /// Returns a per-consumer broadcast stream of ViewModelSnapshot, emitted at
    /// no more than `rate` times per second. The stream lives until the caller
    /// drops it; termination cleans up the internal continuation.
    ///
    /// - Parameter rate: Maximum snapshots per second (e.g. 10 → ≤10 Hz).
    /// - Returns: An AsyncStream<ViewModelSnapshot>.
    public func throttled(rate: Int) async -> AsyncStream<ViewModelSnapshot> {
        precondition(rate > 0, "Snapshot rate must be positive")
        let id = UUID()
        let (stream, continuation) = AsyncStream<ViewModelSnapshot>.makeStream(
            of: ViewModelSnapshot.self,
            bufferingPolicy: .bufferingNewest(5)
        )
        snapshotSubscribers[id] = SnapshotSubscriber(
            continuation: continuation,
            minimumInterval: .seconds(1) / rate,
            lastEmission: nil  // nil → first sample always emits immediately
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSnapshotSubscriber(id) }
        }
        let pipeline = await coordinatorSnapshotProvider?()
        // Ensure bridging is running so upstream samples reach publishSnapshot.
        await startBridging()
        continuation.yield(ViewModelSnapshot(
            latestHR: latestHR,
            latestSpO2: latestSpO2,
            latestHRV: latestHRV,
            alertTier: pipeline?.tier ?? .normal,
            isIdle: await isIdle(now: Date().timeIntervalSince1970),
            fusionScore: pipeline?.fusion ?? 0
        ))
        return stream
    }

    private func removeSnapshotSubscriber(_ id: UUID) {
        snapshotSubscribers.removeValue(forKey: id)
    }

    private func publishSnapshot(for sample: AnySensorSample) async {
        switch sample {
        case .polar(let hr):
            latestHR = hr.heartRate
        case .emay(let oxygen):
            latestSpO2 = oxygen.spo2Percent
            if let pulse = oxygen.pulseRate { latestHR = pulse }
        case .healthkit(let hk):
            switch hk.quantityType {
            case .heartRate:            latestHR = Int(hk.value)
            case .heartRateVariability:  latestHRV = hk.value
            case .respiratoryRate:       break
            }
        case .oura(let ibi):
            latestHR = Int(ibi.instantHR.rounded())
            latestHRV = Double(ibi.ibiMs)
        }

        let now = ContinuousClock.now
        let pipeline = await coordinatorSnapshotProvider?()
        let snapshot = ViewModelSnapshot(
            latestHR: latestHR,
            latestSpO2: latestSpO2,
            latestHRV: latestHRV,
            alertTier: pipeline?.tier ?? .normal,
            isIdle: await isIdle(now: sample.timestamp),
            fusionScore: pipeline?.fusion ?? 0
        )

        for id in snapshotSubscribers.keys {
            guard var subscriber = snapshotSubscribers[id] else { continue }
            if let previous = subscriber.lastEmission,
               previous.duration(to: now) < subscriber.minimumInterval {
                continue
            }
            subscriber.continuation.yield(snapshot)
            subscriber.lastEmission = now
            snapshotSubscribers[id] = subscriber
        }
    }

    // MARK: - Outbound stream

    public var outbound: AsyncStream<AnySensorSample> {
        get async {
            await startBridging()
            return stream
        }
    }

    // MARK: - Idle detection

    public func isIdle(now: Double) async -> Bool {
        if let polar, await !polar.isIdle(now: now, idleAfterSeconds: bleIdleAfterSeconds) { return false }
        if let emay,  await !emay.isIdle(now: now, idleAfterSeconds: bleIdleAfterSeconds)  { return false }
        if let healthKit, await !healthKit.isIdle(now: now, idleAfterSeconds: hkIdleAfterSeconds) { return false }
        return true
    }

    public func idleStates(now: Double) async -> [SourceIdleState] {
        var states: [SourceIdleState] = []
        if let polar { states.append(SourceIdleState(sourceName: "Polar", lastFrameAt: await polar.lastFrameAtTimestamp)) }
        if let emay  { states.append(SourceIdleState(sourceName: "EMAY", lastFrameAt: await emay.lastFrameAtTimestamp)) }
        if let healthKit { states.append(SourceIdleState(sourceName: "HealthKit", lastFrameAt: await healthKit.lastFrameAt)) }
        return states
    }

    // MARK: - Test helpers

    public func collectSamples(count: Int) async -> [AnySensorSample] {
        var samples: [AnySensorSample] = []
        for await sample in stream {
            samples.append(sample)
            if samples.count >= count { break }
        }
        return samples
    }
}
