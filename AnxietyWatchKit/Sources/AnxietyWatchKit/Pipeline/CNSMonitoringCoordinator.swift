import Foundation

/// The ONLY impure boundary in the Pipeline layer (Spec §4.2).
/// - Owns the pipeline state var and mutates it after each step.
/// - Consumes SensorRouter.outbound; converts to SensorEvent; steps + fuses.
/// - Interprets AlertCommand values by calling injected effect handlers.
///
/// This file is EXEMPT from the Pipeline purity lint (see
/// testPipelineHasNoImpureReferences) — everything else in Pipeline/ stays
/// pure. Real side effects (UNUserNotificationCenter, WKInterfaceDevice /
/// CoreHaptics, WCSession) are wired by app-layer EffectHandlers; this actor
/// never references those APIs directly, so it stays testable from SPM.
public actor CNSMonitoringCoordinator {

    public struct EffectHandlers: Sendable {
        public let notify: @Sendable (_ tier: AlertTier, _ message: String) async -> Void
        public let haptic: @Sendable (_ pattern: AlertCommand.HapticPattern) async -> Void
        public let watchMessage: @Sendable (_ text: String) async -> Void

        public init(
            notify: @escaping @Sendable (AlertTier, String) async -> Void,
            haptic: @escaping @Sendable (AlertCommand.HapticPattern) async -> Void,
            watchMessage: @escaping @Sendable (String) async -> Void
        ) {
            self.notify = notify
            self.haptic = haptic
            self.watchMessage = watchMessage
        }

        /// A no-op handler set (for tests that don't need to observe effects).
        public static var noOp: EffectHandlers {
            EffectHandlers(
                notify: { _, _ in },
                haptic: { _ in },
                watchMessage: { _ in }
            )
        }
    }

    private let router: SensorRouter
    private let handlers: EffectHandlers
    private var state: PipelineState
    private var lastFusion: CNSFusionEngine.FusionScore
    private var runningTask: Task<Void, Never>?

    public init(
        router: SensorRouter,
        initialState: PipelineState = PipelineState(),
        handlers: EffectHandlers = .noOp
    ) {
        self.router = router
        self.handlers = handlers
        self.state = initialState
        self.lastFusion = CNSFusionEngine.fuse(initialState)
    }

    // MARK: - Lifecycle

    /// Start the monitoring loop. Non-blocking. Idempotent.
    public func start() async {
        guard runningTask == nil else { return }
        let stream = await router.outbound
        runningTask = Task { [weak self] in
            for await sample in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                await self.process(sample)
            }
        }
    }

    /// Stop the loop (cancel the inner task). Idempotent.
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

        let (steppedState, stepCommands) = PipelineStep.step(state, event)
        let fusion = CNSFusionEngine.fuse(steppedState)
        let (fusedState, allCommands) = PipelineStep.applyFusion(
            steppedState, stepCommands, fusion: fusion, tMs: Self.eventTMs(event))

        state = fusedState
        lastFusion = fusion

        for command in allCommands {
            await interpret(command)
        }
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

    // MARK: - Command interpretation (the impure edge)

    private func interpret(_ command: AlertCommand) async {
        switch command {
        case .notify(let tier, let message):
            await handlers.notify(tier, message)
        case .haptic(let pattern):
            await handlers.haptic(pattern)
        case .watchMessage(let text):
            await handlers.watchMessage(text)
        }
    }
}
