import XCTest
import GRDB
@testable import AnxietyWatchKit

final class PanicProtocolTests: XCTestCase {
    private var tempDirectory: URL!
    private var database: DatabaseManager!
    private var samplesStore: SamplesStore!
    private var tombstonesStore: SampleTombstonesStore!
    private var hlc: HLC!

    /// Fixed wall clock for the HLC so "fresh tombstone HLC" is assertable.
    private let hlcWall: Int64 = 5_000_000_000

    private let ourNode = Data(repeating: 0xAA, count: 16)

    /// ACKed watermark used in most tests: rows with pt <= 1_000 are ACKed.
    private var ackedCursor: [Data: (physical: Int64, logical: Int32)] {
        [ourNode: (physical: 1_000, logical: 0)]
    }

    private let yellowSize: Int64 = 225 * 1024 * 1024
    private let redSize: Int64 = 250 * 1024 * 1024

    /// Thread-safe call recorder for the sync hook.
    private final class HookRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }
        func record() {
            lock.lock()
            defer { lock.unlock() }
            _calls += 1
        }
    }

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

    private func makePanic(
        syncSucceeds: Bool,
        recorder: HookRecorder? = nil,
        targetSizeBytes: Int64 = 200 * 1024 * 1024
    ) -> PanicProtocol {
        PanicProtocol(
            dependencies: .init(
                database: database,
                samples: samplesStore,
                tombstones: tombstonesStore,
                hlc: hlc,
                syncOnceHook: {
                    recorder?.record()
                    if !syncSucceeds {
                        throw SyncEndpointError.transientFailure("mock failure")
                    }
                }
            ),
            targetSizeBytes: targetSizeBytes,
            syncTimeoutSeconds: 5
        )
    }

    /// Seed samples for one (source=1, type=1) group on ourNode.
    private func seedSamples(timestamps: [Double], pt: Int64, lcStart: Int32 = 0) async throws {
        let rows = timestamps.enumerated().map { i, ts in
            SampleRow(source: 1, type: 1, timestamp: ts, value: 1.0, extra: nil,
                      hlcPhysical: pt, hlcLogical: lcStart + Int32(i), nodeID: ourNode)
        }
        _ = try await samplesStore.insert(rows)
    }

    // MARK: - Tests

    func testNormalBelowYellow() async throws {
        try await seedSamples(timestamps: [100, 200], pt: 100)
        let recorder = HookRecorder()
        let panic = makePanic(syncSucceeds: true, recorder: recorder)

        let result = try await panic.runPanicCheck(
            currentSizeBytes: 100 * 1024 * 1024,
            ackedCursorPerNode: ackedCursor
        )

        XCTAssertEqual(result, .normal)
        XCTAssertEqual(recorder.calls, 0, "no urgent push below Yellow")
        let count = try await samplesStore.count()
        XCTAssertEqual(count, 2, "no eviction below Yellow")
        let gaps = try await tombstonesStore.count()
        XCTAssertEqual(gaps, 0)
    }

    func testYellowUrgentSyncSucceeded() async throws {
        try await seedSamples(timestamps: [100, 200], pt: 100)
        let recorder = HookRecorder()
        let panic = makePanic(syncSucceeds: true, recorder: recorder)

        let result = try await panic.runPanicCheck(
            currentSizeBytes: yellowSize + 1024,
            ackedCursorPerNode: ackedCursor
        )

        XCTAssertEqual(result, .yellowSyncSucceeded)
        XCTAssertEqual(recorder.calls, 1)
        let count = try await samplesStore.count()
        XCTAssertEqual(count, 2, "no eviction when the urgent push succeeds")
        let gaps = try await tombstonesStore.count()
        XCTAssertEqual(gaps, 0)
    }

    func testYellowUrgentSyncFailedUnderRedNoAction() async throws {
        // Yellow band with a FAILED push but below Red: distinguishable from
        // truly-normal, and still no eviction (spec: keep accepting writes).
        try await seedSamples(timestamps: [100, 200], pt: 100)
        let recorder = HookRecorder()
        let panic = makePanic(syncSucceeds: false, recorder: recorder)

        let result = try await panic.runPanicCheck(
            currentSizeBytes: yellowSize + 1024,   // >= yellow, < red
            ackedCursorPerNode: ackedCursor
        )

        XCTAssertEqual(result, .yellowSyncFailedNoActionNeeded)
        XCTAssertEqual(recorder.calls, 1)
        let count = try await samplesStore.count()
        XCTAssertEqual(count, 2, "no eviction below Red even when the push fails")
        let gaps = try await tombstonesStore.count()
        XCTAssertEqual(gaps, 0)
    }

    func testRedEvictionStopsOnceEnoughReclaimed() async throws {
        // Real bulk data across many 6 h chunks so delete + incremental_vacuum
        // measurably shrinks the file chunk by chunk.
        // 48 h of samples, one per 60 s, with a 256-byte extra blob:
        // 2_880 rows ≈ 8 chunks of 6 h each.
        let blob = Data(repeating: 0xCD, count: 256)
        var rows: [SampleRow] = []
        for i in 0..<2_880 {
            rows.append(SampleRow(source: 1, type: 1, timestamp: Double(i) * 60, value: 1.0,
                                  extra: blob, hlcPhysical: 100, hlcLogical: Int32(i % 1_000),
                                  nodeID: ourNode))
        }
        // hlcLogical must be unique per (pt); vary pt slightly to keep all ACKed.
        rows = rows.enumerated().map { i, r in
            SampleRow(source: r.source, type: r.type, timestamp: r.timestamp, value: r.value,
                      extra: r.extra, hlcPhysical: 100 + Int64(i / 1_000), hlcLogical: Int32(i % 1_000),
                      nodeID: r.nodeID)
        }
        _ = try await samplesStore.insert(rows)

        func measuredSize() async throws -> Int64 {
            try await database.reader { db in
                let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                return pages * pageSize
            }
        }

        let initialSize = try await measuredSize()
        // Target: shed roughly a quarter of the file — reachable well before
        // evicting all 8 chunks.
        let target = initialSize * 3 / 4

        let panic = PanicProtocol(
            dependencies: .init(
                database: database,
                samples: samplesStore,
                tombstones: tombstonesStore,
                hlc: hlc,
                syncOnceHook: { throw SyncEndpointError.transientFailure("mock failure") }
            ),
            yellowThresholdBytes: initialSize - 2,
            redThresholdBytes: initialSize - 1,
            targetSizeBytes: target,
            syncTimeoutSeconds: 5
        )

        let result = try await panic.runPanicCheck(
            currentSizeBytes: initialSize,
            ackedCursorPerNode: ackedCursor
        )

        guard case .yellowSyncFailedThenRed(let dropped, let gaps) = result else {
            return XCTFail("Expected red eviction, got \(result)")
        }

        // (a) Did NOT over-evict: rows remain.
        let remaining = try await samplesStore.count()
        XCTAssertGreaterThan(remaining, 0, "eviction must stop once enough bytes are reclaimed")
        XCTAssertEqual(remaining + dropped, 2_880)

        // (b) The file actually shrank to the target — the whole point of
        // auto_vacuum=INCREMENTAL + incremental_vacuum per chunk.
        let finalSize = try await measuredSize()
        XCTAssertLessThanOrEqual(finalSize, target)

        // (c) Tombstone bookkeeping matches: one gap per evicted chunk, fewer
        // than the total number of chunks (8), all memory_panic.
        let gapRows = try await tombstonesStore.fetchOverlapping(source: 1, type: 1, from: 0, to: 1_000_000)
        XCTAssertEqual(gapRows.count, gaps)
        XCTAssertGreaterThanOrEqual(gaps, 1)
        XCTAssertLessThan(gaps, 8, "should not have needed every chunk")
        for gap in gapRows {
            XCTAssertEqual(gap.reason, .memoryPanic)
        }
    }

    func testYellowUrgentSyncFailedThenRedEvicts() async throws {
        // 10 ACKed samples inside one 6 h span → one memory_panic gap.
        let timestamps = (0..<10).map { Double($0) * 100 + 100 }  // 100...1000
        try await seedSamples(timestamps: timestamps, pt: 100)
        let recorder = HookRecorder()
        let panic = makePanic(syncSucceeds: false, recorder: recorder)

        let result = try await panic.runPanicCheck(
            currentSizeBytes: redSize + 1024,
            ackedCursorPerNode: ackedCursor
        )

        XCTAssertEqual(result, .yellowSyncFailedThenRed(dropped: 10, gapsInserted: 1))
        XCTAssertEqual(recorder.calls, 1, "Yellow push attempted before Red")

        let remaining = try await samplesStore.count()
        XCTAssertEqual(remaining, 0)

        let gaps = try await tombstonesStore.fetchOverlapping(source: 1, type: 1, from: 0, to: 10_000)
        XCTAssertEqual(gaps.count, 1)
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gap.reason, .memoryPanic)
        XCTAssertEqual(gap.tsStart, 100)
        XCTAssertEqual(gap.tsEnd, 1_000)
        XCTAssertEqual(gap.droppedRowCount, 10)
        // Fresh HLC — minted at eviction time, not the dropped rows' pt=100.
        XCTAssertEqual(gap.hlcPhysical, hlcWall)
        XCTAssertEqual(gap.nodeID, ourNode)
    }

    func testOverflowPreconditionsMet() async throws {
        // Every sample is un-ACKed (pt 5_000 > cursor 1_000) — protected.
        try await seedSamples(timestamps: [100, 200, 300], pt: 5_000)
        let panic = makePanic(syncSucceeds: false)

        do {
            _ = try await panic.runPanicCheck(
                currentSizeBytes: redSize + 1024,
                ackedCursorPerNode: ackedCursor
            )
            XCTFail("Expected PanicError.overflowPreconditionsMet")
        } catch let error as PanicProtocol.PanicError {
            guard case .overflowPreconditionsMet = error else {
                return XCTFail("Expected overflowPreconditionsMet, got \(error)")
            }
        }

        // Un-ACKed rows untouched — T18 must never delete them.
        let count = try await samplesStore.count()
        XCTAssertEqual(count, 3)
        let gaps = try await tombstonesStore.count()
        XCTAssertEqual(gaps, 0)
    }

    func testEvictionOrderOldestFirst() async throws {
        // 8 hours of ACKed samples, every 30 min: ts 0, 1800, ..., 28_800.
        // One eviction chunk covers 6 h (ts < 21_600); with the target already
        // satisfied after the first chunk, ONLY the oldest chunk is dropped.
        let timestamps = stride(from: 0.0, through: 28_800.0, by: 1_800.0).map { $0 }
        try await seedSamples(timestamps: timestamps, pt: 100)
        let panic = makePanic(syncSucceeds: false, targetSizeBytes: Int64.max)

        let result = try await panic.runPanicCheck(
            currentSizeBytes: redSize + 1024,
            ackedCursorPerNode: ackedCursor
        )

        guard case .yellowSyncFailedThenRed(let dropped, let gaps) = result else {
            return XCTFail("Expected red eviction, got \(result)")
        }
        XCTAssertEqual(dropped, 12, "ts 0...19_800 (< 21_600) — the OLDEST 6 h chunk")
        XCTAssertEqual(gaps, 1)

        // Newest rows survive.
        let survivors = try await samplesStore.fetch(source: 1, type: 1, from: 0, to: 50_000)
        XCTAssertEqual(survivors.count, timestamps.count - 12)
        XCTAssertEqual(survivors.first?.timestamp, 21_600)

        // Tombstone starts at the original oldest timestamp.
        let gapRows = try await tombstonesStore.fetchOverlapping(source: 1, type: 1, from: 0, to: 50_000)
        XCTAssertEqual(gapRows.first?.tsStart, 0)
        XCTAssertEqual(gapRows.first?.tsEnd, 19_800)
    }

    func testTombstoneHLCIsFresh() async throws {
        // Dropped rows carry pt=100; the HLC mock's wall is hlcWall — the
        // tombstone must carry the freshly minted stamp.
        try await seedSamples(timestamps: [100, 200], pt: 100)
        let panic = makePanic(syncSucceeds: false)

        _ = try await panic.runPanicCheck(
            currentSizeBytes: redSize + 1024,
            ackedCursorPerNode: ackedCursor
        )

        let gaps = try await tombstonesStore.fetchOverlapping(source: 1, type: 1, from: 0, to: 10_000)
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gap.hlcPhysical, hlcWall, "tombstone HLC must be HLC.now() at eviction time")
        XCTAssertNotEqual(gap.hlcPhysical, 100, "must NOT reuse the dropped rows' HLC")

        // And it matches what the HLC service actually minted (same physical,
        // logical advanced past the mint).
        let local = await hlc.currentLocal
        XCTAssertEqual(local.physical, hlcWall)
    }

    func testDataGapCoversFullRange() async throws {
        try await seedSamples(timestamps: [100, 200, 300], pt: 100)
        let panic = makePanic(syncSucceeds: false)

        let result = try await panic.runPanicCheck(
            currentSizeBytes: redSize + 1024,
            ackedCursorPerNode: ackedCursor
        )

        XCTAssertEqual(result, .yellowSyncFailedThenRed(dropped: 3, gapsInserted: 1))

        let gaps = try await tombstonesStore.fetchOverlapping(source: 1, type: 1, from: 0, to: 10_000)
        XCTAssertEqual(gaps.count, 1)
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gap.tsStart, 100)
        XCTAssertEqual(gap.tsEnd, 300)
        XCTAssertEqual(gap.droppedRowCount, 3)
    }
}
