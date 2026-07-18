import XCTest
import GRDB
@testable import AnxietyWatchKit

/// End-to-end check that the @Syncable macro's emitted members compile against
/// the real Syncable protocol + SyncRegistry actor (the fixture tests in
/// AnxietyWatchKitMacrosTests only compare expansion text).
@Syncable(tableName: "integration_widgets", primaryKey: "widget_id")
private struct IntegrationWidget: Syncable {
    let widget_id: Int

    func encodeForSync() -> [String: Int] { ["widget_id": widget_id] }
    init(fromSync: [String: Int]) { self.widget_id = fromSync["widget_id"] ?? 0 }
}

final class SyncableIntegrationTests: XCTestCase {
    func testMacroEmittedMembersCompileAndRegister() async throws {
        XCTAssertEqual(IntegrationWidget.syncDirection, .bidirectional)
        XCTAssertEqual(IntegrationWidget.syncTableName, "integration_widgets")
        XCTAssertTrue(IntegrationWidget.syncTriggerDDL.contains("FROM (SELECT hlc_now_json() AS h)"))
        XCTAssertTrue(IntegrationWidget.syncTriggerDDL.contains("CAST(NEW.widget_id AS TEXT)"))

        let registry = SyncRegistry()
        await IntegrationWidget.registerForSync(registry)

        let registered = await registry.registered
        XCTAssertEqual(registered.count, 1)
        XCTAssertEqual(registered.first?.name, "integration_widgets")
        XCTAssertEqual(registered.first?.direction, .bidirectional)

        // Re-registration is idempotent per table.
        await IntegrationWidget.registerForSync(registry)
        let after = await registry.registered
        XCTAssertEqual(after.count, 1)
    }

    /// The load-bearing test the T16 R2 review flagged as missing: execute the
    /// macro-emitted trigger DDL against a real DB and prove INSERT→UPDATE→DELETE
    /// coalesces to a single _sync_log row with monotonic HLC and correct final
    /// operation. Without this test, the R1 PK-collision regression can silently
    /// reappear the moment someone edits the trigger template.
    func testGeneratedTriggersCoalesceInsertUpdateDelete() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macro-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("macro.sqlite")
        let dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()

        // Apply the redesign schema.
        try await dbManager.writer { db in try SchemaV1.apply(to: db) }

        // Register the mandatory hlc_now_json UDF via a real HLC using a
        // strictly monotonic injected wall clock so we can assert HLC ordering.
        let clock = MonotonicClock()
        let nodeID = Data(repeating: 0xAB, count: 16)
        let hlc = HLC(
            nodeID: nodeID,
            now: { clock.next() },
            monotonicNow: { clock.peek() }
        )
        try await hlc.registerUDFs(on: dbManager)

        // Create the domain table + apply the macro-emitted trigger DDL.
        try await dbManager.writer { db in
            try db.execute(sql: "CREATE TABLE integration_widgets (widget_id INTEGER PRIMARY KEY, v TEXT)")
            try db.execute(sql: IntegrationWidget.syncTriggerDDL)
        }

        // Fixture ops on the domain table — the triggers should fire.
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO integration_widgets (widget_id, v) VALUES (1, 'a')")
        }
        let afterInsert = try await singleLogRow(dbManager, rowPK: "1")
        XCTAssertEqual(afterInsert.count, 1, "INSERT should produce exactly one _sync_log row")
        XCTAssertEqual(afterInsert.op, "upsert")

        try await dbManager.writer { db in
            try db.execute(sql: "UPDATE integration_widgets SET v = 'b' WHERE widget_id = 1")
        }
        let afterUpdate = try await singleLogRow(dbManager, rowPK: "1")
        XCTAssertEqual(afterUpdate.count, 1, "UPDATE must COALESCE, not PK-collide (R1 blocker)")
        XCTAssertEqual(afterUpdate.op, "upsert")
        XCTAssertGreaterThan(afterUpdate.pt, afterInsert.pt,
                             "HLC must strictly advance across UPDATE")

        try await dbManager.writer { db in
            try db.execute(sql: "DELETE FROM integration_widgets WHERE widget_id = 1")
        }
        let afterDelete = try await singleLogRow(dbManager, rowPK: "1")
        XCTAssertEqual(afterDelete.count, 1, "DELETE must COALESCE with prior upserts")
        XCTAssertEqual(afterDelete.op, "delete")
        XCTAssertGreaterThan(afterDelete.pt, afterUpdate.pt,
                             "HLC must strictly advance across DELETE")

        // Resurrection: re-INSERT the deleted PK. The HLC-guarded upsert must
        // flip the operation back to 'upsert' because the new stamp is higher.
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO integration_widgets (widget_id, v) VALUES (1, 'c')")
        }
        let afterResurrect = try await singleLogRow(dbManager, rowPK: "1")
        XCTAssertEqual(afterResurrect.count, 1)
        XCTAssertEqual(afterResurrect.op, "upsert", "Resurrection must flip op back to upsert")
        XCTAssertGreaterThan(afterResurrect.pt, afterDelete.pt)

        // Close synchronously before the temporary-directory defer runs so no
        // SQLite handle can race directory removal on slower CI machines.
        await dbManager.close()
    }

    private struct LogRow {
        let count: Int
        let pt: Int64
        let op: String
    }

    private func singleLogRow(_ db: DatabaseManager, rowPK: String) async throws -> LogRow {
        try await db.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT hlc_physical, operation FROM _sync_log
                 WHERE table_name = 'integration_widgets' AND row_pk = ?
                 ORDER BY hlc_physical DESC
                """, arguments: [rowPK])
            guard let first = rows.first else {
                return LogRow(count: 0, pt: 0, op: "")
            }
            return LogRow(count: rows.count, pt: first["hlc_physical"], op: first["operation"])
        }
    }
}

/// Test-only monotonic wall clock; each call returns a strictly greater value.
private final class MonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64 = 1_000
    func next() -> Int64 { lock.lock(); defer { lock.unlock() }; current += 1_000; return current }
    func peek() -> Int64 { lock.lock(); defer { lock.unlock() }; return current }
}
