import XCTest
import GRDB
@testable import AnxietyWatchKit

final class IdleDownsamplerTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    private var dbManager: DatabaseManager!
    private var downsampler: IdleDownsampler!
    private var samplesStore: SamplesStore!

    private static let node1 = Data(repeating: 0x01, count: 16)
    private static let node2 = Data(repeating: 0x02, count: 16)

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downsampler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory,
                                                withIntermediateDirectories: true)
        dbURL = tempDirectory.appendingPathComponent("test.sqlite")
        dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()
        try await dbManager.writer { db in
            try SchemaV1.apply(to: db)
        }
        downsampler = IdleDownsampler(database: dbManager)
        samplesStore = SamplesStore(database: dbManager)
    }

    override func tearDown() async throws {
        await dbManager.close()
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - Tests

    func testDownsampleMean() async throws {
        // Seed 3 raw samples in bucket 0 (t=0,10,20 with values 10, 20, 30)
        var rows: [SampleRow] = []
        rows.append(SampleRow(source: 1, type: 1, timestamp: 0, value: 10, extra: nil,
                              hlcPhysical: 1000, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 1, timestamp: 10, value: 20, extra: nil,
                              hlcPhysical: 1001, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 1, timestamp: 20, value: 30, extra: nil,
                              hlcPhysical: 1002, hlcLogical: 0, nodeID: Self.node1))
        
        // And 2 in bucket 1 (t=70,80 with values 5, 15)
        rows.append(SampleRow(source: 1, type: 1, timestamp: 70, value: 5, extra: nil,
                              hlcPhysical: 1003, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 1, timestamp: 80, value: 15, extra: nil,
                              hlcPhysical: 1004, hlcLogical: 0, nodeID: Self.node1))
        
        let inserted = try await samplesStore.insert(rows)
        XCTAssertEqual(inserted, 5)
        
        // Downsample with now = 130 (well past both buckets)
        let result = try await downsampler.downsample(now: 130, source: 1, type: 1, aggregator: .mean)
        XCTAssertEqual(result.bucketsWritten, 2)
        
        // Check that 2 rollup rows were written
        let rollupCount = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples_1min WHERE source = 1 AND type = 1") ?? 0
        }
        XCTAssertEqual(rollupCount, 2)
    }
    
    func testDownsampleAcrossTwoNodesProducesTwoRows() async throws {
        // Seed 3 samples in minute_bucket=0 for node1 (timestamps 10, 20, 30)
        var rows: [SampleRow] = []
        rows.append(SampleRow(source: 1, type: 1, timestamp: 10, value: 10, extra: nil,
                              hlcPhysical: 1000, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 1, timestamp: 20, value: 20, extra: nil,
                              hlcPhysical: 1001, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 1, timestamp: 30, value: 30, extra: nil,
                              hlcPhysical: 1002, hlcLogical: 0, nodeID: Self.node1))
        
        // And 3 samples in minute_bucket=0 for node2 (different timestamps to avoid PK conflict)
        rows.append(SampleRow(source: 1, type: 1, timestamp: 11, value: 40, extra: nil,
                              hlcPhysical: 1003, hlcLogical: 0, nodeID: Self.node2))
        rows.append(SampleRow(source: 1, type: 1, timestamp: 21, value: 50, extra: nil,
                              hlcPhysical: 1004, hlcLogical: 0, nodeID: Self.node2))
        rows.append(SampleRow(source: 1, type: 1, timestamp: 31, value: 60, extra: nil,
                              hlcPhysical: 1005, hlcLogical: 0, nodeID: Self.node2))
        
        let inserted = try await samplesStore.insert(rows)
        XCTAssertEqual(inserted, 6)
        
        // Downsample with now = 100 (well past bucket 0)
        let result = try await downsampler.downsample(now: 100, source: 1, type: 1, aggregator: .mean)
        XCTAssertEqual(result.bucketsWritten, 2)
        
        // Check that 2 rollup rows were written, one per node
        let rollupCount = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples_1min WHERE source = 1 AND type = 1") ?? 0
        }
        XCTAssertEqual(rollupCount, 2)
        
        // Check the rollup values for each node
        let node1Rows = try await dbManager.reader { db in
            try Row.fetchAll(db, sql: "SELECT value FROM samples_1min WHERE source = 1 AND type = 1 AND node_id = ?", arguments: [Self.node1])
        }
        XCTAssertEqual(node1Rows.count, 1)
        if let row = node1Rows.first {
            let value: Double = row["value"]
            XCTAssertEqual(value, 20.0, accuracy: 0.001)  // mean of 10,20,30
        }
        
        let node2Rows = try await dbManager.reader { db in
            try Row.fetchAll(db, sql: "SELECT value FROM samples_1min WHERE source = 1 AND type = 1 AND node_id = ?", arguments: [Self.node2])
        }
        XCTAssertEqual(node2Rows.count, 1)
        if let row = node2Rows.first {
            let value: Double = row["value"]
            XCTAssertEqual(value, 50.0, accuracy: 0.001)  // mean of 40,50,60
        }
    }

    func testDoesNotRollupOpenBucket() async throws {
        // Seed samples in the current minute bucket
        let now = 100.0
        let bucketStart = floor(now / 60) * 60  // 60
        let bucketEnd = bucketStart + 60        // 120
        
        var rows: [SampleRow] = []
        rows.append(SampleRow(source: 1, type: 1, timestamp: bucketStart + 10, value: 10, extra: nil,
                              hlcPhysical: 1000, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 1, timestamp: bucketStart + 20, value: 20, extra: nil,
                              hlcPhysical: 1001, hlcLogical: 0, nodeID: Self.node1))
        
        let inserted = try await samplesStore.insert(rows)
        XCTAssertEqual(inserted, 2)
        
        // Try to downsample with now = bucketEnd - 1 (bucket still open)
        let result = try await downsampler.downsample(now: bucketEnd - 1, source: 1, type: 1)
        XCTAssertEqual(result.bucketsWritten, 0)
        
        // Check no rollups were created
        let count = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples_1min") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    func testSkipsAlreadyRolluppedBuckets() async throws {
        // Seed samples for node1
        var rows: [SampleRow] = []
        rows.append(SampleRow(source: 1, type: 1, timestamp: 10, value: 10, extra: nil,
                              hlcPhysical: 1000, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 1, timestamp: 20, value: 20, extra: nil,
                              hlcPhysical: 1001, hlcLogical: 0, nodeID: Self.node1))
        
        let inserted = try await samplesStore.insert(rows)
        XCTAssertEqual(inserted, 2)
        
        // First downsample (node1 only)
        let result1 = try await downsampler.downsample(now: 100, source: 1, type: 1)
        XCTAssertEqual(result1.bucketsWritten, 1)
        
        // Add samples for node2 (different timestamps to avoid PK conflict)
        var moreRows: [SampleRow] = []
        moreRows.append(SampleRow(source: 1, type: 1, timestamp: 11, value: 30, extra: nil,
                                  hlcPhysical: 1002, hlcLogical: 0, nodeID: Self.node2))
        moreRows.append(SampleRow(source: 1, type: 1, timestamp: 21, value: 40, extra: nil,
                                  hlcPhysical: 1003, hlcLogical: 0, nodeID: Self.node2))
        
        let moreInserted = try await samplesStore.insert(moreRows)
        XCTAssertEqual(moreInserted, 2)
        
        // Second downsample should write 1 new bucket (node2), not skip it
        let result2 = try await downsampler.downsample(now: 100, source: 1, type: 1)
        XCTAssertEqual(result2.bucketsWritten, 1)
        
        // Third downsample should write 0 new buckets (both nodes already processed)
        let result3 = try await downsampler.downsample(now: 100, source: 1, type: 1)
        XCTAssertEqual(result3.bucketsWritten, 0)
    }

    func testDownsampleAllYieldsAcrossPartitions() async throws {
        // Seed two distinct (source, type) partitions (non-HK owned)
        var rows: [SampleRow] = []
        // First partition
        rows.append(SampleRow(source: 1, type: 1, timestamp: 10, value: 10, extra: nil,
                              hlcPhysical: 1000, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 1, timestamp: 20, value: 20, extra: nil,
                              hlcPhysical: 1001, hlcLogical: 0, nodeID: Self.node1))
        // Second partition (different type, not HK-owned)
        rows.append(SampleRow(source: 1, type: 2, timestamp: 10, value: 30, extra: nil,
                              hlcPhysical: 1002, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 2, timestamp: 20, value: 40, extra: nil,
                              hlcPhysical: 1003, hlcLogical: 0, nodeID: Self.node1))
        
        let inserted = try await samplesStore.insert(rows)
        XCTAssertEqual(inserted, 4)
        
        // Downsample all
        let results = try await downsampler.downsampleAll(now: 100)
        XCTAssertEqual(results.count, 2)
        
        // Should have results for both partitions
        XCTAssertTrue(results.contains { $0.source == 1 && $0.type == 1 && $0.bucketsWritten == 1 })
        XCTAssertTrue(results.contains { $0.source == 1 && $0.type == 2 && $0.bucketsWritten == 1 })
    }

    func testAggregatorMaxAndMin() async throws {
        // First test max aggregator
        // Seed 3 values (5, 10, 15) in one bucket
        var rows: [SampleRow] = []
        rows.append(SampleRow(source: 1, type: 3, timestamp: 10, value: 5, extra: nil,
                              hlcPhysical: 1000, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 3, timestamp: 20, value: 10, extra: nil,
                              hlcPhysical: 1001, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 3, timestamp: 30, value: 15, extra: nil,
                              hlcPhysical: 1002, hlcLogical: 0, nodeID: Self.node1))
        
        let inserted = try await samplesStore.insert(rows)
        XCTAssertEqual(inserted, 3)
        
        // Test max aggregator
        let maxResult = try await downsampler.downsample(now: 100, source: 1, type: 3, aggregator: .max)
        XCTAssertEqual(maxResult.bucketsWritten, 1)
        
        let maxValue = try await dbManager.reader { db in
            try Double.fetchOne(db, sql: "SELECT value FROM samples_1min WHERE source = 1 AND type = 3")
        }
        XCTAssertEqual(maxValue, 15.0)
        
        // Test min aggregator with different data
        // Seed 3 values (5, 10, 15) in one bucket for min test
        var minRows: [SampleRow] = []
        minRows.append(SampleRow(source: 1, type: 4, timestamp: 10, value: 5, extra: nil,
                              hlcPhysical: 1003, hlcLogical: 0, nodeID: Self.node1))
        minRows.append(SampleRow(source: 1, type: 4, timestamp: 20, value: 10, extra: nil,
                              hlcPhysical: 1004, hlcLogical: 0, nodeID: Self.node1))
        minRows.append(SampleRow(source: 1, type: 4, timestamp: 30, value: 15, extra: nil,
                              hlcPhysical: 1005, hlcLogical: 0, nodeID: Self.node1))
        
        let minInserted = try await samplesStore.insert(minRows)
        XCTAssertEqual(minInserted, 3)
        
        let minResult = try await downsampler.downsample(now: 100, source: 1, type: 4, aggregator: .min)
        XCTAssertEqual(minResult.bucketsWritten, 1)
        
        let minValue = try await dbManager.reader { db in
            try Double.fetchOne(db, sql: "SELECT value FROM samples_1min WHERE source = 1 AND type = 4")
        }
        XCTAssertEqual(minValue, 5.0)
    }

    func testSkipsHealthKitOwnedTypes() async throws {
        // Try to downsample source=2 type=1 (HR)
        let result = try await downsampler.downsample(now: 100, source: 2, type: 1)
        XCTAssertEqual(result.bucketsWritten, 0)
        
        // Check no rollups were created
        let count = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples_1min") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    func testCancellationThrows() async throws {
        // Seed some data with non-HK owned types
        var rows: [SampleRow] = []
        rows.append(SampleRow(source: 1, type: 1, timestamp: 10, value: 10, extra: nil,
                              hlcPhysical: 1000, hlcLogical: 0, nodeID: Self.node1))
        rows.append(SampleRow(source: 1, type: 2, timestamp: 10, value: 20, extra: nil,
                              hlcPhysical: 1001, hlcLogical: 0, nodeID: Self.node1))
        
        let inserted = try await samplesStore.insert(rows)
        XCTAssertEqual(inserted, 2)
        
        // Create a task and cancel it immediately
        let task = Task {
            try await self.downsampler.downsampleAll(now: 100)
        }
        task.cancel()
        
        do {
            let _ = try await task.value
            XCTFail("Should have thrown cancellation error")
        } catch {
            // Expected cancellation
        }
    }
}