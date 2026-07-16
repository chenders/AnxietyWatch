import Foundation

/// A per-node HLC watermark. Missing node_id means "from beginning".
public struct SyncCursor: Sendable, Codable {
    public private(set) var perNode: [Data: (physical: Int64, logical: Int32)]

    public init(perNode: [Data: (physical: Int64, logical: Int32)] = [:]) {
        self.perNode = perNode
    }

    /// Read the watermark for a node. Returns (0, -1) if the node has never
    /// been seen — the smallest possible cursor value so the first fetch
    /// starts from the very first row.
    public func watermark(for nodeID: Data) -> (physical: Int64, logical: Int32) {
        return perNode[nodeID] ?? (physical: 0, logical: -1)
    }

    /// Advance the watermark for a node ONLY if the incoming value is strictly
    /// greater. Returns whether the watermark was updated.
    @discardableResult
    public mutating func advance(nodeID: Data, physical: Int64, logical: Int32) -> Bool {
        let current = watermark(for: nodeID)
        let currentStamped = HLCStamped(physical: current.physical, logical: current.logical, nodeID: nodeID)
        let incomingStamped = HLCStamped(physical: physical, logical: logical, nodeID: nodeID)
        
        if incomingStamped > currentStamped {
            perNode[nodeID] = (physical: physical, logical: logical)
            return true
        }
        return false
    }

    /// All node IDs known to this cursor.
    public var knownNodes: [Data] {
        return Array(perNode.keys)
    }

    // Codable implementation
    private struct Entry: Codable {
        let n: Data
        let p: Int64
        let l: Int32
    }
    
    private enum CodingKeys: String, CodingKey {
        case entries
    }
    
    public static let cursorFormatVersion: Int = 2

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        // Convert to entries array and sort by node ID
        let entries = perNode.map { Entry(n: $0.key, p: $0.value.physical, l: $0.value.logical) }
            .sorted { $0.n.lexicographicallyPrecedes($1.n) }
        
        try container.encode(entries, forKey: .entries)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([Entry].self, forKey: .entries)
        
        // Rebuild the dictionary
        var dict: [Data: (physical: Int64, logical: Int32)] = [:]
        for entry in entries {
            dict[entry.n] = (physical: entry.p, logical: entry.l)
        }
        self.perNode = dict
    }
}

// Manual Equatable conformance
extension SyncCursor: Equatable {
    public static func == (lhs: SyncCursor, rhs: SyncCursor) -> Bool {
        // Check if they have the same number of entries
        guard lhs.perNode.count == rhs.perNode.count else { return false }
        
        // Check each entry
        for (key, value) in lhs.perNode {
            guard let rhsValue = rhs.perNode[key] else { return false }
            if value.physical != rhsValue.physical || value.logical != rhsValue.logical {
                return false
            }
        }
        return true
    }
}

public struct TableCursors: Sendable, Equatable, Codable {
    public var samples: SyncCursor
    public var sampleTombstones: SyncCursor
    public var syncLog: SyncCursor  // covers all CRUD tables

    public init(samples: SyncCursor = .init(),
                sampleTombstones: SyncCursor = .init(),
                syncLog: SyncCursor = .init()) {
        self.samples = samples
        self.sampleTombstones = sampleTombstones
        self.syncLog = syncLog
    }

    /// Wire keys must match Spec §2.7 exactly: samples / sample_tombstones / sync_log.
    /// Without these overrides, Codable would emit sampleTombstones / syncLog on
    /// the wire, causing a guaranteed 2C break against the server contract.
    private enum CodingKeys: String, CodingKey {
        case samples
        case sampleTombstones = "sample_tombstones"
        case syncLog = "sync_log"
    }
}