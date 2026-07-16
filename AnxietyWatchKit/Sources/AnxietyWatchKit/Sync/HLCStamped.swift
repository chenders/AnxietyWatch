import Foundation

/// Compact value carrying a Hybrid Logical Clock timestamp: (physical_ms, logical_counter, node_id).
/// Used by every row-shaped type in AnxietyWatchKit so HLC concerns don't scatter into
/// three separate init args across the codebase.
public struct HLCStamped: Sendable, Hashable, Codable {
    /// Milliseconds since Unix epoch. Always >= 0. Encoded as SQLite INTEGER.
    public let physical: Int64
    /// Monotonically increasing counter within a single physical millisecond.
    public let logical: Int32
    /// 16 raw bytes derived from `UUID.uuid` (NOT the 36-byte `uuidString`).
    /// Produce via `withUnsafeBytes(of: UUID().uuid) { Data($0) }`.
    /// The type is width-agnostic (Data), but every producer in the codebase
    /// must honor 16 bytes so wire framing (§5.1) and HK/Keychain loaders
    /// (§2.1) do not silently truncate or misframe.
    public let nodeID: Data

    public init(physical: Int64, logical: Int32, nodeID: Data) {
        self.physical = physical
        self.logical = logical
        self.nodeID = nodeID
    }
}

extension HLCStamped: Comparable {
    /// Lexicographic (physical, logical) order. node_id is a tiebreaker only for
    /// wire-format determinism, not causal ordering; a full HLC comparator must be
    /// used for causal comparisons (see HLC service, T13).
    public static func < (lhs: HLCStamped, rhs: HLCStamped) -> Bool {
        if lhs.physical != rhs.physical { return lhs.physical < rhs.physical }
        if lhs.logical  != rhs.logical  { return lhs.logical  < rhs.logical  }
        return lhs.nodeID.lexicographicallyPrecedes(rhs.nodeID)
    }
}
