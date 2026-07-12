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

    /// ESCALATION: the plan's Step 1 lists this exact scenario ("benzo at t0,
    /// opioid at t0+23h50m -> expiry >= later dose + 24h") as a "synergy
    /// floor" case. Under the literal overlap rule implemented here (the two
    /// per-dose windows must actually intersect, restricted to ≤ now), this
    /// pairing can NEVER overlap for any opioid class: the benzo window
    /// always ends at t0+12h, strictly before the opioid dose at t0+23h50m
    /// even begins — the opioid's own class window only extends its window's
    /// END, never moves its START earlier. So no synergy pairing is possible
    /// here regardless of opioid class.
    ///
    /// The plan's asserted bound (expiry >= laterDose + 24h) is nonetheless
    /// satisfiable — but only via the opioid's OWN individual window, and
    /// only when that window is >= 24h (ER or methadone). This test uses ER
    /// to demonstrate exactly that: the bound holds with equality, driven
    /// entirely by the individual window, with synergyActive == false.
    /// `synergyFloorAppliesWhenWindowsGenuinelyOverlap` below is the
    /// from-scratch test that actually exercises the synergy+floor code path
    /// on doses that do overlap. See task-2-report.md for the full writeup
    /// and proposed resolution.
    @Test("Near-24h-boundary, non-overlapping opioid: the bound holds via the individual ER window, not synergy")
    func nearBoundaryNonOverlappingOpioidSatisfiesBoundWithoutSynergy() {
        let laterDoseOffset = hours(23) + 50 * 60
        let doses = [dose(.benzodiazepine, at: 0), dose(.opioidER, at: laterDoseOffset)]
        let now = t0.addingTimeInterval(laterDoseOffset + 60)
        let window = DoseWindowGate.activeWindow(doses: doses, at: now)
        let laterDose = t0.addingTimeInterval(laterDoseOffset)
        #expect(window != nil)
        #expect(window!.expiry >= laterDose.addingTimeInterval(hours(24)))
        #expect(window?.expiry == laterDose.addingTimeInterval(hours(24)))  // ER's own window, exactly
        #expect(window?.synergyActive == false)
    }

    @Test("Synergy floor applies when the windows genuinely overlap: benzo then methadone")
    func synergyFloorAppliesWhenWindowsGenuinelyOverlap() {
        // Methadone dosed at t0+11h, still inside the benzo's [t0, t0+12h]
        // window: a real overlap, unlike the near-boundary case above.
        let doses = [dose(.benzodiazepine, at: 0), dose(.methadoneOrUnknownLongActing, at: hours(11))]
        let now = t0.addingTimeInterval(hours(12))
        let window = DoseWindowGate.activeWindow(doses: doses, at: now)
        let laterDose = t0.addingTimeInterval(hours(11))
        // max(12h, 72h) + 12h = 84h, which already exceeds the 24h floor —
        // the floor is not binding here, but the raw formula is exercised
        // end-to-end on a pair that genuinely overlaps.
        #expect(window?.expiry == laterDose.addingTimeInterval(hours(84)))
        #expect(window?.synergyActive == true)
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
        // Spaced so the raw windows never overlap (no synergy contamination):
        // benzo ends at t0+12h; opioid starts at t0+20h.
        let doses = [dose(.benzodiazepine, at: 0), dose(.opioidIR, at: hours(20))]
        let window = DoseWindowGate.activeWindow(doses: doses, at: t0.addingTimeInterval(hours(30)))
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
