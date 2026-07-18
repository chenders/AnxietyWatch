import XCTest
import GRDB
@testable import AnxietyWatchKit

final class QuarantineStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    private var dbManager: DatabaseManager!
    private var store: QuarantineStore!

    private static let node1 = Data(repeating: 0x01, count: 16)
    private static let node2 = Data(repeating: 0x02, count: 16)

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory,
                                                withIntermediateDirectories: true)
        dbURL = tempDirectory.appendingPathComponent("test.sqlite")
        dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()
        try await dbManager.writer { db in
            try SchemaV1.apply(to: db)
        }
        store = QuarantineStore(database: dbManager)
    }

    override func tearDown() async throws {
        await dbManager.close()
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - Tests

    func testInsertAndCount() async throws {
        let row = QuarantineRow(
            tableName: "samples",
            rowPK: "1-2-100.0",
            hlcPhysical: 1_000,
            hlcLogical: 0,
            nodeID: Self.node1,
            reason: "HLC drift exceeded",
            payload: Data("test payload".utf8)
        )
        let inserted = try await store.insert(row)
        XCTAssertEqual(inserted, 1)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func testInsertIgnoresPKDuplicate() async throws {
        let row = QuarantineRow(
            tableName: "samples",
            rowPK: "1-2-100.0",
            hlcPhysical: 1_000,
            hlcLogical: 0,
            nodeID: Self.node1,
            reason: "HLC drift exceeded",
            payload: Data("test payload".utf8)
        )
        let first = try await store.insert(row)
        let second = try await store.insert(row)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0, "Exact PK duplicate must be silently ignored")
        let total = try await store.count()
        XCTAssertEqual(total, 1)
    }

    func testFetchByTableAndRowPK() async throws {
        let row1 = QuarantineRow(
            tableName: "samples",
            rowPK: "1-2-100.0",
            hlcPhysical: 1_000,
            hlcLogical: 0,
            nodeID: Self.node1,
            reason: "HLC drift exceeded",
            payload: Data("test payload 1".utf8)
        )
        let row2 = QuarantineRow(
            tableName: "samples",
            rowPK: "1-2-100.0",
            hlcPhysical: 2_000,
            hlcLogical: 0,
            nodeID: Self.node2,
            reason: "HLC drift exceeded",
            payload: Data("test payload 2".utf8)
        )
        let row3 = QuarantineRow(
            tableName: "samples",
            rowPK: "3-4-200.0",
            hlcPhysical: 3_000,
            hlcLogical: 0,
            nodeID: Self.node1,
            reason: "Different reason",
            payload: Data("test payload 3".utf8)
        )
        
        try await store.insert(row1)
        try await store.insert(row2)
        try await store.insert(row3)
        
        let fetched = try await store.fetch(tableName: "samples", rowPK: "1-2-100.0")
        XCTAssertEqual(fetched.count, 2)
        XCTAssertTrue(fetched.contains { $0.nodeID == Self.node1 })
        XCTAssertTrue(fetched.contains { $0.nodeID == Self.node2 })
        
        let fetchedOther = try await store.fetch(tableName: "samples", rowPK: "3-4-200.0")
        XCTAssertEqual(fetchedOther.count, 1)
        XCTAssertEqual(fetchedOther.first?.payload, Data("test payload 3".utf8))
    }

    func testFetchAllOrdersByCapturedAtDescending() async throws {
        let row1 = QuarantineRow(
            tableName: "samples",
            rowPK: "1-2-100.0",
            hlcPhysical: 1_000,
            hlcLogical: 0,
            nodeID: Self.node1,
            reason: "Reason 1",
            payload: Data("payload 1".utf8)
        )
        // Give each row a distinct capturedAt so ordering is deterministic;
        // hlcPhysical intentionally NOT monotonic to prove ordering ignores it
        // (Opus round: HLC of quarantined rows is untrusted so cannot drive UI order).
        let row2 = QuarantineRow(
            tableName: "samples",
            rowPK: "1-2-200.0",
            hlcPhysical: 3_000,
            hlcLogical: 0,
            nodeID: Self.node1,
            reason: "Reason 2",
            payload: Data("payload 2".utf8),
            capturedAt: 2_000
        )
        let row3 = QuarantineRow(
            tableName: "samples",
            rowPK: "1-2-300.0",
            hlcPhysical: 2_000,
            hlcLogical: 0,
            nodeID: Self.node1,
            reason: "Reason 3",
            payload: Data("payload 3".utf8),
            capturedAt: 3_000
        )

        try await store.insert(row1)
        try await store.insert(row2)
        try await store.insert(row3)

        let allRows = try await store.fetchAll()
        XCTAssertEqual(allRows.count, 3)

        // Ordered by trusted `captured_at` DESC, NOT by hlc_physical.
        // row3 (captured_at=3000) → row2 (2000) → row1 (default now, but > 3000 since fresh)
        // Actually row1 was inserted FIRST without explicit capturedAt, so it takes
        // Date().timeIntervalSince1970 * 1000 which is >> 3000. So insertion-time row1
        // comes first in DESC order.
        XCTAssertEqual(allRows[0].rowPK, "1-2-100.0")  // largest capturedAt (Date.now)
        XCTAssertEqual(allRows[1].rowPK, "1-2-300.0")  // capturedAt=3000
        XCTAssertEqual(allRows[2].rowPK, "1-2-200.0")  // capturedAt=2000
    }

    func testDeleteRemovesSpecificRow() async throws {
        let row1 = QuarantineRow(
            tableName: "samples",
            rowPK: "1-2-100.0",
            hlcPhysical: 1_000,
            hlcLogical: 0,
            nodeID: Self.node1,
            reason: "HLC drift exceeded",
            payload: Data("test payload 1".utf8)
        )
        let row2 = QuarantineRow(
            tableName: "samples",
            rowPK: "1-2-100.0",
            hlcPhysical: 2_000,
            hlcLogical: 0,
            nodeID: Self.node2,
            reason: "HLC drift exceeded",
            payload: Data("test payload 2".utf8)
        )
        
        try await store.insert(row1)
        try await store.insert(row2)
        
        var count = try await store.count()
        XCTAssertEqual(count, 2)
        
        let deleted = try await store.delete(
            tableName: "samples",
            rowPK: "1-2-100.0",
            hlcPhysical: 1_000,
            hlcLogical: 0,
            nodeID: Self.node1
        )
        XCTAssertEqual(deleted, 1)
        
        count = try await store.count()
        XCTAssertEqual(count, 1)
        
        let remaining = try await store.fetch(tableName: "samples", rowPK: "1-2-100.0")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.nodeID, Self.node2)
    }
}