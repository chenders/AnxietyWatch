import XCTest
@testable import AnxietyWatchKit

final class CNSMonitoringCoordinatorTests: XCTestCase {
    private var polar: PolarActor!
    private var emay: EMAYActor!
    private var healthKit: HealthKitAdapterActor!
    private var router: SensorRouter!
    private var coordinator: CNSMonitoringCoordinator!

    override func setUp() {
        super.setUp()
        polar = PolarActor()
        emay = EMAYActor()
        healthKit = HealthKitAdapterActor()
        router = SensorRouter(polar: polar, emay: emay, healthKit: healthKit)
        coordinator = CNSMonitoringCoordinator(router: router)
    }

    override func tearDown() {
        let expectation = expectation(description: "stop coordinator")
        Task {
            await coordinator.stop()
            expectation.fulfill()
        }
        waitForExpectations(timeout: 10)
        super.tearDown()
    }

    private func waitUntil(
        maxYields: Int = 5_000,
        _ condition: @escaping () async -> Bool,
        message: String = "condition never became true"
    ) async {
        for _ in 0..<maxYields {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail(message)
    }

    private func drain(_ yields: Int = 200) async {
        for _ in 0..<yields { await Task.yield() }
    }

    func testStartConsumesRouterStreamAndPublishesState() async {
        await coordinator.start()
        await polar.ingest(PolarActor.HRSample(
            timestamp: 100, heartRate: 200, rrIntervals: []
        ))

        let localCoordinator = coordinator!
        await waitUntil(
            { await localCoordinator.currentTier == .warning },
            message: "tier never reflected the sample"
        )
    }

    func testStopHaltsLoop() async {
        await coordinator.start()
        let running = await coordinator.isRunning
        XCTAssertTrue(running)

        await coordinator.stop()
        let stopped = await coordinator.isRunning
        XCTAssertFalse(stopped)

        await polar.ingest(PolarActor.HRSample(
            timestamp: 100, heartRate: 200, rrIntervals: []
        ))
        await drain()
        let tier = await coordinator.currentTier
        XCTAssertEqual(tier, .normal)
    }

    func testFusionAppliedToPublishedState() async {
        var initialState = PipelineState()
        for i in 0..<3 {
            (initialState, _) = PipelineStep.step(
                initialState, .accel(tMs: Int64(i), magnitude: 0.5)
            )
        }
        coordinator = CNSMonitoringCoordinator(router: router, initialState: initialState)
        await coordinator.start()

        for i in 0..<5 {
            await polar.ingest(PolarActor.HRSample(
                timestamp: Double(100 + i), heartRate: 20, rrIntervals: []
            ))
        }
        await healthKit.ingest(HealthKitAdapterActor.HKSample(
            timestamp: 106, quantityType: .heartRateVariability, value: 0.5
        ))
        await emay.ingest(EMAYActor.OxygenSample(
            timestamp: 107,
            spo2Percent: 85,
            pulseRate: nil,
            signalQuality: 2,
            batteryPercent: nil
        ))

        let localCoordinator = coordinator!
        await waitUntil(
            { await localCoordinator.currentTier == .critical },
            message: "fusion-driven critical tier was not published"
        )
        let fusion = await coordinator.currentFusionScore
        XCTAssertGreaterThanOrEqual(fusion.overall, 0.8)
    }

    func testIdempotentStartProcessesSampleOnce() async {
        await coordinator.start()
        await coordinator.start()

        await polar.ingest(PolarActor.HRSample(
            timestamp: 100, heartRate: 200, rrIntervals: []
        ))
        let localCoordinator = coordinator!
        await waitUntil(
            { await localCoordinator.currentTier == .warning },
            message: "sample was not processed"
        )

        let state = await coordinator.currentPipelineState
        XCTAssertEqual(state.hrRing.count, 1)
    }

    func testCurrentTierReflectsDirectStateProcessing() async {
        let initialTier = await coordinator.currentTier
        XCTAssertEqual(initialTier, .normal)
        await coordinator.process(.hr(tMs: 1_000, bpm: 200))
        let updatedTier = await coordinator.currentTier
        XCTAssertEqual(updatedTier, .warning)
    }

    func testRespiratoryRateIsDroppedWithoutStoppingLoop() async {
        await coordinator.start()
        await healthKit.ingest(HealthKitAdapterActor.HKSample(
            timestamp: 100, quantityType: .respiratoryRate, value: 14
        ))
        await drain()
        let tier = await coordinator.currentTier
        XCTAssertEqual(tier, .normal)

        await polar.ingest(PolarActor.HRSample(
            timestamp: 200, heartRate: 200, rrIntervals: []
        ))
        let localCoordinator = coordinator!
        await waitUntil(
            { await localCoordinator.currentTier == .warning },
            message: "loop died after dropping respiratory rate"
        )
    }
}
