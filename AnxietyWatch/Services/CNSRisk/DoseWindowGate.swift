import Foundation

/// A logged CNS-depressant dose, as consumed by `DoseWindowGate`.
struct LoggedCNSDose: Equatable, Sendable {
    let timestamp: Date
    let drugClass: CNSDepressantClass
}

/// §14.1 pharmacokinetic monitoring-window gate: given logged CNS-depressant
/// doses and the current time, decides whether overnight respiratory-
/// depression monitoring should be active, and when it expires.
///
/// Pure and clock-explicit (spec §14.1): `now` is always passed in, never
/// read from `Date()`/`Date.now`. SAFETY-CRITICAL — this decides when
/// overnight respiratory-depression monitoring arms and disarms. The
/// stacking rule is absolute: windows may only extend, never shorten;
/// `activeWindow` always returns the LATEST candidate expiry among every
/// individual and synergy window, never an earlier one.
enum DoseWindowGate {

    /// An active monitoring window.
    struct Window: Equatable, Sendable {
        /// When the window closes (monitoring may disarm), absent further doses.
        let expiry: Date
        /// True when a benzodiazepine + opioid-class synergy window (§14.1)
        /// is still unexpired at `now` — independent of whether that
        /// particular synergy window happens to be the one producing
        /// `expiry` (a later, non-synergy window can still be the governing
        /// max while an earlier synergy window remains active).
        let synergyActive: Bool
    }

    /// Opioid-class members that combine with a benzodiazepine dose to
    /// produce a synergy window (§14.1). Methadone/unknown-long-acting is
    /// grouped here, WITH the opioids, not with benzodiazepines — a
    /// methadone + IR-opioid pair is opioid+opioid, not benzo+opioid, and
    /// must NOT trigger synergy (see `DoseWindowGateTests.methadoneThenOpioidIsNotSynergy`).
    private static let opioidClasses: Set<CNSDepressantClass> = [
        .opioidIR, .opioidER, .methadoneOrUnknownLongActing,
    ]

    /// §14.1: per-dose windows; benzo+opioid synergy = max(class windows) + 12h
    /// from the LATER dose, 24h floor; stacking always takes the LATER expiry.
    /// Returns nil when no window is active at `now`.
    ///
    /// A dose whose logged `timestamp` is in the future relative to `now`
    /// (clock skew, a manual backdate that lands forward) still produces its
    /// own window: its expiry is simply `timestamp + classWindow`, computed
    /// identically to any other dose, and it counts toward the max like any
    /// other dose. This deliberately does NOT special-case "hasn't started
    /// yet" — the simplest rule, and the one that can never under-monitor, is
    /// to treat every logged dose the same regardless of where its timestamp
    /// falls relative to `now` (see `DoseWindowGateTests.futureTimestampedDoseStillProducesItsWindow`).
    static func activeWindow(doses: [LoggedCNSDose], at now: Date) -> Window? {
        guard !doses.isEmpty else { return nil }

        let individualExpiries = doses.map { $0.timestamp.addingTimeInterval($0.drugClass.doseWindow) }
        let synergyExpiries = synergyWindowExpiries(doses: doses)

        guard let maxExpiry = (individualExpiries + synergyExpiries).max(), maxExpiry > now else {
            return nil
        }
        let synergyActive = synergyExpiries.contains { $0 > now }
        return Window(expiry: maxExpiry, synergyActive: synergyActive)
    }

    /// One candidate synergy expiry per (benzo, opioid-class) dose pair
    /// whose timestamps fall within `CNSMonitoringConstants
    /// .synergyPairingHorizon` (24 h) of each other, in either order.
    ///
    /// PAIRING-HORIZON rule, replacing an earlier monitoring-window-overlap
    /// rule (plan-owner decision 2026-07-12, recorded in task-2-report.md):
    /// spec §14.1's synergy clause is about the two drugs being "onboard
    /// together" — pharmacological presence — and monitoring windows are
    /// deliberately shorter than elimination half-lives (clonazepam t½
    /// 30–40 h vs its 12 h monitoring window), so window overlap would
    /// under-detect exactly the lethal case the clause exists for: a benzo
    /// still onboard when an opioid is dosed 20+ hours later.
    ///
    /// Known, deliberate consequence (plan-owner call, flagged for clinical
    /// review): doses farther apart than the horizon never pair even when
    /// the long-acting opioid's own MONITORING window still contains the
    /// benzo dose (methadone @ t0 + benzo @ t0+50h) — there the long-acting
    /// class's own 72 h window does the protective work. See
    /// `DoseWindowGateTests.benzoInsideMethadoneWindowBeyondHorizonIsNotSynergy`.
    ///
    /// No `now` condition here, consistent with the future-timestamped-dose
    /// rule above: pairing is a pure function of the two logged timestamps,
    /// and expiry-vs-`now` is adjudicated once, in `activeWindow`.
    private static func synergyWindowExpiries(doses: [LoggedCNSDose]) -> [Date] {
        let benzoDoses = doses.filter { $0.drugClass == .benzodiazepine }
        let opioidDoses = doses.filter { opioidClasses.contains($0.drugClass) }
        guard !benzoDoses.isEmpty, !opioidDoses.isEmpty else { return [] }

        var expiries: [Date] = []
        for benzo in benzoDoses {
            for opioid in opioidDoses {
                let gap = abs(benzo.timestamp.timeIntervalSince(opioid.timestamp))
                guard gap <= CNSMonitoringConstants.synergyPairingHorizon else { continue }

                let laterDose = max(benzo.timestamp, opioid.timestamp)
                let reach = max(benzo.drugClass.doseWindow, opioid.drugClass.doseWindow)
                    + CNSMonitoringConstants.synergyWindowExtension
                let raw = laterDose.addingTimeInterval(reach)
                let floor = laterDose.addingTimeInterval(CNSMonitoringConstants.synergyWindowFloor)
                expiries.append(max(raw, floor))
            }
        }
        return expiries
    }
}
