import Foundation
import GRDB
import os

/// Manages the SQLite database connection, opening, closing, and corruption recovery
public actor DatabaseManager {
    /// Applies schema migrations to a freshly-opened database connection.
    /// Called both on first open() and after recoverFromCorruption() reopens.
    /// Runs on the writer queue inside a savepoint, so throwing rolls back cleanly.
    public typealias SchemaMigrator = @Sendable (Database) throws -> Void

    /// Called after a corruption recovery has completed (fresh empty DB + schema
    /// applied). Intended for the SyncCoordinator to kick full-restore-from-server
    /// (Spec §1.6 step 6). The Error argument is nil on success, or the underlying
    /// error if the migrator itself threw (in which case restore should NOT be
    /// attempted).
    public typealias PostRecoveryHook = @Sendable (Error?) async -> Void

    /// URL to the database file
    private let url: URL
    
    /// The underlying GRDB DatabaseQueue
    private var queue: DatabaseQueue?
    
    /// Registered database functions for re-adding after recovery
    private var registeredFunctions: [DatabaseFunction] = []
    
    /// Schema migrator applied at the end of every successful open() (Spec §1.6:
    /// after recovery the fresh DB must get its schema back before anyone reads it).
    private var schemaMigrator: SchemaMigrator?
    
    /// Hook invoked after a corruption recovery completes (SyncCoordinator.fullRestore
    /// plumbing, T18). Invoked OFF the writer queue so it can call other actors.
    private var postRecoveryHook: PostRecoveryHook?
    
    /// AsyncStream for corruption events
    private let (corruptionEventStream, corruptionEventContinuation) = AsyncStream<CorruptionEvent>.makeStream()
    
    /// Tracks corruption events for circuit breaker
    private var corruptionEventTimestamps: [Date] = []
    
    /// UserDefaults key for clean shutdown flag
    private static let cleanShutdownKey = "com.anxietywatch.kit.storage.cleanShutdown"
    
    /// Clean shutdown marker file name
    private var cleanShutdownMarker: URL {
        url.deletingLastPathComponent().appendingPathComponent(".cleanshutdown-\(url.lastPathComponent)")
    }
    
    /// Checkpoint in progress marker file name
    private var checkpointInProgressMarker: URL {
        url.deletingLastPathComponent().appendingPathComponent(".checkpoint-in-progress-\(url.lastPathComponent)")
    }
    
    /// Database errors
    public enum DatabaseError: Error, Sendable {
        case notOpen
        case corruptionThresholdExceeded
        case integrityCheckFailed(String)
    }
    
    /// Corruption event phases
    public struct CorruptionEvent: Sendable {
        public let timestamp: Date
        public let phase: Phase
        
        public enum Phase: Sendable {
            case detected
            case recovering
            case recovered
            /// Emitted after a recovery reopen has successfully re-applied the
            /// schema migrator (Spec §1.6 — the fresh DB is usable again).
            case schemaReapplied
            /// Emitted just before the PostRecoveryHook is invoked on success
            /// (UI "Recovering…" → restore-in-progress signal, Spec §1.6 step 7).
            case restoreStarted
            /// Failure carries a Sendable projection of the underlying error so the
            /// event can cross actor boundaries (CorruptionBroadcaster, DiagnosticsScreen,
            /// MetricKitReporter). For GRDB DatabaseError, `code` is the SQLite result code.
            case failed(message: String, code: Int32)
        }
    }

    /// Convenience: build a `Phase.failed` from an arbitrary Error, extracting a
    /// SQLite result code when the error is a GRDB `DatabaseError`.
    private static func failedPhase(_ error: any Error) -> CorruptionEvent.Phase {
        if let dbErr = error as? DatabaseError {
            // Our own DatabaseError has no SQLite code; use -1 as sentinel.
            return .failed(message: String(describing: dbErr), code: -1)
        }
        if let grdbErr = error as? GRDB.DatabaseError {
            return .failed(message: grdbErr.message ?? String(describing: grdbErr),
                           code: Int32(grdbErr.resultCode.rawValue))
        }
        return .failed(message: String(describing: error), code: -1)
    }
    
    /// Creates a new DatabaseManager
    /// - Parameter url: The URL to the database file
    public init(url: URL) {
        self.url = url
    }
    
    /// Sets the schema migrator, applied at the end of every successful open()
    /// (including the reopen inside recoverFromCorruption()). Set this BEFORE
    /// calling open() so the first connection is migrated too.
    public func setSchemaMigrator(_ migrator: @escaping SchemaMigrator) async {
        self.schemaMigrator = migrator
    }
    
    /// Sets the post-recovery hook, invoked after recoverFromCorruption() has
    /// reopened and re-migrated the fresh database. DatabaseManager stays
    /// dependency-free: the Sync layer registers itself here at bootstrap.
    public func setPostRecoveryHook(_ hook: @escaping PostRecoveryHook) async {
        self.postRecoveryHook = hook
    }
    
    /// Builds a GRDB `Configuration` whose `prepareDatabase` closure applies the
    /// required PRAGMAs and re-adds every currently-registered UDF. The closure
    /// captures a snapshot of `registeredFunctions` at the moment of build, so a
    /// later corruption-recovery reopen sees whatever functions were registered
    /// before recovery ran. New registrations after this build only affect future
    /// connections; the currently-open queue is patched separately via `registerFunction`.
    private func makeConfiguration() -> Configuration {
        let fnsSnapshot = registeredFunctions
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            for fn in fnsSnapshot {
                db.add(function: fn)
            }
        }
        return configuration
    }

    /// Registers a SQLite user-defined function on the current (and future) DB connection.
    /// Used by the HLC service (T13) to expose `hlc_now_pt`, `hlc_now_lc`, `hlc_now_node`
    /// to the @Syncable-generated triggers, and by anyone else needing a UDF. The function
    /// is remembered on the actor so it is re-registered automatically after a
    /// corruption-recovery reopen.
    public func registerFunction(
        name: String,
        argumentCount: Int?,
        pure: Bool = false,
        _ body: @escaping @Sendable (_ arguments: [DatabaseValue]) throws -> (any DatabaseValueConvertible)?
    ) async throws {
        let fn = DatabaseFunction(
            name,
            argumentCount: argumentCount,
            pure: pure,
            function: body
        )
        registeredFunctions.append(fn)
        // If the queue is already open, patch this single connection so callers
        // don't have to close/reopen to see the new UDF.
        if let queue {
            try await queue.write { db in
                db.add(function: fn)
            }
        }
    }

    /// Opens the database connection, applying required PRAGMAs and integrity checks
    public func open() async throws {
        // Check for clean shutdown marker
        let wasCleanShutdown = FileManager.default.fileExists(atPath: cleanShutdownMarker.path)
        
        // Check for checkpoint in progress marker
        let hadAbortedCheckpoint = FileManager.default.fileExists(atPath: checkpointInProgressMarker.path)
        
        // Try to open database, with corruption recovery if needed
        do {
            let dbQueue = try DatabaseQueue(path: url.path, configuration: makeConfiguration())
            self.queue = dbQueue
        } catch let error {
            // Check if it's a corruption-related error by examining the error description
            let errorDesc = String(describing: error).lowercased()
            if errorDesc.contains("sqlite_corrupt") || 
               errorDesc.contains("sqlite_notadb") || 
               errorDesc.contains("sqlite_cantopen") ||
               errorDesc.contains("database disk image is malformed") ||
               errorDesc.contains("file is not a database") {
                Log.storage.warning("Detected corruption on open: \(error). Attempting recovery.")
                try await recoverFromCorruption()
                let dbQueue = try DatabaseQueue(path: url.path, configuration: makeConfiguration())
                self.queue = dbQueue
            } else {
                throw error
            }
        }
        
        // Set file protection and exclude from backup after the file exists
        do {
            // Set backup exclusion
            var fileURL = url
            var vals = URLResourceValues()
            vals.isExcludedFromBackup = true
            try fileURL.setResourceValues(vals)
            
            // Set file protection
            try FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ], ofItemAtPath: url.path)
        } catch {
            Log.storage.warning("Failed to set file protection or backup exclusion: \(error)")
        }
        
        // Remove clean shutdown marker on successful open (before any writes)
        if wasCleanShutdown {
            try? FileManager.default.removeItem(at: cleanShutdownMarker)
        }
        
        // Handle aborted checkpoint independently of clean shutdown
        if hadAbortedCheckpoint {
            // Run RESTART checkpoint to recover from aborted TRUNCATE
            try await self.queue!.write { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(RESTART)")
            }
            
            // Re-check integrity after checkpoint
            let postCheckpointIntegrity = try await self.queue!.read { db in
                try String.fetchOne(db, sql: "PRAGMA integrity_check")
            }
            
            if postCheckpointIntegrity != "ok" {
                try await recoverFromCorruption()
                return
            }
            
            // Remove checkpoint marker after successful recovery
            try? FileManager.default.removeItem(at: checkpointInProgressMarker)
        }
        
        // Check integrity
        let integrityResult = try await self.queue!.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }
        
        if integrityResult != "ok" {
            try await recoverFromCorruption()
            return
        }
        
        // Check for unclean shutdown
        if !wasCleanShutdown {
            try await self.queue!.write { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(RESTART)")
            }
            
            // Re-check integrity after checkpoint
            let postCheckpointIntegrity = try await self.queue!.read { db in
                try String.fetchOne(db, sql: "PRAGMA integrity_check")
            }
            
            if postCheckpointIntegrity != "ok" {
                try await recoverFromCorruption()
                return
            }
        }
        
        // Apply schema migrations on the writer queue. Runs inside a savepoint
        // so a throwing migrator rolls back cleanly; on failure the connection
        // is closed and the error propagated (callers must not see a half-
        // migrated DB).
        if let migrator = schemaMigrator, let queue = self.queue {
            do {
                try await queue.write { db in
                    try db.inSavepoint {
                        try migrator(db)
                        return .commit
                    }
                }
            } catch {
                Log.storage.error("Schema migrator failed during open: \(error)")
                self.queue = nil
                throw error
            }
        }
    }
    
    /// Closes the database connection
    public func close() async {
        guard let queue = self.queue else { return }
        
        do {
            try await queue.write { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
            }
            
            // Create clean shutdown marker file
            FileManager.default.createFile(atPath: cleanShutdownMarker.path, contents: nil)
            
            Log.storage.info("Database closed cleanly")
        } catch {
            Log.storage.error("Error during database close: \(error)")
        }
        
        self.queue = nil
    }
    
    /// Executes a write operation on the database
    /// - Parameter block: The write operation to execute
    /// - Returns: The result of the write operation
    public func writer<T>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        guard let queue = self.queue else {
            throw DatabaseError.notOpen
        }
        
        return try queue.write(block)
    }
    
    /// Executes a write operation on the database without wrapping in a transaction
    /// - Parameter block: The write operation to execute
    /// - Returns: The result of the write operation
    public func writeWithoutTransaction<T>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        guard let queue = self.queue else {
            throw DatabaseError.notOpen
        }
        
        return try queue.writeWithoutTransaction(block)
    }
    
    /// Executes a read operation on the database
    /// - Parameter block: The read operation to execute
    /// - Returns: The result of the read operation
    public func reader<T>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        guard let queue = self.queue else {
            throw DatabaseError.notOpen
        }
        
        return try queue.read(block)
    }
    
    /// Recovers from database corruption by deleting files and reopening
    public func recoverFromCorruption() async throws {
        // Check circuit breaker
        try checkCorruptionCircuitBreaker()
        
        let timestamp = Date()
        
        // Notify about corruption detection
        corruptionEventContinuation.yield(CorruptionEvent(timestamp: timestamp, phase: .detected))
        Log.storage.fault("Database corruption detected")
        
        // Close current connection if open
        if self.queue != nil {
            self.queue = nil
        }
        
        // Notify about recovery start
        corruptionEventContinuation.yield(CorruptionEvent(timestamp: timestamp, phase: .recovering))
        
        do {
            // Delete database files with correct names
            let walFile = URL(fileURLWithPath: "\(url.path)-wal")
            let shmFile = URL(fileURLWithPath: "\(url.path)-shm")
            
            for file in [url, walFile, shmFile] {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
            
            // Reopen fresh database. open() re-applies the schema migrator at
            // the end of a successful open, so the fresh DB is never left
            // schemaless ("no such table" on the next read).
            try await open()
            
            // Notify about successful recovery
            corruptionEventContinuation.yield(CorruptionEvent(timestamp: Date(), phase: .recovered))
            if schemaMigrator != nil {
                corruptionEventContinuation.yield(CorruptionEvent(timestamp: Date(), phase: .schemaReapplied))
            }
            Log.storage.info("Database corruption recovery completed")
            
            // Kick the post-recovery hook (SyncCoordinator.fullRestore, Spec §1.6
            // step 6) OFF the writer queue: plain await in actor context so the
            // hook can freely hop to other actors.
            if let hook = postRecoveryHook {
                corruptionEventContinuation.yield(CorruptionEvent(timestamp: Date(), phase: .restoreStarted))
                await hook(nil)
            }
        } catch {
            // Notify about failed recovery
            corruptionEventContinuation.yield(CorruptionEvent(timestamp: Date(), phase: Self.failedPhase(error)))
            Log.storage.fault("Database corruption recovery failed: \(error)")
            // Inform the hook that recovery did NOT produce a usable DB (e.g.
            // the migrator threw). Restore must not be attempted in this case.
            if let hook = postRecoveryHook {
                await hook(error)
            }
            throw error
        }
    }
    
    /// Checks if the corruption circuit breaker should trip
    private func checkCorruptionCircuitBreaker() throws {
        let now = Date()
        let twentyFourHoursAgo = now.addingTimeInterval(-24 * 60 * 60)
        
        // Remove old events
        corruptionEventTimestamps.removeAll { $0 < twentyFourHoursAgo }
        
        // Add current event
        corruptionEventTimestamps.append(now)
        
        // Check if we've exceeded the threshold
        if corruptionEventTimestamps.count > 3 {
            // Emit event before breaker throw
            corruptionEventContinuation.yield(CorruptionEvent(timestamp: Date(), phase: Self.failedPhase(DatabaseError.corruptionThresholdExceeded)))
            Log.storage.fault("Corruption circuit breaker tripped")
            throw DatabaseError.corruptionThresholdExceeded
        }
    }
    
    /// Acknowledges the corruption circuit breaker, allowing further operations
    public func acknowledgeCorruptionCircuit() {
        corruptionEventTimestamps.removeAll()
        Log.storage.info("Corruption circuit breaker acknowledged")
    }
    
    /// Forces corruption recovery for testing purposes
    public func forceCorruptionRecovery() async throws {
        try await recoverFromCorruption()
    }
    
    /// Provides access to corruption events
    public var corruptionEvents: AsyncStream<CorruptionEvent> {
        corruptionEventStream
    }
}