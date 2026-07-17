import Foundation

/// Server-side sync endpoint contract per Spec §2.7. Test-injectable.
///
/// Concrete implementations own the HTTP envelope, including
/// `cursor_format_version` (currently `SyncCursor.cursorFormatVersion`); a 409
/// from the server surfaces as `SyncEndpointError.cursorFormatMismatch`.
public protocol SyncEndpoint: Sendable {
    /// POST /sync/pull
    func pull(cursor: TableCursors, maxBatchBytes: Int) async throws -> SyncPullResponse
    /// POST /sync/push
    func push(payload: SyncPushPayload) async throws -> SyncPushResponse
}

public struct SyncPullResponse: Sendable, Codable, Equatable {
    public let samples: [SampleRow]
    public let sampleTombstones: [SampleTombstoneRow]
    public let syncLog: [SyncLogEntry]
    public let nextCursor: TableCursors
    public let serverHLC: HLCStamped

    public init(
        samples: [SampleRow],
        sampleTombstones: [SampleTombstoneRow],
        syncLog: [SyncLogEntry],
        nextCursor: TableCursors,
        serverHLC: HLCStamped
    ) {
        self.samples = samples
        self.sampleTombstones = sampleTombstones
        self.syncLog = syncLog
        self.nextCursor = nextCursor
        self.serverHLC = serverHLC
    }

    private enum CodingKeys: String, CodingKey {
        case samples
        case sampleTombstones = "sample_tombstones"
        case syncLog = "sync_log"
        case nextCursor = "next_cursor"
        case serverHLC = "server_hlc"
    }
}

public struct SyncPushPayload: Sendable, Codable {
    public let samples: [SampleRow]
    public let sampleTombstones: [SampleTombstoneRow]
    public let syncLog: [SyncLogEntry]
    public let clientHLC: HLCStamped

    public init(
        samples: [SampleRow],
        sampleTombstones: [SampleTombstoneRow],
        syncLog: [SyncLogEntry],
        clientHLC: HLCStamped
    ) {
        self.samples = samples
        self.sampleTombstones = sampleTombstones
        self.syncLog = syncLog
        self.clientHLC = clientHLC
    }

    private enum CodingKeys: String, CodingKey {
        case samples
        case sampleTombstones = "sample_tombstones"
        case syncLog = "sync_log"
        case clientHLC = "client_hlc"
    }
}

public struct SyncPushResponse: Sendable, Codable, Equatable {
    public let ackCursor: TableCursors
    public let serverHLC: HLCStamped

    public init(ackCursor: TableCursors, serverHLC: HLCStamped) {
        self.ackCursor = ackCursor
        self.serverHLC = serverHLC
    }

    private enum CodingKeys: String, CodingKey {
        case ackCursor = "ack_cursor"
        case serverHLC = "server_hlc"
    }
}

public enum SyncEndpointError: Error, Sendable, Equatable {
    /// Server returned 409 CursorFormatMismatch — fall back to legacy REST.
    case cursorFormatMismatch
    /// Caller may retry (retry ladder, Spec §5.4).
    case transientFailure(String)
    /// Caller should escalate; retrying will not help.
    case permanent(String)
}
