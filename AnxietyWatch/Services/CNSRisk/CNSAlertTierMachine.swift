import Foundation

/// §5.3 hysteretic escalation state machine: `clear → watch → confirm →
/// klaxon`. Rising demands sustained elevation; falling demands sustained,
/// decisively-lower scores; missing data can never clear an alert (spec
/// §14.2 asymmetry, §11 fail-safe bias). Pure value type — callers pass
/// `now`; there is no hidden clock.
struct CNSAlertTierMachine {
    private let thresholds: CNSThresholds
    /// Re-markable mid-session (spec §6): a `var`, consulted fresh by
    /// `entryThreshold(for:)` at every threshold comparison, so flipping it
    /// via `setCompanionPresent(_:)` changes future comparisons WITHOUT
    /// touching `tier`/`canAssess`/the rise/clear candidate clocks below —
    /// rebuilding the whole machine on a re-mark would reset sustain
    /// progress and delay escalation, the wrong direction for safety.
    private var companionPresent: Bool

    private(set) var tier: CNSAlertTier = .clear
    /// False until the first ingest: before anything has been assessed,
    /// claiming assessability would be false reassurance.
    private(set) var canAssess = false

    /// When the score first met the next tier's threshold (nil = no rise
    /// in progress).
    private var riseCandidateSince: Date?
    private var riseCandidateTier: CNSAlertTier?
    /// The most recent qualifying assessed update — used to detect gaps
    /// inside a rise-sustain window (see `sustainMaxGapSeconds`).
    private var riseCandidateLastQualifyingAt: Date?
    /// When the score first fell decisively below the current tier's
    /// threshold (nil = no clear in progress).
    private var clearCandidateSince: Date?
    /// The most recent qualifying (decisively-low, primary-informed) update —
    /// used to detect gaps inside a clear-sustain window. Tick starvation
    /// (app suspension) must not let two low readings bracketing a blackout
    /// complete a 120s clear (see `sustainMaxGapSeconds`).
    private var clearCandidateLastQualifyingAt: Date?

    init(thresholds: CNSThresholds, companionPresent: Bool) {
        self.thresholds = thresholds
        self.companionPresent = companionPresent
    }

    /// Re-mark companion presence (spec §6). Threshold-comparison-time only:
    /// mutates nothing else, so `tier`, `canAssess`, and every rise/clear
    /// sustain clock survive the flip untouched.
    mutating func setCompanionPresent(_ present: Bool) {
        companionPresent = present
    }

    /// Threshold to ENTER a tier, adjusted for §14.4: alone fires earlier
    /// (lower thresholds); companion-present uses the base values.
    private func entryThreshold(for tier: CNSAlertTier) -> Double {
        let base: Double
        switch tier {
        case .clear: base = 0
        case .watch: base = thresholds.watchThreshold
        case .confirm: base = thresholds.confirmThreshold
        case .klaxon: base = thresholds.klaxonThreshold
        }
        return companionPresent ? base : base - thresholds.aloneModeThresholdDelta
    }

    private func sustainSeconds(toEnter tier: CNSAlertTier, critical: Bool) -> TimeInterval {
        if critical {
            // Severity-scaled fast path: a critical primary reading (score at
            // the klaxon threshold — SpO₂ at the floor / absolute danger line)
            // does not pay the graded ladder. One short validity sustain.
            return thresholds.criticalFastPathSustainSeconds
        }
        if companionPresent {
            return tier == .klaxon ? thresholds.klaxonRiseSustainSeconds : thresholds.riseSustainSeconds
        } else {
            return tier == .klaxon ? thresholds.aloneModeKlaxonRiseSustainSeconds : thresholds.aloneModeRiseSustainSeconds
        }
    }

    @discardableResult
    mutating func ingest(_ assessment: CNSRiskAssessment, at now: Date) -> CNSAlertTier {
        switch assessment {
        case .assessed(let score, let contributions):
            canAssess = true
            // Whether a primary signal (SpO₂ / respiratory rate) actually
            // informed this score. Only the signal class that can raise the
            // alarm may earn reassurance or contradict a rise in progress.
            let primaryInformed = contributions.contains {
                $0.kind == .spo2 || $0.kind == .respiratoryRate
            }

            advanceRise(score: score, primaryInformed: primaryInformed, at: now)
            advanceClear(score: score, primaryInformed: primaryInformed, at: now)
            return tier

        case .monitoringPaused:
            // Mask off / large leak suppresses physiological assessment for this
            // tick, but does not erase a rise already supported by primary data.
            // `advanceRise` restarts it if the next qualifying tick exceeds the
            // maximum allowed gap. Holding is safer than clearing or delaying a
            // real escalation after a brief mask slip.
            canAssess = false
            resetClearCandidate()
            return tier

        case .monitoringDegraded, .insufficientData:
            // No data / bridge down: hold the tier, surface can't-assess, and discard any
            // progress toward clearing — silence must never read as safety.
            //
            // The rise candidate is deliberately NOT reset here. `advanceRise`'s
            // `sustainMaxGapSeconds` gap guard (via `riseCandidateLastQualifyingAt`,
            // stamped only on qualifying `.assessed` ticks) already invalidates a
            // sustain window that spans a too-long gap, so wiping progress here would
            // only DELAY a legitimate escalation after a brief blip — the wrong
            // direction for a fail-safe alarm. Mirrors the corroborating-only and
            // `.monitoringPaused` paths.
            canAssess = false
            resetClearCandidate()
            return tier
        }
    }

    private mutating func advanceRise(score: Double, primaryInformed: Bool, at now: Date) {
        // Severity-scaled fast path: a primary-informed score at the klaxon
        // threshold is deep, unambiguous danger (severity ≈ 1.0 — SpO₂ at the
        // floor / absolute danger line). It escalates STRAIGHT to klaxon after
        // one short validity sustain, skipping the watch→confirm ladder, so a
        // crash does not pay the full graded latency. Reaching the klaxon
        // threshold at all requires primary severity ~1.0, so this is genuinely
        // the critical band, not a gradual rise.
        let critical = primaryInformed && score >= entryThreshold(for: .klaxon)
        let target: CNSAlertTier
        if critical {
            target = .klaxon
        } else if let next = CNSAlertTier(rawValue: tier.rawValue + 1) {
            target = next
        } else {
            resetRiseCandidate()
            return
        }
        // Already at or above the target (e.g. critical while already at klaxon):
        // nothing to rise into.
        guard target > tier else {
            resetRiseCandidate()
            return
        }
        // Only primary-informed evidence can escalate the tier PAST watch — HR/HRV
        // alone (corroborating signals) can trigger a watch state, but cannot
        // push into confirm/klaxon (a critical target is primary-informed by
        // construction). Without this guard, a chest-strap-only (no SpO₂)
        // session could rise to confirm on HR/HRV alone.
        if target > .watch {
            guard primaryInformed else {
                return
            }
        }
        guard score >= entryThreshold(for: target) else {
            // Only contrary PRIMARY evidence resets a rise in progress. A
            // corroborating-only tick can't testify about the primary stream
            // that started the candidate, so it leaves the candidate intact
            // (like insufficientData); the gap guard's lastQualifying
            // timestamp still governs staleness.
            if primaryInformed {
                resetRiseCandidate()
            }
            return
        }
        // A fresh candidate, a changed target, OR a stale one whose last
        // qualifying update is too old: (re)start the window at now. Unobserved
        // time never counts.
        let gapTooLong = riseCandidateLastQualifyingAt.map {
            now.timeIntervalSince($0) > thresholds.sustainMaxGapSeconds
        } ?? false
        if riseCandidateTier != target || gapTooLong {
            riseCandidateTier = target
            riseCandidateSince = now
            riseCandidateLastQualifyingAt = now
            return
        }
        riseCandidateLastQualifyingAt = now
        if let since = riseCandidateSince,
           now.timeIntervalSince(since) >= sustainSeconds(toEnter: target, critical: critical) {
            tier = target
            resetClearCandidate()
            // Chain-escalation continues from a fresh candidate window.
            resetRiseCandidate()
        }
    }

    private mutating func advanceClear(score: Double, primaryInformed: Bool, at now: Date) {
        guard tier > .clear else {
            resetClearCandidate()
            return
        }
        // Clearing requires primary-informed evidence: a healthy chest strap
        // must never launder a missing/indeterminate primary stream into
        // "all clear" — reassurance is earned only by the signal class that
        // can raise the alarm (spec §14.2 asymmetry).
        guard primaryInformed else {
            resetClearCandidate()
            return
        }
        let decisiveCeiling = entryThreshold(for: tier) - thresholds.clearHysteresis
        guard score < decisiveCeiling else {
            resetClearCandidate()
            return
        }
        // A fresh candidate, OR a stale one whose last qualifying update is
        // too old: (re)start the window at now. Tick starvation (app
        // suspension) must not let two low readings bracketing a blackout
        // complete a 120s clear.
        let gapTooLong = clearCandidateLastQualifyingAt.map {
            now.timeIntervalSince($0) > thresholds.sustainMaxGapSeconds
        } ?? false
        if clearCandidateSince == nil || gapTooLong {
            clearCandidateSince = now
            clearCandidateLastQualifyingAt = now
            return
        }
        clearCandidateLastQualifyingAt = now
        if let since = clearCandidateSince,
           now.timeIntervalSince(since) >= thresholds.clearSustainSeconds,
           let lower = CNSAlertTier(rawValue: tier.rawValue - 1) {
            tier = lower
            resetClearCandidate()
        }
    }

    private mutating func resetRiseCandidate() {
        riseCandidateSince = nil
        riseCandidateTier = nil
        riseCandidateLastQualifyingAt = nil
    }

    private mutating func resetClearCandidate() {
        clearCandidateSince = nil
        clearCandidateLastQualifyingAt = nil
    }
}
