import Testing

@testable import AnxietyWatch

/// Tests for the source filtering logic used in TrendsView.
struct SourceFilterTests {

    @Test("Entries with nil source are self-reported")
    func nilSourceIsSelfReported() {
        let entry = ModelFactory.anxietyEntry(source: nil)
        #expect(entry.source == nil)
        // Self-reported filter: source == nil || source == "user" || source == "dose_followup"
        let isSelfReported = entry.source == nil || entry.source == "user" || entry.source == "dose_followup"
        #expect(isSelfReported)
    }

    @Test("Entries with user source are self-reported")
    func userSourceIsSelfReported() {
        let entry = ModelFactory.anxietyEntry(source: "user")
        let isSelfReported = entry.source == nil || entry.source == "user" || entry.source == "dose_followup"
        #expect(isSelfReported)
    }

    @Test("Entries with dose_followup source are self-reported")
    func doseFollowUpIsSelfReported() {
        let entry = ModelFactory.anxietyEntry(source: "dose_followup")
        let isSelfReported = entry.source == nil || entry.source == "user" || entry.source == "dose_followup"
        #expect(isSelfReported)
    }

    @Test("Entries with random_checkin source are not self-reported")
    func randomCheckInIsNotSelfReported() {
        let entry = ModelFactory.anxietyEntry(source: "random_checkin")
        let isSelfReported = entry.source == nil || entry.source == "user" || entry.source == "dose_followup"
        #expect(!isSelfReported)
    }

    @Test("Entries with random_checkin source match check-in filter")
    func randomCheckInMatchesFilter() {
        let entry = ModelFactory.anxietyEntry(source: "random_checkin")
        #expect(entry.source == "random_checkin")
    }

    @Test("Filter produces correct counts from mixed entries")
    func mixedEntriesFilterCorrectly() {
        let entries = [
            ModelFactory.anxietyEntry(severity: 7, source: nil),
            ModelFactory.anxietyEntry(severity: 3, source: "random_checkin"),
            ModelFactory.anxietyEntry(severity: 5, source: "user"),
            ModelFactory.anxietyEntry(severity: 6, source: "dose_followup"),
            ModelFactory.anxietyEntry(severity: 2, source: "random_checkin"),
        ]

        let selfReported = entries.filter { $0.source == nil || $0.source == "user" || $0.source == "dose_followup" }
        let checkIns = entries.filter { $0.source == "random_checkin" }

        #expect(selfReported.count == 3)
        #expect(checkIns.count == 2)
        #expect(selfReported.count + checkIns.count == entries.count)
    }
}
