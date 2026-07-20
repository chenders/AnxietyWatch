import Foundation

/// Monitoring-session cadence, retention, and notification identifiers for
/// the CNS-depression monitor (spec §14.1/§14.3). One place for every tunable
/// here, per project convention (mirrors `CNSThresholds`) — tests reference
/// these members; never re-type a literal.
enum CNSMonitoringConstants {

    /// How often the coordinator's tick loop reads sensors and re-runs the
    /// detection pipeline while monitoring is active.
    static let tickInterval: TimeInterval = 1
    /// How often a `CNSRiskSampleRecord` is persisted for the ~1-hour view.
    static let samplePersistInterval: TimeInterval = 10
    /// Persisted risk samples older than this (relative to `now`) are pruned.
    static let sampleRetention: TimeInterval = 24 * 3600
    /// Safety-net window for `MonitoringSessionStore.prune`: the most recent
    /// hour of a still-active (un-ended) session's samples is never pruned,
    /// regardless of the cutoff a caller passes. Protects the live rolling-
    /// buffer / Phase 3 "current session" view from losing its most recent
    /// data to an overly aggressive or misconfigured cutoff — the retention
    /// window (24h) is what normally governs pruning, but this is an
    /// independent floor, not a consequence of it.
    static let activeSessionProtectedWindow: TimeInterval = 3600

    /// Posted when a device transitions to `.degradeDisclosed` (spec §14.2's
    /// asymmetry rule: degradation is always disclosed, never silent).
    static let degradedNotificationID = "cns.monitoring.degraded"
    /// Posted ONLY when monitoring ends because of device loss (the sole
    /// `EndReason` that posts through this identifier) — the §7 "never a
    /// silent stop" interim measure for the dangerous silent-gap case.
    /// Stale-session (`.appTerminated`, fix item 5) and the dead-man's-switch
    /// watchdog (fix item 1) post through their OWN identifiers
    /// (`staleSessionNotificationID` / `deadMansSwitchNotificationID`
    /// below) — not this one.
    ///
    /// `.windowExpired` ends post NOTHING through any identifier — that is
    /// BY DESIGN (plan-owner decision, §14.1/§15's "Background execution
    /// limits" note): the pharmacokinetic risk window closing is a planned,
    /// expected end, not an incident, and a notification at 5am for a
    /// routine window close would be hostile rather than helpful. That end
    /// reason remains fully visible in session history
    /// (`MonitoringSession.endReason == "windowExpired"`), just never
    /// surfaced as a push notification.
    static let endedNotificationID = "cns.monitoring.ended"
    /// Posted when `handleLaunch()` finds ≥1 `MonitoringSession` left
    /// un-ended by a force-quit/crash/suspension and marks it
    /// `.appTerminated` (fix item 5) — "Monitoring was interrupted while the
    /// app was closed" must reach the user even though the dead-man's-switch
    /// watchdog (fix item 1) likely already fired; reopening the app is what
    /// confirms the interruption either way.
    static let staleSessionNotificationID = "cns.monitoring.staleSession"

    /// Dead-man's-switch watchdog (fix item 1 — CRITICAL): while monitoring,
    /// the coordinator keeps a LOCAL notification scheduled this far out,
    /// cancelling and rescheduling it every firing tick (persist cadence —
    /// see `CNSMonitoringCoordinator.persistIfDue`'s doc comment for why
    /// this rides the same 10s cadence as pruning) so it never actually
    /// fires while the tick loop is alive. If iOS suspends or kills the app
    /// while monitoring is active (e.g. the phone's screen locks and the OS
    /// reclaims the background slot — Phase 2's 1 Hz `Task.sleep` loop has
    /// no background-execution guarantee; see §15), nothing reschedules the
    /// watchdog again, and it fires ~90s after the last successful tick —
    /// the one notification path that does NOT depend on the tick loop
    /// still running. Cancelled on every `endSession`/disarm. Robust
    /// BLE-event-driven background monitoring and Critical Alerts are Phase
    /// 3 scope (§15).
    static let deadMansSwitchInterval: TimeInterval = 90
    /// `UNTimeIntervalNotificationTrigger` requires a positive delay.
    static let minimumNotificationDelay: TimeInterval = 1
    static let deadMansSwitchNotificationID = "cns.monitoring.deadMansSwitch"

    /// `CNSMonitoringCoordinator`'s rolling sample buffer keeps samples back to
    /// `gateWindowSeconds + bufferTrimSlackSeconds` before trimming, rather
    /// than exactly `gateWindowSeconds`: `CNSDetectionPipeline.process`
    /// re-applies the exact `gateWindowSeconds` boundary itself (its own
    /// defense-in-depth trim), so the buffer only needs enough slack to
    /// tolerate tick-to-tick timing jitter without dropping a sample the
    /// pipeline still wants. Not safety-critical arithmetic — generous slack
    /// only widens what's KEPT, never what the gate/scorer actually consider.
    static let bufferTrimSlackSeconds: TimeInterval = 10

    // MARK: - §14.1 benzo+opioid synergy

    /// One leg of the UNION synergy-pairing rule: a benzodiazepine dose and
    /// an opioid-class dose form a synergy pair when their timestamps are
    /// within this horizon of each other (either order), OR when their §14.1
    /// monitoring windows overlap at any instant (the other leg; see
    /// `DoseWindowGate`). Spec §14.1's synergy clause means "onboard
    /// together" — pharmacological presence — and each leg covers a case
    /// the other misses:
    /// - Monitoring windows are deliberately shorter than elimination
    ///   half-lives (clonazepam t½ 30–40 h vs its 12 h window), so window
    ///   overlap alone misses a benzo still onboard when an opioid is dosed
    ///   20+ h later — the horizon leg catches it. 24 h is the spec's own
    ///   synergy figure, reused as the pairing bound.
    /// - The horizon alone misses a benzo dosed 50 h into a methadone
    ///   window (methadone's long pharmacological tail is why its window is
    ///   72 h); dropping that pairing would forgo 62 h of monitoring
    ///   (synergy expiry t0+134h vs the methadone window's own t0+72h) —
    ///   the overlap leg catches it.
    /// Plan-owner call (2026-07-12), fail-safe direction, pending clinical
    /// review.
    static let synergyPairingHorizon: TimeInterval = 24 * 3600

    /// Added to `max(benzoClassWindow, opioidClassWindow)` from the LATER of
    /// the two dose times to anchor a synergy window.
    static let synergyWindowExtension: TimeInterval = 12 * 3600
    /// Minimum synergy window length from the later dose, regardless of how
    /// the two class windows compare — a structural safety floor. With the
    /// current class windows (benzo 12 h ≤ every opioid-class window) the raw
    /// `max(...) + synergyWindowExtension` formula already meets or exceeds
    /// this floor for every pairing, so the floor is never strictly binding
    /// today; it is enforced anyway so a future change to the class windows
    /// (§14.1 constants) can't silently produce a synergy window shorter than
    /// 24 h.
    static let synergyWindowFloor: TimeInterval = 24 * 3600

    // MARK: - Persisted dose list retention (fix item 3)

    /// Horizon beyond which a persisted dose can no longer affect ANY active
    /// or future `DoseWindowGate.activeWindow` computation — pruned from the
    /// coordinator's persisted `[LoggedCNSDose]` list on both save and load
    /// so it doesn't grow forever across months of real usage. Computed, not
    /// hardcoded. The bound must cover BOTH synergy-pairing legs
    /// (`DoseWindowGate.synergyWindowExpiries`), measured from the pruned
    /// dose's own timestamp `t`:
    ///
    /// - **Pairing-horizon leg:** a partner dose can be logged up to
    ///   `synergyPairingHorizon` (24 h) after `t`; the synergy window
    ///   anchors at that later dose and reaches
    ///   `max(class windows) + synergyWindowExtension` ≤ 72 h + 12 h = 84 h
    ///   further → influence ends ≤ `t + 24h + 84h = t + 108h`.
    /// - **Window-overlap leg (the governing one):** a partner dose pairs as
    ///   long as the two §14.1 monitoring windows intersect at any instant,
    ///   i.e. it can be logged as late as the pruned dose's OWN window
    ///   expiry — up to `t + 72h` for a methadone/unknown dose. The synergy
    ///   window again anchors at that later dose and reaches ≤ 84 h further
    ///   → influence ends ≤ `t + 72h + 84h = t + 156h`. Concretely:
    ///   methadone@t + benzo@t+50h yields synergy expiry t+134h; a 108 h
    ///   horizon would prune the methadone at any load/save after t+108h,
    ///   dissolve the pair, and silently forgo up to 47 h of mandated
    ///   monitoring — permanently, given the load-time disk rewrite.
    ///
    /// Flat bound = the overlap leg's worst case:
    /// `doseWindow (72h, latest overlap-pairing partner) + max(anchor reach,
    /// synergyWindowFloor)` where anchor reach = `max(class windows) (72h)
    /// + synergyWindowExtension (12h)` = 84 h — so 156 h today. The
    /// `synergyWindowFloor` term (24 h) cannot govern at current values, but
    /// it participates in the formula so a future downward tuning of class
    /// windows or the extension can never silently make pruning more
    /// aggressive than the floor-governed synergy window it must outlive.
    /// Deliberately a flat conservative bound rather than the tightest
    /// per-class bound — fail-safe direction: keeping a dose longer than
    /// strictly necessary costs a few bytes of `UserDefaults`, never a
    /// missed synergy pairing.
    static let doseRetentionHorizon: TimeInterval =
        CNSDepressantClass.methadoneOrUnknownLongActing.doseWindow
            + max(
                CNSDepressantClass.methadoneOrUnknownLongActing.doseWindow
                    + synergyWindowExtension,
                synergyWindowFloor
            )
}
