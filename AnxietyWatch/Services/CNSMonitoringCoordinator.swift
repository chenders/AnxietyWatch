import Foundation
import Observation
import SwiftData
import UserNotifications

/// Notification-posting seam (spec asymmetry rule: degradation/ending is
/// always disclosed, never silent). Production posts through
/// `UNUserNotificationCenter` (`UNUserNotificationCenterPoster`, same
/// plumbing as `DoseFollowUpManager`); tests inject a spy so contract 6 can
/// be asserted without touching the real notification center.
///
/// `schedule(identifier:title:body:at:)`/`cancel(identifier:)` (fix item 1)
/// are the dead-man's-switch primitive: a DEFERRED local notification that
/// fires unless cancelled or re-scheduled (same `identifier`) first —
/// distinct from `post`, which fires immediately. Production replaces the
/// pending request under the same identifier every time (`UNUserNotificationCenter.add`
/// with a matching identifier replaces rather than stacks).
protocol CNSMonitoringNotificationPosting {
    func post(identifier: String, title: String, body: String)
    func schedule(identifier: String, title: String, body: String, at fireDate: Date)
    func cancel(identifier: String)
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

    /// Schedules (replacing any pending request under `identifier`) a local
    /// notification to fire at `fireDate` via `UNTimeIntervalNotificationTrigger`
    /// — the dead-man's-switch primitive (fix item 1). `fireDate` is an
    /// absolute time (not a raw interval) so the coordinator's injected
    /// clock (`now`) governs when the deadline lands in tests; production
    /// converts to the relative interval `UNTimeIntervalNotificationTrigger`
    /// needs via `timeIntervalSinceNow` (real wall-clock time — this poster
    /// has no injected clock of its own). Floored at 1s: `UNTimeIntervalNotificationTrigger`
    /// requires a positive interval.
    func schedule(identifier: String, title: String, body: String, at fireDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let interval = max(fireDate.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancel(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
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

    /// Fix item 7b: an unrecognized `rawValue` (a future class value written
    /// by a newer app version, or corrupt data) maps to
    /// `.methadoneOrUnknownLongActing` — the 72h fail-safe window — rather
    /// than dropping the dose entirely (the previous `compactMap`-via-`nil`
    /// behavior). Silently forgetting a logged CNS-depressant dose is the
    /// less-monitoring direction; §14.1's own "unknown = long-acting" fail-
    /// safe principle (used identically by `CNSDepressantClassifier` for an
    /// unrecognized opioid formulation) applies the same way here. Always
    /// succeeds — no longer optional.
    var asLoggedCNSDose: LoggedCNSDose {
        let resolvedClass = CNSDepressantClass(rawValue: drugClass) ?? .methadoneOrUnknownLongActing
        return LoggedCNSDose(timestamp: timestamp, drugClass: resolvedClass)
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
    private let latestAS11State: () -> AS11StreamState
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
    /// Fired once per `endSession` call (every end reason) so the EMAY
    /// oximeter session started alongside this one (`emayStartHook`) doesn't
    /// outlive it and keep scanning/heartbeating in the background. The
    /// coordinator stays deliberately ignorant of the continuous-streaming
    /// toggle — the production closure (see the convenience init) mirrors
    /// `EMAYLiveView`'s "stop on disappear ONLY if `!continuousModeEnabled`"
    /// rule itself, exactly the same way `emayStartHook` never touches that
    /// toggle. Optional/`nil` default: tests that don't care about EMAY
    /// teardown (most of them) never have to supply one.
    private let emayStopHook: (() -> Void)?

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
    /// Fix item 2: the arrival time of the most recent GENUINE Polar HR
    /// packet, as reported by `noteLivePolarSample` (production: the
    /// `polarService.onLiveSample` tap, which fires once per real BLE
    /// packet — never from tick-polling `latestPolarHR()`). `nil` until the
    /// first arrival this session.
    private var lastPolarHRArrivalTime: Date?
    /// The arrival time already turned into a `CNSSignalSample` this
    /// session — `collectPolarHRSample` only emits when
    /// `lastPolarHRArrivalTime` is newer than this, so a cached-but-stale
    /// `latestPolarHR()` value (the ~10 min post-death reconnect-grace
    /// window `PolarHRMService` keeps `state.currentHR` populated for) is
    /// never re-emitted as if it just arrived.
    private var lastEmittedPolarHRArrivalTime: Date?
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

    /// `internal` (not `private`) so `CNSMonitoringCoordinatorTests` can
    /// write a hand-crafted `PersistedCNSDose`-shaped blob directly (e.g. an
    /// unrecognized `drugClass` rawValue, fix 7b's test) without needing
    /// access to the file-private `PersistedCNSDose` type itself.
    static let loggedDosesKey = "cns.monitoring.loggedDoses"

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
        latestAS11State: @escaping () -> AS11StreamState = { .streamingOK },
        notificationPoster: CNSMonitoringNotificationPosting,
        defaults: UserDefaults = .standard,
        enableTickLoop: Bool = true,
        emayStartHook: @escaping () -> Void = {},
        emayStopHook: (() -> Void)? = nil
    ) {
        self.modelContext = modelContext
        self.now = now
        self.latestEMAYReading = latestEMAYReading
        self.latestPolarHR = latestPolarHR
        self.latestPolarRMSSD = latestPolarRMSSD
        self.latestAS11State = latestAS11State
        self.notificationPoster = notificationPoster
        self.defaults = defaults
        self.enableTickLoop = enableTickLoop
        self.emayStartHook = emayStartHook
        self.emayStopHook = emayStopHook
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
            emayStartHook: { [weak emayService] in emayService?.start() },
            emayStopHook: { [weak emayService] in
                // Mirrors EMAYLiveView's "stop on disappear ONLY if
                // !continuousModeEnabled" rule (EMAYLiveView.swift:75-80):
                // never fight the user's continuous-streaming toggle — with
                // it on, the EMAY session outlives CNS monitoring by design.
                guard let emayService, !emayService.continuousModeEnabled else { return }
                emayService.stop()
            }
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

    /// Honors the current `companionPresent` marking (spec §6): the user's
    /// explicit "someone is here" toggle is not uncertain, so §14.4's
    /// default-to-alone rule doesn't apply — a pre-arm companion marking
    /// carries into the session instead of silently snapping back to alone.
    func armAdHoc() {
        let now = self.now()
        if isMonitoring {
            activeTriggers.insert(.adHoc)
        } else {
            activeTriggers = [.adHoc]
            startNewSession(companionPresent: companionPresent, at: now)
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

        var doses = loadPersistedDoses(at: now)
        doses.append(LoggedCNSDose(timestamp: dose.timestamp, drugClass: drugClass))
        savePersistedDoses(doses, at: now)

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
    ///
    /// Fix item 7a: `!isMonitoring` is now the FIRST thing checked (a
    /// no-op — not even `markStaleUnendedSessions` runs — while monitoring
    /// is active), not just a later guard on the re-arm half. SwiftUI's
    /// `.task` modifier can, under some view-identity churn, re-fire while
    /// this same coordinator instance is already mid-session; without this
    /// guard at the top, `markStaleUnendedSessions`'s "every un-ended
    /// session" query would sweep up the CURRENTLY ACTIVE session (its
    /// `endedAt` is nil precisely because it's still live) and stamp it
    /// `.appTerminated` in the persisted store while the in-memory
    /// coordinator carries on believing it's still monitoring — a silent
    /// divergence between persisted and live state.
    func handleLaunch() {
        guard !isMonitoring else { return }
        let now = self.now()
        markStaleUnendedSessions(at: now)
        // Invalidate the dose cache before reading: launch is the one point
        // where the UserDefaults store may have been written by a previous
        // coordinator instance (previous process; a second instance in the
        // relaunch-simulation tests), so the persisted list is authoritative
        // here.
        cachedDoses = nil
        let doses = loadPersistedDoses(at: now)
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

        let (assessment, tier) = pipeline.process(
            samples: sampleBuffer, 
            baselines: baselines, 
            as11State: latestAS11State(), 
            at: now
        )
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
        samples.append(contentsOf: collectPolarHRSample())
        samples.append(contentsOf: collectPolarRMSSDSample(at: now))
        return samples
    }

    /// Fix item 2 (IMPORTANT — Polar liveness from packet arrival, not cached
    /// values): emits a Polar HR sample ONLY when a genuine new packet
    /// arrival occurred since the last emission. `PolarHRMService.state.currentHR`
    /// stays populated for its ~10-min reconnect grace after the strap dies
    /// mid-session, so polling `latestPolarHR()` every tick and stamping the
    /// sample `at: now` (the OLD behavior) would read a frozen cached value
    /// as perpetually fresh — `lastSampleBySource[.polarH10]` would never go
    /// stale, and `reportingSources`/the §7 device-state matrix would keep
    /// lying that Polar is still reporting. `lastPolarHRArrivalTime` only
    /// ever advances via `noteLivePolarSample`, which production wires to
    /// `PolarHRMService.onLiveSample` — a tap that fires exactly once per
    /// REAL BLE packet, independent of tick cadence. The emitted sample's
    /// timestamp is the genuine arrival time, not `now`, so downstream
    /// staleness detection (`CNSDeviceStateMatrix.state`) reflects when data
    /// actually arrived, not when the tick loop happened to run.
    private func collectPolarHRSample() -> [CNSSignalSample] {
        guard let arrival = lastPolarHRArrivalTime, arrival != lastEmittedPolarHRArrivalTime,
              let hr = latestPolarHR() else { return [] }
        lastEmittedPolarHRArrivalTime = arrival
        return CNSSensorAdapters.samples(polarHR: hr, at: arrival)
    }

    /// Fix item 2, RMSSD leg — BOUNDED SAMPLE-AND-HOLD. `PolarHRMService`
    /// exposes no packet-arrival timestamp for its per-minute RMSSD mean
    /// (`onLiveSample` taps HR arrivals only), and the per-minute value is
    /// genuinely a 60s aggregate — emitting it only when it CHANGES
    /// (~1 sample/min) could never satisfy the quality gate's
    /// `gateMinContiguousGoodSeconds` (30s of ≤3s-gap samples), which would
    /// leave the Polar HRV channel permanently inert: a silent, LESS
    /// protective regression versus Phase 2's intent. Construction: re-emit
    /// the service's cached per-minute RMSSD stamped `now` on every tick,
    /// but ONLY while the most recent GENUINE Polar HR packet arrival
    /// (`lastPolarHRArrivalTime`, fed exclusively by the real BLE tap) is
    /// within `CNSThresholds.standard.gateWindowSeconds` (60s) of `now`. HR
    /// packets and RMSSD come from the same strap over the same link, so a
    /// live HR stream is a trustworthy liveness oracle for the RMSSD cache
    /// — and when HR arrivals stop (strap died; `state.currentHR` frozen
    /// through the ~10-min reconnect grace), RMSSD emission hard-stops
    /// within `gateWindowSeconds`, so the frozen-corpse case this fix
    /// exists for cannot be resurrected through this channel. The hold does
    /// NOT extend the source's presence clock: `updateDeviceStates`
    /// deliberately excludes `.polarH10` from its emission-based
    /// `lastSampleBySource` refresh (genuine arrivals via
    /// `noteLivePolarSample` are its only feed), so died-detection still
    /// fires at `lastPolarHRArrivalTime + gateWindowSeconds` — held
    /// re-emissions merely let already-trusted data finish draining
    /// through the pipeline's rolling window.
    private func collectPolarRMSSDSample(at now: Date) -> [CNSSignalSample] {
        guard let rmssd = latestPolarRMSSD(),
              let arrival = lastPolarHRArrivalTime,
              now.timeIntervalSince(arrival) <= CNSThresholds.standard.gateWindowSeconds
        else { return [] }
        return CNSSensorAdapters.samples(polarRMSSD: rmssd, at: now)
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
            // Presence clock. `.polarH10`'s is fed EXCLUSIVELY by genuine
            // packet arrivals — `noteLivePolarSample` (the BLE tap) already
            // stamps `lastSampleBySource`/`wasEverReportingBySource` for it,
            // and a held RMSSD re-emission (`collectPolarRMSSDSample`) must
            // NOT refresh it here, or died-detection would lag one extra
            // `gateWindowSeconds` behind the last real packet. The other
            // sources keep the emission-based refresh: an emitted sample is
            // genuine evidence for them (EMAY's provider is the freshly
            // polled reading; Apple Watch has no live adapter in Phase 2).
            if source != .polarH10, newSamples.contains(where: { $0.source == source }) {
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
    /// production convenience init's doc comment) AND (fix item 2) is now
    /// the sole arrival signal `collectPolarHRSample` uses to decide
    /// whether a genuine new HR sample should enter the buffer this tick —
    /// so a dead strap whose cached `latestPolarHR()` value stays populated
    /// for the ~10-min reconnect grace can never read as still-arriving.
    /// `internal` (not `private`), same rationale as
    /// `PolarHRMService.finalizeOrphan`: unit tests simulate a genuine BLE
    /// packet arrival by calling this directly (no real CoreBluetooth
    /// needed), since the coordinator's only OTHER Polar seam
    /// (`latestPolarHR: () -> Int?`) carries no arrival-time information by
    /// design.
    func noteLivePolarSample(at timestamp: Date) {
        guard isMonitoring else { return }
        lastSampleBySource[.polarH10] = timestamp
        wasEverReportingBySource[.polarH10] = true
        lastPolarHRArrivalTime = timestamp
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
    ///
    /// Fix item 1: the dead-man's-switch watchdog reschedule ALSO rides this
    /// 10s cadence (same reasoning — no need to re-call
    /// `notificationPoster.schedule` every single second while monitoring is
    /// healthy). This bounds watchdog staleness to at most
    /// `samplePersistInterval` (10s) beyond `deadMansSwitchInterval` (90s) —
    /// still "~90s" as documented. `startNewSession` schedules the FIRST
    /// watchdog immediately (not gated on this cadence) so a death in the
    /// first 10s of a session is still covered.
    private func persistIfDue(
        assessment: CNSRiskAssessment, tier: CNSAlertTier, at now: Date, into session: MonitoringSession
    ) {
        let tierIncreased = tier > previousObservedTier
        let persistDue = lastPersistAt.map {
            now.timeIntervalSince($0) >= CNSMonitoringConstants.samplePersistInterval
        } ?? true

        // Prune BEFORE the insert+save below: `persistDue` implies the
        // insert branch also runs, so the single existing
        // `modelContext.save()` commits the prune's deletions in the same
        // transaction. Pruning after the save (the previous order) left the
        // deletions pending in the context until the NEXT cadence save
        // ~10s later — an app death inside that window dropped them
        // (bounded, since the next prune idempotently re-derives the same
        // deletions, but a needless re-do and a window where the on-disk
        // store over-reports retention).
        if persistDue {
            try? MonitoringSessionStore.prune(
                before: now.addingTimeInterval(-CNSMonitoringConstants.sampleRetention),
                now: now, in: modelContext
            )
            scheduleDeadMansSwitch(at: now)
        }
        if persistDue || tierIncreased {
            let riskScore: Double?
            let contributions: [CNSContributionRecord]
            switch assessment {
            case .insufficientData, .monitoringDegraded, .monitoringPaused:
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
        // Architecture seam for Phase 3: tier-edge is the hook point for
        // klaxon/haptic escalation and alone-mode fast-escalation UI (spec
        // §5.3/§14.4) — Phase 2 only persists the edge; it triggers no
        // alerting itself.
        previousObservedTier = tier
    }

    /// Fix item 1 (CRITICAL — dead-man's-switch): (re)schedules the watchdog
    /// notification `CNSMonitoringConstants.deadMansSwitchInterval` out from
    /// `now`, replacing any pending one under the same identifier. If the
    /// tick loop dies for ANY reason (iOS suspension/kill while monitoring —
    /// see §15's "Background execution limits") nothing calls this again,
    /// and the previously-scheduled notification fires on schedule — the
    /// one disclosure path that does NOT depend on the tick loop staying
    /// alive.
    private func scheduleDeadMansSwitch(at now: Date) {
        notificationPoster.schedule(
            identifier: CNSMonitoringConstants.deadMansSwitchNotificationID,
            title: "CNS monitoring may have stopped",
            body: "Monitoring may have been interrupted (the app may have been suspended or closed). "
                + "Reopen AnxietyWatch to check its status.",
            at: now.addingTimeInterval(CNSMonitoringConstants.deadMansSwitchInterval)
        )
    }

    private func evaluateDoseWindowExpiry(at now: Date) {
        guard activeTriggers.contains(.doseWindow) else { return }
        let doses = loadPersistedDoses(at: now)
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
        lastPolarHRArrivalTime = nil
        lastEmittedPolarHRArrivalTime = nil

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

        // Fix item 1: arm the dead-man's-switch immediately — don't wait for
        // the first 10s persist-cadence boundary, or a death in the first
        // few seconds of a session would never have had a watchdog
        // scheduled at all.
        scheduleDeadMansSwitch(at: now)

        startTickLoopIfNeeded()
        updateStatusLine()
    }

    private func endSession(reason: EndReason, at now: Date) {
        session?.endedAt = now
        session?.endReason = reason.rawValue
        try? modelContext.save()

        // Tear down the EMAY session started alongside this one
        // (`emayStartHook` in `startNewSession`) — every end reason, not
        // just manual disarm, so a device-loss or window-expiry end doesn't
        // also leave a stray BLE session behind. The hook itself (production
        // closure) is what checks the continuous-streaming toggle; this
        // coordinator stays ignorant of EMAY specifics.
        emayStopHook?()

        // Fix item 1: the dead-man's-switch is only meaningful WHILE
        // monitoring — a deliberate end (any reason) must not leave a
        // watchdog notification pending to needlessly fire ~90s later.
        notificationPoster.cancel(identifier: CNSMonitoringConstants.deadMansSwitchNotificationID)

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
        lastPolarHRArrivalTime = nil
        lastEmittedPolarHRArrivalTime = nil
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

    /// Fix item 5 (IMPORTANT — `.appTerminated` must not be silent): a
    /// force-quit/crash/suspension that left ≥1 `MonitoringSession` un-ended
    /// now posts a notification once this fixup runs, rather than silently
    /// rewriting the row. (Only reachable from `handleLaunch()`, which fix
    /// 7a moved the `!isMonitoring` guard ahead of — so this never touches
    /// a session this SAME coordinator instance is actively running.)
    private func markStaleUnendedSessions(at now: Date) {
        let descriptor = FetchDescriptor<MonitoringSession>(predicate: #Predicate { $0.endedAt == nil })
        guard let staleSessions = try? modelContext.fetch(descriptor), !staleSessions.isEmpty else { return }
        for stale in staleSessions {
            stale.endedAt = now
            stale.endReason = EndReason.appTerminated.rawValue
        }
        try? modelContext.save()
        notificationPoster.post(
            identifier: CNSMonitoringConstants.staleSessionNotificationID,
            title: "Monitoring interrupted",
            body: "Monitoring was interrupted while the app was closed."
        )
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
    /// `handleLaunch()` invalidates the cache).
    ///
    /// Fix item 3: prunes the decoded list before caching it, so a stale
    /// dose can never influence a decision (arming/expiry) even before any
    /// save happens. If pruning actually dropped something that was on
    /// disk, the trimmed list is ALSO written straight back via
    /// `persistDoses` — "prune on load" means the on-disk blob shrinks the
    /// moment a stale entry is first read, not only the next time a dose
    /// happens to be logged. A load that finds nothing stale stays
    /// read-only (no redundant write).
    private func loadPersistedDoses(at now: Date) -> [LoggedCNSDose] {
        if let cachedDoses { return cachedDoses }
        let decodedDoses: [LoggedCNSDose]
        if let data = defaults.data(forKey: Self.loggedDosesKey),
           let decoded = try? JSONDecoder().decode([PersistedCNSDose].self, from: data) {
            decodedDoses = decoded.map(\.asLoggedCNSDose)
        } else {
            decodedDoses = []
        }
        let pruned = pruneDoses(decodedDoses, at: now)
        if pruned.count != decodedDoses.count {
            persistDoses(pruned)
        } else {
            cachedDoses = pruned
        }
        return pruned
    }

    private func savePersistedDoses(_ doses: [LoggedCNSDose], at now: Date) {
        persistDoses(pruneDoses(doses, at: now))
    }

    /// Fix item 3 (IMPORTANT — prune the persisted dose list): drops doses
    /// older than `CNSMonitoringConstants.doseRetentionHorizon` (156h — see
    /// that constant's doc comment for the two-leg derivation) — the horizon
    /// beyond which no individual OR synergy window (either pairing leg)
    /// this dose could ever be part of can reach. Run on every save AND
    /// every decode-from-disk load so
    /// the persisted list stays bounded across months of real usage instead
    /// of growing forever (the previous `savePersistedDoses` only ever
    /// appended).
    private func pruneDoses(_ doses: [LoggedCNSDose], at now: Date) -> [LoggedCNSDose] {
        let cutoff = now.addingTimeInterval(-CNSMonitoringConstants.doseRetentionHorizon)
        return doses.filter { $0.timestamp >= cutoff }
    }

    /// Single encode+write path — `savePersistedDoses` and (when a decode
    /// finds stale entries) `loadPersistedDoses` both funnel through this,
    /// so the in-memory cache and the on-disk blob can never disagree about
    /// what "pruned" produced. Cache is updated FIRST: even if encoding
    /// fails (never expected for these plain Codable values), in-memory
    /// state should reflect the already-pruned list — under-persisting must
    /// not become under-monitoring within the live instance.
    private func persistDoses(_ doses: [LoggedCNSDose]) {
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
        case .as11Bridge: return "AS11 Bridge"
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
