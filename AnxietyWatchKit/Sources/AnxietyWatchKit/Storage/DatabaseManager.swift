import Foundation
import GRDB
import os

/// Manages the SQLite database connection, opening, closing, and corruption recovery
public actor DatabaseManager {
    /// URL to the database file
    private let url: URL
    
    /// The underlying GRDB DatabaseQueue
    private var queue: DatabaseQueue?
    
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
            case failed(Error)
        }
    }
    
    /// Creates a new DatabaseManager
    /// - Parameter url: The URL to the database file
    public init(url: URL) {
        self.url = url
    }
    
    /// Opens the database connection, applying required PRAGMAs and integrity checks
    public func open() async throws {
        // Check for clean shutdown marker
        let wasCleanShutdown = FileManager.default.fileExists(atPath: cleanShutdownMarker.path)
        
        // Try to open database, with corruption recovery if needed
        do {
            // Open the database (this will create the file if it doesn't exist)
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                // Apply PRAGMAs during database initialization
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
                try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            
            let dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
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
                
                // Retry opening
                var configuration = Configuration()
                configuration.prepareDatabase { db in
                    // Apply PRAGMAs during database initialization
                    try db.execute(sql: "PRAGMA journal_mode = WAL")
                    try db.execute(sql: "PRAGMA synchronous = NORMAL")
                    try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
                    try db.execute(sql: "PRAGMA foreign_keys = ON")
                }
                
                let dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
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
            
            // Reopen fresh database
            try await open()
            
            // Notify about successful recovery
            corruptionEventContinuation.yield(CorruptionEvent(timestamp: Date(), phase: .recovered))
            Log.storage.info("Database corruption recovery completed")
        } catch {
            // Notify about failed recovery
            corruptionEventContinuation.yield(CorruptionEvent(timestamp: Date(), phase: .failed(error)))
            Log.storage.fault("Database corruption recovery failed: \(error)")
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
            corruptionEventContinuation.yield(CorruptionEvent(timestamp: Date(), phase: .failed(DatabaseError.corruptionThresholdExceeded)))
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