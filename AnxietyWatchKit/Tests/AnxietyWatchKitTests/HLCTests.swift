import XCTest
import GRDB
@testable import AnxietyWatchKit

final class HLCTests: XCTestCase {
    // MARK: - Helpers

    /// Lock-guarded mutable clock for injecting into HLC.
    private final class MockClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _wall: Int64
        private var _mono: Int64

        init(wall: Int64, mono: Int64 = 0) {
            self._wall = wall
            self._mono = mono
        }

        var wall: Int64 {
            get { lock.lock(); defer { lock.unlock() }; return _wall }
            set { lock.lock(); defer { lock.unlock() }; _wall = newValue }
        }

        var mono: Int64 {
            get { lock.lock(); defer { lock.unlock() }; return _mono }
            set { lock.lock(); defer { lock.unlock() }; _mono = newValue }
        }
    }

    /// Deterministic seeded RNG (SplitMix64) for reproducible property tests.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func makeNodeID(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 16)
    }

    private func makeHLC(nodeByte: UInt8 = 0xA1, clock: MockClock) -> HLC {
        HLC(
            nodeID: makeNodeID(nodeByte),
            now: { clock.wall },
            monotonicNow: { clock.mono }
        )
    }

    // MARK: - now() properties

    func testMonotonicity() async throws {
        // Wall advances slowly (one tick every 3 calls) so both the
        // logical-bump and physical-advance paths are exercised.
        let clock = MockClock(wall: 0)
        let hlc = makeHLC(clock: clock)

        var previous: HLCStamped?
        for i in 0..<1000 {
            clock.wall = Int64(i / 3)
            let current = await hlc.now()
            if let previous {
                XCTAssertGreaterThan(current, previous, "now() not strictly monotonic at call \(i)")
            }
            previous = current
        }
    }

    func testMonotonicityAcrossFrozenWallClock() async throws {
        let clock = MockClock(wall: 100)
        let hlc = makeHLC(clock: clock)

        for i in 0..<500 {
            let stamp = await hlc.now()
            XCTAssertEqual(stamp.physical, 100)
            XCTAssertEqual(stamp.logical, Int32(i), "logical must advance 0, 1, 2, ... under a frozen wall clock")
        }
    }

    func testWallAdvanceResetsLogical() async throws {
        let clock = MockClock(wall: 100)
        let hlc = makeHLC(clock: clock)

        for i in 0..<5 {
            let stamp = await hlc.now()
            XCTAssertEqual(stamp.physical, 100)
            XCTAssertEqual(stamp.logical, Int32(i))
        }

        clock.wall = 200
        let stamp = await hlc.now()
        XCTAssertEqual(stamp.physical, 200)
        XCTAssertEqual(stamp.logical, 0)
    }

    // MARK: - observe() properties

    func testObserveMovesForwardOnHigherRemote() async throws {
        let clock = MockClock(wall: 100)
        let hlc = makeHLC(clock: clock)
        _ = await hlc.now()  // local = (100, 0)

        let remote = HLCStamped(physical: 200, logical: 5, nodeID: makeNodeID(0xB2))
        let result = try await hlc.observe(remote)

        XCTAssertGreaterThanOrEqual(result.physical, 200)
        XCTAssertGreaterThanOrEqual(result, remote)
        // Kulkarni: candidate == clamped remote → lc = remote.lc + 1.
        XCTAssertEqual(result.physical, 200)
        XCTAssertEqual(result.logical, 6)

        let local = await hlc.currentLocal
        XCTAssertGreaterThanOrEqual(local.physical, 200)
    }

    func testObserveNoOpOnLowerRemote() async throws {
        let clock = MockClock(wall: 200)
        let hlc = makeHLC(clock: clock)
        for _ in 0..<4 { _ = await hlc.now() }  // local = (200, 3)

        let before = await hlc.currentLocal
        XCTAssertEqual(before.physical, 200)
        XCTAssertEqual(before.logical, 3)

        let remote = HLCStamped(physical: 100, logical: 0, nodeID: makeNodeID(0xB2))
        let result = try await hlc.observe(remote)

        // Physical must NOT move; the receive event only ticks the local
        // logical counter (Kulkarni receive always produces a fresh event),
        // uninfluenced by the stale remote's counter.
        XCTAssertEqual(result.physical, 200)
        XCTAssertEqual(result.logical, 4)

        let after = await hlc.currentLocal
        XCTAssertEqual(after.physical, 200)
    }

    func testObserveBoundsMergeAt60sDrift() async throws {
        let clock = MockClock(wall: 1000)
        let hlc = makeHLC(clock: clock)

        // Remote is 60_001 ms ahead of wall — beyond the 60 s bound, below 24 h.
        let remote = HLCStamped(physical: 61_001, logical: 0, nodeID: makeNodeID(0xB2))
        let result = try await hlc.observe(remote)

        // Bounded merge: local physical clamped to wall + 60_000 = 61_000.
        XCTAssertLessThanOrEqual(result.physical, 61_000)
        XCTAssertEqual(result.physical, 61_000)
        XCTAssertEqual(result.logical, 1)  // clamped-remote wins → remote.lc + 1

        let local = await hlc.currentLocal
        XCTAssertLessThanOrEqual(local.physical, 61_000)
    }

    func testObserveThrowsAt24hDrift() async throws {
        // NOTE: the drift threshold is remote.pt - wall > 86_400_000. With
        // wall = 1, remote.pt = 86_400_002 gives drift 86_400_001 — just over.
        let clock = MockClock(wall: 1)
        let hlc = makeHLC(clock: clock)

        let remote = HLCStamped(physical: 86_400_002, logical: 0, nodeID: makeNodeID(0xB2))
        do {
            _ = try await hlc.observe(remote)
            XCTFail("Expected HLCError.driftExceeded")
        } catch let error as HLC.HLCError {
            XCTAssertEqual(error, .driftExceeded(driftMillis: 86_400_001))
        }

        // The failed observe must NOT have perturbed the local clock.
        let local = await hlc.currentLocal
        XCTAssertEqual(local.physical, 0)
        XCTAssertEqual(local.logical, 0)
    }

    func testObserveConcurrentSameWall() async throws {
        let clock = MockClock(wall: 100)
        let hlc = makeHLC(clock: clock)
        for _ in 0..<4 { _ = await hlc.now() }  // local = (100, 3)

        let remote = HLCStamped(physical: 100, logical: 5, nodeID: makeNodeID(0xB2))
        let result = try await hlc.observe(remote)

        // candidate == local.pt == remote.pt → lc = max(3, 5) + 1 = 6.
        XCTAssertEqual(result.physical, 100)
        XCTAssertEqual(result.logical, 6)
    }

    func testObserveRejectsInvalidRemote() async throws {
        let clock = MockClock(wall: 100)
        let hlc = makeHLC(clock: clock)

        do {
            _ = try await hlc.observe(HLCStamped(physical: 100, logical: 0, nodeID: Data()))
            XCTFail("Expected HLCError.invalidRemote for empty nodeID")
        } catch let error as HLC.HLCError {
            guard case .invalidRemote = error else {
                return XCTFail("Expected invalidRemote, got \(error)")
            }
        }

        do {
            _ = try await hlc.observe(HLCStamped(physical: -5, logical: 0, nodeID: makeNodeID(0xB2)))
            XCTFail("Expected HLCError.invalidRemote for negative physical")
        } catch let error as HLC.HLCError {
            guard case .invalidRemote = error else {
                return XCTFail("Expected invalidRemote, got \(error)")
            }
        }
    }

    // MARK: - SQLite UDFs

    /// Opens a temp DB with SchemaV1 applied. Caller must close + remove dir.
    private func makeTempDatabase() async throws -> (DatabaseManager, URL) {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnxietyWatchKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let dbURL = tempDirectory.appendingPathComponent("test.db")
        let database = DatabaseManager(url: dbURL)
        try await database.open()
        try await database.writer { db in
            try SchemaV1.apply(to: db)
        }
        return (database, tempDirectory)
    }

    func testRegisterUDFsMintOneHLCPerTriggerRow() async throws {
        let (database, tempDirectory) = try await makeTempDatabase()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let nodeID = makeNodeID(0xC3)
        let hlc = HLC(nodeID: nodeID)  // real clocks
        try await hlc.registerUDFs(on: database)

        // test_source table + trigger using the REQUIRED T16 scalar-subquery
        // pattern: hlc_now_json() evaluated exactly once per row inside the
        // FROM subquery; all three fields extracted from the same stamp, with
        // NO dependency on SQLite's expression evaluation order.
        try await database.writer { db in
            try db.execute(sql: "CREATE TABLE test_source (id INTEGER PRIMARY KEY, v TEXT)")
            try db.execute(sql: """
                CREATE TRIGGER trg_test_source_sync AFTER INSERT ON test_source BEGIN
                  INSERT INTO _sync_log (table_name, row_pk, hlc_physical, hlc_logical, node_id, operation)
                  SELECT 'test_source', CAST(NEW.id AS TEXT),
                         json_extract(h, '$.pt'),
                         json_extract(h, '$.lc'),
                         unhex(json_extract(h, '$.n')),
                         'upsert'
                    FROM (SELECT hlc_now_json() AS h);
                END
                """)
        }

        // 3 rows in one batch (single write transaction).
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO test_source (id, v) VALUES (1, 'a'), (2, 'b'), (3, 'c')")
        }

        struct LogRow {
            let rowPK: String
            let pt: Int64
            let lc: Int32
            let node: Data
        }
        let rows: [LogRow] = try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT row_pk, hlc_physical, hlc_logical, node_id
                  FROM _sync_log
                 WHERE table_name = 'test_source'
                 ORDER BY CAST(row_pk AS INTEGER)
                """).map {
                LogRow(rowPK: $0["row_pk"], pt: $0["hlc_physical"], lc: $0["hlc_logical"], node: $0["node_id"])
            }
        }

        XCTAssertEqual(rows.count, 3)

        // All rows carry the identical 16-byte node ID (hex → unhex round trip).
        for row in rows {
            XCTAssertEqual(row.node, nodeID)
        }

        // Three DIFFERENT (pt, lc) pairs, strictly monotonic in row order —
        // the critical "one HLC per row" invariant.
        let stamps = rows.map { HLCStamped(physical: $0.pt, logical: $0.lc, nodeID: $0.node) }
        XCTAssertEqual(Set(stamps).count, 3, "each trigger row must mint a distinct HLC")
        XCTAssertGreaterThan(stamps[1], stamps[0])
        XCTAssertGreaterThan(stamps[2], stamps[1])

        await database.close()
    }

    /// DECISIVE test for the "one HLC per row" invariant: with a frozen wall
    /// clock the sequence of logicals in a 3-row batch must be exactly 0, 1, 2.
    /// Under a hypothetical broken subquery-flattening regression where each of
    /// the three json_extract() calls minted its own HLC, the sequence would be
    /// [1, 4, 7] (or similar). This turns Opus's out-of-band empirical
    /// verification of SQLite's materialization behavior into a permanent
    /// regression guard — no more "passes by luck".
    func testRegisterUDFsMintsExactlyOncePerRowUnderFrozenClock() async throws {
        let (database, tempDirectory) = try await makeTempDatabase()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let nodeID = makeNodeID(0xC5)
        // Frozen wall clock at 1_000 ms; monotonic mirrors it so no drift.
        let hlc = HLC(nodeID: nodeID, now: { 1_000 }, monotonicNow: { 1_000 })
        try await hlc.registerUDFs(on: database)

        try await database.writer { db in
            try db.execute(sql: "CREATE TABLE frozen_source (id INTEGER PRIMARY KEY)")
            try db.execute(sql: """
                CREATE TRIGGER trg_frozen_sync AFTER INSERT ON frozen_source BEGIN
                  INSERT INTO _sync_log (table_name, row_pk, hlc_physical, hlc_logical, node_id, operation)
                  SELECT 'frozen_source', CAST(NEW.id AS TEXT),
                         json_extract(h, '$.pt'),
                         json_extract(h, '$.lc'),
                         unhex(json_extract(h, '$.n')),
                         'upsert'
                    FROM (SELECT hlc_now_json() AS h);
                END
                """)
        }

        try await database.writer { db in
            try db.execute(sql: "INSERT INTO frozen_source (id) VALUES (1), (2), (3)")
        }

        let pts: [Int64] = try await database.reader { db in
            try Int64.fetchAll(db,
                sql: "SELECT hlc_physical FROM _sync_log WHERE table_name = 'frozen_source' ORDER BY row_pk")
        }
        let lcs: [Int32] = try await database.reader { db in
            try Int32.fetchAll(db,
                sql: "SELECT hlc_logical FROM _sync_log WHERE table_name = 'frozen_source' ORDER BY row_pk")
        }

        // All physical values pinned at the frozen wall (1_000).
        XCTAssertEqual(pts, [1_000, 1_000, 1_000])
        // Exact logical sequence 0, 1, 2 — proves each row minted EXACTLY once.
        // A broken 3-mints-per-row pattern would produce [1, 4, 7] here.
        XCTAssertEqual(lcs, [0, 1, 2],
                       "Frozen clock must yield sequential logicals 0,1,2; other values indicate multi-mint regression")

        await database.close()
    }

    /// NEGATIVE test documenting the failure mode the subquery pattern exists
    /// to prevent: calling hlc_now_json() multiple times directly in a column
    /// list mints a FRESH stamp per call, so extracted fields can mismatch.
    /// This is exactly what T16's macro must NOT emit.
    func testRegisterUDFsRejectOldMultiCallPattern() async throws {
        let (database, tempDirectory) = try await makeTempDatabase()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let hlc = HLC(nodeID: makeNodeID(0xC4))  // real clocks
        try await hlc.registerUDFs(on: database)

        // WRONG pattern: two direct hlc_now_json() calls in one row — each is
        // a separate non-deterministic UDF invocation, i.e. a separate mint.
        try await database.writer { db in
            try db.execute(sql: "CREATE TABLE wrong_base (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE wrong_audit (id INTEGER, h1 TEXT, h2 TEXT, pt1 INTEGER, pt2 INTEGER)")
            try db.execute(sql: """
                CREATE TRIGGER trg_wrong AFTER INSERT ON wrong_base BEGIN
                  INSERT INTO wrong_audit (id, h1, h2, pt1, pt2)
                  SELECT NEW.id,
                         hlc_now_json(),
                         hlc_now_json(),
                         json_extract(hlc_now_json(), '$.pt'),
                         json_extract(hlc_now_json(), '$.lc');
                END
                """)
            try db.execute(sql: "INSERT INTO wrong_base (id) VALUES (1)")
        }

        let (h1, h2, pt1, pt2): (String, String, Int64, Int64) = try await database.reader { db in
            let row = try Row.fetchOne(db, sql: "SELECT h1, h2, pt1, pt2 FROM wrong_audit")!
            return (row["h1"], row["h2"], row["pt1"], row["pt2"])
        }

        // The two full stamps MUST differ (HLC now() is strictly monotonic),
        // proving each direct call minted separately — the subquery pattern
        // is load-bearing.
        XCTAssertNotEqual(h1, h2, "direct multi-call pattern mints a fresh HLC per call — fields would mismatch")

        // The raw pt values of two separate mints in the same millisecond can
        // coincide (logical differs instead); document rather than assert.
        if pt1 == pt2 {
            print("NOTE: two direct hlc_now_json() calls shared physical=\(pt1) — logical counters differed instead; the mismatch failure mode is on (pt, lc) pairs.")
        }

        await database.close()
    }

    // MARK: - Multi-node property test

    func testTotalOrderStabilityUnderShuffledObservations() async throws {
        var rng = SeededRNG(seed: 0xDEC0DE)

        // Three producer nodes. Producer node IDs (0x01/0x02/0x03) sort ABOVE
        // the observer node ID (0x00), so the HLCStamped nodeID tiebreak can
        // never rescue a logical-counter off-by-one: on a (pt, lc) tie,
        // observer < producer, and `merged > event` would correctly FAIL.
        let producerClocks = [
            MockClock(wall: 1_000),
            MockClock(wall: 1_500),
            MockClock(wall: 2_000),
        ]
        let producers = [
            makeHLC(nodeByte: 0x01, clock: producerClocks[0]),
            makeHLC(nodeByte: 0x02, clock: producerClocks[1]),
            makeHLC(nodeByte: 0x03, clock: producerClocks[2]),
        ]

        // Produce 100 events across the three nodes in seeded-random order,
        // occasionally advancing the producer's wall clock. Frozen stretches
        // produce many events sharing the same physical (logical runs), which
        // is what makes the tie branch reachable in observers.
        var events: [HLCStamped] = []
        for _ in 0..<100 {
            let idx = Int(rng.next() % 3)
            if rng.next() % 4 == 0 {
                producerClocks[idx].wall += Int64(rng.next() % 50)
            }
            events.append(await producers[idx].now())
        }

        // Each observer starts with wall BELOW all producer physicals and
        // advances past them during observation, so all three interesting
        // merge branches fire: remote-wins early, ties on repeated physicals,
        // wall-wins once the observer wall overtakes the events.
        var totalTie = 0
        var totalRemoteWins = 0
        var totalWallWins = 0

        // 10 observer rounds: remote-wins hits are record-maxima of the
        // shuffled event stream (~ln(100) ≈ 5 per round), so several rounds
        // are needed to make the >= 10 branch-coverage floor robust.
        for _ in 0..<10 {
            let observerClock = MockClock(wall: 800)
            let observer = makeHLC(nodeByte: 0x00, clock: observerClock)

            var shuffled = events
            shuffled.shuffle(using: &rng)
            for event in shuffled {
                // Classify which merge branch this observation will take,
                // mirroring the implementation's candidate computation.
                let wall = observerClock.wall
                let local = await observer.currentLocal
                let clamped = min(event.physical, wall + 60_000)
                let candidate = max(local.physical, max(clamped, wall))
                if candidate == local.physical && candidate == clamped {
                    totalTie += 1
                } else if candidate == local.physical {
                    // local-wins: uncounted; not one of the required branches.
                } else if candidate == clamped {
                    totalRemoteWins += 1
                } else {
                    totalWallWins += 1
                }

                let merged = try await observer.observe(event)
                XCTAssertGreaterThan(merged, event, "merge result must be > the observed event")

                // Advance the observer wall so it interleaves with, then
                // overtakes, the producer physicals (~1000...2600).
                observerClock.wall += 25
            }

            // Final local HLC strictly greater than every observed event.
            let final = await observer.currentLocal
            for event in events {
                XCTAssertGreaterThan(final, event)
            }
        }

        // Branch coverage: every interesting merge branch must actually fire.
        // A zero count means the test went vacuous — fail loudly.
        XCTAssertGreaterThanOrEqual(totalTie, 10, "tie branch under-covered (\(totalTie))")
        XCTAssertGreaterThanOrEqual(totalRemoteWins, 10, "remote-wins branch under-covered (\(totalRemoteWins))")
        XCTAssertGreaterThanOrEqual(totalWallWins, 10, "wall-wins branch under-covered (\(totalWallWins))")
    }
}
