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
        if pageOffset == 0 {
            // Current period ends at "now" so the chart's right edge is the present moment.
            self.end = now
            self.start = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -periodDays, to: now)!
            )
        } else {
            // Past periods are snapped to day boundaries for clean, non-overlapping windows.
            let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
            let end = calendar.date(byAdding: .day, value: pageOffset * periodDays, to: tomorrow)!
            self.end = end
            self.start = calendar.date(byAdding: .day, value: -periodDays, to: end)!
        }
    }
}
