import XCTest
@testable import AnxietyWatchKit

final class CNSMonitoringCoordinatorTests: XCTestCase {

    /// Spy for the injected effect handlers.
    private actor EffectSpy {
        private(set) var notifications: [(tier: AlertTier, message: String)] = []
        private(set) var haptics: [AlertCommand.HapticPattern] = []
        private(set) var watchMessages: [String] = []

        func recordNotify(_ tier: AlertTier, _ message: String) {
            notifications.append((tier, message))
        }
        func recordHaptic(_ pattern: AlertCommand.HapticPattern) {
            haptics.append(pattern)
        }
        func recordWatchMessage(_ text: String) {
            watchMessages.append(text)
        }
    }

    private var polar: PolarActor!
    private var emay: EMAYActor!
    private var healthKit: HealthKitAdapterActor!
    private var router: SensorRouter!
    private var spy: EffectSpy!
    private var coordinator: CNSMonitoringCoordinator!

    override func setUp() {
        super.setUp()
        polar = PolarActor()
        emay = EMAYActor()
        healthKit = HealthKitAdapterActor()
        router = SensorRouter(polar: polar, emay: emay, healthKit: healthKit)
        spy = EffectSpy()

        let localSpy = spy!
        coordinator = CNSMonitoringCoordinator(
            router: router,
            handlers: .init(
                notify: { tier, message in await localSpy.recordNotify(tier, message) },
                haptic: { pattern in await localSpy.recordHaptic(pattern) },
                watchMessage: { text in await localSpy.recordWatchMessage(text) }
            )
        )
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

    /// Yield-burst polling: wait until `condition` holds, without Task.sleep.
    /// Fails the test if the condition never becomes true within maxYields.
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

    /// Fixed yield burst for negative assertions (nothing should happen).
    private func drain(_ yields: Int = 200) async {
        for _ in 0..<yields {
            await Task.yield()
        }
    }

    // MARK: - Tests

    func testStartConsumesRouterStreamAndCallsHandlers() async throws {
        await coordinator.start()

        // HR far above hrMax → per-sample warning escalation.
        await polar.ingest(PolarActor.HRSample(timestamp: 100, heartRate: 200, rrIntervals: []))

        let localSpy = spy!
        await waitUntil({ await !localSpy.notifications.isEmpty },
                        message: "notify handler never called")

        let notifications = await spy.notifications
        XCTAssertEqual(notifications.first?.tier, .warning)
        XCTAssertEqual(notifications.first?.message, "Heart rate 200 BPM outside 40–180")
    }

    func testTierEscalationDelivered() async throws {
        await coordinator.start()

        await polar.ingest(PolarActor.HRSample(timestamp: 100, heartRate: 200, rrIntervals: []))

        let localSpy = spy!
        await waitUntil({ await !localSpy.notifications.isEmpty },
                        message: "escalation never delivered")
        let notifications = await spy.notifications
        XCTAssertTrue(notifications.contains { $0.tier == .warning },
                      "HR=200 must deliver a .warning notify")
    }

    func testStopHaltsLoop() async throws {
        await coordinator.start()
        let running = await coordinator.isRunning
        XCTAssertTrue(running)

        await coordinator.stop()
        let stopped = await coordinator.isRunning
        XCTAssertFalse(stopped)

        // Ingest after stop: nothing may reach the handlers.
        await polar.ingest(PolarActor.HRSample(timestamp: 100, heartRate: 200, rrIntervals: []))
        await drain()

        let notifications = await spy.notifications
        let haptics = await spy.haptics
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertTrue(haptics.isEmpty)
    }

    func testFusionApplied() async throws {
        // The router has no accel source, so pre-fill the accel ring through
        // the pure step function and hand it to the coordinator as its
        // initial state (low magnitude → no tier change: 0.5 < accelSumHigh).
        var initialState = PipelineState()
        for i in 0..<3 {
            (initialState, _) = PipelineStep.step(initialState, .accel(tMs: Int64(i), magnitude: 0.5))
        }
        let localSpy = spy!
        coordinator = CNSMonitoringCoordinator(
            router: router,
            initialState: initialState,
            handlers: .init(
                notify: { tier, message in await localSpy.recordNotify(tier, message) },
                haptic: { pattern in await localSpy.recordHaptic(pattern) },
                watchMessage: { text in await localSpy.recordWatchMessage(text) }
            )
        )
        await coordinator.start()

        // Build a fusion-critical picture that per-sample logic alone cannot
        // reach (per-sample maxes out at .warning here):
        // - 5 low-HR samples (bpm=20): hrContribution = 1.0 → weight 0.30.
        //   Per-sample: warning.
        // - HRV 0.5 ms: hrvContribution ≈ 0.97 → ~0.145. Per-sample: advisory.
        // - SpO2 85 with signalQuality 2: per-sample SUPPRESSED (bad signal),
        //   but the ring records it → spo2Contribution 1.0 → 0.35.
        // - Pre-filled low accel (0.5): with hrContribution > 0.3 → 1.0 → 0.10.
        // Total ≈ 0.895 ≥ 0.8 → fusion proposes .critical.
        for i in 0..<5 {
            await polar.ingest(PolarActor.HRSample(timestamp: Double(100 + i), heartRate: 20, rrIntervals: []))
        }
        await healthKit.ingest(HealthKitAdapterActor.HKSample(
            timestamp: 106, quantityType: .heartRateVariability, value: 0.5))
        await emay.ingest(EMAYActor.OxygenSample(
            timestamp: 107, spo2Percent: 85, pulseRate: nil, signalQuality: 2, batteryPercent: nil))

        await waitUntil({ await localSpy.notifications.contains { $0.tier == .critical } },
                        message: "fusion-driven critical never delivered")

        let notifications = await spy.notifications
        XCTAssertTrue(notifications.contains {
            $0.tier == .critical && $0.message == "Fusion score indicated CNS depression risk"
        })
        let haptics = await spy.haptics
        XCTAssertTrue(haptics.contains(.failure))

        let tier = await coordinator.currentTier
        XCTAssertEqual(tier, .critical)
        let fusion = await coordinator.currentFusionScore
        XCTAssertGreaterThanOrEqual(fusion.overall, 0.8)
    }

    func testIdempotentStart() async throws {
        await coordinator.start()
        await coordinator.start()   // second start must be a no-op

        let running = await coordinator.isRunning
        XCTAssertTrue(running)

        // One sample → exactly one escalation notify (a second loop would
        // double-process and double-emit... actually a second consumer on the
        // single AsyncStream would steal samples — either failure mode shows
        // up as a wrong notification count).
        await polar.ingest(PolarActor.HRSample(timestamp: 100, heartRate: 200, rrIntervals: []))
        let localSpy = spy!
        await waitUntil({ await !localSpy.notifications.isEmpty },
                        message: "notify never delivered")
        await drain()

        let notifications = await spy.notifications
        XCTAssertEqual(notifications.count, 1)
    }

    func testCurrentTierReflectsState() async throws {
        let initialTier = await coordinator.currentTier
        XCTAssertEqual(initialTier, .normal)

        await coordinator.start()
        await polar.ingest(PolarActor.HRSample(timestamp: 100, heartRate: 200, rrIntervals: []))

        let localCoordinator = coordinator!
        await waitUntil({ await localCoordinator.currentTier == .warning },
                        message: "currentTier never reflected the escalation")

        let tier = await coordinator.currentTier
        XCTAssertEqual(tier, .warning)
    }

    func testRespiratoryRateSampleDoesNotCrash() async throws {
        await coordinator.start()

        // Respiratory rate has no pipeline event — must be dropped silently.
        await healthKit.ingest(HealthKitAdapterActor.HKSample(
            timestamp: 100, quantityType: .respiratoryRate, value: 14))
        await drain()

        let notifications = await spy.notifications
        XCTAssertTrue(notifications.isEmpty)

        // The loop must still be alive and processing afterwards.
        await polar.ingest(PolarActor.HRSample(timestamp: 200, heartRate: 200, rrIntervals: []))
        let localSpy = spy!
        await waitUntil({ await !localSpy.notifications.isEmpty },
                        message: "loop died after the dropped sample")

        let tier = await coordinator.currentTier
        XCTAssertEqual(tier, .warning)
    }
}
