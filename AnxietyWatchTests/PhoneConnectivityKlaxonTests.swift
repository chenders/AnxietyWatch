import Testing
@testable import AnxietyWatch

struct PhoneConnectivityKlaxonTests {
    @Test("Klaxon haptic payload uses the typed message marker")
    func klaxonPayload() {
        let payload = PhoneConnectivityManager.klaxonHapticPayload()

        #expect(payload.count == 1)
        #expect(payload["type"] as? String == "cnsKlaxonHaptic")
    }
}
