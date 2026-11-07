import Foundation

/// Primary @Observable surface for live vitals on iOS/watchOS.
/// Publishes latest HR/SpO2/HRV from SensorRouter without clinical alert tiers.
@MainActor
@Observable
public final class MonitoringViewModel {
    public private(set) var latestHR: Int?
    public private(set) var latestSpO2: Int?
    public private(set) var latestHRV: Double?
    public private(set) var vitalsStatus: VitalsStatus = .idle
    public private(set) var isIdle: Bool = true
    public private(set) var lastUpdateAt: Date?

    private let router: SensorRouter
    private var loopTask: Task<Void, Never>?

    public init(router: SensorRouter) {
        self.router = router
    }

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

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    public func apply(_ snap: ViewModelSnapshot) {
        self.latestHR = snap.latestHR
        self.latestSpO2 = snap.latestSpO2
        self.latestHRV = snap.latestHRV
        self.vitalsStatus = snap.vitalsStatus
        self.isIdle = snap.isIdle
        self.lastUpdateAt = Date()
    }
}
