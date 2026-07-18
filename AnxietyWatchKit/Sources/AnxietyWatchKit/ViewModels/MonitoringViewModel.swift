import Foundation

/// The primary @Observable surface consumed by SwiftUI views on both iOS and
/// watchOS. It subscribes to a throttled snapshot stream from the SensorRouter
/// and publishes the latest vitals / alert tier synchronously so views never
/// need `await`.
///
/// Spec §3.4: instantiated with a SensorRouter, updates at 10 Hz.
///
/// ## Usage
/// ```swift
/// @State private var monitor = MonitoringViewModel(router: deps.router)
///
/// var body: some View {
///     VStack {
///         Text("HR: \(monitor.latestHR ?? 0)")
///         Text("Tier: \(monitor.alertTier.rawValue)")
///     }
/// }
/// ```
@MainActor
@Observable
public final class MonitoringViewModel {

    // MARK: - Published state (read synchronously by views)

    public private(set) var latestHR: Int?
    public private(set) var latestSpO2: Int?
    public private(set) var latestHRV: Double?
    public private(set) var alertTier: AlertTier = .normal
    public private(set) var isIdle: Bool = true
    public private(set) var fusionScore: Double = 0.0

    /// When the last snapshot was received. Nil before the first update.
    public private(set) var lastUpdateAt: Date?

    // MARK: - Internal

    private let router: SensorRouter
    private var loopTask: Task<Void, Never>?

    public init(router: SensorRouter) {
        self.router = router
    }

    // MARK: - Lifecycle

    /// Start consuming the throttled snapshot stream. Idempotent.
    /// Call once from the app/scene entry point; views do not need to call this.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await snap in await self.router.throttled(rate: 10) {
                if Task.isCancelled { return }
                self.apply(snap)
            }
        }
    }

    /// Stop the subscription loop. Idempotent.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Directly apply a snapshot (for testing or manual injection).
    public func apply(_ snap: ViewModelSnapshot) {
        self.latestHR = snap.latestHR
        self.latestSpO2 = snap.latestSpO2
        self.latestHRV = snap.latestHRV
        self.alertTier = snap.alertTier
        self.isIdle = snap.isIdle
        self.fusionScore = snap.fusionScore
        self.lastUpdateAt = Date()
    }
}
