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
}
