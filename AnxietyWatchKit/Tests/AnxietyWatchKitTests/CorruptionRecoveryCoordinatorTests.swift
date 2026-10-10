import Foundation
import GRDB
import Testing
@testable import AnxietyWatchKit

@Suite("Corruption recovery coordination")
struct CorruptionRecoveryCoordinatorTests {
    @Test("replacement recreates schema, restores data, rederives HealthKit, and preserves identity")
    func completeRecovery() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }

        let callbacks = RecoveryCallbackRecorder()
        let database = DatabaseManager(url: fixture.databaseURL)
        await database.setSchemaMigrator { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS restored (source TEXT PRIMARY KEY)")
        }

        let nodeID = Data(repeating: 0xA7, count: 16)
        let coordinator = CorruptionRecoveryCoordinator(
            database: database,
            nodeID: nodeID,
            restoreFromServer: {
                await callbacks.record("server")
                try await database.writer { db in
                    try db.execute(sql: "INSERT INTO restored (source) VALUES ('server')")
                }
            },
            rederiveHealthKit: {
                await callbacks.record("healthkit")
                try await database.writer { db in
                    try db.execute(sql: "INSERT INTO restored (source) VALUES ('healthkit')")
                }
            }
        )
        await coordinator.bootstrap()

        try await database.open()
        try await database.writer { db in
            try db.execute(sql: "CREATE TABLE abandoned (value TEXT)")
            try db.execute(sql: "INSERT INTO abandoned VALUES ('old-store')")
        }
        await database.close()

        let sidecarSentinel = Data("must-be-replaced".utf8)
        try sidecarSentinel.write(to: fixture.walURL)
        try sidecarSentinel.write(to: fixture.shmURL)

        let identityBefore = await coordinator.nodeIdentity
        try await coordinator.recover()

        let restored = try await database.reader { db in
            try String.fetchAll(db, sql: "SELECT source FROM restored ORDER BY source")
        }
        let abandonedExists = try await database.reader { db in
            try db.tableExists("abandoned")
        }

        #expect(restored == ["healthkit", "server"])
        #expect(abandonedExists == false)
        #expect((try? Data(contentsOf: fixture.walURL)) != sidecarSentinel)
        #expect((try? Data(contentsOf: fixture.shmURL)) != sidecarSentinel)
        #expect(await callbacks.values == ["server", "healthkit"])
        #expect(identityBefore == nodeID)
        #expect(await coordinator.nodeIdentity == nodeID)
        #expect(await coordinator.currentState == .recovered)
        #expect(await coordinator.stateHistory == [
            .idle,
            .replacingStore,
            .restoringFromServer,
            .rederivingHealthKit,
            .recovered,
        ])
    }

    @Test("third event in 24 hours stops replacement until the window expires")
    func circuitBreakerStopsThirdEvent() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }

        let clock = RecoveryClock(Date(timeIntervalSince1970: 1_000_000))
        let database = DatabaseManager(url: fixture.databaseURL, now: { clock.now })
        let callbacks = RecoveryCallbackRecorder()
        let coordinator = CorruptionRecoveryCoordinator(
            database: database,
            nodeID: Data(repeating: 0xB8, count: 16),
            restoreFromServer: { await callbacks.record("server") },
            rederiveHealthKit: { await callbacks.record("healthkit") }
        )
        await coordinator.bootstrap()
        try await database.open()

        try await coordinator.recover()
        try await coordinator.recover()

        // A process relaunch must not reset the safety window. Close the old
        // handle and construct a new manager/coordinator over the same files.
        await database.close()
        let relaunchedDatabase = DatabaseManager(url: fixture.databaseURL, now: { clock.now })
        let relaunchedCoordinator = CorruptionRecoveryCoordinator(
            database: relaunchedDatabase,
            nodeID: Data(repeating: 0xB8, count: 16),
            restoreFromServer: { await callbacks.record("server") },
            rederiveHealthKit: { await callbacks.record("healthkit") }
        )
        await relaunchedCoordinator.bootstrap()

        await #expect(throws: DatabaseManager.DatabaseError.corruptionThresholdExceeded) {
            try await relaunchedCoordinator.recover()
        }
        #expect(await relaunchedCoordinator.currentState == .requiresUserAction)
        #expect(await callbacks.values.count == 4)

        clock.advance(by: 24 * 60 * 60 + 1)
        try await relaunchedCoordinator.recover()

        #expect(await relaunchedCoordinator.currentState == .recovered)
        #expect(await callbacks.values.count == 6)
    }

    @Test("restore failure is published and propagated")
    func restoreFailureIsVisible() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }

        let database = DatabaseManager(url: fixture.databaseURL)
        let coordinator = CorruptionRecoveryCoordinator(
            database: database,
            nodeID: Data(repeating: 0xC9, count: 16),
            restoreFromServer: { throw RecoveryFixtureError.restoreFailed },
            rederiveHealthKit: { Issue.record("HealthKit must not run after restore failure") }
        )
        await coordinator.bootstrap()
        try await database.open()

        await #expect(throws: CorruptionRecoveryCoordinator.RecoveryError.restorationFailed) {
            try await coordinator.recover()
        }

        #expect(await coordinator.currentState == .failed(stage: .serverRestore))
    }
}

private struct RecoveryFixture {
    let directory: URL
    let databaseURL: URL
    let walURL: URL
    let shmURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorruptionRecoveryCoordinatorTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("fictional.sqlite")
        walURL = URL(fileURLWithPath: "\(databaseURL.path)-wal")
        shmURL = URL(fileURLWithPath: "\(databaseURL.path)-shm")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum RecoveryFixtureError: Error {
    case restoreFailed
}

private actor RecoveryCallbackRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private final class RecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}
