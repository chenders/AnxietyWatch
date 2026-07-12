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
    /// Posted when monitoring ends for any reason a user might not be
    /// watching for (device loss, window expiry) — "never a silent stop."
    static let endedNotificationID = "cns.monitoring.ended"

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
}
