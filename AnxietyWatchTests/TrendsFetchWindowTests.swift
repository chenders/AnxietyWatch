// AnxietyWatchTests/TrendsFetchWindowTests.swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Regression coverage for the window-scoped Trends fetches.
///
/// `TrendsView` used to hold these three tables as predicate-less whole-table
/// `@Query`s and narrow them in `body`. That made every insert into any of the
/// tables re-run a full fetch + sort on the main thread; iOS killed the app for
/// it three times in July 2026 (`AnxietyWatch.cpu_resource_fatal`, 91–96% CPU
/// sustained for ~50s). These tests exercise the PRODUCTION predicates, so they
/// fail if anyone re-widens the bounds or breaks the day-floor superset rule.
struct TrendsFetchWindowTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AnxietyEntry.self,
            CPAPSession.self,
            BarometricReading.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Fixed UTC calendar so the day-floor assertions can't drift with the
    /// machine's timezone or a DST boundary.
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 2023-11-14 00:00:00 UTC — a clean midnight to anchor day math on.
    private var dayStart: Date {
        utc.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func makeCPAP(date: Date) -> CPAPSession {
        CPAPSession(
            date: date,
            ahi: 3.0,
            totalUsageMinutes: 420,
            pressureMin: 6,
            pressureMax: 14,
            pressureMean: 9,
            obstructiveEvents: 1,
            centralEvents: 0,
            hypopneaEvents: 2,
            importSource: "test"
        )
    }

    // MARK: - Bounding actually excludes out-of-window rows

    @Test("Entry fetch excludes rows outside the window on both edges")
    @MainActor
    func entriesAreBounded() throws {
        let context = ModelContext(try makeContainer())
        let start = dayStart
        let end = dayStart.addingTimeInterval(24 * 3600)

        context.insert(AnxietyEntry(timestamp: start.addingTimeInterval(-1), severity: 1))
        context.insert(AnxietyEntry(timestamp: start.addingTimeInterval(3600), severity: 2))
        context.insert(AnxietyEntry(timestamp: end.addingTimeInterval(1), severity: 3))
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<AnxietyEntry>(
                predicate: TrendsFetchWindow.entries(windowStart: start, windowEnd: end)
            )
        )
        #expect(fetched.count == 1)
        #expect(fetched.first?.severity == 2)
    }

    @Test("Barometric fetch excludes rows outside the window on both edges")
    @MainActor
    func barometricIsBounded() throws {
        let context = ModelContext(try makeContainer())
        let start = dayStart
        let end = dayStart.addingTimeInterval(24 * 3600)

        context.insert(BarometricReading(timestamp: start.addingTimeInterval(-1), pressureKPa: 100, relativeAltitudeM: 0))
        context.insert(BarometricReading(timestamp: start.addingTimeInterval(60), pressureKPa: 101, relativeAltitudeM: 1))
        context.insert(BarometricReading(timestamp: end.addingTimeInterval(1), pressureKPa: 102, relativeAltitudeM: 2))
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<BarometricReading>(
                predicate: TrendsFetchWindow.barometric(windowStart: start, windowEnd: end)
            )
        )
        #expect(fetched.count == 1)
        #expect(abs((fetched.first?.pressureKPa ?? 0) - 101) < 0.001)
    }

    // MARK: - Boundary instants are inclusive

    @Test("Rows sitting exactly on the window edges are included")
    @MainActor
    func windowEdgesAreInclusive() throws {
        let context = ModelContext(try makeContainer())
        let start = dayStart
        let end = dayStart.addingTimeInterval(24 * 3600)

        context.insert(AnxietyEntry(timestamp: start, severity: 1))
        context.insert(AnxietyEntry(timestamp: end, severity: 2))
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<AnxietyEntry>(
                predicate: TrendsFetchWindow.entries(windowStart: start, windowEnd: end)
            )
        )
        // `TrendsView.inWindow` includes the end instant for the active page,
        // so the fetch must not be narrower than that in-memory filter.
        #expect(fetched.count == 2)
    }

    // MARK: - Day floor (the superset rule)

    @Test("dayFloor returns the start of the window's first calendar day")
    func dayFloorFloorsToMidnight() {
        let midAfternoon = dayStart.addingTimeInterval(14 * 3600)
        #expect(TrendsFetchWindow.dayFloor(for: midAfternoon, calendar: utc) == dayStart)
    }

    @Test("CPAP fetch keeps midnight-normalized rows for a window starting mid-day")
    @MainActor
    func cpapFetchCoversWholeFirstDay() throws {
        let context = ModelContext(try makeContainer())
        // `CPAPSession.init` normalizes `date` with `Calendar.current`
        // (Models/CPAPSession.swift), and the production predicate defaults to
        // that same calendar. Both sides must therefore use `.current` here —
        // pinning the predicate to UTC while the model stores LOCAL midnight
        // compares two different day boundaries and fails everywhere except
        // a UTC machine. Day arithmetic goes through Calendar, not 86400, so
        // a DST transition inside the window can't shift the boundaries.
        let cal = Calendar.current
        let day0 = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let day1 = try #require(cal.date(byAdding: .day, value: 1, to: day0))
        let dayBefore = try #require(cal.date(byAdding: .day, value: -1, to: day0))
        // A 2 PM start is the case a naive bound breaks: that day's session row
        // is stamped at midnight, i.e. BEFORE windowStart.
        let start = try #require(cal.date(byAdding: .hour, value: 14, to: day0))
        let end = try #require(cal.date(byAdding: .day, value: 2, to: day0))

        context.insert(makeCPAP(date: day0))
        context.insert(makeCPAP(date: day1))
        context.insert(makeCPAP(date: dayBefore))
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<CPAPSession>(
                predicate: TrendsFetchWindow.cpapSessions(
                    windowStart: start, windowEnd: end, calendar: cal
                )
            )
        )
        // Both in-window days survive; the prior day does not.
        #expect(fetched.count == 2)
        #expect(fetched.allSatisfy { $0.date >= day0 })
    }

    // MARK: - Bound snapping

    /// A bucket-aligned instant, so "same bucket" below is unambiguous.
    private var alignedBase: Date {
        Date(timeIntervalSinceReferenceDate: 700_000_020)
    }

    @Test("Instants inside one bucket snap to identical bounds")
    func snappingIsStableWithinBucket() {
        // Two body evaluations a fraction of a minute apart — what a
        // `.now`-anchored window produces on consecutive renders. If these
        // diverged, @Query would re-fetch on every render and the whole
        // window-scoping split would buy nothing.
        let firstRender = alignedBase.addingTimeInterval(12.25)
        let secondRender = alignedBase.addingTimeInterval(47.80)

        #expect(TrendsFetchWindow.snapDown(firstRender) == TrendsFetchWindow.snapDown(secondRender))
        #expect(TrendsFetchWindow.snapUp(firstRender) == TrendsFetchWindow.snapUp(secondRender))
    }

    @Test("Snapping only ever widens the window")
    func snappingOnlyWidens() {
        let midBucket = alignedBase.addingTimeInterval(12.4)
        #expect(TrendsFetchWindow.snapDown(midBucket) <= midBucket)
        #expect(TrendsFetchWindow.snapUp(midBucket) >= midBucket)
        // Already-aligned instants must not be widened by a whole bucket.
        #expect(TrendsFetchWindow.snapDown(alignedBase) == alignedBase)
        #expect(TrendsFetchWindow.snapUp(alignedBase) == alignedBase)
    }

    @Test("Snapped bounds still return rows sitting on the exact window edges")
    @MainActor
    func snappedBoundsStillCoverExactEdges() throws {
        let context = ModelContext(try makeContainer())
        // Deliberately mid-bucket, as a `.now`-anchored window would be.
        let start = alignedBase.addingTimeInterval(37.4)
        let end = start.addingTimeInterval(3600)

        context.insert(AnxietyEntry(timestamp: start, severity: 1))
        context.insert(AnxietyEntry(timestamp: end, severity: 2))
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<AnxietyEntry>(
                predicate: TrendsFetchWindow.entries(windowStart: start, windowEnd: end)
            )
        )
        // Snapping widens, so the exact edges must survive — the in-memory
        // filter in `charts(...)` is what trims back to the precise window.
        #expect(fetched.count == 2)
    }
}
