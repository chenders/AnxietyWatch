import Testing
@testable import AnxietyWatchKit

@Test("Umbrella exposes the redesign version")
func umbrellaVersion() {
    #expect(AnxietyWatchKit.version == "0.1.0-redesign")
}