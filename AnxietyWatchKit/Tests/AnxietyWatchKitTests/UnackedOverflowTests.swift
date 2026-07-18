import XCTest
import GRDB
@testable import AnxietyWatchKit

final class UnackedOverflowTests: XCTestCase {
    private var tempDirectory: URL!
    private var database: DatabaseManager!
    private var samplesStore: SamplesStore!
    private var tombstonesStore: SampleTombstonesStore!
    private var downsampler: IdleDownsampler!
    private var hlc: HLC!

    /// Fixed wall (ms). nowSeconds = 5_000_000 s — all small test timestamps
    /// are safely inside fully-closed minute buckets.
    private let hlcWall: Int64 = 5_000_000_000

    private let ourNode = Data(repeating: 0xAA, count: 16)

    override func setUp() {
        super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnxietyWatchKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        database = DatabaseManager(url: tempDirectory.appendingPathComponent("test.db"))
        let wall = hlcWall
        hlc = HLC(nodeID: ourNode, now: { wall }, monotonicNow: { 0 })

        let setupExpectation = expectation(description: "setup")
        Task {
            do {
                try await database.open()
                try await database.writer { db in
                    try SchemaV1.apply(to: db)
                }
                setupExpectation.fulfill()
            } catch {
                XCTFail("setup failed: \(error)")
                setupExpectation.fulfill()
            }
        }
        waitForExpectations(timeout: 10)

        samplesStore = SamplesStore(database: database)
        tombstonesStore = SampleTombstonesStore(database: database)
        downsampler = IdleDownsampler(database: database)
    }

    override func tearDown() {
        let teardownExpectation = expectation(description: "teardown")
        Task {
            await database.close()
            teardownExpectation.fulfill()
        }
        waitForExpectations(timeout: 10)
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeOverflow(syncSucceeds: Bool = false) -> UnackedOverflow {
        UnackedOverflow(
            dependencies: .init(
                database: database,
                samples: samplesStore,
                tombstones: tombstonesStore,
                downsampler: downsampler,
                hlc: hlc,
                syncOnceHook: {
                    if !syncSucceeds {
                        throw SyncEndpointError.transientFailure("mock failure")
                    }
                }
            ),
            urgentSyncTimeoutSeconds: 5
        )
    }

    /// Seed un-ACKed raw samples on ourNode.
    private func seedSamples(timestamps: [Double], pt: Int64 = 100,
                             source: Int32 = 1, type: Int32 = 1) async throws {
        let rows = timestamps.enumerated().map { i, ts in
            SampleRow(source: source, type: type, timestamp: ts, value: Double(i), extra: nil,
                      hlcPhysical: pt, hlcLogical: Int32(i), nodeID: ourNode)
        }
        _ = try await samplesStore.insert(rows)
    }

    private func rollupCount() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples_1min") ?? 0
        }
    }

    private func run(_ overflow: UnackedOverflow) async throws -> UnackedOverflow.OverflowResult {
        try await overflow.run(
            currentSizeBytes: 260 * 1024 * 1024,
            ordinaryEvictionAttempted: true,
            urgentSyncAttempted: true
        )
    }

    // MARK: - Preconditions

    func testThrowsWhenOrdinaryEvictionNotAttempted() async throws {
        try await seedSamples(timestamps: [100, 200])
        let overflow = makeOverflow()

        do {
            _ = try await overflow.run(
                currentSizeBytes: 260 * 1024 * 1024,
                ordinaryEvictionAttempted: false,
                urgentSyncAttempted: true
            )
            XCTFail("Expected ordinaryEvictionNotAttempted")
        } catch let error as UnackedOverflow.OverflowError {
            XCTAssertEqual(error, .ordinaryEvictionNotAttempted)
        }

        let count = try await samplesStore.count()
        XCTAssertEqual(count, 2, "no data may be touched when preconditions fail")
    }

    func testThrowsWhenUrgentSyncNotAttempted() async throws {
        try await seedSamples(timestamps: [100, 200])
        let overflow = makeOverflow()

        do {
            _ = try await overflow.run(
                currentSizeBytes: 260 * 1024 * 1024,
                ordinaryEvictionAttempted: true,
                urgentSyncAttempted: false
            )
            XCTFail("Expected urgentSyncNotAttempted")
        } catch let error as UnackedOverflow.OverflowError {
            XCTAssertEqual(error, .urgentSyncNotAttempted)
        }

        let count = try await samplesStore.count()
        XCTAssertEqual(count, 2)
    }

    func testLastChanceSyncSuccessSkipsEviction() async throws {
        // Bonus guard: if the defensive last-chance push succeeds, NO un-ACKed
        // data is dropped.
        try await seedSamples(timestamps: [100, 200])
        let overflow = makeOverflow(syncSucceeds: true)

        let result = try await run(overflow)
        XCTAssertEqual(result, .zero)
        let count = try await samplesStore.count()
        XCTAssertEqual(count, 2)
    }

    func testHysteresisPreventsRepeatWithinWindow() async throws {
        try await seedSamples(timestamps: [100, 200])

        // A prior unacked_overflow for (1,1) fired 1 minute ago.
        try await tombstonesStore.insert([SampleTombstoneRow(
            source: 1, type: 1, tsStart: 10, tsEnd: 20,
            hlcPhysical: hlcWall - 60_000, hlcLogical: 0, nodeID: ourNode,
            droppedRowCount: 5, reason: .unackedOverflow
        )])

        // Per-group hysteresis SKIPS the group (expected steady state — wait
        // for the next window); it does not throw.
        let overflow = makeOverflow()
        let result = try await run(overflow)

        XCTAssertEqual(result.hysteresisBlockedGroups, 1)
        XCTAssertEqual(result.evictedGroups, 0)
        XCTAssertEqual(result.evictedSamples, 0)
        XCTAssertEqual(result.tombstonesInserted, 0)

        let count = try await samplesStore.count()
        XCTAssertEqual(count, 2, "hysteresis must protect the raw rows")
    }

    func testMultiGroupHysteresisSkipsBlockedContinuesOthers() async throws {
        // Group (1,1): hysteresis active (fired 30 min ago).
        try await seedSamples(timestamps: [100, 200], source: 1, type: 1)
        try await tombstonesStore.insert([SampleTombstoneRow(
            source: 1, type: 1, tsStart: 10, tsEnd: 20,
            hlcPhysical: hlcWall - 30 * 60_000, hlcLogical: 0, nodeID: ourNode,
            droppedRowCount: 5, reason: .unackedOverflow
        )])

        // Group (2,2): un-ACKed samples, no recent tombstone — evictable.
        // (NOT (2,1): source 2 + type 1 is HealthKit-owned and traps on insert.)
        try await seedSamples(timestamps: [300, 400, 500], source: 2, type: 2)

        let overflow = makeOverflow()
        let result = try await run(overflow)

        // Blocked group skipped; the other group still relieves pressure.
        XCTAssertEqual(result.hysteresisBlockedGroups, 1)
        XCTAssertEqual(result.evictedGroups, 1)
        XCTAssertEqual(result.evictedSamples, 3)
        XCTAssertEqual(result.tombstonesInserted, 1)

        // (1,1) untouched; (2,2) evicted.
        let group1 = try await samplesStore.fetch(source: 1, type: 1, from: 0, to: 10_000)
        XCTAssertEqual(group1.count, 2)
        let group2 = try await samplesStore.fetch(source: 2, type: 2, from: 0, to: 10_000)
        XCTAssertEqual(group2.count, 0)

        let gaps = try await tombstonesStore.fetchOverlapping(source: 2, type: 2, from: 0, to: 10_000)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.reason, .unackedOverflow)
        XCTAssertEqual(gaps.first?.tsStart, 300)
        XCTAssertEqual(gaps.first?.tsEnd, 500)
    }

    // MARK: - Eviction

    func testEvictsOldestUnAckedSamplesForOneGroup() async throws {
        // 8 hours of raw samples every 30 min: ts 0, 1_800, ..., 28_800 (17 rows).
        let timestamps = stride(from: 0.0, through: 28_800.0, by: 1_800.0).map { $0 }
        try await seedSamples(timestamps: timestamps)

        let overflow = makeOverflow()
        let result = try await run(overflow)

        // Exactly the oldest 6 h evicted: ts < 21_600 → 12 rows.
        XCTAssertEqual(result.evictedGroups, 1)
        XCTAssertEqual(result.evictedSamples, 12)
        XCTAssertEqual(result.tombstonesInserted, 1)

        let survivors = try await samplesStore.fetch(source: 1, type: 1, from: 0, to: 50_000)
        XCTAssertEqual(survivors.count, timestamps.count - 12)
        XCTAssertEqual(survivors.first?.timestamp, 21_600)

        let gaps = try await tombstonesStore.fetchOverlapping(source: 1, type: 1, from: 0, to: 50_000)
        XCTAssertEqual(gaps.count, 1)
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gap.tsStart, 0)
        XCTAssertEqual(gap.tsEnd, 19_800)
        XCTAssertEqual(gap.droppedRowCount, 12)
    }

    func testPreservesRollupsUnderEviction() async throws {
        // Raw samples in three minute-buckets + their pre-existing rollups.
        try await seedSamples(timestamps: [0, 60, 120])
        try await database.writer { [ourNode] db in
            for bucket in [0, 1, 2] {
                try db.execute(sql: """
                    INSERT INTO samples_1min
                        (source, type, minute_bucket, value, sample_count,
                         hlc_physical, hlc_logical, node_id)
                    VALUES (1, 1, ?, 1.0, 1, 100, 0, ?)
                    """, arguments: [bucket, ourNode])
            }
        }

        let overflow = makeOverflow()
        let result = try await run(overflow)

        XCTAssertEqual(result.evictedSamples, 3)
        XCTAssertEqual(result.downsamplesRun, 0, "rollups already existed — no on-demand downsample needed")

        // Raw gone, rollups fully intact (Spec §2.6: the gap is coarse-grained,
        // not total).
        let raw = try await samplesStore.count()
        XCTAssertEqual(raw, 0)
        let rollups = try await rollupCount()
        XCTAssertEqual(rollups, 3)
    }

    func testOnDemandDownsampleFillsMissingRollups() async throws {
        // Raw samples with NO rollups — precondition (3) must synchronously
        // downsample before eviction.
        try await seedSamples(timestamps: [0, 60, 120])
        let before = try await rollupCount()
        XCTAssertEqual(before, 0)

        let overflow = makeOverflow()
        let result = try await run(overflow)

        XCTAssertEqual(result.downsamplesRun, 1)
        XCTAssertEqual(result.evictedSamples, 3)

        // Rollups were produced from the raw rows BEFORE they were deleted.
        let rollups = try await rollupCount()
        XCTAssertEqual(rollups, 3)
        let raw = try await samplesStore.count()
        XCTAssertEqual(raw, 0)
    }

    func testTombstoneReasonIsUnackedOverflow() async throws {
        try await seedSamples(timestamps: [100, 200, 300])
        let overflow = makeOverflow()
        _ = try await run(overflow)

        let gaps = try await tombstonesStore.fetchOverlapping(source: 1, type: 1, from: 0, to: 10_000)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.reason, .unackedOverflow)
    }

    func testTombstoneHLCIsFresh() async throws {
        // Dropped rows carry pt=100; the tombstone must carry a freshly minted
        // stamp at hlcWall.
        try await seedSamples(timestamps: [100, 200], pt: 100)
        let overflow = makeOverflow()
        _ = try await run(overflow)

        let gaps = try await tombstonesStore.fetchOverlapping(source: 1, type: 1, from: 0, to: 10_000)
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gap.hlcPhysical, hlcWall, "tombstone HLC must be HLC.now() at eviction time")
        XCTAssertNotEqual(gap.hlcPhysical, 100, "must NOT reuse the dropped rows' HLC")
        XCTAssertEqual(gap.nodeID, ourNode)
    }
}
