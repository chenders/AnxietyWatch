import Foundation
import SwiftData

/// Fetch bounds for the three `TrendsView` tables whose only consumer is the
/// currently displayed window.
///
/// Extracted from `WindowedTrendTables` so the PRODUCTION predicates are the
/// ones under test — the same reason `TrendsView.filterBySource` is
/// `nonisolated static` (F-048). A test that re-implements a predicate proves
/// nothing about the query the app actually runs.
///
/// Every predicate here is a **two-clause `Date`-only** window. That shape is
/// safe from the iOS 26 SwiftData ORDER BY hang, which targets captured
/// non-primitive locals (`String`, `UUID`) — see `CPAPDetailView` for the same
/// documented pattern. **Do not add a `String` clause to any of these**: that
/// is exactly the F-030 shape that hangs the main thread during SQL ORDER BY
/// generation, and it is why `TrendsView`'s `source`-filtered queries are
/// deliberately left unbounded instead of being windowed here.
enum TrendsFetchWindow {
    /// Bucket that fetch bounds are snapped to before they reach a
    /// `#Predicate`.
    ///
    /// This exists because the current period's window is `.now`-anchored:
    /// `TrendWindow.init(now:periodDays:pageOffset:)` sets `end = now` (and,
    /// for the 1D preset, `start = now - 24h`) with sub-second precision. A
    /// `@Query` cannot prove two `#Predicate` closures are semantically equal,
    /// so it re-runs its fetch whenever a captured value differs — and a
    /// `.now`-derived `Date` differs on *every* body evaluation. Without
    /// snapping, any re-render caused by the tables still queried whole
    /// (`allSnapshots`, the source-filtered three) would rebuild these
    /// descriptors and re-fetch, which is the same continuous fetch loop this
    /// type exists to stop — just at windowed row counts instead of whole-table
    /// ones. Snapping collapses every render inside the same minute onto one
    /// identical bound, so the fetch re-runs at most once a minute.
    static let boundGranularity: TimeInterval = 60

    /// Snaps *down*. Always widens the window, so the fetch stays a superset
    /// of the exact in-memory filter in `TrendsView.charts(...)`.
    static func snapDown(_ date: Date, granularity: TimeInterval = boundGranularity) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / granularity).rounded(.down) * granularity)
    }

    /// Snaps *up*. Always widens the window — same superset rule as `snapDown`.
    static func snapUp(_ date: Date, granularity: TimeInterval = boundGranularity) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / granularity).rounded(.up) * granularity)
    }

    /// Floor for midnight-normalized rows (`CPAPSession.date`).
    ///
    /// `TrendsView`'s custom-window path widens day-granular series to whole
    /// calendar days (`dayWindow`, which starts at `startOfDay(window.start)`).
    /// Flooring here keeps the fetch a superset of that in-memory filter — a
    /// fetch bounded at the raw window instant would drop the first day's rows
    /// for any window starting after midnight.
    static func dayFloor(for windowStart: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: windowStart)
    }

    static func entries(windowStart: Date, windowEnd: Date) -> Predicate<AnxietyEntry> {
        let lower = snapDown(windowStart)
        let upper = snapUp(windowEnd)
        return #Predicate<AnxietyEntry> { $0.timestamp >= lower && $0.timestamp <= upper }
    }

    static func cpapSessions(
        windowStart: Date,
        windowEnd: Date,
        calendar: Calendar = .current
    ) -> Predicate<CPAPSession> {
        // The lower bound is already day-stable, so only the `.now`-anchored
        // upper bound needs snapping.
        let floor = dayFloor(for: windowStart, calendar: calendar)
        let upper = snapUp(windowEnd)
        return #Predicate<CPAPSession> { $0.date >= floor && $0.date <= upper }
    }

    static func barometric(windowStart: Date, windowEnd: Date) -> Predicate<BarometricReading> {
        let lower = snapDown(windowStart)
        let upper = snapUp(windowEnd)
        return #Predicate<BarometricReading> { $0.timestamp >= lower && $0.timestamp <= upper }
    }

    static func hrvReadings(windowStart: Date, windowEnd: Date) -> Predicate<HRVReading> {
        // Widened by 24h so overnight sessions spanning the window bounds 
        // have their full row set available for LFHFAggregator.
        let lower = snapDown(windowStart.addingTimeInterval(-24 * 3600))
        let upper = snapUp(windowEnd.addingTimeInterval(24 * 3600))
        return #Predicate<HRVReading> { $0.timestamp >= lower && $0.timestamp <= upper }
    }

    static func sensorSessions(windowStart: Date, windowEnd: Date) -> Predicate<SensorSession> {
        let lower = snapDown(windowStart.addingTimeInterval(-24 * 3600))
        let upper = snapUp(windowEnd.addingTimeInterval(24 * 3600))
        return #Predicate<SensorSession> { $0.startTime >= lower && $0.startTime <= upper }
    }

    static func liveOximeterSamples(windowStart: Date, windowEnd: Date) -> Predicate<QuantityHealthSample> {
        let lower = snapDown(windowStart)
        let upper = snapUp(windowEnd)
        return #Predicate<QuantityHealthSample> { $0.timestamp >= lower && $0.timestamp <= upper }
    }
}
