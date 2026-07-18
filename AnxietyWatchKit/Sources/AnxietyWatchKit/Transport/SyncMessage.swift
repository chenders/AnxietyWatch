import Foundation

/// Wire format for all sync communication over WCSession.
///
/// Compact JSON envelopes carry structured sync commands. The transport
/// layer (WCSessionCoordinator) passes opaque `[String: Any]` payloads;
/// SyncMessageCodec bridges between those payloads and these types.
///
/// Spec §5.2 — small payloads required:
/// - `.ping` / `.pong` ride `sendMessage` (interactive, low latency).
/// - `.fetch` / `.batch` ride `sendMessage` for cursor negotiation or small
///   batches, or `transferFile` for large historical time-series.
/// - `.urgent` rides `updateApplicationContext` for LWW alerting or
///   `sendMessage` for CNS critical alerts needing <2 s P95.
public enum SyncMessage: Codable, Sendable, Equatable {

    /// A ping to negotiate sync state. Sent interactively.
    case ping(nodeID: String, cursor: SyncCursor)

    /// A response to a ping. Contains the receiver's cursor.
    case pong(nodeID: String, cursor: SyncCursor)

    /// A request to fetch records modified after a given cursor.
    case fetch(nodeID: String, after: SyncCursor, limit: Int)

    /// A batch of records returned for a fetch. `recordsData` is raw JSON
    /// (an array of record dictionaries) — the transport layer does NOT
    /// decode it, avoiding a deserialize/re-serialize round-trip.
    case batch(nodeID: String, cursor: SyncCursor, recordsData: Data)

    /// Notification that urgent data (e.g. panic or high-risk CNS event)
    /// is waiting. Used via `updateApplicationContext` or interactive message.
    case urgent(nodeID: String, latestHLC: HLCStamped)
}

// MARK: - Codable dispatch keys

extension SyncMessage {
    private enum Key: String, CodingKey {
        case type
        case nodeID, cursor, after, limit, recordsData, latestHLC
    }

    private enum TypeKey: String, Codable {
        case ping, pong, fetch, batch, urgent
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .ping(let nodeID, let cursor):
            try container.encode(TypeKey.ping.rawValue, forKey: .type)
            try container.encode(nodeID, forKey: .nodeID)
            try container.encode(cursor, forKey: .cursor)
        case .pong(let nodeID, let cursor):
            try container.encode(TypeKey.pong.rawValue, forKey: .type)
            try container.encode(nodeID, forKey: .nodeID)
            try container.encode(cursor, forKey: .cursor)
        case .fetch(let nodeID, let after, let limit):
            try container.encode(TypeKey.fetch.rawValue, forKey: .type)
            try container.encode(nodeID, forKey: .nodeID)
            try container.encode(after, forKey: .after)
            try container.encode(limit, forKey: .limit)
        case .batch(let nodeID, let cursor, let recordsData):
            try container.encode(TypeKey.batch.rawValue, forKey: .type)
            try container.encode(nodeID, forKey: .nodeID)
            try container.encode(cursor, forKey: .cursor)
            try container.encode(recordsData, forKey: .recordsData)
        case .urgent(let nodeID, let latestHLC):
            try container.encode(TypeKey.urgent.rawValue, forKey: .type)
            try container.encode(nodeID, forKey: .nodeID)
            try container.encode(latestHLC, forKey: .latestHLC)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case TypeKey.ping.rawValue:
            let nodeID = try container.decode(String.self, forKey: .nodeID)
            let cursor = try container.decode(SyncCursor.self, forKey: .cursor)
            self = .ping(nodeID: nodeID, cursor: cursor)
        case TypeKey.pong.rawValue:
            let nodeID = try container.decode(String.self, forKey: .nodeID)
            let cursor = try container.decode(SyncCursor.self, forKey: .cursor)
            self = .pong(nodeID: nodeID, cursor: cursor)
        case TypeKey.fetch.rawValue:
            let nodeID = try container.decode(String.self, forKey: .nodeID)
            let after = try container.decode(SyncCursor.self, forKey: .after)
            let limit = try container.decode(Int.self, forKey: .limit)
            self = .fetch(nodeID: nodeID, after: after, limit: limit)
        case TypeKey.batch.rawValue:
            let nodeID = try container.decode(String.self, forKey: .nodeID)
            let cursor = try container.decode(SyncCursor.self, forKey: .cursor)
            let recordsData = try container.decode(Data.self, forKey: .recordsData)
            self = .batch(nodeID: nodeID, cursor: cursor, recordsData: recordsData)
        case TypeKey.urgent.rawValue:
            let nodeID = try container.decode(String.self, forKey: .nodeID)
            let latestHLC = try container.decode(HLCStamped.self, forKey: .latestHLC)
            self = .urgent(nodeID: nodeID, latestHLC: latestHLC)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unknown SyncMessage type: \(type)"
                )
            )
        }
    }
}
