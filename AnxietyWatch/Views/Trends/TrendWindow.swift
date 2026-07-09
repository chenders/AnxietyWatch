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
            if periodDays == 1 {
                // A rolling 24 hours, not startOfDay(yesterday): the day-
                // aligned formula would make "1D" silently span up to ~48h
                // (at 11 PM it covers nearly two full days with no visible
                // cue). Multi-day presets keep day alignment — sub-day fuzz
                // is negligible at 7+ days.
                self.start = now.addingTimeInterval(-24 * 3600)
            } else {
                self.start = calendar.startOfDay(
                    for: calendar.date(byAdding: .day, value: -periodDays, to: now)!
                )
            }
        } else {
            // Past periods are snapped to day boundaries for clean, non-overlapping windows.
            let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
            let end = calendar.date(byAdding: .day, value: pageOffset * periodDays, to: tomorrow)!
            self.end = end
            self.start = calendar.date(byAdding: .day, value: -periodDays, to: end)!
        }
    }

    /// Explicit user-picked range (the "Custom" mode). Paging shifts by the
    /// range's own duration so the chevrons/swipes walk event-sized windows
    /// instead of fixed weeks. A degenerate range (end at or before start)
    /// is normalized to one hour so window math can never page by a
    /// zero/negative length.
    init(customStart: Date, customEnd: Date, pageOffset: Int) {
        let safeEnd = customEnd > customStart ? customEnd : customStart.addingTimeInterval(3600)
        let shift = Double(pageOffset) * safeEnd.timeIntervalSince(customStart)
        self.start = customStart.addingTimeInterval(shift)
        self.end = safeEnd.addingTimeInterval(shift)
    }

    /// Inclusive chart-domain end for a fixed-preset window. Past multi-day
    /// pages map their exclusive-midnight end to the inclusive last day; a
    /// one-day window (and any current window) keeps its exact end —
    /// subtracting a day from a 1-day past page would collapse the chart's
    /// x-domain to zero width and break every chart's x-scale.
    func chartEnd(isCurrentPeriod: Bool, periodDays: Int) -> Date {
        guard !isCurrentPeriod, periodDays > 1 else { return end }
        return Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
    }
}
