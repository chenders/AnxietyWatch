import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for `RestoreMode.reconcile` — the "heal a populated store" path.
///
/// Context: sync only pushes UP, and restore only pulls DOWN into a blank store.
/// Neither could repair a store that was merely *incomplete* — a device missing
/// rows the server had could only be fixed by wiping it and restoring from
/// scratch. Reconcile closes that gap.
///
/// The properties that make it safe, all covered here:
///
/// 1. **Every importer is skip-if-present**, keyed on the same natural key the
///    server uses as its PRIMARY KEY (`anxiety_entries.timestamp`,
///    `medication_doses.(timestamp, medication_name)`, …). Note "skip-if-present",
///    NOT "has a unique constraint" — SwiftData resolves a `#Unique` collision by
///    REPLACING the whole object, so relying on the constraint would silently
///    overwrite locally-corrected rows with the server's older copy.
/// 2. **The local copy wins on conflict.** A row differing from the server's is far
///    likelier to be a local correction pending upload than to be stale.
/// 3. **Reconcile never advances the sync cursor.** A reconcile runs against a
///    populated store that may hold rows the server has never seen. Advancing
///    `lastSyncDate` past them would make the next incremental sync's `since`
///    filter skip them forever — they'd exist only on a device that believed
///    they were backed up. That is the CLAUDE.md cursor race in its most
///    destructive form, and it is why the finalize block is restore-only.
/// 4. **The existence guards fail CLOSED.** An unreadable table aborts the whole
///    reconcile rather than degrading to "nothing exists" — which would disable the
///    skip checks and re-enable the clobber in (1). A guard that fails open is worse
///    than no guard, because it looks like protection.
/// `.serialized` + a private `SyncService()` instance rather than `.shared`: the
/// config properties are stored instance vars whose `didSet` writes through to
/// `UserDefaults.standard`. Asserting on a private instance keeps the cursor check
/// immune to whatever `SyncServiceTests` is doing concurrently; `.serialized` keeps
/// this suite's own write-through from racing itself. (Swift Testing parallelizes
/// tests by default, which is what made the first draft of these tests flaky.)
@Suite(.serialized)
@MainActor
struct ReconcileFromServerTests {

    /// Fictional UUIDs, per CLAUDE.md test-data rules.
    private static let sessionUUID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private static let hrvUUID = "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D"

    /// The UserDefaults keys `SyncService`'s config properties write through to.
    /// Mirrors `SyncServiceTests.syncKeys` — setting `sync.serverURL` on ANY instance
    /// persists globally via `didSet`, so tests must put them back.
    private static let syncKeys = [
        "syncServerURL", "syncApiKey", "syncAutoEnabled", "lastSyncDate", "lastSyncSuccessDate",
    ]

    private static func saveSyncDefaults() -> (() -> Void) {
        let saved = syncKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        return {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    /// Route a stubbed request by path. A restore/reconcile makes TWO kinds of
    /// call: the bulk `GET /api/data`, and a paged
    /// `GET /api/data/quantityHealthSamples` (that table is ~250k rows / ~79 MB
    /// of JSON, far too big to inline). The paged endpoint parses a
    /// `quantityHealthSamples` key and throws `.invalidJSON` if it's absent — so a
    /// stub that returns the bulk body for every URL fails the whole reconcile.
    /// Answer the paged endpoint with an empty page, which terminates its loop.
    private static func respond(to request: URLRequest, bulk: Data) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        if request.url?.path.hasPrefix("/api/data/quantityHealthSamples") == true {
            let empty = try! JSONSerialization.data(
                withJSONObject: ["quantityHealthSamples": [], "total": 0]
            )
            return (empty, response)
        }
        return (bulk, response)
    }

    private static func instant(_ s: String) -> Date {
        guard let d = ISO8601DateFormatter().date(from: s) else {
            fatalError("bad fixture timestamp: \(s)")
        }
        return d
    }

    // MARK: - Importer idempotency
    //
    // These exercise the importers directly (rather than through a stubbed HTTP
    // round trip) because idempotency is a property of the importers, and it is
    // what the whole reconcile design rests on. Each asserts the same shape:
    // import once, import the identical rows again, expect no growth.

    @Test("anxiety entries dedupe by timestamp (the server's PK)")
    func anxietyEntriesAreIdempotent() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rows: [[String: Any]] = [
            ["timestamp": "2026-03-01T10:00:00Z", "severity": 6, "notes": "first", "tags": ["work"]],
            ["timestamp": "2026-03-01T14:30:00Z", "severity": 3, "notes": "second", "tags": []],
        ]

        #expect(try SyncService.importAnxietyEntries(rows, shift: 0, into: context) == 2)
        try context.save()
        #expect(try SyncService.importAnxietyEntries(rows, shift: 0, into: context) == 0,
                "a second import of identical rows must add nothing")
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<AnxietyEntry>()) == 2)
    }

    @Test("a reconcile adds only the rows the device is missing")
    func anxietyEntriesAddOnlyMissing() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Device already has the 10:00 entry (say it synced up before the gap).
        context.insert(AnxietyEntry(
            timestamp: Self.instant("2026-03-01T10:00:00Z"), severity: 6, notes: "first", tags: []
        ))
        try context.save()

        // Server has both. Only the 14:30 one should land.
        let rows: [[String: Any]] = [
            ["timestamp": "2026-03-01T10:00:00Z", "severity": 6, "notes": "first", "tags": []],
            ["timestamp": "2026-03-01T14:30:00Z", "severity": 3, "notes": "second", "tags": []],
        ]
        #expect(try SyncService.importAnxietyEntries(rows, shift: 0, into: context) == 1)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<AnxietyEntry>()) == 2)
    }

    @Test("medication doses dedupe by (timestamp, medicationName) — the server's composite PK")
    func medDosesAreIdempotent() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        // Same instant, two different medications: the composite key must keep
        // BOTH. Keying on timestamp alone would silently drop one.
        let rows: [[String: Any]] = [
            ["timestamp": "2026-03-01T08:00:00Z", "medication_name": "Clonazepam 1mg Tablets", "dose_mg": 1.0],
            ["timestamp": "2026-03-01T08:00:00Z", "medication_name": "Propranolol 20mg Tablets", "dose_mg": 20.0],
        ]

        #expect(try SyncService.importMedDoses(rows, shift: 0, into: context) == 2,
                "same timestamp, different medication — both are distinct doses")
        try context.save()
        #expect(try SyncService.importMedDoses(rows, shift: 0, into: context) == 0)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<MedicationDose>()) == 2)
    }

    @Test("sensor sessions dedupe by server UUID")
    func sensorSessionsAreIdempotent() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rows: [[String: Any]] = [
            ["id": Self.sessionUUID, "start_time": "2026-03-01T22:00:00Z",
             "end_time": "2026-03-02T06:00:00Z", "battery_at_start": 95, "source": "polar_h10"],
        ]

        let (first, _) = try SyncService.importSensorSessions(rows, shift: 0, into: context)
        #expect(first == 1)
        try context.save()

        let (second, map) = try SyncService.importSensorSessions(rows, shift: 0, into: context)
        #expect(second == 0)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<SensorSession>()) == 1)

        // The critical subtlety: a session that was SKIPPED must still appear in
        // the returned map. importHRVReadings resolves session_id through it, so
        // dropping skipped sessions would orphan every HRV reading belonging to a
        // session the device already had — silently, as a nil relationship.
        #expect(map[Self.sessionUUID] == UUID(uuidString: Self.sessionUUID),
                "skipped sessions must still be reachable for HRV re-linking")
    }

    @Test("HRV readings still re-link to a sensor session that already existed")
    func hrvReadingsRelinkToPreexistingSession() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let sessionRows: [[String: Any]] = [
            ["id": Self.sessionUUID, "start_time": "2026-03-01T22:00:00Z", "battery_at_start": 95],
        ]

        // First pass: session lands.
        _ = try SyncService.importSensorSessions(sessionRows, shift: 0, into: context)
        try context.save()

        // Reconcile pass: session is skipped, but its HRV readings are missing and
        // must still attach to it.
        let (_, map) = try SyncService.importSensorSessions(sessionRows, shift: 0, into: context)
        let hrvRows: [[String: Any]] = [
            ["id": Self.hrvUUID, "timestamp": "2026-03-01T22:05:00Z",
             "session_id": Self.sessionUUID, "sdnn": 42.0, "rmssd": 38.0, "pnn50": 12.5],
        ]
        #expect(try SyncService.importHRVReadings(hrvRows, shift: 0, sessionMap: map, into: context) == 1)
        try context.save()

        let readings = try context.fetch(FetchDescriptor<HRVReading>())
        #expect(readings.count == 1)
        #expect(readings.first?.sensorSessionID == UUID(uuidString: Self.sessionUUID),
                "HRV reading must link to the pre-existing session, not be orphaned")
    }

    // MARK: - Local-wins-on-conflict
    //
    // The bug class a pre-PR review caught before this shipped. A `#Unique` /
    // `@Attribute(.unique)` constraint does NOT make an insert idempotent —
    // SwiftData resolves the collision by REPLACING the whole object. Relying on
    // the constraint (rather than an explicit existence check) meant a reconcile
    // would silently overwrite locally-corrected rows with the server's older copy.
    //
    // These tests differ from the idempotency ones above in the way that matters:
    // they re-import a row with DIFFERENT field values, so they can distinguish
    // "skipped" from "replaced with identical data". The idempotency tests cannot.

    @Test("a locally-corrected HealthSnapshot is NOT overwritten by the server's older copy")
    func healthSnapshotLocalCorrectionSurvives() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let day = Self.instant("2026-03-01T00:00:00Z")

        // A snapshot the aggregator re-derived after a late HealthKit backfill:
        // corrected value, and marked dirty so the next sync re-uploads it.
        let corrected = HealthSnapshot(date: day)
        corrected.hrvAvg = 55.0
        corrected.syncedToServer = false
        context.insert(corrected)
        try context.save()

        // The server still holds the pre-correction value.
        let rows: [[String: Any]] = [["date": "2026-03-01T00:00:00Z", "hrv_avg": 31.0]]
        #expect(try SyncService.importHealthSnapshots(rows, shift: 0, into: context) == 0,
                "the date is already present — nothing to add")
        try context.save()

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.count == 1)
        #expect(snapshots[0].hrvAvg == 55.0, """
            The local correction must survive. A blind insert would let SwiftData's \
            unique-key conflict resolution REPLACE the row with the server's 31.0.
            """)
        #expect(snapshots[0].syncedToServer == false, """
            And syncedToServer must stay false. A replace would set it true on the way \
            in, so the re-upload the dirty flag exists to guarantee would never happen — \
            making the local correction not merely stale but unrecoverable.
            """)
    }

    @Test("a locally-corrected CPAPSession is NOT overwritten by the server's older copy")
    func cpapSessionLocalCorrectionSurvives() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let day = Self.instant("2026-03-01T00:00:00Z")

        // CPAPImporter.updateSession corrected this night's AHI on a re-import.
        context.insert(CPAPSession(
            date: day, ahi: 2.1, totalUsageMinutes: 430,
            pressureMin: 6.0, pressureMax: 12.0, pressureMean: 9.0,
            obstructiveEvents: 4, centralEvents: 1, hypopneaEvents: 10,
            importSource: "oscar"
        ))
        try context.save()

        // Server holds the older, wrong figures.
        let rows: [[String: Any]] = [
            ["date": "2026-03-01T00:00:00Z", "ahi": 9.9, "total_usage_minutes": 120],
        ]
        #expect(try SyncService.importCPAPSessions(rows, shift: 0, into: context) == 0)
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>())
        #expect(sessions.count == 1)
        #expect(sessions[0].ahi == 2.1, "local correction must win over the server's stale AHI")
        #expect(sessions[0].totalUsageMinutes == 430)
    }

    /// The reported counts must mean "rows ADDED", not "rows processed". Without the
    /// existence checks, a repair on an already-healthy device would claim it added
    /// the server's entire row count — the opposite of the truth, and visible to the
    /// user in the report. Tapping Repair twice on a synced device is the manual QA
    /// that catches this; here it's automated.
    @Test("a second reconcile reports zeros — the counts mean rows ADDED")
    func secondReconcileReportsZeros() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let sync = SyncService()

        let restoreDefaults = Self.saveSyncDefaults()
        defer { restoreDefaults() }
        sync.serverURL = "http://127.0.0.1:9999"
        sync.apiKey = "test-key"

        let payload: [String: Any] = [
            "anxietyEntries": [
                ["timestamp": "2026-03-02T10:00:00Z", "severity": 4, "notes": "x", "tags": []],
            ],
            "healthSnapshots": [["date": "2026-03-02T00:00:00Z", "hrv_avg": 44.0]],
            "cpapSessions": [
                ["date": "2026-03-02T00:00:00Z", "ahi": 3.2, "total_usage_minutes": 400],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let first = try await sync.reconcileFromServer(modelContext: context) { request in
            Self.respond(to: request, bulk: data)
        }
        #expect(first.contains("anxietyEntries: 1"))
        #expect(first.contains("healthSnapshots: 1"))
        #expect(first.contains("cpapSessions: 1"))

        let second = try await sync.reconcileFromServer(modelContext: context) { request in
            Self.respond(to: request, bulk: data)
        }
        #expect(second.contains("anxietyEntries: 0"))
        #expect(second.contains("healthSnapshots: 0"))
        #expect(second.contains("cpapSessions: 0"))

        // And nothing was duplicated.
        #expect(try context.fetchCount(FetchDescriptor<AnxietyEntry>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<HealthSnapshot>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CPAPSession>()) == 1)
    }

    /// `RestoreFromServer.importPrescriptions` is insert-only and `Prescription` has
    /// no `#Unique` constraint on `rxNumber`, so calling it unfiltered against every
    /// server row would insert a fresh duplicate for every prescription the device
    /// already has, on every reconcile — not a revert, but the same "existing rows
    /// must be skipped, not re-processed" property every other importer here
    /// depends on. Filtering to genuinely-new rx numbers first is what makes that
    /// true for prescriptions too.
    @Test("a locally-edited Prescription is NOT reverted by the server's copy")
    func prescriptionLocalEditSurvives() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        context.insert(Prescription(
            rxNumber: "7654321",
            medicationName: "Clonazepam 1mg Tablets",
            doseMg: 1.0,
            doseDescription: "1 tablet",
            quantity: 30,
            refillsRemaining: 2,
            dateFilled: Self.instant("2026-03-01T00:00:00Z"),
            estimatedRunOutDate: nil,
            pharmacyName: "Test Pharmacy #12345",
            notes: "locally corrected",
            dailyDoseCount: 1,
            prescriberName: "Jane Smith MD",
            ndcCode: "00000-0000-00"
        ))
        try context.save()

        // Server still has the pre-edit refill count.
        let rows: [[String: Any]] = [[
            "rx_number": "7654321",
            "medication_name": "Clonazepam 1mg Tablets",
            "dose_mg": 1.0, "quantity": 30, "refills_remaining": 9,
            "date_filled": "2026-03-01T00:00:00Z",
            "notes": "stale server copy",
        ]]

        let newRows = try SyncService.prescriptionRowsNotAlreadyPresent(rows, in: context)
        #expect(newRows.isEmpty, "an rx_number the store already has must not reach the upsert")

        let prescriptions = try context.fetch(FetchDescriptor<Prescription>())
        #expect(prescriptions.count == 1)
        #expect(prescriptions[0].refillsRemaining == 2, "local edit must not be reverted")
        #expect(prescriptions[0].notes == "locally corrected")
    }

    @Test("a prescription the device is missing IS added")
    func missingPrescriptionIsAdded() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let rows: [[String: Any]] = [[
            "rx_number": "7654322",
            "medication_name": "Propranolol 20mg Tablets",
            "dose_mg": 20.0, "quantity": 60, "refills_remaining": 1,
            "date_filled": "2026-03-01T00:00:00Z",
        ]]
        let newRows = try SyncService.prescriptionRowsNotAlreadyPresent(rows, in: context)
        #expect(newRows.count == 1, "the filter must not drop rows the store lacks")
    }

    /// Duplicates *within a single payload*, not just against the store.
    ///
    /// `Song` has no unique constraint on `serverId`, so the store-backed existence
    /// set alone only catches rows that were already persisted — a payload carrying
    /// the same song twice would insert it twice. Every other importer folds new
    /// keys into its `seen` set as it goes; `importSongs` was the one that didn't.
    @Test("importSongs skips a serverId repeated within the same payload")
    func songsDedupeWithinPayload() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let rows: [[String: Any]] = [
            ["id": 42, "title": "Test Song", "artist": "Test Artist"],
            ["id": 42, "title": "Test Song", "artist": "Test Artist"],
        ]
        let (n, map) = try SyncService.importSongs(rows, into: context)
        try context.save()

        #expect(n == 1, "the same serverId twice in one payload is one song")
        #expect(try context.fetchCount(FetchDescriptor<Song>()) == 1)
        #expect(map[42] != nil, "and it must still be reachable for occurrence re-linking")
    }

    /// Same class as `songsDedupeWithinPayload`, in the importer I fixed *second*
    /// after only noticing the first. `SensorSession` has no unique constraint on
    /// `id`, so a payload carrying the same session twice would insert two rows —
    /// and duplicate sessions make HRV re-linking ambiguous downstream.
    @Test("importSensorSessions skips a session id repeated within the same payload")
    func sensorSessionsDedupeWithinPayload() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let rows: [[String: Any]] = [
            ["id": Self.sessionUUID, "start_time": "2026-03-01T22:00:00Z", "battery_at_start": 95],
            ["id": Self.sessionUUID, "start_time": "2026-03-01T22:00:00Z", "battery_at_start": 95],
        ]
        let (n, map) = try SyncService.importSensorSessions(rows, shift: 0, into: context)
        try context.save()

        #expect(n == 1, "the same session id twice in one payload is one session")
        #expect(try context.fetchCount(FetchDescriptor<SensorSession>()) == 1)
        #expect(map[Self.sessionUUID] == UUID(uuidString: Self.sessionUUID),
                "and it must still be reachable for HRV re-linking")
    }

    // MARK: - Mutual exclusion with sync
    //
    // Gating the Settings buttons is not sufficient: auto-sync fires from
    // AnxietyWatchApp at launch and from the background-refresh handler, neither of
    // which consults the UI. The mutex has to live on the service.

    @Test("reconcile refuses to start while a sync is in flight")
    func reconcileRefusesWhileSyncing() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let sync = SyncService()

        let restoreDefaults = Self.saveSyncDefaults()
        defer { restoreDefaults() }
        sync.serverURL = "http://127.0.0.1:9999"
        sync.apiKey = "test-key"
        sync.isSyncing = true   // a background auto-sync is mid-flight

        await #expect(throws: RestoreError.self) {
            _ = try await sync.reconcileFromServer(modelContext: context) { request in
                Self.respond(to: request, bulk: Data("{}".utf8))
            }
        }
    }

    /// …and it must RELEASE the mutex, or one reconcile would wedge every subsequent
    /// sync for the life of the process.
    @Test("reconcile releases the sync mutex when it finishes")
    func reconcileReleasesMutex() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let sync = SyncService()

        let restoreDefaults = Self.saveSyncDefaults()
        defer { restoreDefaults() }
        sync.serverURL = "http://127.0.0.1:9999"
        sync.apiKey = "test-key"

        let data = try JSONSerialization.data(withJSONObject: ["anxietyEntries": []])
        _ = try await sync.reconcileFromServer(modelContext: context) { request in
            Self.respond(to: request, bulk: data)
        }
        #expect(sync.isSyncing == false)
    }

    // MARK: - Cursor invariant
    //
    // The most dangerous thing reconcile could do.

    @Test("reconcile does NOT advance the sync cursor")
    func reconcileLeavesSyncCursorAlone() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let sync = SyncService()

        // A local row created BEFORE the reconcile that has never been uploaded.
        // This is the row that gets stranded if the cursor advances.
        context.insert(AnxietyEntry(
            timestamp: Self.instant("2026-03-05T09:00:00Z"), severity: 7, notes: "not yet synced", tags: []
        ))
        try context.save()

        let cursorBefore = Self.instant("2026-03-01T00:00:00Z")
        let restoreDefaults = Self.saveSyncDefaults()
        defer { restoreDefaults() }
        sync.serverURL = "http://127.0.0.1:9999"
        sync.apiKey = "test-key"
        sync.lastSyncDate = cursorBefore

        let payload: [String: Any] = [
            "anxietyEntries": [
                ["timestamp": "2026-03-02T10:00:00Z", "severity": 4, "notes": "from server", "tags": []],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        _ = try await sync.reconcileFromServer(modelContext: context) { request in
            Self.respond(to: request, bulk: data)
        }

        #expect(sync.lastSyncDate == cursorBefore, """
            Reconcile must not touch the upload cursor. Advancing it past the \
            2026-03-05 local entry would make the next incremental sync's `since` \
            filter skip it forever — stranded on a device that believes it is \
            backed up.
            """)
    }

    @Test("reconcile runs against a populated store — no empty-store guard")
    func reconcileIgnoresEmptyStoreGuard() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let sync = SyncService()

        // Populate the store so the restore guard would definitely trip.
        context.insert(HealthSnapshot(date: Self.instant("2026-03-01T00:00:00Z")))
        try context.save()
        #expect(!SyncService.restoreGuardBlockers(context).isEmpty,
                "precondition: guard would block a restore")

        let restoreDefaults = Self.saveSyncDefaults()
        defer { restoreDefaults() }
        sync.serverURL = "http://127.0.0.1:9999"
        sync.apiKey = "test-key"

        let payload: [String: Any] = [
            "anxietyEntries": [
                ["timestamp": "2026-03-02T10:00:00Z", "severity": 4, "notes": "healed", "tags": []],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let report = try await sync.reconcileFromServer(modelContext: context) { request in
            Self.respond(to: request, bulk: data)
        }

        #expect(report.contains("anxietyEntries: 1"))
        #expect(try context.fetchCount(FetchDescriptor<AnxietyEntry>()) == 1)
    }
}
