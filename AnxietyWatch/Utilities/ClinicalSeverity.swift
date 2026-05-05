import SwiftUI

/// Clinical severity classification for overnight respiratory and glucose
/// metrics. Pure-function thresholds drawn from standard sleep-medicine and
/// glycemic-variability guidelines. Used by the Dashboard, Trends, CPAP
/// Detail, and PDF Report for consistent color cues.
enum ClinicalSeverity {
    enum Severity: Sendable, Equatable {
        case normal, mild, moderate, severe

        var color: Color {
            switch self {
            case .normal: return .green
            case .mild: return .yellow
            case .moderate: return .orange
            case .severe: return .red
            }
        }
    }

    /// CPAP AHI (events/hr) — AASM bands: <5 normal · 5–<15 mild · 15–<30
    /// moderate · ≥30 severe. Single source of truth for the AHI color
    /// ladder used by CPAPDetailView, CPAPListView, and the
    /// SleepRespiratoryTrendChart's bar coloring.
    static func ahiSeverity(_ ahi: Double) -> Severity {
        switch ahi {
        case ..<5: return .normal
        case 5..<15: return .mild
        case 15..<30: return .moderate
        default: return .severe
        }
    }

    /// SpO₂ nadir overnight (%): ≥95 normal · 90–94 mild · 85–89 moderate · <85 severe.
    static func spo2NadirSeverity(_ percent: Double) -> Severity {
        switch percent {
        case 95...: return .normal
        case 90..<95: return .mild
        case 85..<90: return .moderate
        default: return .severe
        }
    }

    /// T90 minutes: 0 normal · 1–5 mild · 6–30 moderate · >30 severe.
    static func t90Severity(_ minutes: Int) -> Severity {
        switch minutes {
        case 0: return .normal
        case 1...5: return .mild
        case 6...30: return .moderate
        default: return .severe
        }
    }

    /// Desat events per night: <5 normal · 5–15 mild · 16–30 moderate · >30 severe.
    static func desatCountSeverity(_ count: Int) -> Severity {
        switch count {
        case ..<5: return .normal
        case 5...15: return .mild
        case 16...30: return .moderate
        default: return .severe
        }
    }

    /// Glucose coefficient of variation (%): <36 normal · 36–50 mild · >50 severe.
    /// No `moderate` band — clinical convention has only stable / unstable.
    static func glucoseCVSeverity(_ percent: Double) -> Severity {
        switch percent {
        case ..<36: return .normal
        case 36...50: return .mild
        default: return .severe
        }
    }

    /// Glucose reading (mg/dL): 70–180 normal · <70 or 180–250 mild · >250 severe.
    static func glucoseValueSeverity(_ mgdL: Double) -> Severity {
        if mgdL >= 70, mgdL <= 180 { return .normal }
        if mgdL > 250 { return .severe }
        return .mild
    }
}
