import Foundation

enum Constants {
    /// Number of days for rolling baseline calculations
    static let baselineWindowDays = 30

    /// How many standard deviations from baseline triggers a flag
    static let deviationThreshold = 1.0

    /// Lookback window (minutes) for physiological context around journal entries
    static let journalContextWindowMinutes = 60

    /// Default severity for new journal entries
    static let defaultSeverity = 5

    /// Severity range
    static let severityRange = 1...10
}
