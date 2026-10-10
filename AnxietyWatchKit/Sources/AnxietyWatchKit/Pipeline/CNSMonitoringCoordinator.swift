import Foundation

/// Monitoring-state coordinator for the package pipeline (Spec §4.2).
/// - Owns the pipeline state var and mutates it after each step.
/// - Consumes SensorRouter.outbound; converts to SensorEvent; steps + fuses.
/// - Publishes tier/fusion snapshots for presentation and diagnostics.
///
/// CLINICAL SIDE-EFFECT BOUNDARY: this package type deliberately has no
/// notification, haptic, audio, or watch-message injection surface. The
/// app-level `Services/CNSRisk/CNSAlarmPresenter` is the sole owner of those
/// effects. Package `AlertCommand` values are pure calculation outputs; this
/// coordinator discards them and publishes monitoring state only.
public actor CNSMonitoringCoordinator {
    private let router: SensorRouter
    private let featureFlags: any FeatureFlagProvider
    private var state: PipelineState
    private var lastFusion: CNSFusionEngine.FusionScore
    private var runningTask: Task<Void, Never>?

    public init(
        router: SensorRouter,
        initialState: PipelineState = PipelineState(),
        featureFlags: any FeatureFlagProvider = Feature.defaultProvider
    ) {
        self.router = router
        self.featureFlags = featureFlags
        self.state = initialState
        self.lastFusion = CNSFusionEngine.fuse(initialState)
    }

    // MARK: - Lifecycle

    /// Start the monitoring loop. Non-blocking. Idempotent.
    public func start() async {
        guard runningTask == nil else { return }
        await router.setCoordinatorSnapshotProvider { [weak self] in
            guard let self else { return nil }
            return (tier: await self.currentTier, fusion: await self.currentFusionScore.overall)
        }
        let stream = await router.outbound
        runningTask = Task { [weak self] in
            for await sample in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                await self.process(sample)
            }
        }
    }

    /// Stop the loop (cancel the inner tasks). Idempotent.
    public func stop() async {
        runningTask?.cancel()
        runningTask = nil
    }

    // MARK: - Snapshot readers (ViewModel / diagnostics)

    public var currentTier: AlertTier {
        state.currentAlertTier
    }

    public var currentFusionScore: CNSFusionEngine.FusionScore {
        lastFusion
    }

    internal var currentPipelineState: PipelineState {
        state
    }

    public var isRunning: Bool {
        runningTask != nil
    }

    // MARK: - Loop body

    private func process(_ sample: SensorRouter.AnySensorSample) async {
        guard let event = Self.translate(sample: sample) else {
            // Respiratory rate has no pipeline event yet — drop and continue
            // (a .breath event may arrive in a later phase).
            Log.pipeline.debug("Dropping unsupported sensor sample: \(String(describing: sample))")
            return
        }

        await process(event)
    }

    /// Event-level production decision point. Kept internal so focused tests
    /// can prove both values without manufacturing a sensor transport frame.
    internal func process(_ event: SensorEvent) async {
        let gapEventsEnabled: Bool
        if case .dataGap = event {
            gapEventsEnabled = await Feature.isEnabled(.pipelineGapEvents, using: featureFlags)
        } else {
            gapEventsEnabled = false
        }

        let (steppedState, stepCommands) = PipelineStep.step(
            state,
            event,
            gapEventsEnabled: gapEventsEnabled
        )
        let fusion = CNSFusionEngine.fuse(steppedState)
        let (fusedState, _) = PipelineStep.applyFusion(
            steppedState, stepCommands, fusion: fusion, tMs: Self.eventTMs(event))

        state = fusedState
        lastFusion = fusion
    }

    /// AnySensorSample → SensorEvent. Returns nil for samples the pipeline
    /// cannot represent yet (respiratory rate).
    static func translate(sample: SensorRouter.AnySensorSample) -> SensorEvent? {
        switch sample {
        case .polar(let hr):
            return .hr(tMs: Int64(hr.timestamp * 1_000), bpm: hr.heartRate)
        case .emay(let oxygen):
            return .spo2(tMs: Int64(oxygen.timestamp * 1_000),
                         percent: oxygen.spo2Percent,
                         signalQuality: oxygen.signalQuality)
        case .healthkit(let hk):
            let tMs = Int64(hk.timestamp * 1_000)
            switch hk.quantityType {
            case .heartRate:
                return .hr(tMs: tMs, bpm: Int(hk.value))
            case .heartRateVariability:
                return .hrv(tMs: tMs, sdnnMs: hk.value)
            case .respiratoryRate:
                return nil
            }
        case .oura(let ibi):
            // IBI → HRV (SDNN). Single-point IBI is routed as an HRV sample
            // so the fusion engine's HRV ring receives it. The pipeline's
            // CNSFusionEngine accumulates multiple IBI-derived values to
            // compute a meaningful HRV contribution over time.
            let tMs = Int64(ibi.timestamp * 1_000)
            return .hrv(tMs: tMs, sdnnMs: Double(ibi.ibiMs))
        }
    }

    /// The event's own timestamp — used as the fusion hysteresis anchor.
    static func eventTMs(_ event: SensorEvent) -> Int64 {
        switch event {
        case .hr(let tMs, _): return tMs
        case .spo2(let tMs, _, _): return tMs
        case .hrv(let tMs, _): return tMs
        case .accel(let tMs, _): return tMs
        case .dataGap(let range): return range.upperBound
        case .tick(let tMs): return tMs
        }
    }
}
