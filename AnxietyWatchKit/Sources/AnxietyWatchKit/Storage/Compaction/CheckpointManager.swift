import Foundation
import GRDB

public actor CheckpointManager {
    private let database: DatabaseManager
    private let markerURL: URL

    public struct CheckpointResult: Sendable, Equatable {
        public let mode: Mode
        public let elapsedMillis: Int
        public let busy: Int
        public let log: Int
        public let checkpointed: Int
    }

    public enum Mode: String, Sendable, Codable {
        case passive = "PASSIVE"
        case full = "FULL"
        case restart = "RESTART"
        case truncate = "TRUNCATE"
    }

    public enum CheckpointManagerError: Error, Sendable {
        case blePreconditionFailed
        case syncPreconditionFailed
        case checkpointBusy(Int)
    }

    /// - Parameters:
    ///   - database: the target DatabaseManager.
    ///   - markerURL: file path used as the aborted-checkpoint marker. Written
    ///     immediately before `wal_checkpoint(TRUNCATE)` runs and removed after
    ///     the pragma returns. Typically a sibling of the DB file:
    ///     `<dbdir>/.checkpoint-in-progress-<dbname>`.
    public init(database: DatabaseManager, markerURL: URL) {
        self.database = database
        self.markerURL = markerURL
    }

    /// Run a checkpoint at the requested mode.
    /// - Parameters:
    ///   - mode: PASSIVE (during ingest, low-priority), FULL/RESTART (rarely used),
    ///     TRUNCATE (only inside WK background task when BLE idle).
    ///   - blePrecondition: a closure returning true if BLE actor is currently idle.
    ///     Required to be true for .truncate; ignored for others.
    ///   - syncPrecondition: closure returning true if no sync operation is in flight.
    ///     Required to be true for .truncate; ignored for others.
    /// - Returns: parsed result of `PRAGMA wal_checkpoint(...)` which returns
    ///   (busy, log, checkpointed).
    public func run(
        mode: Mode,
        blePrecondition: (@Sendable () async -> Bool)? = nil,
        syncPrecondition: (@Sendable () async -> Bool)? = nil
    ) async throws -> CheckpointResult {
        // For TRUNCATE mode, check preconditions
        if mode == .truncate {
            // Fail closed on nil
            guard let blePrecondition = blePrecondition else {
                throw CheckpointManagerError.blePreconditionFailed
            }
            
            guard let syncPrecondition = syncPrecondition else {
                throw CheckpointManagerError.syncPreconditionFailed
            }
            
            let bleIdle = await blePrecondition()
            if !bleIdle {
                throw CheckpointManagerError.blePreconditionFailed
            }
            
            let syncIdle = await syncPrecondition()
            if !syncIdle {
                throw CheckpointManagerError.syncPreconditionFailed
            }
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Write marker file before checkpoint for TRUNCATE mode
        var markerWritten = false
        if mode == .truncate {
            do {
                let data = Data()
                try data.write(to: markerURL, options: .atomic)
                markerWritten = true
            } catch {
                Log.storage.warning("Failed to create checkpoint marker file: \(error)")
                // Continue anyway - marker is best-effort
            }
        }
        
        defer {
            // Remove marker file after checkpoint completes
            if markerWritten {
                try? FileManager.default.removeItem(at: markerURL)
            }
        }
        
        // Signpost the checkpoint operation
        // Note: Signposts may not be available in this context, so we'll skip for now
        
        let result: CheckpointResult = try await database.writeWithoutTransaction { db in
            let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(\(mode.rawValue))")
            
            guard let row = row else {
                throw GRDB.DatabaseError(resultCode: .SQLITE_ERROR, message: "PRAGMA wal_checkpoint returned no rows")
            }
            
            let busy: Int = row[0]
            let log: Int = row[1]
            let checkpointed: Int = row[2]
            
            let elapsedMillis = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            
            // For TRUNCATE mode, throw error if busy
            if mode == .truncate && busy > 0 {
                throw CheckpointManagerError.checkpointBusy(busy)
            }
            
            let result = CheckpointResult(
                mode: mode,
                elapsedMillis: elapsedMillis,
                busy: busy,
                log: log,
                checkpointed: checkpointed
            )
            
            Log.storage.info("Checkpoint \(mode.rawValue): busy=\(busy) log=\(log) checkpointed=\(checkpointed) elapsed=\(elapsedMillis)ms")
            
            return result
        }
        
        return result
    }
}