import Foundation

/// §5.3 hysteretic escalation state machine: `clear → watch → confirm →
/// klaxon`. Rising demands sustained elevation; falling demands sustained,
/// decisively-lower scores; missing data can never clear an alert (spec
/// §14.2 asymmetry, §11 fail-safe bias). Pure value type — callers pass
/// `now`; there is no hidden clock.
struct CNSAlertTierMachine {
    private let thresholds: CNSThresholds
    private let companionPresent: Bool

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

    private func sustainSeconds(toEnter tier: CNSAlertTier) -> TimeInterval {
        tier == .klaxon ? thresholds.klaxonRiseSustainSeconds : thresholds.riseSustainSeconds
    }

    @discardableResult
    mutating func ingest(_ assessment: CNSRiskAssessment, at now: Date) -> CNSAlertTier {
        guard case .assessed(let score, let contributions) = assessment else {
            // No data: hold the tier, surface can't-assess, and discard any
            // progress toward clearing — silence must never read as safety.
            canAssess = false
            resetClearCandidate()
            return tier
        }
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
    }

    private mutating func advanceRise(score: Double, primaryInformed: Bool, at now: Date) {
        guard let next = CNSAlertTier(rawValue: tier.rawValue + 1) else {
            resetRiseCandidate()
            return
        }
        guard score >= entryThreshold(for: next) else {
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
        // A fresh candidate, OR a stale one whose last qualifying update is
        // too old: (re)start the window at now. Unobserved time never counts.
        let gapTooLong = riseCandidateLastQualifyingAt.map {
            now.timeIntervalSince($0) > thresholds.sustainMaxGapSeconds
        } ?? false
        if riseCandidateTier != next || gapTooLong {
            riseCandidateTier = next
            riseCandidateSince = now
            riseCandidateLastQualifyingAt = now
            return
        }
        riseCandidateLastQualifyingAt = now
        if let since = riseCandidateSince,
           now.timeIntervalSince(since) >= sustainSeconds(toEnter: next) {
            tier = next
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
