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
        let synergyExpiries = synergyWindowExpiries(doses: doses, now: now)

        guard let maxExpiry = (individualExpiries + synergyExpiries).max(), maxExpiry > now else {
            return nil
        }
        let synergyActive = synergyExpiries.contains { $0 > now }
        return Window(expiry: maxExpiry, synergyActive: synergyActive)
    }

    /// One candidate synergy expiry per (benzo, opioid-class) dose pair whose
    /// individual windows overlap at some point at-or-before `now`.
    ///
    /// Overlap is the plain interval intersection of the two per-dose
    /// windows (`[timestamp, timestamp + classWindow]`), restricted to
    /// intersections that have actually begun by `now`
    /// (`overlapStart <= now`) — a pairing whose windows only overlap in the
    /// future does not yet justify a synergy window. This is the literal
    /// reading of spec §14.1 ("window overlaps ... window at any point ≤
    /// now") and is exactly what's needed to reproduce the plan's own worked
    /// example (benzo @ t0, IR opioid @ t0+2h → t0+26h).
    ///
    /// ESCALATION NOTE (see task-2-report.md): the plan's "synergy floor"
    /// example (benzo @ t0, opioid @ t0+23h50m) does not actually satisfy
    /// this overlap test for ANY opioid class — the benzo window always ends
    /// at t0+12h, before an opioid dose at t0+23h50m even starts, so the raw
    /// windows never intersect regardless of the opioid's own class window
    /// length. Under this (textually literal) overlap rule that case is not
    /// a synergy pairing at all; the plan's asserted lower bound
    /// (`expiry >= laterDose + 24h`) is instead satisfied via the opioid's
    /// own individual window when it is ER or methadone class (whose window
    /// is >= 24h on its own). See `DoseWindowGateTests` for the corresponding
    /// test and a from-scratch synergy+floor test built on doses that do
    /// overlap.
    private static func synergyWindowExpiries(doses: [LoggedCNSDose], now: Date) -> [Date] {
        let benzoDoses = doses.filter { $0.drugClass == .benzodiazepine }
        let opioidDoses = doses.filter { opioidClasses.contains($0.drugClass) }
        guard !benzoDoses.isEmpty, !opioidDoses.isEmpty else { return [] }

        var expiries: [Date] = []
        for benzo in benzoDoses {
            let benzoExpiry = benzo.timestamp.addingTimeInterval(benzo.drugClass.doseWindow)
            for opioid in opioidDoses {
                let opioidExpiry = opioid.timestamp.addingTimeInterval(opioid.drugClass.doseWindow)
                let overlapStart = max(benzo.timestamp, opioid.timestamp)
                let overlapEnd = min(benzoExpiry, opioidExpiry)
                guard overlapStart <= overlapEnd, overlapStart <= now else { continue }

                let laterDose = overlapStart
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
