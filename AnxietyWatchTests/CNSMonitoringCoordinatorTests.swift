import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Covers `CNSMonitoringCoordinator`'s 8-item behavior contract (task-6-brief):
/// tick loop, persistence cadence + prune + peakTier ratchet, tier-edge
/// off-cadence writes, dose arming (incl. UserDefaults-persisted
/// `[LoggedCNSDose]` + relaunch re-arm), dose-window expiry vs.
/// manual/adHoc trigger independence, device-state transitions
/// (device-loss end + interim notification / degrade-disclosed once per
/// session per source), the minimum-bar status line, and state-preserving
/// companion re-marks. Synthetic clock + provider closures throughout —
/// `enableTickLoop: false` so no real `Task`/`Timer` ever runs; every test
/// drives `tick(at:)` manually, one simulated second at a time, mirroring
/// `CNSDetectionPipelineTests.replay`.
@MainActor
struct CNSMonitoringCoordinatorTests {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Test doubles

    private final class NotificationPosterSpy: CNSMonitoringNotificationPosting {
        struct Post: Equatable {
            let identifier: String
            let title: String
            let body: String
        }
        private(set) var posts: [Post] = []
        func post(identifier: String, title: String, body: String) {
            posts.append(Post(identifier: identifier, title: title, body: body))
        }
    }

    // MARK: - Helpers

    private func makeDefaults(_ suite: String = #function) -> UserDefaults {
        let name = "CNSMonitoringCoordinatorTests.\(suite).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("could not create UserDefaults suite \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeCoordinator(
        context: ModelContext,
        now: @escaping () -> Date,
        emayReading: @escaping () -> EMAYReading? = { nil },
        polarHR: @escaping () -> Int? = { nil },
        polarRMSSD: @escaping () -> Double? = { nil },
        poster: CNSMonitoringNotificationPosting,
        defaults: UserDefaults
    ) -> CNSMonitoringCoordinator {
        CNSMonitoringCoordinator(
            modelContext: context,
            now: now,
            latestEMAYReading: emayReading,
            latestPolarHR: polarHR,
            latestPolarRMSSD: polarRMSSD,
            notificationPoster: poster,
            defaults: defaults,
            enableTickLoop: false
        )
    }

    private func makeBenzoMedication(context: ModelContext) -> MedicationDefinition {
        let med = MedicationDefinition(name: "Test Benzo 1mg", defaultDoseMg: 1, category: "Benzodiazepine")
        context.insert(med)
        return med
    }

    // MARK: - Contract 1: tick loop

    @Test("Tick loop: reads sensors via injected providers each tick and updates currentTier/canAssess as the pipeline processes")
    func tickLoopUpdatesTierAndCanAssess() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0
        var reading: EMAYReading?
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, emayReading: { reading },
            poster: NotificationPosterSpy(), defaults: makeDefaults()
        )

        coordinator.armManually(companionPresent: true)
        #expect(coordinator.isMonitoring)
        #expect(coordinator.canAssess == false)

        for second in 1...60 {
            currentTime = t0.addingTimeInterval(Double(second))
            reading = EMAYReading(spo2: 96, pulseRate: 62, timestamp: currentTime)
            coordinator.tick(at: currentTime)
        }

        #expect(coordinator.canAssess == true)
        #expect(coordinator.currentTier == .clear)
        #expect(coordinator.reportingSources.contains(.emayOximeter))
    }

    // MARK: - Contract 2: persistence cadence + prune(cutoff: now - sampleRetention)

    @Test("Persistence: writes a CNSRiskSampleRecord and prunes samples older than now - sampleRetention (Task 3's exact cutoff contract)")
    func persistsAndPrunesUsingRetentionCutoff() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())

        // An unrelated, ENDED, stale session with a sample older than
        // retention — proves the coordinator calls
        // MonitoringSessionStore.prune(before: now - sampleRetention, ...).
        let staleSession = MonitoringSession(
            startedAt: t0.addingTimeInterval(-30 * 3600),
            endedAt: t0.addingTimeInterval(-26 * 3600),
            activationTriggers: ["manual"], companionPresent: true
        )
        context.insert(staleSession)
        MonitoringSessionStore.insertSample(
            timestamp: t0.addingTimeInterval(-25 * 3600), riskScore: 0.1, tier: .clear,
            canAssess: true, into: staleSession, context: context
        )
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<CNSRiskSampleRecord>()) == 1)

        var currentTime = t0
        var reading: EMAYReading? = EMAYReading(spo2: 96, pulseRate: 62, timestamp: t0)
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, emayReading: { reading },
            poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)

        for second in 1...12 {
            currentTime = t0.addingTimeInterval(Double(second))
            reading = EMAYReading(spo2: 96, pulseRate: 62, timestamp: currentTime)
            coordinator.tick(at: currentTime)
        }

        let allRecords = try context.fetch(FetchDescriptor<CNSRiskSampleRecord>())
        #expect(!allRecords.contains { $0.timestamp == t0.addingTimeInterval(-25 * 3600) })
        #expect(!allRecords.isEmpty)
    }

    // MARK: - Contract 3: tier edges (off-cadence write) + peakTier ratchet

    @Test(
        """
        Tier edges: an off-cadence CNSRiskSampleRecord is written exactly when tier increases; \
        session.peakTier ratchets to the highest tier reached
        """
    )
    func tierEdgeWritesOffCadenceRecordAndRatchetsPeakTier() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0

        let coordinator = makeCoordinator(
            context: context, now: { currentTime },
            emayReading: {
                let second = currentTime.timeIntervalSince(self.t0)
                let decline = min(second / 600, 1.0)
                let spo2 = Int((96 - decline * 14).rounded())
                return EMAYReading(spo2: spo2, pulseRate: 62, timestamp: currentTime)
            },
            poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: false)

        for second in 1...900 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }

        #expect(coordinator.currentTier == .klaxon)

        let session = try #require(try context.fetch(FetchDescriptor<MonitoringSession>()).first)
        #expect(session.peakTier == CNSAlertTier.klaxon.rawValue)

        let records = try context.fetch(
            FetchDescriptor<CNSRiskSampleRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        var foundOffCadenceEdge = false
        for (previous, current) in zip(records, records.dropFirst()) {
            let gap = current.timestamp.timeIntervalSince(previous.timestamp)
            if gap < CNSMonitoringConstants.samplePersistInterval && current.tier > previous.tier {
                foundOffCadenceEdge = true
                break
            }
        }
        #expect(
            foundOffCadenceEdge,
            "expected at least one persisted record written off the 10s cadence at a tier increase"
        )
    }

    // MARK: - Contract 4: dose arming + persisted-list relaunch re-arm

    @Test(
        """
        Dose arming: doseLogged classifies + persists to UserDefaults + arms with .doseWindow; \
        a fresh coordinator instance re-arms from the persisted list at relaunch
        """
    )
    func doseArmingPersistsAndRearmsOnRelaunch() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let sharedDefaults = makeDefaults()
        let med = makeBenzoMedication(context: context)
        let dose = MedicationDose(timestamp: t0, medicationName: med.name, doseMg: 1, medication: med)
        context.insert(dose)
        try context.save()

        let currentTime = t0
        let coordinatorA = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: sharedDefaults
        )
        coordinatorA.doseLogged(dose)

        #expect(coordinatorA.isMonitoring)
        #expect(coordinatorA.activeTriggers.contains(.doseWindow))

        // Simulate relaunch: a fresh coordinator instance, same UserDefaults
        // suite, 1 hour later — the 12h benzo window is still active.
        let relaunchTime = t0.addingTimeInterval(3600)
        let coordinatorB = makeCoordinator(
            context: context, now: { relaunchTime }, poster: NotificationPosterSpy(), defaults: sharedDefaults
        )
        #expect(!coordinatorB.isMonitoring)
        coordinatorB.handleLaunch()
        #expect(coordinatorB.isMonitoring)
        #expect(coordinatorB.activeTriggers == [.doseWindow])
    }

    // MARK: - Contract 5: window expiry vs. trigger independence

    @Test("Window expiry: ends the session with .windowExpired when doseWindow was the sole trigger")
    func windowExpiryEndsSessionWhenSoleTrigger() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let med = makeBenzoMedication(context: context)
        var currentTime = t0
        let dose = MedicationDose(timestamp: t0, medicationName: med.name, doseMg: 1, medication: med)
        context.insert(dose)
        try context.save()

        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.doseLogged(dose)
        #expect(coordinator.isMonitoring)

        currentTime = t0.addingTimeInterval(12 * 3600 + 1)
        coordinator.tick(at: currentTime)

        #expect(!coordinator.isMonitoring)
        let session = try #require(try context.fetch(FetchDescriptor<MonitoringSession>()).first)
        #expect(session.endReason == CNSMonitoringCoordinator.EndReason.windowExpired.rawValue)
    }

    @Test("Window expiry: a manual trigger survives dose-window expiry — triggers are independent, monitoring continues")
    func windowExpirySurvivesWhenManualAlsoActive() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let med = makeBenzoMedication(context: context)
        var currentTime = t0
        let dose = MedicationDose(timestamp: t0, medicationName: med.name, doseMg: 1, medication: med)
        context.insert(dose)
        try context.save()

        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)
        coordinator.doseLogged(dose)
        #expect(coordinator.activeTriggers == [.manual, .doseWindow])

        currentTime = t0.addingTimeInterval(12 * 3600 + 1)
        coordinator.tick(at: currentTime)

        #expect(coordinator.isMonitoring)
        #expect(coordinator.activeTriggers == [.manual])
    }

    // MARK: - Contract 6: device-state transitions

    @Test("Device loss: EMAY dying mid-session ends monitoring with .deviceLoss and posts the interim ended notification")
    func emayDeviceLossEndsSessionAndNotifies() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0
        var reading: EMAYReading? = EMAYReading(spo2: 96, pulseRate: 62, timestamp: t0)
        let poster = NotificationPosterSpy()
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, emayReading: { reading },
            poster: poster, defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)

        for second in 1...10 {
            currentTime = t0.addingTimeInterval(Double(second))
            reading = EMAYReading(spo2: 96, pulseRate: 62, timestamp: currentTime)
            coordinator.tick(at: currentTime)
        }
        #expect(coordinator.isMonitoring)

        reading = nil
        currentTime = t0.addingTimeInterval(10 + 61)
        coordinator.tick(at: currentTime)

        #expect(!coordinator.isMonitoring)
        #expect(poster.posts.contains { $0.identifier == CNSMonitoringConstants.endedNotificationID })
        let session = try #require(try context.fetch(FetchDescriptor<MonitoringSession>()).first)
        #expect(session.endReason == CNSMonitoringCoordinator.EndReason.deviceLoss.rawValue)
    }

    @Test(
        """
        Device degrade: Polar dying mid-session posts the degraded notification exactly once per \
        session, discloses on statusLine, and does not end monitoring
        """
    )
    func polarDegradeDisclosesOnceWithoutEndingSession() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0
        var polarHR: Int? = 62
        let poster = NotificationPosterSpy()
        let coordinator = makeCoordinator(
            context: context, now: { currentTime },
            emayReading: { EMAYReading(spo2: 96, pulseRate: 62, timestamp: currentTime) },
            polarHR: { polarHR },
            poster: poster, defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)

        for second in 1...10 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }

        polarHR = nil
        for second in 11...(10 + 65) {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }

        #expect(coordinator.isMonitoring)
        #expect(poster.posts.filter { $0.identifier == CNSMonitoringConstants.degradedNotificationID }.count == 1)
        #expect(coordinator.statusLine.contains("Polar"))
    }

    // MARK: - Contract 7: minimum-bar status line

    @Test("Minimum bar: armed without EMAY reporting states the bare-minimum device requirement on statusLine")
    func minimumBarStatusLineWithoutEMAY() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, emayReading: { nil },
            polarHR: { 62 }, poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)
        currentTime = t0.addingTimeInterval(1)
        coordinator.tick(at: currentTime)

        #expect(
            coordinator.statusLine
                == "Connect the EMAY oximeter for danger-relevant monitoring — currently can't assess"
        )
    }

    // MARK: - Contract 8: companion re-mark is state-preserving

    @Test("Companion re-mark: mutates session + companion log + pipeline without resetting tier/canAssess mid-sustain")
    func companionRemarkPreservesStateMidSustain() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0

        let coordinator = makeCoordinator(
            context: context, now: { currentTime },
            emayReading: {
                let second = currentTime.timeIntervalSince(self.t0)
                let decline = min(second / 600, 1.0)
                let spo2 = Int((96 - decline * 14).rounded())
                return EMAYReading(spo2: spo2, pulseRate: 62, timestamp: currentTime)
            },
            poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: false)

        // Partway into the decline — well before klaxon.
        for second in 1...200 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }
        let tierBeforeFlip = coordinator.currentTier
        let canAssessBeforeFlip = coordinator.canAssess

        coordinator.setCompanionPresent(true)

        #expect(coordinator.currentTier == tierBeforeFlip)
        #expect(coordinator.canAssess == canAssessBeforeFlip)
        #expect(coordinator.companionPresent == true)

        let session = try #require(try context.fetch(FetchDescriptor<MonitoringSession>()).first)
        #expect(session.companionPresent == true)
        #expect(session.companionLog.last?.present == true)

        // Monitoring keeps running normally afterward — the flip didn't
        // corrupt anything.
        for second in 201...900 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }
        #expect(coordinator.currentTier == .klaxon)
    }

    // MARK: - disarm() always wins

    @Test("disarm() ends monitoring with .manual even when other triggers are active")
    func disarmAlwaysWinsOverOtherTriggers() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let med = makeBenzoMedication(context: context)
        let currentTime = t0
        let dose = MedicationDose(timestamp: t0, medicationName: med.name, doseMg: 1, medication: med)
        context.insert(dose)
        try context.save()

        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)
        coordinator.doseLogged(dose)
        #expect(coordinator.activeTriggers == [.manual, .doseWindow])

        coordinator.disarm()

        #expect(!coordinator.isMonitoring)
        #expect(coordinator.activeTriggers.isEmpty)
        let session = try #require(try context.fetch(FetchDescriptor<MonitoringSession>()).first)
        #expect(session.endReason == CNSMonitoringCoordinator.EndReason.manual.rawValue)
    }
}
