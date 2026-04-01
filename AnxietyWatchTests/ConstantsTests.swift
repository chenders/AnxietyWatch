import Testing

@testable import AnxietyWatch

/// Contract tests for Constants — ensures that key values used across the app
/// stay consistent. These tests catch silent breakage if a constant is changed
/// without updating dependent code.
struct ConstantsTests {

    @Test("Baseline window is 30 days")
    func baselineWindow() {
        #expect(Constants.baselineWindowDays == 30)
    }

    @Test("Deviation threshold is 1.0 standard deviations")
    func deviationThreshold() {
        #expect(Constants.deviationThreshold == 1.0)
    }

    @Test("Journal context window is 60 minutes")
    func journalContextWindow() {
        #expect(Constants.journalContextWindowMinutes == 60)
    }

    @Test("Default severity is 5")
    func defaultSeverity() {
        #expect(Constants.defaultSeverity == 5)
    }

    @Test("Severity range is 1 through 10")
    func severityRange() {
        #expect(Constants.severityRange == 1...10)
        #expect(Constants.severityRange.lowerBound == 1)
        #expect(Constants.severityRange.upperBound == 10)
    }

    @Test("Default severity is within severity range")
    func defaultSeverityInRange() {
        #expect(Constants.severityRange.contains(Constants.defaultSeverity))
    }
}
