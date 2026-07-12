import Foundation
import Observation
import SwiftData
import UserNotifications

/// Notification-posting seam (spec asymmetry rule: degradation/ending is
/// always disclosed, never silent). Production posts through
/// `UNUserNotificationCenter` (`UNUserNotificationCenterPoster`, same
/// plumbing as `DoseFollowUpManager`); tests inject a spy so contract 6 can
/// be asserted without touching the real notification center.
protocol CNSMonitoringNotificationPosting {
    func post(identifier: String, title: String, body: String)
}

/// Production `CNSMonitoringNotificationPosting`: an immediate local
/// notification (no trigger/delay — the interim "never a silent stop"
/// measure is posted the instant the coordinator detects the condition).
struct UNUserNotificationCenterPoster: CNSMonitoringNotificationPosting {
    func post(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// `Codable` mirror of `LoggedCNSDose` for `UserDefaults` persistence (the
/// `PendingFollowUp`/`DoseFollowUpManager` precedent) — kept separate so the
/// persisted shape never has to change when the pure `DoseWindowGate`-facing
/// type does (same rationale as `CNSContributionRecord` mirroring
/// `CNSSignalAssessment`).
private struct PersistedCNSDose: Codable, Equatable {
    let timestamp: Date
    let drugClass: String

    init(_ dose: LoggedCNSDose) {
        self.timestamp = dose.timestamp
        self.drugClass = dose.drugClass.rawValue
    }

    var asLoggedCNSDose: LoggedCNSDose? {
        CNSDepressantClass(rawValue: drugClass).map { LoggedCNSDose(timestamp: timestamp, drugClass: $0) }
    }
}

/// App-scoped coordinator that owns the CNS-depression monitor's lifecycle
/// (spec §6/§14.1/§14.3/§7): arm/disarm, the 1 Hz tick loop that drives
/// `CNSDetectionPipeline`, `MonitoringSession`/`CNSRiskSampleRecord`
/// persistence, dose-window activation (`DoseWindowGate`), and per-device
/// fallback classification (`CNSDeviceStateMatrix`). Composes every unit
/// Tasks 1-5 delivered; this file adds no new detection logic.
///
/// TESTABILITY SEAM: the designated init takes `modelContext`, an injected
/// clock (`now`), sample-provider closures (latest EMAY reading / Polar HR /
/// Polar RMSSD), a notification-poster protocol, and `enableTickLoop` — with
/// `enableTickLoop: false` the coordinator never starts the real `Task`-based
/// timer, and tests drive the detection loop by calling `tick(at:)` directly
/// once per simulated second (mirrors `CNSDetectionPipelineTests.replay`),
/// with zero BLE and zero wall-clock dependency. The production convenience
/// init wires the real `EMAYRealtimeService`/`PolarHRMService` observation
/// reads and `UNUserNotificationCenter`.
@MainActor
@Observable
final class CNSMonitoringCoordinator {

    enum ActivationTrigger: String, Sendable {
        case manual
        case doseWindow
        case adHoc
    }

    /// Raw value persisted to `MonitoringSession.endReason`.
    enum EndReason: String, Sendable {
        case manual
        case windowExpired
        case deviceLoss
        case appTerminated
    }

    // MARK: - Observable state (public surface)

    private(set) var isMonitoring: Bool = false
    private(set) var activeTriggers: Set<ActivationTrigger> = []
    private(set) var companionPresent: Bool = false
    private(set) var currentTier: CNSAlertTier = .clear
    private(set) var canAssess: Bool = false
    private(set) var reportingSources: Set<CNSSignalSource> = []
    private(set) var statusLine: String = "Not monitoring"
    /// §14.1 dose-window expiry while `.doseWindow` is an active trigger —
    /// Task 7's UI countdown reads this. `nil` whenever `.doseWindow` is not
    /// currently in `activeTriggers` (not monitoring at all, or monitoring
    /// for another reason only). Escalation note: Task 6 exposed no expiry
    /// accessor, so this is the minimal seam Task 7 added rather than
    /// reworking Task 6 — recomputed every tick (and immediately on
    /// `doseLogged`/`handleLaunch`) alongside `evaluateDoseWindowExpiry` so
    /// it reflects a later dose's extension without waiting on the UI.
    private(set) var doseWindowExpiry: Date?

    // MARK: - Injected dependencies

    private let modelContext: ModelContext
    private let now: () -> Date
    private let latestEMAYReading: () -> EMAYReading?
    private let latestPolarHR: () -> Int?
    private let latestPolarRMSSD: () -> Double?
    private let notificationPoster: CNSMonitoringNotificationPosting
    private let defaults: UserDefaults
    /// `false` in tests: suppresses the real `Task`-based tick loop so tests
    /// drive `tick(at:)` manually with zero wall-clock dependency.
    private let enableTickLoop: Bool
    /// Fired once per new session (every trigger kind — EMAY is the only
    /// primary-capable source regardless of what armed monitoring) so the
    /// EMAY oximeter session is already starting by the time the tick loop
    /// first polls `latestEMAYReading`. Production wires
    /// `emayService.start()`, which is idempotent/no-op while a session is
    /// already active and never touches the user's continuous-mode toggle
    /// (`setContinuousMode`/`stop()` are separate, explicit calls) — so this
    /// hook can never fight that setting. Tests default to a no-op.
    private let emayStartHook: () -> Void

    // MARK: - Session-scoped state (reset in `startNewSession`/`endSession`)

    private var pipeline: CNSDetectionPipeline?
    private var session: MonitoringSession?
    private var sampleBuffer: [CNSSignalSample] = []
    private var baselines: CNSBaselines = .none
    private var lastPersistAt: Date?
    private var previousObservedTier: CNSAlertTier = .clear
    private var lastSampleBySource: [CNSSignalSource: Date] = [:]
    private var wasEverReportingBySource: [CNSSignalSource: Bool] = [:]
    private var previousDeviceStateBySource: [CNSSignalSource: CNSDeviceState] = [:]
    /// Sources already notified `.degradeDisclosed` this session — posts once
    /// per session per source (contract 6).
    private var degradedNotifiedSources: Set<CNSSignalSource> = []
    /// Sources currently disclosed-degraded, surfaced on `statusLine`.
    private var disclosedDegradedSources: Set<CNSSignalSource> = []
    private var tickTask: Task<Void, Never>?
    /// In-memory cache of the persisted `[LoggedCNSDose]` list, so
    /// `evaluateDoseWindowExpiry` (called every 1 Hz tick, potentially for a
    /// 72h+ methadone window) doesn't JSON-decode from `UserDefaults` per
    /// second. `nil` = not yet loaded; populated lazily by
    /// `loadPersistedDoses`, kept coherent by `savePersistedDoses` (the ONLY
    /// write path), and explicitly invalidated by `handleLaunch()` in case an
    /// earlier coordinator instance wrote to the same suite (relaunch
    /// simulation in tests; defensive in production, where there is one
    /// instance).
    private var cachedDoses: [LoggedCNSDose]?

    private static let loggedDosesKey = "cns.monitoring.loggedDoses"

    // MARK: - Init

    /// Designated init — the testability seam described in the class doc
    /// comment. `now` is the injected clock every internal computation reads
    /// (never `Date()`/`Date.now` directly); tests supply a closure over a
    /// local mutable variable and step it between `tick(at:)` calls.
    init(
        modelContext: ModelContext,
        now: @escaping () -> Date = Date.init,
        latestEMAYReading: @escaping () -> EMAYReading?,
        latestPolarHR: @escaping () -> Int?,
        latestPolarRMSSD: @escaping () -> Double?,
        notificationPoster: CNSMonitoringNotificationPosting,
        defaults: UserDefaults = .standard,
        enableTickLoop: Bool = true,
        emayStartHook: @escaping () -> Void = {}
    ) {
        self.modelContext = modelContext
        self.now = now
        self.latestEMAYReading = latestEMAYReading
        self.latestPolarHR = latestPolarHR
        self.latestPolarRMSSD = latestPolarRMSSD
        self.notificationPoster = notificationPoster
        self.defaults = defaults
        self.enableTickLoop = enableTickLoop
        self.emayStartHook = emayStartHook
    }

    /// Production convenience init: wires the real `EMAYRealtimeService` /
    /// `PolarHRMService` observation reads and `UNUserNotificationCenter`.
    /// `emayService`/`polarService` are captured weakly by the provider
    /// closures — this coordinator does not need to keep either service
    /// alive (the app already owns them at app scope).
    ///
    /// Additionally wires `polarService.onLiveSample` — a tap Task 4 added
    /// specifically for this coordinator — to keep Polar liveness tracking
    /// (`CNSDeviceStateMatrix` staleness detection, contract 6) responsive
    /// independent of the 1 Hz tick cadence, rather than only learning a
    /// packet arrived the next time the tick loop happens to poll
    /// `latestPolarHR()`. The closure captures `self` WEAKLY: `polarService`
    /// is a long-lived, strongly-held app-scoped service, so a strong capture
    /// here would keep this coordinator alive for the app's entire lifetime
    /// even if it were ever replaced (handoff note from the Task 4 review).
    convenience init(
        modelContext: ModelContext,
        emayService: EMAYRealtimeService,
        polarService: PolarHRMService
    ) {
        self.init(
            modelContext: modelContext,
            latestEMAYReading: { [weak emayService] in emayService?.latestReading },
            latestPolarHR: { [weak polarService] in polarService?.state.currentHR },
            latestPolarRMSSD: { [weak polarService] in polarService?.state.lastMinuteRMSSD },
            notificationPoster: UNUserNotificationCenterPoster(),
            emayStartHook: { [weak emayService] in emayService?.start() }
        )
        polarService.onLiveSample = { [weak self] _, timestamp in
            self?.noteLivePolarSample(at: timestamp)
        }
    }

    // MARK: - Public control surface

    func armManually(companionPresent: Bool) {
        let now = self.now()
        if isMonitoring {
            activeTriggers.insert(.manual)
            applyCompanionPresent(companionPresent, at: now)
        } else {
            activeTriggers = [.manual]
            startNewSession(companionPresent: companionPresent, at: now)
        }
        updateStatusLine()
    }

    func armAdHoc() {
        let now = self.now()
        if isMonitoring {
            activeTriggers.insert(.adHoc)
        } else {
            activeTriggers = [.adHoc]
            startNewSession(companionPresent: false, at: now)
        }
        updateStatusLine()
    }

    /// Manual disarm always wins, regardless of what else is in
    /// `activeTriggers` — the user's explicit "stop" overrides an active
    /// dose window or ad-hoc trigger. Ends the session with `.manual`.
    func disarm() {
        guard isMonitoring else { return }
        endSession(reason: .manual, at: now())
    }

    /// Re-mark companion presence mid-session (spec §6). Threads to the
    /// pipeline's state-preserving setter — never rebuilds the pipeline —
    /// and appends a `CompanionLogEntry` to the session.
    func setCompanionPresent(_ present: Bool) {
        applyCompanionPresent(present, at: now())
    }

    /// Called from both dose-log sites (`MedicationsHubView.logDose`'s
    /// direct-insert path and `DoseAnxietyPromptView`'s prompt-confirm path)
    /// immediately after a `MedicationDose` is inserted. Classifies the dose,
    /// persists it to the `[LoggedCNSDose]` UserDefaults list (so a relaunch
    /// can re-arm via `handleLaunch()`), and arms with `.doseWindow` when
    /// `DoseWindowGate` reports an active window. Never removes an active
    /// `.manual`/`.adHoc` trigger — window EXPIRY (the inverse transition) is
    /// evaluated per-tick in `evaluateDoseWindowExpiry`, not here.
    func doseLogged(_ dose: MedicationDose) {
        guard let drugClass = classify(dose) else { return }
        let now = self.now()

        var doses = loadPersistedDoses()
        doses.append(LoggedCNSDose(timestamp: dose.timestamp, drugClass: drugClass))
        savePersistedDoses(doses)

        guard refreshDoseWindowExpiry(doses: doses, at: now) != nil else { return }
        if isMonitoring {
            activeTriggers.insert(.doseWindow)
        } else {
            activeTriggers = [.doseWindow]
            startNewSession(companionPresent: false, at: now)
        }
        updateStatusLine()
    }

    /// App-launch hook (called once from `AnxietyWatchApp`'s launch task).
    /// First marks any `MonitoringSession` left un-ended by a force-quit/
    /// crash as `.appTerminated` (a freshly-constructed coordinator can never
    /// itself be mid-session yet, so this only fixes up persisted rows), then
    /// re-evaluates the persisted dose list: if a window is still active,
    /// re-arms with `.doseWindow` — the "relaunch re-arms" half of contract 4.
    func handleLaunch() {
        let now = self.now()
        markStaleUnendedSessions(at: now)
        guard !isMonitoring else { return }
        // Invalidate the dose cache before reading: launch is the one point
        // where the UserDefaults store may have been written by a previous
        // coordinator instance (previous process; a second instance in the
        // relaunch-simulation tests), so the persisted list is authoritative
        // here.
        cachedDoses = nil
        let doses = loadPersistedDoses()
        guard refreshDoseWindowExpiry(doses: doses, at: now) != nil else { return }
        activeTriggers = [.doseWindow]
        startNewSession(companionPresent: false, at: now)
    }

    // MARK: - Tick

    /// Drives one iteration of the monitoring loop at `now`. Not part of the
    /// class's headline public surface, but intentionally not `private`:
    /// production drives it from a real `Task`-based loop (see
    /// `startTickLoopIfNeeded`); tests call it directly, once per simulated
    /// second, with a controllable `now` — mirroring how
    /// `CNSDetectionPipelineTests.replay` drives `pipeline.process`.
    func tick(at now: Date) {
        // Contract 5: dose-window expiry is independent of manual/adHoc
        // triggers and can end the session outright if it was the only one.
        evaluateDoseWindowExpiry(at: now)
        guard isMonitoring, var pipeline, let session else { return }

        let newSamples = collectSamples(at: now)
        updateDeviceStates(newSamples: newSamples, at: now)
        // A device-loss transition may have just ended the session.
        guard isMonitoring, self.session != nil else { return }

        sampleBuffer.append(contentsOf: newSamples)
        let trimBefore = now.addingTimeInterval(
            -(CNSThresholds.standard.gateWindowSeconds + CNSMonitoringConstants.bufferTrimSlackSeconds)
        )
        sampleBuffer.removeAll { $0.timestamp < trimBefore }

        let (assessment, tier) = pipeline.process(samples: sampleBuffer, baselines: baselines, at: now)
        self.pipeline = pipeline
        currentTier = tier
        canAssess = pipeline.canAssess
        reportingSources = Set(CNSSignalSource.allCases.filter { source in
            CNSDeviceStateMatrix.state(
                lastSample: lastSampleBySource[source], sessionStart: session.startedAt, now: now,
                wasEverReporting: wasEverReportingBySource[source] ?? false
            ) == .reporting
        })

        persistIfDue(assessment: assessment, tier: tier, at: now, into: session)

        updateStatusLine()
    }

    // MARK: - Tick internals

    private func collectSamples(at now: Date) -> [CNSSignalSample] {
        var samples: [CNSSignalSample] = []
        if let reading = latestEMAYReading() {
            samples.append(contentsOf: CNSSensorAdapters.samples(from: reading))
        }
        samples.append(contentsOf: CNSSensorAdapters.samples(polarHR: latestPolarHR(), at: now))
        samples.append(contentsOf: CNSSensorAdapters.samples(polarRMSSD: latestPolarRMSSD(), at: now))
        return samples
    }

    /// Contract 6: derives each source's `CNSDeviceState`; on a TRANSITION
    /// into `.diedMidSession`/`.idle`, classifies via the matrix and acts.
    /// `isOnlyPrimarySource` is fixed per-source (only EMAY is primary-
    /// capable — the strengthened `CNSDeviceStateMatrix` contract, Task 5
    /// review): `isOnlyPrimarySource = (source == .emayOximeter)`, regardless
    /// of what else happens to be present.
    private func updateDeviceStates(newSamples: [CNSSignalSample], at now: Date) {
        guard let session else { return }
        for source in CNSSignalSource.allCases {
            if newSamples.contains(where: { $0.source == source }) {
                lastSampleBySource[source] = now
                wasEverReportingBySource[source] = true
            }
            let state = CNSDeviceStateMatrix.state(
                lastSample: lastSampleBySource[source], sessionStart: session.startedAt, now: now,
                wasEverReporting: wasEverReportingBySource[source] ?? false
            )
            let previous = previousDeviceStateBySource[source]
            previousDeviceStateBySource[source] = state
            guard previous != state, state == .diedMidSession || state == .idle else { continue }

            let isOnlyPrimarySource = (source == .emayOximeter)
            let classification = CNSDeviceStateMatrix.classify(
                source: source, state: state, isOnlyPrimarySource: isOnlyPrimarySource
            )
            switch classification {
            case .ignorable:
                break
            case .degradeDisclosed:
                disclosedDegradedSources.insert(source)
                if degradedNotifiedSources.insert(source).inserted {
                    notificationPoster.post(
                        identifier: CNSMonitoringConstants.degradedNotificationID,
                        title: "CNS Monitoring Degraded",
                        body: "\(sourceLabel(source)) stopped reporting. Monitoring continues in a degraded state."
                    )
                }
            case .endMonitoring:
                // The specific device/fallback action isn't a MonitoringSession
                // field (schema frozen at Task 3) — endReason == .deviceLoss
                // IS the persisted record of what happened; Phase 3's alerting
                // engine looks up the per-device CNSDeviceFallbackConfig
                // action separately (it's UserDefaults-persisted, not
                // per-session) when it renders/acts on ended sessions.
                notificationPoster.post(
                    identifier: CNSMonitoringConstants.endedNotificationID,
                    title: "CNS Monitoring Ended",
                    body: "\(sourceLabel(source)) stopped reporting and no other primary sensor is "
                        + "active. Monitoring has ended."
                )
                endSession(reason: .deviceLoss, at: now)
                return
            }
        }
    }

    /// Keeps Polar liveness tracking responsive between ticks (see the
    /// production convenience init's doc comment). Deliberately does NOT
    /// touch the sample buffer/pipeline — sample collection stays uniform
    /// and tick-polled (contract 1) via `latestPolarHR()`/`latestPolarRMSSD()`
    /// so production never double-counts a reading.
    private func noteLivePolarSample(at timestamp: Date) {
        guard isMonitoring else { return }
        lastSampleBySource[.polarH10] = timestamp
        wasEverReportingBySource[.polarH10] = true
    }

    /// Contract 2 (10s cadence) + contract 3 (immediate write on any tier
    /// increase, so a fast escalation isn't only captured at the next 10s
    /// boundary). One `insertSample` call per tick when either condition
    /// holds — never two in the same tick — so a coincidental cadence/edge
    /// overlap doesn't double-write the same instant.
    ///
    /// Pruning rides the SAME 10s cadence (the `persistDue` branch only, NOT
    /// tier-increase writes): `MonitoringSessionStore.prune` fetches the whole
    /// `CNSRiskSampleRecord` table, so running it on the 1 Hz tick would cost
    /// a full-table fetch every second, all night, to delete rows that only
    /// ever age past retention seconds apart. An off-cadence tier-edge write
    /// doesn't need its own prune — the next cadence boundary is ≤ 10s away.
    private func persistIfDue(
        assessment: CNSRiskAssessment, tier: CNSAlertTier, at now: Date, into session: MonitoringSession
    ) {
        let tierIncreased = tier > previousObservedTier
        let persistDue = lastPersistAt.map {
            now.timeIntervalSince($0) >= CNSMonitoringConstants.samplePersistInterval
        } ?? true

        if persistDue || tierIncreased {
            let riskScore: Double?
            let contributions: [CNSContributionRecord]
            switch assessment {
            case .insufficientData:
                riskScore = nil
                contributions = []
            case .assessed(let score, let assessmentContributions):
                riskScore = score
                contributions = assessmentContributions.map(CNSContributionRecord.init(assessment:))
            }
            MonitoringSessionStore.insertSample(
                timestamp: now, riskScore: riskScore, tier: tier, canAssess: canAssess,
                contributions: contributions, into: session, context: modelContext
            )
            try? modelContext.save()
            lastPersistAt = now
        }
        if persistDue {
            try? MonitoringSessionStore.prune(
                before: now.addingTimeInterval(-CNSMonitoringConstants.sampleRetention),
                now: now, in: modelContext
            )
        }
        // Architecture seam for Phase 3: tier-edge is the hook point for
        // klaxon/haptic escalation and alone-mode fast-escalation UI (spec
        // §5.3/§14.4) — Phase 2 only persists the edge; it triggers no
        // alerting itself.
        previousObservedTier = tier
    }

    private func evaluateDoseWindowExpiry(at now: Date) {
        guard activeTriggers.contains(.doseWindow) else { return }
        let doses = loadPersistedDoses()
        guard refreshDoseWindowExpiry(doses: doses, at: now) == nil else { return }
        activeTriggers.remove(.doseWindow)
        if activeTriggers.isEmpty {
            endSession(reason: .windowExpired, at: now)
        }
    }

    /// Recomputes the active dose window over the full persisted-dose list
    /// and mirrors its expiry onto `doseWindowExpiry` (nil when no window is
    /// active) — the one place `doseLogged`, `handleLaunch`, and
    /// `evaluateDoseWindowExpiry` all update the UI-facing countdown, so the
    /// three call sites can't drift from each other or from the gate's own
    /// verdict.
    @discardableResult
    private func refreshDoseWindowExpiry(doses: [LoggedCNSDose], at now: Date) -> DoseWindowGate.Window? {
        let window = DoseWindowGate.activeWindow(doses: doses, at: now)
        doseWindowExpiry = window?.expiry
        return window
    }

    // MARK: - Session lifecycle

    private func startNewSession(companionPresent: Bool, at now: Date) {
        self.companionPresent = companionPresent
        isMonitoring = true
        pipeline = CNSDetectionPipeline(thresholds: .standard, companionPresent: companionPresent)
        baselines = loadBaselines()
        sampleBuffer = []
        lastPersistAt = nil
        previousObservedTier = .clear
        currentTier = .clear
        canAssess = false
        reportingSources = []
        lastSampleBySource = [:]
        wasEverReportingBySource = [:]
        previousDeviceStateBySource = [:]
        degradedNotifiedSources = []
        disclosedDegradedSources = []

        let newSession = MonitoringSession(
            startedAt: now,
            activationTriggers: activeTriggers.map(\.rawValue).sorted(),
            companionPresent: companionPresent
        )
        modelContext.insert(newSession)
        try? modelContext.save()
        session = newSession

        // EMAY is the only primary-capable (continuous SpO2) source
        // regardless of which trigger armed monitoring — start it
        // alongside every new session, not just manual arms, so the tick
        // loop's first poll has a session to read from. Idempotent/no-op
        // if a session (incl. the user's own continuous-mode session) is
        // already active; see the property's doc comment for why this can
        // never fight `setContinuousMode`.
        emayStartHook()

        startTickLoopIfNeeded()
        updateStatusLine()
    }

    private func endSession(reason: EndReason, at now: Date) {
        session?.endedAt = now
        session?.endReason = reason.rawValue
        try? modelContext.save()

        stopTickLoop()
        session = nil
        pipeline = nil
        isMonitoring = false
        activeTriggers = []
        currentTier = .clear
        canAssess = false
        reportingSources = []
        lastSampleBySource = [:]
        wasEverReportingBySource = [:]
        previousDeviceStateBySource = [:]
        degradedNotifiedSources = []
        disclosedDegradedSources = []
        doseWindowExpiry = nil
        updateStatusLine()
    }

    private func applyCompanionPresent(_ present: Bool, at now: Date) {
        companionPresent = present
        pipeline?.setCompanionPresent(present)
        if let session {
            session.companionPresent = present
            var log = session.companionLog
            log.append(CompanionLogEntry(timestamp: now, present: present))
            session.companionLog = log
            try? modelContext.save()
        }
    }

    private func markStaleUnendedSessions(at now: Date) {
        let descriptor = FetchDescriptor<MonitoringSession>(predicate: #Predicate { $0.endedAt == nil })
        guard let staleSessions = try? modelContext.fetch(descriptor), !staleSessions.isEmpty else { return }
        for stale in staleSessions {
            stale.endedAt = now
            stale.endReason = EndReason.appTerminated.rawValue
        }
        try? modelContext.save()
    }

    // MARK: - Production tick loop

    private func startTickLoopIfNeeded() {
        guard enableTickLoop, tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = Int(CNSMonitoringConstants.tickInterval.rounded())
                try? await Task.sleep(for: .seconds(max(interval, 1)))
                if Task.isCancelled { return }
                guard let self, self.isMonitoring else { return }
                self.tick(at: self.now())
            }
        }
    }

    private func stopTickLoop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Baselines

    /// Loaded once per session (not per tick) from the most recent
    /// `HealthSnapshot`. Nil-safe: an absent snapshot, or any absent field
    /// on it, yields `nil` on the corresponding `CNSBaselines` field —
    /// `CNSThresholds`/`CNSSeverityScorer` already treat a nil baseline as
    /// "use the conservative population default," never a crash.
    private func loadBaselines() -> CNSBaselines {
        var descriptor = FetchDescriptor<HealthSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let snapshot = try? modelContext.fetch(descriptor).first else { return .none }
        return CNSBaselines(
            spo2Nadir: snapshot.spo2NadirOvernight,
            restingHeartRate: snapshot.restingHR,
            hrvMean: snapshot.hrvAvg,
            respiratoryRateMean: snapshot.respiratoryRate
        )
    }

    // MARK: - Dose classification + persistence

    private func classify(_ dose: MedicationDose) -> CNSDepressantClass? {
        if let raw = dose.medication?.cnsDepressantClass, let stored = CNSDepressantClass(rawValue: raw) {
            return stored
        }
        return CNSDepressantClassifier.classify(
            name: dose.medicationName, category: dose.medication?.category ?? ""
        )
    }

    /// Returns the in-memory cache when populated; decodes from
    /// `UserDefaults` only on the first read after init (or after
    /// `handleLaunch()` invalidates the cache). `savePersistedDoses` is the
    /// only write path and updates the cache in the same call, so cache and
    /// store cannot diverge within one coordinator instance.
    private func loadPersistedDoses() -> [LoggedCNSDose] {
        if let cachedDoses { return cachedDoses }
        let doses: [LoggedCNSDose]
        if let data = defaults.data(forKey: Self.loggedDosesKey),
           let decoded = try? JSONDecoder().decode([PersistedCNSDose].self, from: data) {
            doses = decoded.compactMap(\.asLoggedCNSDose)
        } else {
            doses = []
        }
        cachedDoses = doses
        return doses
    }

    private func savePersistedDoses(_ doses: [LoggedCNSDose]) {
        // Cache first: even if encoding fails (never expected for these
        // plain Codable values), in-memory state should reflect what the
        // caller logged — under-persisting must not become under-monitoring
        // within the live instance.
        cachedDoses = doses
        guard let data = try? JSONEncoder().encode(doses.map(PersistedCNSDose.init)) else { return }
        defaults.set(data, forKey: Self.loggedDosesKey)
    }

    // MARK: - Status line

    private func updateStatusLine() {
        guard isMonitoring else {
            statusLine = "Not monitoring"
            return
        }
        // Contract 7 (decision 5's minimum-bar guardrail): armed without the
        // only primary-capable source reporting states the requirement
        // verbatim-ish, regardless of what else is reporting.
        guard reportingSources.contains(.emayOximeter) else {
            statusLine = "Connect the EMAY oximeter for danger-relevant monitoring — currently can't assess"
            return
        }
        if !disclosedDegradedSources.isEmpty {
            let names = disclosedDegradedSources.map(sourceLabel).sorted().joined(separator: ", ")
            statusLine = "Monitoring degraded (\(names) not reporting) — tier: \(tierLabel(currentTier))"
            return
        }
        statusLine = canAssess
            ? "Monitoring — tier: \(tierLabel(currentTier))"
            : "Monitoring — can't assess (insufficient data)"
    }

    private func sourceLabel(_ source: CNSSignalSource) -> String {
        switch source {
        case .emayOximeter: return "EMAY oximeter"
        case .polarH10: return "Polar H10"
        case .appleWatch: return "Apple Watch"
        }
    }

    private func tierLabel(_ tier: CNSAlertTier) -> String {
        switch tier {
        case .clear: return "clear"
        case .watch: return "watch"
        case .confirm: return "confirm"
        case .klaxon: return "klaxon"
        }
    }
}
