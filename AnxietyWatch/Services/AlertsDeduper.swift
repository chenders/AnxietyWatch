import Foundation

/// One row in the rolled-up alerts strip.
struct DashboardAlert: Identifiable, Sendable {
    enum Severity: Sendable { case info, warn, critical }
    enum Category: Sendable { case autonomic, sleep, environment, supply }

    let id: String
    let title: String
    let message: String
    let severity: Severity
    let category: Category
    /// Signed z-score against personal baseline; 0 for non-statistical alerts (e.g., supply).
    let zScore: Double
    var relatedCount: Int = 0
}

extension DashboardAlert: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.message == rhs.message &&
        lhs.severity == rhs.severity &&
        lhs.category == rhs.category &&
        lhs.zScore == rhs.zScore &&
        lhs.relatedCount == rhs.relatedCount
    }
}

extension DashboardAlert.Severity: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.info, .info), (.warn, .warn), (.critical, .critical): return true
        default: return false
        }
    }
}

extension DashboardAlert.Category: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.autonomic, .autonomic), (.sleep, .sleep),
             (.environment, .environment), (.supply, .supply): return true
        default: return false
        }
    }
}

/// Collapses correlated alerts so the strip shows the strongest signal per
/// category plus a "+N related" chip. Supply alerts are always distinct.
nonisolated enum AlertsDeduper {
    static func collapse(alerts: [DashboardAlert]) -> [DashboardAlert] {
        // Canonical order — never derive order from a Set/Dictionary.
        // "Deterministic ordering" pitfall from CLAUDE.md.
        // Use filter-per-category to avoid Dictionary(grouping:) which
        // requires Hashable on Category (incompatible with nonisolated context
        // under SWIFT_TREAT_WARNINGS_AS_ERRORS=YES).
        let order: [DashboardAlert.Category] = [.supply, .autonomic, .sleep, .environment]
        return order.compactMap { cat -> DashboardAlert? in
            let bucket = alerts.filter { $0.category == cat }
            guard !bucket.isEmpty else { return nil }
            if cat == .supply {
                // Supply: pass through unchanged (no z-score ranking).
                // V1 assumption: at most one supply alert in the input.
                return bucket.first
            }
            let sorted = bucket.sorted { abs($0.zScore) > abs($1.zScore) }
            var top = sorted[0]
            top.relatedCount = sorted.count - 1
            return top
        }
    }
}
