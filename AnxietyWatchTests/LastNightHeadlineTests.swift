import Foundation
import Testing
@testable import AnxietyWatch

struct LastNightHeadlineTests {

    @Test("Clean night (eff >= 85, AHI < 5, nadir >= 92) → Solid night")
    func solid() {
        let h = LastNightHeadline.compose(efficiencyPct: 92, ahi: 3.1, nadirPct: 94)
        #expect(h.verdict == "Solid night")
        #expect(h.text.contains("92%"))
        #expect(h.text.contains("3.1"))
    }

    @Test("One breach (AHI > 5) → OK")
    func okOneBreach() {
        let h = LastNightHeadline.compose(efficiencyPct: 90, ahi: 6.1, nadirPct: 94)
        #expect(h.verdict == "OK")
    }

    @Test("Two+ breaches → Rough night")
    func rough() {
        let h = LastNightHeadline.compose(efficiencyPct: 70, ahi: 6.1, nadirPct: 87)
        #expect(h.verdict == "Rough night")
    }

    @Test("Missing nadir is omitted from headline gracefully")
    func missingNadir() {
        let h = LastNightHeadline.compose(efficiencyPct: 88, ahi: 3.5, nadirPct: nil)
        #expect(!h.text.contains("nadir"))
    }

    @Test("Missing AHI omits CPAP clause")
    func missingAHI() {
        let h = LastNightHeadline.compose(efficiencyPct: 88, ahi: nil, nadirPct: 95)
        #expect(!h.text.contains("AHI"))
    }

    @Test("Estimated efficiency gets a ~ prefix so a pinned 100% can't read as measured")
    func estimatedEfficiencyMarked() {
        let h = LastNightHeadline.compose(efficiencyPct: 100, efficiencyEstimated: true, ahi: 3.0, nadirPct: 94)
        #expect(h.text.contains("~100%"))
    }

    @Test("Measured efficiency has no ~ prefix")
    func measuredEfficiencyUnmarked() {
        let h = LastNightHeadline.compose(efficiencyPct: 92, efficiencyEstimated: false, ahi: 3.0, nadirPct: 94)
        #expect(!h.text.contains("~"))
    }

    // F-024: a pinned-to-100% estimated efficiency is not a measurement.
    // It must not certify a "Solid night" — the pin exists precisely because
    // the real efficiency is unknown and could have been poor.
    @Test("Estimated efficiency with otherwise-clean night caps the verdict at OK")
    func estimatedEfficiencyCapsVerdictAtOK() {
        let h = LastNightHeadline.compose(efficiencyPct: 100, efficiencyEstimated: true, ahi: 3.0, nadirPct: 94)
        #expect(h.verdict == "OK")
        #expect(h.text.contains("~100%"))
    }

    @Test("Estimated efficiency does not add a breach on top of real breaches")
    func estimatedEfficiencyNotCountedAsBreach() {
        // One real breach (AHI). The estimated efficiency must neither hide
        // it (verdict stays OK, not Solid) nor inflate it to Rough.
        let h = LastNightHeadline.compose(efficiencyPct: 100, efficiencyEstimated: true, ahi: 6.5, nadirPct: 94)
        #expect(h.verdict == "OK")
    }

    @Test("Measured sub-85% efficiency still breaches")
    func measuredLowEfficiencyBreaches() {
        let h = LastNightHeadline.compose(efficiencyPct: 80, efficiencyEstimated: false, ahi: 3.0, nadirPct: 94)
        #expect(h.verdict == "OK")
    }

    // F-094: an EDF-only night has real CPAP usage but no scored AHI (nil).
    // An unknown AHI must not certify a "Solid night" — it could have been
    // severe. It caps the verdict at OK, mirroring the estimated-efficiency
    // rule, and is never coerced to 0 (which would have breached at >= 5).
    @Test("Unknown AHI with otherwise-clean night caps the verdict at OK")
    func unknownAHICapsVerdictAtOK() {
        let h = LastNightHeadline.compose(efficiencyPct: 92, efficiencyEstimated: false, ahi: nil, nadirPct: 94)
        #expect(h.verdict == "OK")
        #expect(!h.text.contains("AHI"))
    }

    @Test("Unknown AHI does not add a breach on top of a real breach")
    func unknownAHINotCountedAsBreach() {
        // One real breach (nadir < 92). Unknown AHI must neither hide it nor
        // inflate a single breach to Rough.
        let h = LastNightHeadline.compose(efficiencyPct: 92, efficiencyEstimated: false, ahi: nil, nadirPct: 87)
        #expect(h.verdict == "OK")
    }
}
