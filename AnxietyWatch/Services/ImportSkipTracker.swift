import Foundation

/// Accumulates skip diagnostics during a CSV import. Caps stored warnings at
/// `cap` and appends an "... and N more" line when the total exceeds the cap,
/// so a CSV with hundreds of bad rows produces a bounded message list.
///
/// Shared across CSV importers (CPAP simple, OSCAR, EMAY) so warning shape and
/// cap behavior stay identical regardless of source format.
struct ImportSkipTracker {
    private(set) var count = 0
    private var collected: [String] = []
    private static let cap = 5

    mutating func record(row: Int, reason: String) {
        count += 1
        if collected.count < Self.cap {
            collected.append("Row \(row): \(reason)")
        }
    }

    var warnings: [String] {
        guard count > Self.cap else { return collected }
        return collected + ["... and \(count - Self.cap) more"]
    }
}
