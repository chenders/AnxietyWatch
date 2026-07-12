import Foundation
import Testing
@testable import AnxietyWatch

struct AlertsDeduperTests {

    @Test("Empty input → empty output")
    func emptyIn() {
        #expect(AlertsDeduper.collapse(alerts: []).isEmpty)
    }

    @Test("Single alert passes through with relatedCount 0")
    func single() {
        let a = DashboardAlert(id: "hrv", title: "HRV low", message: "",
                               severity: .warn, category: .autonomic, zScore: -2.0)
        let r = AlertsDeduper.collapse(alerts: [a])
        #expect(r.count == 1)
        #expect(r[0].relatedCount == 0)
    }

    @Test("Correlated autonomic alerts collapse to highest-|z| + related count")
    func collapseCorrelated() {
        let hrvLow = DashboardAlert(id: "hrv", title: "HRV", message: "",
                                    severity: .warn, category: .autonomic, zScore: -2.0)
        let rhrUp = DashboardAlert(id: "rhr", title: "RHR up", message: "",
                                   severity: .warn, category: .autonomic, zScore: 1.5)
        let r = AlertsDeduper.collapse(alerts: [hrvLow, rhrUp])
        #expect(r.count == 1)
        #expect(r[0].id == "hrv")
        #expect(r[0].relatedCount == 1)
    }
}
