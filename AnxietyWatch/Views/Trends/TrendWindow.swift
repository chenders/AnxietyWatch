import Foundation

/// Pure date-math for the navigable trend chart window.
/// Extracted from TrendsView so it can be unit-tested without SwiftUI.
struct TrendWindow {
    let start: Date
    let end: Date

    /// - Parameters:
    ///   - now: The reference "now" time.
    ///   - periodDays: Window width in days (7, 30, 90).
    ///   - pageOffset: 0 = current period, -1 = previous period, etc.
    init(now: Date, periodDays: Int, pageOffset: Int) {
        let calendar = Calendar.current
        // Snap to start-of-next-day so the rightmost day is fully included
        // (charts use unit: .day, so today's data point needs the full day in the domain).
        let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        let end = calendar.date(byAdding: .day, value: pageOffset * periodDays, to: tomorrow)!
        let start = calendar.date(byAdding: .day, value: -periodDays, to: end)!
        self.start = start
        self.end = end
    }
}
