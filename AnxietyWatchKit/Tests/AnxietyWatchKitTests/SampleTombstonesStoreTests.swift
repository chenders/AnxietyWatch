import XCTest
import GRDB
@testable import AnxietyWatchKit

final class SampleTombstonesStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    private var dbManager: DatabaseManager!
    private var store: SampleTombstonesStore!

    private static let node1 = Data(repeating: 0x01, count: 16)
    private static let node2 = Data(repeating: 0x02, count: 16)

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory,
                                                withIntermediateDirectories: true)
        dbURL = tempDirectory.appendingPathComponent("test.sqlite")
        dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()
        try await dbManager.writer { db in
            try SchemaV1.apply(to: db)
        }
        store = SampleTombstonesStore(database: dbManager)
    }

    override func tearDown() async throws {
        await dbManager.close()
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - insert

    func testInsertAndCount() async throws {
        let row = SampleTombstoneRow(
            source: 1, type: 3,
            tsStart: 100, tsEnd: 200,
            hlcPhysical: 1_000, hlcLogical: 0,
            nodeID: Self.node1,
            droppedRowCount: 42,
            reason: .memoryPanic
        )
        let inserted = try await store.insert([row])
        XCTAssertEqual(inserted, 1)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func testInsertMultipleReasonsCoexist() async throws {
        // Same (source, type) window can have multiple tombstones at different HLCs
        let base = SampleTombstoneRow(
            source: 1, type: 3,
            tsStart: 100, tsEnd: 200,
            hlcPhysical: 1_000, hlcLogical: 0,
            nodeID: Self.node1,
            droppedRowCount: 10,
            reason: .memoryPanic
        )
        let later = SampleTombstoneRow(
            source: 1, type: 3,
            tsStart: 100, tsEnd: 200,
            hlcPhysical: 2_000, hlcLogical: 0,
            nodeID: Self.node1,
            droppedRowCount: 5,
            reason: .unackedOverflow
        )
        try await store.insert([base, later])
        let total = try await store.count()
        XCTAssertEqual(total, 2)
        let panicCount = try await store.countByReason(.memoryPanic)
        XCTAssertEqual(panicCount, 1)
        let overflowCount = try await store.countByReason(.unackedOverflow)
        XCTAssertEqual(overflowCount, 1)
    }

    func testInsertIgnoresExactDuplicatePK() async throws {
        let row = SampleTombstoneRow(
            source: 1, type: 3,
            tsStart: 100, tsEnd: 200,
            hlcPhysical: 1_000, hlcLogical: 0,
            nodeID: Self.node1,
            droppedRowCount: 42,
            reason: .memoryPanic
        )
        let first = try await store.insert([row])
        let second = try await store.insert([row])
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0, "Exact PK duplicate must be silently ignored")
        let total = try await store.count()
        XCTAssertEqual(total, 1)
    }

    // MARK: - fetchOverlapping

    func testFetchOverlappingReturnsIntersectingRanges() async throws {
        // Tombstone covers [100, 200]; also one at [300, 400]; also one at [50, 60].
        let a = SampleTombstoneRow(source: 1, type: 3, tsStart: 100, tsEnd: 200,
            hlcPhysical: 1, hlcLogical: 0, nodeID: Self.node1,
            droppedRowCount: 1, reason: .memoryPanic)
        let b = SampleTombstoneRow(source: 1, type: 3, tsStart: 300, tsEnd: 400,
            hlcPhysical: 2, hlcLogical: 0, nodeID: Self.node1,
            droppedRowCount: 1, reason: .memoryPanic)
        let c = SampleTombstoneRow(source: 1, type: 3, tsStart: 50, tsEnd: 60,
            hlcPhysical: 3, hlcLogical: 0, nodeID: Self.node1,
            droppedRowCount: 1, reason: .retention)
        try await store.insert([a, b, c])

        // Query for [150, 250] — should intersect only `a`.
        let hits = try await store.fetchOverlapping(source: 1, type: 3, from: 150, to: 250)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.tsStart, 100)
        XCTAssertEqual(hits.first?.tsEnd, 200)
    }

    func testFetchOverlappingFiltersBySourceAndType() async throws {
        let a = SampleTombstoneRow(source: 1, type: 3, tsStart: 100, tsEnd: 200,
            hlcPhysical: 1, hlcLogical: 0, nodeID: Self.node1,
            droppedRowCount: 1, reason: .memoryPanic)
        let other = SampleTombstoneRow(source: 2, type: 3, tsStart: 100, tsEnd: 200,
            hlcPhysical: 2, hlcLogical: 0, nodeID: Self.node1,
            droppedRowCount: 1, reason: .memoryPanic)
        try await store.insert([a, other])

        let hits = try await store.fetchOverlapping(source: 1, type: 3, from: 100, to: 200)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.source, 1)
    }

    // MARK: - fetchForSync

    func testFetchForSyncPaginatesByHLC() async throws {
        // Insert 5 rows with monotonic HLC on node1.
        var rows: [SampleTombstoneRow] = []
        for i in 0..<5 {
            rows.append(SampleTombstoneRow(
                source: 1, type: 3,
                tsStart: Double(1000 + i * 100),
                tsEnd: Double(1050 + i * 100),
                hlcPhysical: Int64(1_000_000 + i * 1_000),
                hlcLogical: Int32(i),
                nodeID: Self.node1,
                droppedRowCount: 1,
                reason: .memoryPanic
            ))
        }
        try await store.insert(rows)

        // Page 1: first 3 rows after cursor (0, -1).
        let page1 = try await store.fetchForSync(nodeID: Self.node1,
                                                  afterHLC: 0, lc: -1, limit: 3)
        XCTAssertEqual(page1.count, 3)
        XCTAssertEqual(page1.map { $0.hlcPhysical }, [1_000_000, 1_001_000, 1_002_000])

        // Page 2: continue from last HLC of page1.
        let last = page1.last!
        let page2 = try await store.fetchForSync(nodeID: Self.node1,
                                                  afterHLC: last.hlcPhysical,
                                                  lc: last.hlcLogical,
                                                  limit: 10)
        XCTAssertEqual(page2.count, 2)
        XCTAssertEqual(page2.map { $0.hlcPhysical }, [1_003_000, 1_004_000])
    }

    func testFetchForSyncOnlyReturnsMatchingNode() async throws {
        try await store.insert([
            SampleTombstoneRow(source: 1, type: 3, tsStart: 100, tsEnd: 200,
                hlcPhysical: 1, hlcLogical: 0, nodeID: Self.node1,
                droppedRowCount: 1, reason: .memoryPanic),
            SampleTombstoneRow(source: 1, type: 3, tsStart: 100, tsEnd: 200,
                hlcPhysical: 1, hlcLogical: 0, nodeID: Self.node2,
                droppedRowCount: 1, reason: .memoryPanic),
        ])
        let hits = try await store.fetchForSync(nodeID: Self.node1,
                                                 afterHLC: 0, lc: -1, limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.nodeID, Self.node1)
    }

    // MARK: - reason decode

    func testAllReasonsRoundTrip() async throws {
        var rows: [SampleTombstoneRow] = []
        for (i, reason) in SampleTombstoneRow.Reason.allCases.enumerated() {
            rows.append(SampleTombstoneRow(
                source: 1, type: 3,
                tsStart: Double(i * 100), tsEnd: Double(i * 100 + 50),
                hlcPhysical: Int64(1_000 + i),
                hlcLogical: 0,
                nodeID: Self.node1,
                droppedRowCount: 1,
                reason: reason
            ))
        }
        try await store.insert(rows)
        for reason in SampleTombstoneRow.Reason.allCases {
            let c = try await store.countByReason(reason)
            XCTAssertEqual(c, 1, "Reason \(reason.rawValue) should have exactly 1 row")
        }
    }
}
