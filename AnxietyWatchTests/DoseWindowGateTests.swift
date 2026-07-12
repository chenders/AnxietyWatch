import Foundation
import Testing

@testable import AnxietyWatch

/// Covers §14.1 dose-window gating: per-class windows and expiries,
/// benzo+opioid synergy stacking (incl. the 24h floor and order-
/// independence), and the "stacking never shortens" rule. SAFETY-CRITICAL —
/// this decides when overnight respiratory-depression monitoring arms and
/// disarms.
struct DoseWindowGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func hours(_ count: Double) -> TimeInterval { count * 3600 }

    private func dose(_ drugClass: CNSDepressantClass, at offset: TimeInterval) -> LoggedCNSDose {
        LoggedCNSDose(timestamp: t0.addingTimeInterval(offset), drugClass: drugClass)
    }

    // MARK: - Single-class windows and expiries

    @Test("A single benzodiazepine dose is active within its 12h window")
    func benzoActive() {
        let window = DoseWindowGate.activeWindow(
            doses: [dose(.benzodiazepine, at: 0)], at: t0.addingTimeInterval(hours(11))
        )
        #expect(window?.expiry == t0.addingTimeInterval(hours(12)))
        #expect(window?.synergyActive == false)
    }

    @Test("A single benzodiazepine dose is expired 1s past its 12h window")
    func benzoExpired() {
        let window = DoseWindowGate.activeWindow(
            doses: [dose(.benzodiazepine, at: 0)], at: t0.addingTimeInterval(hours(12) + 1)
        )
        #expect(window == nil)
    }

    @Test("A single immediate-release opioid dose is active within its 8h window, expired just after")
    func opioidIRWindow() {
        let active = DoseWindowGate.activeWindow(
            doses: [dose(.opioidIR, at: 0)], at: t0.addingTimeInterval(hours(7))
        )
        #expect(active?.expiry == t0.addingTimeInterval(hours(8)))
        #expect(active?.synergyActive == false)

        let expired = DoseWindowGate.activeWindow(
            doses: [dose(.opioidIR, at: 0)], at: t0.addingTimeInterval(hours(8) + 1)
        )
        #expect(expired == nil)
    }

    @Test("A single extended-release opioid dose is active within its 24h window, expired just after")
    func opioidERWindow() {
        let active = DoseWindowGate.activeWindow(
            doses: [dose(.opioidER, at: 0)], at: t0.addingTimeInterval(hours(23))
        )
        #expect(active?.expiry == t0.addingTimeInterval(hours(24)))
        #expect(active?.synergyActive == false)

        let expired = DoseWindowGate.activeWindow(
            doses: [dose(.opioidER, at: 0)], at: t0.addingTimeInterval(hours(24) + 1)
        )
        #expect(expired == nil)
    }

    @Test("A single methadone dose is active within its 72h window, expired just after")
    func methadoneWindow() {
        let active = DoseWindowGate.activeWindow(
            doses: [dose(.methadoneOrUnknownLongActing, at: 0)], at: t0.addingTimeInterval(hours(71))
        )
        #expect(active?.expiry == t0.addingTimeInterval(hours(72)))
        #expect(active?.synergyActive == false)

        let expired = DoseWindowGate.activeWindow(
            doses: [dose(.methadoneOrUnknownLongActing, at: 0)], at: t0.addingTimeInterval(hours(72) + 1)
        )
        #expect(expired == nil)
    }

    // MARK: - Synergy

    @Test("Benzo then IR opioid: synergy expiry anchors at the later dose + max(class windows) + 12h")
    func synergyBenzoThenOpioid() {
        let doses = [dose(.benzodiazepine, at: 0), dose(.opioidIR, at: hours(2))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(3)))
        // t0+2h + max(12h, 8h) + 12h = t0+26h
        #expect(window?.expiry == t0.addingTimeInterval(hours(26)))
        #expect(window?.synergyActive == true)
    }

    @Test("Synergy is order-independent: opioid then benzo anchors at the later (benzo) dose")
    func synergyOpioidThenBenzo() {
        let doses = [dose(.opioidIR, at: 0), dose(.benzodiazepine, at: hours(2))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(3)))
        // Later dose is the benzo @ t0+2h; max(12h, 8h) + 12h = 24h -> t0+2h+24h = t0+26h.
        #expect(window?.expiry == t0.addingTimeInterval(hours(26)))
        #expect(window?.synergyActive == true)
    }

    /// The plan's "synergy floor" case, under the plan-owner-decided
    /// PAIRING-HORIZON rule (§14.1 "onboard together"): the dose timestamps
    /// are 23h50m apart — inside the 24h pairing horizon — so this IS a
    /// synergy pair even though the benzo's own MONITORING window (ends
    /// t0+12h) closed before the opioid dose. Pharmacologically the benzo is
    /// still onboard (clonazepam t½ 30–40h); the monitoring window is
    /// deliberately shorter than elimination and must not double as a
    /// presence test. With an IR opioid, the raw synergy formula
    /// (later + max(12h, 8h) + 12h) exactly EQUALS the 24h floor, making
    /// this the floor-binding boundary: expiry = later dose + 24h.
    @Test("Synergy floor: benzo then IR opioid 23h50m later pairs within the horizon; expiry = later + 24h")
    func synergyFloorAtPairingHorizonBoundary() {
        let laterDoseOffset = hours(23) + 50 * 60
        let doses = [dose(.benzodiazepine, at: 0), dose(.opioidIR, at: laterDoseOffset)]
        let now = t0.addingTimeInterval(laterDoseOffset + 60)
        let window = DoseWindowGate.activeWindow(doses: doses, at: now)
        let laterDose = t0.addingTimeInterval(laterDoseOffset)
        #expect(window?.expiry == laterDose.addingTimeInterval(hours(24)))
        #expect(window?.synergyActive == true)
    }

    @Test("Doses more than the 24h pairing horizon apart are never a synergy pair")
    func beyondPairingHorizonIsNotSynergy() {
        let doses = [dose(.benzodiazepine, at: 0), dose(.opioidIR, at: hours(25))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(26)))
        // Individual windows only: benzo ended at t0+12h; IR ends t0+33h.
        #expect(window?.expiry == t0.addingTimeInterval(hours(33)))
        #expect(window?.synergyActive == false)
    }

    @Test("Pairing horizon is order-independent: opioid first, benzo 23h later")
    func pairingHorizonOrderIndependence() {
        let doses = [dose(.opioidIR, at: 0), dose(.benzodiazepine, at: hours(23))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(24)))
        // later (benzo, t0+23h) + max(12h, 8h) + 12h = t0+47h; floor equal.
        #expect(window?.expiry == t0.addingTimeInterval(hours(47)))
        #expect(window?.synergyActive == true)
    }

    @Test("Synergy inside the horizon with a long-acting opioid: benzo then methadone")
    func synergyWithinHorizonLongActingOpioid() {
        let doses = [dose(.benzodiazepine, at: 0), dose(.methadoneOrUnknownLongActing, at: hours(11))]
        let now = t0.addingTimeInterval(hours(12))
        let window = DoseWindowGate.activeWindow(doses: doses, at: now)
        let laterDose = t0.addingTimeInterval(hours(11))
        // max(12h, 72h) + 12h = 84h, which already exceeds the 24h floor —
        // the floor is not binding here; the raw formula governs.
        #expect(window?.expiry == laterDose.addingTimeInterval(hours(84)))
        #expect(window?.synergyActive == true)
    }

    /// PLAN-OWNER CALL (recorded in task-2-report.md): the pairing horizon
    /// governs even when the long-acting opioid's MONITORING window still
    /// contains the benzo dose. Methadone@t0 + benzo@t0+50h: the methadone
    /// window [t0, t0+72h] contains the benzo dose, but the timestamps are
    /// 50h apart — beyond the 24h horizon — so this is NOT a synergy pair.
    /// The long-acting class's own 72h window is doing the protective work
    /// here: it governs the expiry (the benzo's individual window ends at
    /// t0+62h, inside it). A window-overlap rule WOULD have paired these
    /// (synergy expiry t0+134h); the horizon rule deliberately trades that
    /// away for one simple pairing definition — flagged for clinical review
    /// alongside the horizon constant itself.
    @Test("Beyond the horizon, a benzo inside a methadone monitoring window is still not a synergy pair")
    func benzoInsideMethadoneWindowBeyondHorizonIsNotSynergy() {
        let doses = [dose(.methadoneOrUnknownLongActing, at: 0), dose(.benzodiazepine, at: hours(50))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(51)))
        #expect(window?.expiry == t0.addingTimeInterval(hours(72)))
        #expect(window?.synergyActive == false)
    }

    @Test("Benzo + benzo does not set synergyActive")
    func benzoPlusBenzoIsNotSynergy() {
        let doses = [dose(.benzodiazepine, at: 0), dose(.benzodiazepine, at: hours(1))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(2)))
        #expect(window?.expiry == t0.addingTimeInterval(hours(13)))
        #expect(window?.synergyActive == false)
    }

    @Test("Methadone then IR opioid does not set synergyActive: opioid+opioid is not benzo+opioid")
    func methadoneThenOpioidIsNotSynergy() {
        let doses = [dose(.methadoneOrUnknownLongActing, at: 0), dose(.opioidIR, at: hours(1))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(2)))
        // Methadone's own 72h window is the max; the 9h IR window never
        // pulls it earlier (stacking never shortens) and never contributes synergy.
        #expect(window?.expiry == t0.addingTimeInterval(hours(72)))
        #expect(window?.synergyActive == false)
    }

    // MARK: - Stacking never shortens

    @Test("A second benzo dose extends the window; it never shortens it")
    func stackingBenzoExtends() {
        let doses = [dose(.benzodiazepine, at: 0), dose(.benzodiazepine, at: hours(1))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(2)))
        #expect(window?.expiry == t0.addingTimeInterval(hours(13)))
    }

    @Test("A later, shorter-windowed dose never pulls the overall expiry earlier")
    func laterShorterWindowDoesNotShortenExpiry() {
        let doses = [dose(.methadoneOrUnknownLongActing, at: 0), dose(.opioidIR, at: hours(1))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(2)))
        #expect(window?.expiry == t0.addingTimeInterval(hours(72)))
    }

    // MARK: - Empty / fully expired

    @Test("No doses -> no active window")
    func emptyDosesReturnsNil() {
        #expect(DoseWindowGate.activeWindow(doses: [], at: t0) == nil)
    }

    @Test("Doses whose windows (individual and any synergy) have all expired -> no active window")
    func fullyExpiredDosesReturnNil() {
        // Spaced beyond the 24h pairing horizon (no synergy window exists):
        // benzo ends at t0+12h; opioid dosed t0+30h ends at t0+38h.
        let doses = [dose(.benzodiazepine, at: 0), dose(.opioidIR, at: hours(30))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(40)))
        #expect(window == nil)
    }

    @Test("A benzo+opioid pair within the horizon whose synergy window has itself expired -> nil")
    func expiredSynergyPairReturnsNil() {
        // Pairs (2h apart); synergy expiry is t0+26h, the max of everything.
        // At t0+27h even the synergy window is over: nil, synergy included.
        let doses = [dose(.benzodiazepine, at: 0), dose(.opioidIR, at: hours(2))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(27)))
        #expect(window == nil)
    }

    // MARK: - Future-timestamped doses (clock skew / forward backdating)

    /// A dose logged with a timestamp AFTER `now` still produces its window,
    /// computed identically to any other dose (`timestamp + classWindow`).
    /// This is the simplest rule and the one that can never under-monitor;
    /// see the doc comment on `DoseWindowGate.activeWindow` for the full
    /// rationale.
    @Test("A future-timestamped dose still produces its window, active immediately")
    func futureTimestampedDoseStillProducesItsWindow() {
        let doses = [dose(.benzodiazepine, at: hours(5))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0)
        #expect(window?.expiry == t0.addingTimeInterval(hours(17)))
        #expect(window?.synergyActive == false)
    }
}
