import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for `ExportDateRange` — the whole-day normalization behind the
/// date-only export picker (F-044). The picker shows calendar days, but its
/// bound `Date`s carry the time-of-day current when the sheet opened, so
/// filtering against the raw instants silently dropped same-day records logged
/// later in the day.
struct ExportDateRangeTests {

    private let cal = Calendar.current
    private var day: Date { cal.date(from: DateComponents(year: 2024, month: 4, day: 1))! }

    @Test("lowerBound is the start of the selected start day")
    func lowerBoundIsStartOfDay() {
        let seededStart = cal.date(byAdding: .hour, value: 10, to: day)! // sheet opened 10 AM
        let lower = ExportDateRange.lowerBound(for: seededStart)
        #expect(lower == cal.startOfDay(for: day))

        // A record earlier that same day (before the seeded 10 AM instant) is
        // in range under the normalized lower bound but would have been
        // excluded by `>= seededStart`.
        let earlySameDay = cal.date(byAdding: .hour, value: 2, to: day)!
        #expect(earlySameDay >= lower)
        #expect(earlySameDay < seededStart)
    }

    @Test("upperBoundExclusive is the start of the day after the selected end day")
    func upperBoundIsStartOfNextDay() {
        let seededEnd = cal.date(byAdding: .hour, value: 10, to: day)! // sheet opened 10 AM
        let upper = ExportDateRange.upperBoundExclusive(for: seededEnd)
        let nextMidnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day))!
        #expect(upper == nextMidnight)

        // A late same-day record (8 PM) is in range — this is the F-044 bug:
        // filtering with the raw 10 AM instant would have excluded it.
        let lateSameDay = cal.date(byAdding: .hour, value: 20, to: day)!
        #expect(lateSameDay < upper)
        #expect(lateSameDay > seededEnd)

        // A record at the following midnight is out of range.
        #expect(!(nextMidnight < upper))
    }

    @Test("Late same-day record is included in the JSON export range (F-044)")
    func lateSameDayRecordExported() throws {
        let seededEnd = cal.date(byAdding: .hour, value: 10, to: day)! // sheet opened 10 AM
        let lateEntry = cal.date(byAdding: .hour, value: 20, to: day)! // logged 8 PM

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        context.insert(AnxietyEntry(timestamp: lateEntry, severity: 6))
        try context.save()

        let data = try DataExporter.exportJSON(
            from: context,
            start: ExportDateRange.lowerBound(for: day),
            end: ExportDateRange.upperBoundExclusive(for: seededEnd)
        )
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["anxietyEntries"] as? [Any])?.count == 1)

        // Regression guard: exporting against the raw seeded end instant drops it.
        let dropped = try DataExporter.exportJSON(from: context, start: day, end: seededEnd)
        let droppedJSON = try #require(try JSONSerialization.jsonObject(with: dropped) as? [String: Any])
        #expect((droppedJSON["anxietyEntries"] as? [Any])?.isEmpty == true)
    }

    @Test("upperBoundExclusive is DST-safe (spring-forward day still spans a full day)")
    func upperBoundHandlesDST() {
        // 2024-03-10 is US spring-forward (23-hour day). start-of-next-day must
        // still land on 2024-03-11 00:00, not 23:00 of the same day.
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstDay = pacific.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 9))!
        let upper = ExportDateRange.upperBoundExclusive(for: dstDay, calendar: pacific)
        let expected = pacific.date(from: DateComponents(year: 2024, month: 3, day: 11))!
        #expect(upper == expected)
    }
}
