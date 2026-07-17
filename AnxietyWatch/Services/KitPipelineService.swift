import Foundation
import SwiftUI
import os
import AnxietyWatchKit

/// Bridges the v3 AnxietyWatchKit pipeline into the iOS app target.
///
/// Owns the BLE actors, SensorRouter, CNS pipeline, and ViewModel.
/// Coexists with legacy PolarHRMService/EMAYRealtimeService during the
/// §7 phased rollout — the old services continue to drive existing
/// recording/export features while this service feeds the new
/// MonitoringViewModel and ComplicationCacheWriter.
///
/// ## Lifecycle
/// - Created once in `AnxietyWatchApp.bootstrapKit()` and held as
///   `@State` for the process lifetime.
/// - `start()` begins BLE scanning and pipeline processing.
/// - `stop()` tears down actors (called on background).
@MainActor
public final class KitPipelineService: ObservableObject {

    // MARK: - Public observable state

    /// The monitoring view model — bind directly in SwiftUI views.
    /// Updated ~10 Hz by the throttled SensorRouter stream.
    @Published public private(set) var monitoring: MonitoringViewModel?

    /// True when the pipeline is actively processing samples.
    @Published public private(set) var isRunning = false

    // MARK: - Internal state

    private let logger = Logger(subsystem: "com.anxietywatch.app", category: "KitPipeline")

    private var polar: PolarActor?
    private var emay: EMAYActor?
    private var healthKit: HealthKitAdapterActor?
    private var router: SensorRouter?
    private var coordinator: CNSMonitoringCoordinator?
    private var complicationWriter: ComplicationCacheWriter?
    private var monitoringTask: Task<Void, Never>?

    // MARK: - Init

    public init() {}

    // MARK: - Start / Stop

    /// Creates all actors, starts BLE scanning, and begins the pipeline.
    /// Idempotent — safe to call multiple times.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        logger.info("KitPipelineService starting")

        // ── BLE actors ────────────────────────────────────────────
        // Each actor manages its own CBCentralManager on a private
        // serial dispatch queue. Samples flow through AsyncStream
        // continuations into the SensorRouter.
        polar = PolarActor()
        emay = EMAYActor()
        healthKit = HealthKitAdapterActor()

        // ── Sensor router ─────────────────────────────────────────
        // Fans in all BLE sources. Creates the outbound sample stream
        // and the throttled snapshot stream for the ViewModel.
        router = SensorRouter(polar: polar, emay: emay, healthKit: healthKit)

        // ── Pipeline coordinator ──────────────────────────────────
        guard let router else { return }
        coordinator = CNSMonitoringCoordinator(router: router)
        await coordinator?.start()

        // ── Complication cache writer ─────────────────────────────
        // Runs on both iOS (for iPhone complications) and watchOS.
        // On iOS this is a no-op for the complication target, but
        // setting up here keeps the architecture symmetric.
        complicationWriter = ComplicationCacheWriter()

        // ── Monitoring ViewModel ──────────────────────────────────
        // Subscribes to the throttled 10 Hz snapshot stream from the
        // SensorRouter. The coordinator injects alertTier and fusion
        // score into each snapshot via coordinatorSnapshotProvider.
        let vm = MonitoringViewModel(router: router)
        monitoring = vm

        // ── Complication cache feed ───────────────────────────────
        // Watch the throttled stream and submit each snapshot to the
        // ComplicationCacheWriter. The writer coalesces with a 500ms
        // trailing-edge debounce (§6.2).
        monitoringTask = Task { [weak self, weak router] in
            guard let self, let router else { return }
            let stream = await router.throttled(rate: 10)
            for await snap in stream {
                guard !Task.isCancelled else { break }
                let state = ComplicationState(
                    latestHR: snap.latestHR,
                    latestSpO2: snap.latestSpO2,
                    alertTier: snap.alertTier.rawValue,
                    fusionScore: snap.fusionScore,
                    lastUpdate: Date()
                )
                await self.complicationWriter?.submit(state)
            }
        }

        logger.info("KitPipelineService started")
    }

    /// Stops all actors, cancels the pipeline loop, and flushes the
    /// complication cache. Safe to call multiple times.
    public func stop() async {
        guard isRunning else { return }
        logger.info("KitPipelineService stopping")

        monitoringTask?.cancel()
        monitoringTask = nil

        await coordinator?.stop()
        await complicationWriter?.flush()

        polar = nil
        emay = nil
        healthKit = nil
        router = nil
        coordinator = nil
        isRunning = false

        logger.info("KitPipelineService stopped")
    }
}
