import Testing

@testable import AnxietyWatch

/// Tests for the source filtering logic used in TrendsView. These exercise the
/// PRODUCTION `TrendsView.filterBySource(_:filter:)` rather than re-implementing
/// the predicate inline (F-048) — so the nil-source back-compat invariant
/// (legacy rows have `source == nil` and must count as self-reported) is
/// genuinely protected by these tests.
struct SourceFilterTests {

    private func entries(_ sources: [String?]) -> [AnxietyEntry] {
        sources.map { ModelFactory.anxietyEntry(source: $0) }
    }

    @Test("Self-reported filter includes nil, user, and dose_followup sources")
    func selfReportedIncludesNilUserDoseFollowup() {
        let input = entries([nil, "user", "dose_followup", "random_checkin"])
        let result = TrendsView.filterBySource(input, filter: .selfReported)
        #expect(result.count == 3)
        #expect(result.allSatisfy {
            $0.source == nil || $0.source == "user" || $0.source == "dose_followup"
        })
    }

    @Test("nil-source (legacy) entry counts as self-reported")
    func nilSourceIsSelfReported() {
        let result = TrendsView.filterBySource(entries([nil]), filter: .selfReported)
        #expect(result.count == 1)
    }

    @Test("Check-ins filter matches only random_checkin")
    func checkInsMatchesOnlyRandomCheckin() {
        let input = entries([nil, "user", "random_checkin", "random_checkin", "dose_followup"])
        let result = TrendsView.filterBySource(input, filter: .checkIns)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.source == "random_checkin" })
    }

    @Test("All filter returns every entry unchanged")
    func allReturnsEverything() {
        let input = entries([nil, "user", "random_checkin", "dose_followup"])
        let result = TrendsView.filterBySource(input, filter: .all)
        #expect(result.count == input.count)
    }

    @Test("Self-reported and check-in partitions are disjoint and total the input")
    func partitionsAreDisjointAndComplete() {
        let input = entries([nil, "random_checkin", "user", "dose_followup", "random_checkin"])
        let selfReported = TrendsView.filterBySource(input, filter: .selfReported)
        let checkIns = TrendsView.filterBySource(input, filter: .checkIns)
        #expect(selfReported.count == 3)
        #expect(checkIns.count == 2)
        #expect(selfReported.count + checkIns.count == input.count)
    }
}
