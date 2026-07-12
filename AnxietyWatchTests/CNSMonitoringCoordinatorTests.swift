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
        struct Scheduled: Equatable {
            let identifier: String
            let title: String
            let body: String
            let fireDate: Date
        }
        private(set) var posts: [Post] = []
        /// Latest `schedule` call per identifier — mirrors production's
        /// "replace the pending request" semantics (`UNUserNotificationCenter.add`
        /// with a matching identifier replaces, never stacks), so a spy
        /// consumer only ever sees the CURRENT deadline, matching what a
        /// real pending-request inspection would show.
        private(set) var scheduled: [String: Scheduled] = [:]
        private(set) var cancelledIdentifiers: [String] = []

        func post(identifier: String, title: String, body: String) {
            posts.append(Post(identifier: identifier, title: title, body: body))
        }

        func schedule(identifier: String, title: String, body: String, at fireDate: Date) {
            scheduled[identifier] = Scheduled(identifier: identifier, title: title, body: body, fireDate: fireDate)
        }

        func cancel(identifier: String) {
            scheduled.removeValue(forKey: identifier)
            cancelledIdentifiers.append(identifier)
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
        defaults: UserDefaults,
        emayStartHook: @escaping () -> Void = {},
        emayStopHook: (() -> Void)? = nil
    ) -> CNSMonitoringCoordinator {
        CNSMonitoringCoordinator(
            modelContext: context,
            now: now,
            latestEMAYReading: emayReading,
            latestPolarHR: polarHR,
            latestPolarRMSSD: polarRMSSD,
            notificationPoster: poster,
            defaults: defaults,
            enableTickLoop: false,
            emayStartHook: emayStartHook,
            emayStopHook: emayStopHook
        )
    }

    private func makeBenzoMedication(context: ModelContext) -> MedicationDefinition {
        let med = MedicationDefinition(name: "Test Benzo 1mg", defaultDoseMg: 1, category: "Benzodiazepine")
        context.insert(med)
        return med
    }

    private func makeMethadoneMedication(context: ModelContext) -> MedicationDefinition {
        let med = MedicationDefinition(name: "Methadone 10mg", defaultDoseMg: 10, category: "Opioid")
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

    @Test(
        """
        Prune rides the 10s persist cadence, not the 1Hz tick: an over-retention sample \
        survives every non-cadence tick and is removed at the next cadence boundary
        """
    )
    func pruneRunsOnlyOnPersistCadence() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)

        // First tick: lastPersistAt is nil, so this IS a cadence tick
        // (persist + prune both run) — it anchors the cadence clock at t0+1.
        currentTime = t0.addingTimeInterval(1)
        coordinator.tick(at: currentTime)

        // NOW plant an over-retention sample on an ENDED session (no
        // safety-net protection). The plain retention rule alone would
        // delete it on ANY prune run — so its survival below proves prune
        // did not run.
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

        // Ticks at t0+2 ... t0+9: all < samplePersistInterval since the
        // t0+1 cadence anchor, and no samples flow (tier stays clear, so no
        // tier-increase writes either). The stale sample must survive all of
        // them.
        for second in 2...9 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
            let survivors = try context.fetch(FetchDescriptor<CNSRiskSampleRecord>())
            #expect(
                survivors.contains { $0.timestamp == t0.addingTimeInterval(-25 * 3600) },
                "prune must not run on the non-cadence tick at t0+\(second)s"
            )
        }

        // Cross the cadence boundary (>= samplePersistInterval since t0+1):
        // prune runs and the stale sample is gone.
        currentTime = t0.addingTimeInterval(1 + CNSMonitoringConstants.samplePersistInterval)
        coordinator.tick(at: currentTime)
        let remaining = try context.fetch(FetchDescriptor<CNSRiskSampleRecord>())
        #expect(!remaining.contains { $0.timestamp == t0.addingTimeInterval(-25 * 3600) })
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

    @Test(
        """
        Dose-list cache freshness: a second doseLogged mid-window updates the cached list, \
        so expiry evaluation honors the EXTENDED window, not the stale one
        """
    )
    func doseLoggedUpdatesCachedListForExpiryEvaluation() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let med = makeBenzoMedication(context: context)
        var currentTime = t0
        let firstDose = MedicationDose(timestamp: t0, medicationName: med.name, doseMg: 1, medication: med)
        context.insert(firstDose)
        try context.save()

        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.doseLogged(firstDose)
        #expect(coordinator.isMonitoring)

        // Ticks populate/exercise the cache with just the first dose onboard.
        for second in 1...5 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }

        // Second benzo an hour later extends the window to t0+13h. If
        // doseLogged didn't keep the cached list coherent, expiry evaluation
        // would still see only the t0 dose (window t0+12h).
        currentTime = t0.addingTimeInterval(3600)
        let secondDose = MedicationDose(
            timestamp: currentTime, medicationName: med.name, doseMg: 1, medication: med
        )
        context.insert(secondDose)
        try context.save()
        coordinator.doseLogged(secondDose)

        // Past the FIRST dose's window but inside the extended one: a stale
        // cache would end the session here.
        currentTime = t0.addingTimeInterval(12 * 3600 + 60)
        coordinator.tick(at: currentTime)
        #expect(coordinator.isMonitoring, "monitoring must honor the extended (fresh) window")
        #expect(coordinator.activeTriggers == [.doseWindow])

        // Past the extended window: expires normally.
        currentTime = t0.addingTimeInterval(13 * 3600 + 1)
        coordinator.tick(at: currentTime)
        #expect(!coordinator.isMonitoring)
        let session = try context.fetch(FetchDescriptor<MonitoringSession>())
            .first { $0.endReason != nil }
        #expect(session?.endReason == CNSMonitoringCoordinator.EndReason.windowExpired.rawValue)
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
        Device degrade: Polar dying mid-session (no more genuine packet arrivals, fix item 2) posts \
        the degraded notification exactly once per session, discloses on statusLine, and does not \
        end monitoring
        """
    )
    func polarDegradeDisclosesOnceWithoutEndingSession() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0
        // Constant value throughout — liveness now comes from genuine
        // `noteLivePolarSample` arrivals (fix item 2), not from the raw
        // value changing or going nil, matching how `PolarHRMService.state.currentHR`
        // actually behaves (stays populated through the reconnect grace).
        let poster = NotificationPosterSpy()
        let coordinator = makeCoordinator(
            context: context, now: { currentTime },
            emayReading: { EMAYReading(spo2: 96, pulseRate: 62, timestamp: currentTime) },
            polarHR: { 62 },
            poster: poster, defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)

        for second in 1...10 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.noteLivePolarSample(at: currentTime)
            coordinator.tick(at: currentTime)
        }

        // Device "dies": no more genuine arrivals from here on, even though
        // `latestPolarHR()` would still return 62 in production for ~10 more
        // minutes (the reconnect grace).
        for second in 11...(10 + 65) {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }

        #expect(coordinator.isMonitoring)
        #expect(poster.posts.filter { $0.identifier == CNSMonitoringConstants.degradedNotificationID }.count == 1)
        #expect(coordinator.statusLine.contains("Polar"))
    }

    @Test(
        """
        Fix item 2 (IMPORTANT): a frozen cached Polar value with no new packet arrivals must not \
        read as fresh — mirrors PolarHRMService.state.currentHR staying populated through its \
        ~10-min reconnect grace after the strap actually dies. After >60s with no new arrivals, \
        polarH10 leaves reportingSources; EMAY's own tick-polled liveness is unaffected.
        """
    )
    func polarLivenessRequiresGenuineArrivalNotCachedValue() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0
        let coordinator = makeCoordinator(
            context: context, now: { currentTime },
            emayReading: { EMAYReading(spo2: 96, pulseRate: 62, timestamp: currentTime) },
            polarHR: { 62 },  // frozen: identical before AND long after the (simulated) death
            poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)

        // One genuine arrival — Polar is reporting.
        currentTime = t0.addingTimeInterval(1)
        coordinator.noteLivePolarSample(at: currentTime)
        coordinator.tick(at: currentTime)
        #expect(coordinator.reportingSources.contains(.polarH10))

        // No further arrivals, ever — but `latestPolarHR()` keeps returning
        // the SAME cached 62 the whole time, exactly like the real service's
        // frozen post-death state. Tick well past gateWindowSeconds (60s).
        for second in 2...65 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }

        #expect(!coordinator.reportingSources.contains(.polarH10), "a frozen cached value must not read as fresh")
        #expect(coordinator.reportingSources.contains(.emayOximeter), "EMAY's own tick-polled liveness must be unaffected")
    }

    // MARK: - Fix item 2 follow-up: bounded RMSSD sample-and-hold

    /// Shared fixture for the two sample-and-hold tests: a `HealthSnapshot`
    /// carrying an HRV baseline (the scorer never scores `.hrv` without
    /// one), inserted BEFORE arming so `loadBaselines` picks it up.
    private func insertHRVBaselineSnapshot(context: ModelContext, hrvMean: Double) throws {
        let snapshot = HealthSnapshot(date: t0.addingTimeInterval(-86_400))
        snapshot.hrvAvg = hrvMean
        context.insert(snapshot)
        try context.save()
    }

    @Test(
        """
        RMSSD sample-and-hold: while genuine HR arrivals are live, the cached per-minute RMSSD is \
        re-emitted every tick, so the Polar HRV stream passes the 30s-contiguous quality gate \
        across a 60s window (an hrv/polarH10 contribution reaches the persisted record) — a \
        change-only emission (~1 sample/min) could never pass it
        """
    )
    func rmssdSampleAndHoldPassesGateWhileHRArrivalsLive() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        try insertHRVBaselineSnapshot(context: context, hrvMean: 45)

        var currentTime = t0
        let coordinator = makeCoordinator(
            context: context, now: { currentTime },
            emayReading: { EMAYReading(spo2: 96, pulseRate: 62, timestamp: currentTime) },
            polarHR: { 62 },
            polarRMSSD: { 45 },  // constant per-minute value — sample-and-hold must carry it
            poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)

        for second in 1...65 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.noteLivePolarSample(at: currentTime)
            coordinator.tick(at: currentTime)
        }

        #expect(coordinator.reportingSources.contains(.polarH10))
        let records = try context.fetch(
            FetchDescriptor<CNSRiskSampleRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        let lastRecord = try #require(records.last)
        #expect(
            lastRecord.contributions.contains { $0.kind == "hrv" && $0.source == "polarH10" },
            "the held RMSSD stream must pass the gate and contribute while HR arrivals are live"
        )
    }

    @Test(
        """
        RMSSD sample-and-hold is BOUNDED: once genuine HR arrivals stop, RMSSD emission stops \
        within gateWindowSeconds even though latestPolarRMSSD keeps returning the frozen cached \
        value — no frozen resurrection; the hrv contribution drains out and polarH10 leaves \
        reportingSources
        """
    )
    func rmssdSampleAndHoldStopsWithinGateWindowAfterHRArrivalsStop() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        try insertHRVBaselineSnapshot(context: context, hrvMean: 45)

        var currentTime = t0
        let coordinator = makeCoordinator(
            context: context, now: { currentTime },
            emayReading: { EMAYReading(spo2: 96, pulseRate: 62, timestamp: currentTime) },
            polarHR: { 62 },   // frozen through the reconnect grace, like the real service
            polarRMSSD: { 45 },  // ditto — the cached value NEVER goes nil or changes
            poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)

        // Phase 1: live HR arrivals through t0+70 — HRV contributes.
        for second in 1...70 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.noteLivePolarSample(at: currentTime)
            coordinator.tick(at: currentTime)
        }
        let liveRecords = try context.fetch(
            FetchDescriptor<CNSRiskSampleRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        #expect(
            try #require(liveRecords.last).contributions
                .contains { $0.kind == "hrv" && $0.source == "polarH10" }
        )

        // Phase 2: the strap dies — HR arrivals stop, but BOTH providers
        // keep returning the same frozen cached values. The presence clock
        // is fed by genuine arrivals ONLY (held RMSSD re-emissions don't
        // refresh it), so died-detection fires at lastArrival +
        // gateWindowSeconds: strictly after t0+130, i.e. by the t0+131
        // tick. Verify polar has left reportingSources by t0+135 — the
        // hold must not extend presence by even one extra gate window.
        for second in 71...135 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }
        #expect(
            !coordinator.reportingSources.contains(.polarH10),
            "died-detection must fire at lastArrival + gateWindowSeconds; the hold must not extend presence"
        )

        // Emission itself also stopped at t0+130 (arrival + gateWindow);
        // the already-buffered samples take one more gate window to leave
        // the rolling window (t0+190) — so by t0+200 the hrv stream is
        // fully drained from persisted contributions too.
        for second in 136...200 {
            currentTime = t0.addingTimeInterval(Double(second))
            coordinator.tick(at: currentTime)
        }

        #expect(coordinator.isMonitoring, "Polar is corroborating-only; its loss degrades, never ends")
        #expect(!coordinator.reportingSources.contains(.polarH10))
        let allRecords = try context.fetch(
            FetchDescriptor<CNSRiskSampleRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        let finalRecord = try #require(allRecords.last)
        #expect(
            !finalRecord.contributions.contains { $0.source == "polarH10" },
            "no polar-sourced contribution may survive once emission stopped and the window drained"
        )
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

    // MARK: - doseWindowExpiry (Task 7 UI seam)

    @Test(
        """
        doseWindowExpiry mirrors DoseWindowGate's active window while .doseWindow is an active \
        trigger, refreshes every tick, and clears to nil once the window expires
        """
    )
    func doseWindowExpiryTracksActiveWindowAndClearsOnExpiry() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let med = makeBenzoMedication(context: context)
        var currentTime = t0
        let dose = MedicationDose(timestamp: t0, medicationName: med.name, doseMg: 1, medication: med)
        context.insert(dose)
        try context.save()

        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        #expect(coordinator.doseWindowExpiry == nil)

        coordinator.doseLogged(dose)
        #expect(coordinator.doseWindowExpiry == t0.addingTimeInterval(12 * 3600))

        // A tick recomputes it too, not just doseLogged.
        currentTime = t0.addingTimeInterval(3600)
        coordinator.tick(at: currentTime)
        #expect(coordinator.doseWindowExpiry == t0.addingTimeInterval(12 * 3600))

        currentTime = t0.addingTimeInterval(12 * 3600 + 1)
        coordinator.tick(at: currentTime)
        #expect(!coordinator.isMonitoring)
        #expect(coordinator.doseWindowExpiry == nil)
    }

    @Test("doseWindowExpiry is nil when monitoring is armed for a reason other than a dose window")
    func doseWindowExpiryNilWithoutDoseWindowTrigger() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let currentTime = t0
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)
        #expect(coordinator.doseWindowExpiry == nil)
    }

    @Test("doseWindowExpiry clears to nil when the doseWindow trigger drops even if monitoring continues via another trigger")
    func doseWindowExpiryClearsWhenTriggerDropsButSessionSurvives() throws {
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
        #expect(coordinator.doseWindowExpiry != nil)

        currentTime = t0.addingTimeInterval(12 * 3600 + 1)
        coordinator.tick(at: currentTime)

        #expect(coordinator.isMonitoring)
        #expect(coordinator.activeTriggers == [.manual])
        #expect(coordinator.doseWindowExpiry == nil)
    }

    // MARK: - emayStartHook (EMAY auto-start interplay)

    @Test(
        """
        Arming (any trigger kind) fires emayStartHook exactly once per NEW session; adding a \
        trigger to an already-active session does not re-fire it
        """
    )
    func armingFiresEMAYStartHookOncePerSession() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let currentTime = t0
        var startCount = 0
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults(),
            emayStartHook: { startCount += 1 }
        )

        coordinator.armManually(companionPresent: true)
        #expect(startCount == 1)

        // Stacking a second trigger onto the SAME active session must not
        // re-fire the hook — the EMAY session is already (or already trying
        // to be) up.
        coordinator.armAdHoc()
        #expect(startCount == 1)

        coordinator.disarm()
        coordinator.armAdHoc()
        #expect(startCount == 2)
    }

    // MARK: - emayStopHook (EMAY teardown on disarm — session must not outlive monitoring)

    @Test(
        """
        endSession invokes emayStopHook; production-closure semantics (the continuous-mode \
        guard lives in the closure, not the coordinator) are exercised via an injected flag — \
        OFF means the closure actually performs its "stop"
        """
    )
    func endSessionInvokesEMAYStopHookWhenNotContinuous() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let currentTime = t0
        // Mirrors the production closure's own guard: never fight the
        // user's continuous-streaming toggle — the coordinator itself
        // knows nothing about this flag, only that it must call the hook.
        let continuousModeEnabled = false
        var stopCount = 0
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults(),
            emayStopHook: {
                if !continuousModeEnabled { stopCount += 1 }
            }
        )
        coordinator.armManually(companionPresent: true)
        #expect(stopCount == 0, "the hook must not fire before the session actually ends")

        coordinator.disarm()
        #expect(stopCount == 1)
    }

    @Test(
        """
        endSession still calls emayStopHook when continuous mode is ON, but the \
        production-style guard inside the closure suppresses the actual stop — the toggle \
        is never fought
        """
    )
    func endSessionDoesNotStopEMAYWhenContinuousModeOn() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let currentTime = t0
        let continuousModeEnabled = true
        var stopCount = 0
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: makeDefaults(),
            emayStopHook: {
                if !continuousModeEnabled { stopCount += 1 }
            }
        )
        coordinator.armManually(companionPresent: true)

        coordinator.disarm()
        #expect(stopCount == 0, "continuous mode must never be fought by CNS monitoring disarm")
        #expect(!coordinator.isMonitoring)
    }

    // MARK: - Fix item 1 (CRITICAL): dead-man's-switch watchdog

    @Test(
        """
        Dead-man's-switch: arming schedules the watchdog immediately; each persist-cadence tick \
        (not every 1Hz tick) reschedules it forward — the spy always sees the LATEST fire date
        """
    )
    func tickSchedulesAndReschedulesDeadMansSwitchOnPersistCadence() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        var currentTime = t0
        let poster = NotificationPosterSpy()
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: poster, defaults: makeDefaults()
        )

        coordinator.armManually(companionPresent: true)
        let armFireDate = try #require(
            poster.scheduled[CNSMonitoringConstants.deadMansSwitchNotificationID]?.fireDate
        )
        #expect(armFireDate == t0.addingTimeInterval(CNSMonitoringConstants.deadMansSwitchInterval))

        // First tick: lastPersistAt is nil, so this tick IS a cadence tick
        // (mirrors pruneRunsOnlyOnPersistCadence's own first-tick anchor) —
        // reschedules to a later fire date.
        currentTime = t0.addingTimeInterval(1)
        coordinator.tick(at: currentTime)
        let anchorFireDate = try #require(
            poster.scheduled[CNSMonitoringConstants.deadMansSwitchNotificationID]?.fireDate
        )
        #expect(anchorFireDate == currentTime.addingTimeInterval(CNSMonitoringConstants.deadMansSwitchInterval))

        // A non-cadence tick must NOT reschedule.
        currentTime = t0.addingTimeInterval(2)
        coordinator.tick(at: currentTime)
        #expect(poster.scheduled[CNSMonitoringConstants.deadMansSwitchNotificationID]?.fireDate == anchorFireDate)

        // Crossing the cadence boundary reschedules again, further out.
        currentTime = t0.addingTimeInterval(1 + CNSMonitoringConstants.samplePersistInterval)
        coordinator.tick(at: currentTime)
        let laterFireDate = try #require(
            poster.scheduled[CNSMonitoringConstants.deadMansSwitchNotificationID]?.fireDate
        )
        #expect(laterFireDate > anchorFireDate, "the watchdog's fire date must advance as cadence ticks keep firing")
        #expect(laterFireDate == currentTime.addingTimeInterval(CNSMonitoringConstants.deadMansSwitchInterval))
    }

    @Test("Dead-man's-switch: endSession (any reason) cancels the pending watchdog")
    func endSessionCancelsDeadMansSwitch() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let currentTime = t0
        let poster = NotificationPosterSpy()
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: poster, defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)
        #expect(poster.scheduled[CNSMonitoringConstants.deadMansSwitchNotificationID] != nil)

        coordinator.disarm()

        #expect(poster.scheduled[CNSMonitoringConstants.deadMansSwitchNotificationID] == nil)
        #expect(poster.cancelledIdentifiers.contains(CNSMonitoringConstants.deadMansSwitchNotificationID))
    }

    @Test("Dead-man's-switch: never scheduled while not monitoring")
    func noDeadMansSwitchScheduleWhenNotMonitoring() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let currentTime = t0
        let poster = NotificationPosterSpy()
        let coordinator = makeCoordinator(
            context: context, now: { currentTime }, poster: poster, defaults: makeDefaults()
        )

        coordinator.tick(at: currentTime)

        #expect(poster.scheduled.isEmpty)
        #expect(!coordinator.isMonitoring)
    }

    // MARK: - Fix item 3 (IMPORTANT): persisted dose list retention

    @Test(
        """
        Fix item 3: the persisted dose list is pruned beyond doseRetentionHorizon (156h) on \
        decode-from-disk load (and, by the same shared write path, on save) — a 200h-old dose is \
        dropped from both the live arming decision and the on-disk blob; a 50h-old methadone dose \
        (inside the horizon, and inside its own 72h window) survives both
        """
    )
    func persistedDoseListPrunesBeyondRetentionHorizon() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let defaults = makeDefaults()

        let staleDoseTime = t0.addingTimeInterval(-200 * 3600)
        let freshDoseTime = t0.addingTimeInterval(-50 * 3600)
        // Hand-crafted PersistedCNSDose-shaped JSON (that private type isn't
        // visible from this file) — Foundation's default Date Codable
        // encodes as `timeIntervalSinceReferenceDate`, matching the
        // coordinator's plain `JSONEncoder()`/`JSONDecoder()` (no custom
        // date strategy).
        let rawJSON = """
        [
          {"timestamp": \(staleDoseTime.timeIntervalSinceReferenceDate), "drugClass": "benzodiazepine"},
          {"timestamp": \(freshDoseTime.timeIntervalSinceReferenceDate), "drugClass": "methadoneOrUnknownLongActing"}
        ]
        """
        defaults.set(Data(rawJSON.utf8), forKey: CNSMonitoringCoordinator.loggedDosesKey)

        let coordinator = makeCoordinator(
            context: context, now: { t0 }, poster: NotificationPosterSpy(), defaults: defaults
        )
        coordinator.handleLaunch()

        // Behavior: only the still-active methadone window arms monitoring
        // — the 200h-old benzo dose (long past its own 12h window) never
        // could have armed anything regardless of pruning.
        #expect(coordinator.isMonitoring, "the 50h-old methadone dose is still inside its own 72h window")
        #expect(
            coordinator.doseWindowExpiry
                == freshDoseTime.addingTimeInterval(CNSDepressantClass.methadoneOrUnknownLongActing.doseWindow)
        )

        // On-disk: load-time pruning rewrites the blob immediately — the
        // 200h-old dose must not survive on disk either, even though no
        // dose has been logged (no explicit save) since launch.
        struct DecodedDose: Decodable {
            let timestamp: Date
            let drugClass: String
        }
        let onDisk = try #require(defaults.data(forKey: CNSMonitoringCoordinator.loggedDosesKey))
        let decoded = try JSONDecoder().decode([DecodedDose].self, from: onDisk)
        #expect(
            !decoded.contains { $0.drugClass == "benzodiazepine" },
            "the 200h-old dose must be pruned from disk on load"
        )
        #expect(
            decoded.contains { $0.drugClass == "methadoneOrUnknownLongActing" },
            "the 50h-old methadone dose must survive"
        )
    }

    @Test(
        """
        doseRetentionHorizon covers the OVERLAP synergy leg (156h, not 108h): methadone@t0 + \
        benzo@t0+50h form a synergy window expiring t0+134h; a cold relaunch at t0+120h must \
        still retain the (120h-old) methadone dose, see the pair, and re-arm — a 108h horizon \
        would prune the methadone on load, dissolve the pair, and silently forgo the remaining \
        14h of mandated monitoring
        """
    )
    func overlapLegSynergyPairSurvivesRetentionPruneAcrossRelaunch() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let sharedDefaults = makeDefaults()
        let methadoneMed = makeMethadoneMedication(context: context)
        let benzoMed = makeBenzoMedication(context: context)
        var currentTime = t0

        let methadoneDose = MedicationDose(
            timestamp: t0, medicationName: methadoneMed.name, doseMg: 10, medication: methadoneMed
        )
        context.insert(methadoneDose)
        let benzoTime = t0.addingTimeInterval(50 * 3600)
        let benzoDose = MedicationDose(
            timestamp: benzoTime, medicationName: benzoMed.name, doseMg: 1, medication: benzoMed
        )
        context.insert(benzoDose)
        try context.save()

        // Coordinator A logs both doses at their real times (benzo lands 50h
        // into the methadone window — pairing via the OVERLAP leg only; the
        // 50h gap exceeds the 24h pairing horizon).
        let coordinatorA = makeCoordinator(
            context: context, now: { currentTime }, poster: NotificationPosterSpy(), defaults: sharedDefaults
        )
        coordinatorA.doseLogged(methadoneDose)
        currentTime = benzoTime
        coordinatorA.doseLogged(benzoDose)
        #expect(coordinatorA.doseWindowExpiry == benzoTime.addingTimeInterval(84 * 3600))

        // Cold relaunch at t0+120h: the methadone dose is 120h old — inside
        // the corrected 156h horizon, beyond the old (buggy) 108h one. Both
        // individual windows (t0+72h, t0+62h) are long expired; ONLY the
        // synergy pair (expiry t0+134h) can justify re-arming.
        let relaunchTime = t0.addingTimeInterval(120 * 3600)
        let coordinatorB = makeCoordinator(
            context: context, now: { relaunchTime }, poster: NotificationPosterSpy(), defaults: sharedDefaults
        )
        coordinatorB.handleLaunch()

        #expect(coordinatorB.isMonitoring, "the overlap-leg synergy window (t0+134h) is still active at t0+120h")
        #expect(coordinatorB.activeTriggers == [.doseWindow])
        #expect(coordinatorB.doseWindowExpiry == benzoTime.addingTimeInterval(84 * 3600))
    }

    // MARK: - Fix item 5 (IMPORTANT): stale (.appTerminated) session notification

    @Test("handleLaunch posts a notification when it finds ≥1 stale un-ended session")
    func handleLaunchPostsStaleSessionNotificationWhenFound() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let staleSession = MonitoringSession(
            startedAt: t0.addingTimeInterval(-3600), activationTriggers: ["manual"], companionPresent: true
        )
        context.insert(staleSession)
        try context.save()

        let poster = NotificationPosterSpy()
        let coordinator = makeCoordinator(context: context, now: { t0 }, poster: poster, defaults: makeDefaults())
        coordinator.handleLaunch()

        #expect(poster.posts.contains { $0.identifier == CNSMonitoringConstants.staleSessionNotificationID })
        let fetched = try #require(try context.fetch(FetchDescriptor<MonitoringSession>()).first)
        #expect(fetched.endReason == CNSMonitoringCoordinator.EndReason.appTerminated.rawValue)
    }

    @Test("handleLaunch posts nothing when there is no stale un-ended session")
    func handleLaunchPostsNothingWithoutStaleSession() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let poster = NotificationPosterSpy()
        let coordinator = makeCoordinator(context: context, now: { t0 }, poster: poster, defaults: makeDefaults())

        coordinator.handleLaunch()

        #expect(poster.posts.isEmpty)
    }

    // MARK: - Fix item 7a (MINOR): handleLaunch re-entry guard

    @Test(
        """
        Fix item 7a: handleLaunch() while monitoring is already active is a no-op — a re-fired \
        launch task cannot mark the live session .appTerminated
        """
    )
    func handleLaunchNoOpWhileMonitoring() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let coordinator = makeCoordinator(
            context: context, now: { t0 }, poster: NotificationPosterSpy(), defaults: makeDefaults()
        )
        coordinator.armManually(companionPresent: true)
        #expect(coordinator.isMonitoring)

        coordinator.handleLaunch()

        #expect(coordinator.isMonitoring)
        let session = try #require(try context.fetch(FetchDescriptor<MonitoringSession>()).first)
        #expect(session.endedAt == nil)
        #expect(session.endReason == nil)
    }

    // MARK: - Fix item 7b (MINOR): unknown persisted drugClass fails safe

    @Test(
        """
        Fix item 7b: a persisted dose whose drugClass rawValue is unrecognized (e.g. a future \
        class from a newer app version) maps to .methadoneOrUnknownLongActing and arms with its \
        72h window, rather than being silently dropped
        """
    )
    func unknownPersistedDoseClassFailsSafeToLongActingWindow() throws {
        let context = ModelContext(try TestHelpers.makeFullContainer())
        let defaults = makeDefaults()
        let rawJSON = """
        [{"timestamp": \(t0.timeIntervalSinceReferenceDate), "drugClass": "future_class"}]
        """
        defaults.set(Data(rawJSON.utf8), forKey: CNSMonitoringCoordinator.loggedDosesKey)

        let coordinator = makeCoordinator(
            context: context, now: { t0 }, poster: NotificationPosterSpy(), defaults: defaults
        )
        coordinator.handleLaunch()

        #expect(coordinator.isMonitoring)
        #expect(coordinator.activeTriggers == [.doseWindow])
        #expect(
            coordinator.doseWindowExpiry
                == t0.addingTimeInterval(CNSDepressantClass.methadoneOrUnknownLongActing.doseWindow)
        )
    }

    // MARK: - Constants sanity (every CNSMonitoringConstants member is referenced by a test)

    @Test("tickInterval is the coordinator's 1 Hz real-timer tick cadence")
    func tickIntervalValue() {
        #expect(abs(CNSMonitoringConstants.tickInterval - 1) < 0.001)
    }

    @Test("bufferTrimSlackSeconds pads gateWindowSeconds as the rolling sample buffer's own trim boundary")
    func bufferTrimSlackSecondsValue() {
        #expect(abs(CNSMonitoringConstants.bufferTrimSlackSeconds - 10) < 0.001)
    }
}
