import Foundation
import Testing
@testable import AnxietyWatchKit

@Suite("MonitoringViewModel")
@MainActor
struct MonitoringViewModelTests {
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition did not become true")
    }

    @Test("View model receives sensor snapshots")
    func viewModelReceivesSnapshots() async throws {
        let polar = PolarActor()
        let router = SensorRouter(polar: polar, emay: nil, healthKit: nil)
        let viewModel = MonitoringViewModel(router: router)
        viewModel.start()
        try await Task.sleep(for: .milliseconds(110))

        await polar.ingest(.init(timestamp: 100, heartRate: 72, rrIntervals: []))

        try await waitUntil { viewModel.latestHR == 72 }
        #expect(viewModel.latestHR == 72)
        viewModel.stop()
    }

    @Test("Start and stop are idempotent")
    func viewModelStartStopIdempotent() async {
        let router = SensorRouter(polar: nil, emay: nil, healthKit: nil)
        let viewModel = MonitoringViewModel(router: router)
        viewModel.start()
        viewModel.start()
        viewModel.stop()
        viewModel.stop()
    }

    @Test("Coordinator tier propagates through router snapshots")
    func viewModelTierPropagation() async throws {
        let polar = PolarActor()
        let router = SensorRouter(polar: polar, emay: nil, healthKit: nil)
        await router.setCoordinatorSnapshotProvider {
            (tier: .critical, fusion: 0.91)
        }
        let viewModel = MonitoringViewModel(router: router)
        viewModel.start()
        try await Task.sleep(for: .milliseconds(110))

        await polar.ingest(.init(timestamp: 100, heartRate: 60, rrIntervals: []))

        try await waitUntil { viewModel.alertTier == .critical }
        #expect(viewModel.alertTier == .critical)
        #expect(viewModel.fusionScore == 0.91)
        viewModel.stop()
    }

    @Test("Fresh router without actors is idle")
    func viewModelIdleDetection() async {
        let router = SensorRouter(polar: nil, emay: nil, healthKit: nil)
        #expect(await router.isIdle(now: 100) == true)
    }

    @Test("ViewModelSnapshot Codable round trip")
    func snapshotEncoding() throws {
        let original = ViewModelSnapshot(
            latestHR: 72,
            latestSpO2: 98,
            latestHRV: 44.5,
            alertTier: .advisory,
            isIdle: false,
            fusionScore: 0.42
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ViewModelSnapshot.self, from: data)
        #expect(decoded == original)
    }
}
