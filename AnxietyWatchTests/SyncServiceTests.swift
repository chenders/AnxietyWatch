import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

@Suite(.serialized)
struct SyncServiceTests {

    private static let syncKeys = ["syncServerURL", "syncApiKey", "syncAutoEnabled", "lastSyncDate"]

    /// Save current UserDefaults values and return a restore closure.
    private func saveSyncDefaults() -> (() -> Void) {
        let saved = Self.syncKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        return {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    // MARK: - isConfigured

    @Test("Not configured when both URL and key are empty")
    func notConfiguredEmpty() {
        let restore = saveSyncDefaults()
        defer { restore() }

        UserDefaults.standard.removeObject(forKey: "syncServerURL")
        UserDefaults.standard.removeObject(forKey: "syncApiKey")

        #expect(SyncService().isConfigured == false)
    }

    @Test("Not configured when URL is set but key is empty")
    func notConfiguredNoKey() {
        let restore = saveSyncDefaults()
        defer { restore() }

        UserDefaults.standard.set("http://example.com", forKey: "syncServerURL")
        UserDefaults.standard.removeObject(forKey: "syncApiKey")

        #expect(SyncService().isConfigured == false)
    }

    @Test("Not configured when key is set but URL is empty")
    func notConfiguredNoURL() {
        let restore = saveSyncDefaults()
        defer { restore() }

        UserDefaults.standard.removeObject(forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")

        #expect(SyncService().isConfigured == false)
    }

    @Test("Configured when both URL and key are set")
    func configuredBoth() {
        let restore = saveSyncDefaults()
        defer { restore() }

        UserDefaults.standard.set("http://example.com", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")

        #expect(SyncService().isConfigured == true)
    }

    @Test("Not configured when URL is whitespace only")
    func notConfiguredWhitespaceURL() {
        let restore = saveSyncDefaults()
        defer { restore() }

        UserDefaults.standard.set("   ", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")

        #expect(SyncService().isConfigured == false)
    }

    // MARK: - lastSyncDate persistence

    @Test("lastSyncDate persists through UserDefaults across instances")
    func lastSyncDateRoundTrip() {
        let restore = saveSyncDefaults()
        defer { restore() }

        SyncService().lastSyncDate = Date(timeIntervalSince1970: 1_711_300_000)

        // Read from a fresh instance to verify UserDefaults persistence
        #expect(SyncService().lastSyncDate?.timeIntervalSince1970 == 1_711_300_000)
    }

    @Test("lastSyncDate is nil when not set")
    func lastSyncDateNilByDefault() {
        let restore = saveSyncDefaults()
        defer { restore() }

        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        #expect(SyncService().lastSyncDate == nil)
    }

    @Test("lastSyncDate can be cleared")
    func lastSyncDateClear() {
        let restore = saveSyncDefaults()
        defer { restore() }

        let service = SyncService()
        service.lastSyncDate = .now
        service.lastSyncDate = nil

        #expect(service.lastSyncDate == nil)
    }

    // MARK: - SyncError descriptions

    @Test("SyncError.notConfigured has description")
    func errorNotConfigured() {
        #expect(SyncService.SyncError.notConfigured.errorDescription?.isEmpty == false)
    }

    @Test("SyncError.invalidURL has description")
    func errorInvalidURL() {
        #expect(SyncService.SyncError.invalidURL.errorDescription?.isEmpty == false)
    }

    @Test("SyncError.serverError includes status code")
    func errorServerError() {
        let error = SyncService.SyncError.serverError(500, "Internal Server Error")
        #expect(error.errorDescription?.contains("500") == true)
    }

    @Test("SyncError.serverError handles nil body")
    func errorServerErrorNilBody() {
        let error = SyncService.SyncError.serverError(401, nil)
        #expect(error.errorDescription?.contains("401") == true)
    }

    @Test("SyncError.noConnection has description")
    func errorNoConnection() {
        #expect(SyncService.SyncError.noConnection.errorDescription?.isEmpty == false)
    }

    // MARK: - Sync guards

    @Test("Sync sets 'Not configured' when not configured")
    @MainActor
    func syncNotConfigured() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }

        UserDefaults.standard.removeObject(forKey: "syncServerURL")
        UserDefaults.standard.removeObject(forKey: "syncApiKey")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()
        await service.sync(modelContext: context)

        #expect(service.lastSyncResult == "Not configured")
    }

    @Test("Sync surfaces 'Sync already in progress' when busy")
    @MainActor
    func syncAlreadyInProgress() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }

        UserDefaults.standard.set("http://example.com", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()
        service.isSyncing = true

        await service.sync(modelContext: context)

        #expect(service.lastSyncResult == "Sync already in progress")
        // The busy flag should remain set — we did not start a sync, so we must
        // not clear someone else's in-flight mutex.
        #expect(service.isSyncing == true)
    }

    @Test("fullSync preserves lastSyncDate when not configured")
    @MainActor
    func fullSyncPreservesCursorWhenUnconfigured() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }

        let cursor = Date(timeIntervalSince1970: 1_711_300_000)
        UserDefaults.standard.set(cursor.timeIntervalSince1970, forKey: "lastSyncDate")
        UserDefaults.standard.removeObject(forKey: "syncServerURL")
        UserDefaults.standard.removeObject(forKey: "syncApiKey")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()

        await service.fullSync(modelContext: context)

        // If fullSync nilled lastSyncDate *before* the isConfigured guard, the
        // cursor would be destroyed even though no sync occurred.
        #expect(service.lastSyncDate?.timeIntervalSince1970 == 1_711_300_000)
        #expect(service.lastSyncResult == "Not configured")
    }

    @Test("fullSync preserves lastSyncDate when busy")
    @MainActor
    func fullSyncPreservesCursorWhenBusy() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }

        let cursor = Date(timeIntervalSince1970: 1_711_300_000)
        UserDefaults.standard.set(cursor.timeIntervalSince1970, forKey: "lastSyncDate")
        UserDefaults.standard.set("http://example.com", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()
        service.isSyncing = true

        await service.fullSync(modelContext: context)

        // If fullSync nilled lastSyncDate *before* the busy guard, the next sync
        // would send everything — destroying the incremental cursor.
        #expect(service.lastSyncDate?.timeIntervalSince1970 == 1_711_300_000)
        #expect(service.lastSyncResult == "Sync already in progress")
    }

    // MARK: - Stored property persistence

    @Test("serverURL persists through UserDefaults across instances")
    func serverURLRoundTrip() {
        let restore = saveSyncDefaults()
        defer { restore() }

        SyncService().serverURL = "http://example.com"

        #expect(SyncService().serverURL == "http://example.com")
    }

    @Test("apiKey persists through UserDefaults across instances")
    func apiKeyRoundTrip() {
        let restore = saveSyncDefaults()
        defer { restore() }

        SyncService().apiKey = "secret-key"

        #expect(SyncService().apiKey == "secret-key")
    }

    @Test("autoSyncEnabled persists through UserDefaults across instances")
    func autoSyncEnabledRoundTrip() {
        let restore = saveSyncDefaults()
        defer { restore() }

        SyncService().autoSyncEnabled = true

        #expect(SyncService().autoSyncEnabled == true)
    }

    // MARK: - findOrCreateMedication

    @Test("Creates new MedicationDefinition when none exists")
    func findOrCreateNew() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let med = try SyncService.findOrCreateMedication(
            name: "Lorazepam", doseMg: 0.5, in: context
        )

        #expect(med?.name == "Lorazepam")
        #expect(med?.defaultDoseMg == 0.5)
        #expect(med?.isActive == true)

        let all = try context.fetch(FetchDescriptor<MedicationDefinition>())
        #expect(all.count == 1)
    }

    @Test("Finds existing MedicationDefinition by case-insensitive name")
    func findOrCreateExisting() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let existing = MedicationDefinition(name: "Lorazepam", defaultDoseMg: 0.5)
        context.insert(existing)
        try context.save()

        let found = try SyncService.findOrCreateMedication(
            name: "lorazepam", doseMg: 1.0, in: context
        )

        #expect(found?.id == existing.id)
        #expect(found?.defaultDoseMg == 0.5)

        let all = try context.fetch(FetchDescriptor<MedicationDefinition>())
        #expect(all.count == 1)
    }

    @Test("Reactivates inactive MedicationDefinition when found")
    func findOrCreateReactivates() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let inactive = MedicationDefinition(
            name: "Lorazepam", defaultDoseMg: 0.5, isActive: false
        )
        context.insert(inactive)
        try context.save()

        let found = try SyncService.findOrCreateMedication(
            name: "Lorazepam", doseMg: 0.5, in: context
        )

        #expect(found?.id == inactive.id)
        #expect(found?.isActive == true)
    }

    @Test("Returns nil when medication name is empty")
    func findOrCreateEmptyName() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try SyncService.findOrCreateMedication(
            name: "", doseMg: 0, in: context
        )

        #expect(result == nil)
        let all = try context.fetch(FetchDescriptor<MedicationDefinition>())
        #expect(all.count == 0)
    }

    @Test("Returns nil when medication name is whitespace only")
    func findOrCreateWhitespaceName() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try SyncService.findOrCreateMedication(
            name: "   ", doseMg: 0, in: context
        )

        #expect(result == nil)
        let all = try context.fetch(FetchDescriptor<MedicationDefinition>())
        #expect(all.count == 0)
    }

    // MARK: - Payload metadata

    @Test("buildPayload upperBound caps the small-volume export range")
    @MainActor
    func payloadUpperBoundCapsExportRange() throws {
        // The drain loop relies on `upperBound` cutting off the small-volume
        // payload at a known timestamp so `lastSyncDate` can be advanced to
        // that same timestamp after the round trip. Without the cap, a
        // record inserted between buildPayload and the cursor advance would
        // fall into a hole: not in the current payload, but its timestamp is
        // less than the new lastSyncDate so the next iteration also skips it.
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        // Two anxiety entries: one before the cutoff, one after.
        context.insert(AnxietyEntry(
            timestamp: baseDate,
            severity: 5,
            notes: "before-cutoff"
        ))
        context.insert(AnxietyEntry(
            timestamp: baseDate.addingTimeInterval(120),
            severity: 6,
            notes: "after-cutoff"
        ))
        try context.save()

        // Cap the payload at baseDate + 60s — only the "before-cutoff" entry
        // should appear in the export.
        let cutoff = baseDate.addingTimeInterval(60)
        let data = try SyncService().buildPayload(from: context, upperBound: cutoff)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["anxietyEntries"] as? [[String: Any]] ?? []
        let notes = entries.compactMap { $0["notes"] as? String }
        #expect(notes.contains("before-cutoff"))
        #expect(!notes.contains("after-cutoff"), "Entries past the upperBound must be excluded so the cursor advance can't skip them")
    }

    @Test("buildPayload bulkOnly does NOT report a small-volume export so callers can skip cursor advance")
    @MainActor
    func payloadBulkOnlyAndCursorAdvanceContract() throws {
        // Regression guard for a cursor-race-redux that round-2 of the
        // Copilot review caught: if `sync()` advances `lastSyncDate` on
        // every successful round trip but uses `bulkOnly: true` on
        // iterations 2+, then small-volume records created between iter 1's
        // upperBound and a later iter's cursor advance get silently
        // skipped — the same race the round-1 fix closed. The contract
        // we want here is structural: a `bulkOnly: true` payload must
        // not contain any of the small-volume keys, so the caller can
        // safely make cursor advance conditional on `bulkOnly == false`
        // via the same flag.
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        context.insert(AnxietyEntry(timestamp: .now, severity: 5, notes: "during-drain"))
        try context.save()

        let bulkData = try SyncService().buildPayload(from: context, bulkOnly: true)
        let bulkJSON = try JSONSerialization.jsonObject(with: bulkData) as? [String: Any]

        // None of the small-volume keys may appear in a bulkOnly payload.
        // If any one of these starts appearing, the caller MUST audit
        // whether their cursor-advance logic still matches what the
        // payload actually contained.
        let smallVolumeKeys = [
            "anxietyEntries",
            "medicationDefinitions",
            "medicationDoses",
            "cpapSessions",
            "healthSnapshots",
            "barometricReadings",
            "labResults",
            "pharmacies",
            "prescriptions",
            "pharmacyCallLogs",
            "songs",
            "songOccurrences",
        ]
        for key in smallVolumeKeys {
            #expect(bulkJSON?[key] == nil, "bulkOnly payload must not contain '\(key)' — cursor-advance contract depends on this")
        }
    }

    @Test("buildPayload bulkOnly skips small-volume tables but keeps bulk arrays")
    @MainActor
    func payloadBulkOnlyOmitsSmallVolumeTables() throws {
        // Subsequent drain-loop iterations request bulk-only payloads to
        // avoid `DataExporter.buildBundle` re-scanning every small-volume
        // table on the MainActor each iteration. Pin the contract: an
        // anxiety entry that would normally appear in the payload is
        // absent under `bulkOnly: true`, while the bulk arrays still
        // appear (empty here, but present so the server's `data.get(...)`
        // fallbacks behave consistently).
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        context.insert(AnxietyEntry(
            timestamp: Date(timeIntervalSince1970: 1_711_300_000),
            severity: 5,
            notes: "in-payload"
        ))
        try context.save()

        // Sanity: non-bulkOnly payload includes the entry.
        let normalData = try SyncService().buildPayload(from: context)
        let normalJSON = try JSONSerialization.jsonObject(with: normalData) as? [String: Any]
        let normalEntries = normalJSON?["anxietyEntries"] as? [[String: Any]] ?? []
        try #require(normalEntries.contains { ($0["notes"] as? String) == "in-payload" })

        // bulkOnly path: small-volume tables are absent entirely.
        let bulkData = try SyncService().buildPayload(from: context, bulkOnly: true)
        let bulkJSON = try JSONSerialization.jsonObject(with: bulkData) as? [String: Any]
        #expect(bulkJSON?["anxietyEntries"] == nil, "bulkOnly must not run the small-volume DataExporter scan")
        // Bulk arrays still present (even if empty) so the server's payload
        // handler keys exist as expected.
        #expect(bulkJSON?["quantitySamples"] != nil)
        #expect(bulkJSON?["sleepStageEvents"] != nil)
        #expect(bulkJSON?["sensorSessions"] != nil)
        #expect(bulkJSON?["hrvReadings"] != nil)
    }

    @Test("buildPayload includes syncSchemaVersion=4 in the wrapper metadata")
    @MainActor
    func payloadIncludesSchemaVersion() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        // SyncService reads lastSyncDate from UserDefaults at init; clearing
        // it isolates this test from prior runs / dev state that could flip
        // syncType to "incremental".
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        // v4 adds top-level sensorSessions + hrvReadings (Polar H10 BLE).
        // v3 added raw quantitySamples + sleepStageEvents arrays plus the
        // dataQuality JSONB on each snapshot. The server uses the version flag
        // to decide whether a missing dataQuality key is "clear-on-conflict"
        // (v3+) or "preserve via COALESCE" (older clients).
        #expect((json?["syncSchemaVersion"] as? Int) == 4)
    }

    @Test("buildPayload includes unsynced QuantityHealthSample rows")
    @MainActor
    func payloadIncludesQuantitySamples() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let groupID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        let samples = [
            QuantityHealthSample(
                timestamp: baseDate,
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 95.0,
                unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo",
                sourceName: "Stelo",
                deviceModel: "Stelo CGM"
            ),
            QuantityHealthSample(
                timestamp: baseDate.addingTimeInterval(60),
                metricType: "HKQuantityTypeIdentifierBloodPressureSystolic",
                value: 122,
                unitString: "mmHg",
                sourceBundleID: "com.omronhealthcare.OmronConnect",
                sourceName: "Omron",
                groupID: groupID
            ),
            QuantityHealthSample(
                timestamp: baseDate.addingTimeInterval(60),
                metricType: "HKQuantityTypeIdentifierBloodPressureDiastolic",
                value: 78,
                unitString: "mmHg",
                sourceBundleID: "com.omronhealthcare.OmronConnect",
                sourceName: "Omron",
                groupID: groupID
            ),
        ]
        for sample in samples { context.insert(sample) }
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = json?["quantitySamples"] as? [[String: Any]]
        #expect(array?.count == 3)

        // Find the glucose entry by id and verify the encoded shape.
        let glucoseID = samples[0].id.uuidString
        let glucose = array?.first { ($0["id"] as? String) == glucoseID }
        #expect(glucose?["metricType"] as? String == "HKQuantityTypeIdentifierBloodGlucose")
        #expect(glucose?["value"] as? Double == 95.0)
        #expect(glucose?["unitString"] as? String == "mg/dL")
        #expect(glucose?["sourceBundleID"] as? String == "com.dexcom.stelo")
        #expect(glucose?["sourceName"] as? String == "Stelo")
        #expect(glucose?["deviceModel"] as? String == "Stelo CGM")
        // ISO8601 timestamps end in "Z" for UTC; presence + format is enough.
        let ts = glucose?["timestamp"] as? String
        #expect(ts != nil)
        #expect(ts?.contains("T") == true)

        // BP rows share a groupId so the server can rebuild the correlation.
        let systolic = array?.first { ($0["id"] as? String) == samples[1].id.uuidString }
        #expect(systolic?["groupId"] as? String == groupID.uuidString)
    }

    @Test("buildPayload includes unsynced SleepStageEvent rows")
    @MainActor
    func payloadIncludesSleepStageEvents() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        let events = [
            SleepStageEvent(
                startTime: baseDate,
                endTime: baseDate.addingTimeInterval(1800),
                stage: "asleepDeep",
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch7,1"
            ),
            SleepStageEvent(
                startTime: baseDate.addingTimeInterval(1800),
                endTime: baseDate.addingTimeInterval(3600),
                stage: "asleepREM",
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch"
            ),
        ]
        for event in events { context.insert(event) }
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = json?["sleepStageEvents"] as? [[String: Any]]
        #expect(array?.count == 2)

        let deep = array?.first { ($0["id"] as? String) == events[0].id.uuidString }
        #expect(deep?["stage"] as? String == "asleepDeep")
        #expect(deep?["sourceBundleID"] as? String == "com.apple.health")
        #expect(deep?["sourceName"] as? String == "Apple Watch")
        #expect(deep?["deviceModel"] as? String == "Watch7,1")
        #expect((deep?["startTime"] as? String)?.contains("T") == true)
        #expect((deep?["endTime"] as? String)?.contains("T") == true)
    }

    @Test("buildPayload omits already-synced samples")
    @MainActor
    func payloadOmitsAlreadySyncedSamples() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        for i in 0..<5 {
            let sample = QuantityHealthSample(
                timestamp: baseDate.addingTimeInterval(TimeInterval(i)),
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 90.0 + Double(i),
                unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo",
                sourceName: "Stelo",
                syncedToServer: i < 2  // first 2 already synced
            )
            context.insert(sample)
        }
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = json?["quantitySamples"] as? [[String: Any]]
        #expect(array?.count == 3)
    }

    // MARK: - UploadedSyncedIDs.hitBulkLimit

    @Test("hitBulkLimit returns true when any bulk array fills the cap")
    func hitBulkLimitTrueWhenCapReached() {
        let ids = (0..<1000).map { _ in UUID() }
        // quantitySamples at cap
        #expect(UploadedSyncedIDs(quantitySamples: ids).hitBulkLimit(1000))
        // sleepStageEvents at cap
        #expect(UploadedSyncedIDs(sleepStageEvents: ids).hitBulkLimit(1000))
        // sensorSessions at cap
        #expect(UploadedSyncedIDs(sensorSessions: ids).hitBulkLimit(1000))
        // hrvReadings at cap
        #expect(UploadedSyncedIDs(hrvReadings: ids).hitBulkLimit(1000))
    }

    @Test("hitBulkLimit returns false when all bulk arrays are below the cap")
    func hitBulkLimitFalseWhenBelowCap() {
        let ids = (0..<999).map { _ in UUID() }
        let uploaded = UploadedSyncedIDs(
            quantitySamples: ids,
            sleepStageEvents: ids,
            sensorSessions: ids,
            hrvReadings: ids
        )
        // Even with 999 × 4 types, none hit the 1000 cap → no more rounds needed.
        #expect(!uploaded.hitBulkLimit(1000))
    }

    @Test("hitBulkLimit returns false on an empty payload")
    func hitBulkLimitFalseWhenEmpty() {
        #expect(!UploadedSyncedIDs().hitBulkLimit(1000))
    }

    @Test("buildPayload caps the sample batch at 1000")
    @MainActor
    func payloadCapsBatchAt1000() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        for i in 0..<1500 {
            context.insert(QuantityHealthSample(
                timestamp: baseDate.addingTimeInterval(TimeInterval(i)),
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 90.0,
                unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo",
                sourceName: "Stelo"
            ))
        }
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = json?["quantitySamples"] as? [[String: Any]]
        #expect(array?.count == 1000)
    }

    /// Regression: `markSamplesSynced` is called with up to
    /// `sampleBatchLimit` (1000) UUIDs after a successful upload. Without
    /// chunking, the resulting `Set.contains($0.id)` predicate exceeds
    /// SQLite's default 999-parameter limit, the fetch fails silently, and
    /// the next sync re-uploads the same first 1000 samples forever. The fix
    /// chunks the IN-list under the limit; this test pins the behaviour by
    /// flagging > 900 IDs in a single call and verifying every row was
    /// flipped.
    @Test("markSamplesSynced flips syncedToServer when called with >900 ids (SQLite limit regression)")
    @MainActor
    func markSamplesSyncedHandlesLargeIDListWithoutExceedingSQLiteLimit() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let count = 1000
        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        var inserted: [QuantityHealthSample] = []
        for i in 0..<count {
            let row = QuantityHealthSample(
                timestamp: baseDate.addingTimeInterval(Double(i * 60)),
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 90 + Double(i % 50),
                unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo",
                sourceName: "Stelo"
            )
            context.insert(row)
            inserted.append(row)
            // Save in chunks so the seed itself doesn't blow up — purely a
            // test-setup concern, unrelated to the production path under test.
            if inserted.count.isMultiple(of: 200) {
                try context.save()
            }
        }
        try context.save()
        let allIDs = inserted.map(\.id)

        try SyncService().markSamplesSynced(
            UploadedSyncedIDs(quantitySamples: allIDs),
            modelContext: context
        )

        let predicate = #Predicate<QuantityHealthSample> { $0.syncedToServer == true }
        let flagged = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(flagged.count == count, "All \(count) rows must be flagged synced after a single call")
    }

    @Test("markSamplesSynced flips syncedToServer on matched rows")
    @MainActor
    func markSamplesSyncedAfterSuccess() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        let q1 = QuantityHealthSample(
            timestamp: baseDate,
            metricType: "HKQuantityTypeIdentifierBloodGlucose",
            value: 90,
            unitString: "mg/dL",
            sourceBundleID: "com.dexcom.stelo",
            sourceName: "Stelo"
        )
        let q2 = QuantityHealthSample(
            timestamp: baseDate.addingTimeInterval(60),
            metricType: "HKQuantityTypeIdentifierBloodGlucose",
            value: 100,
            unitString: "mg/dL",
            sourceBundleID: "com.dexcom.stelo",
            sourceName: "Stelo"
        )
        let s1 = SleepStageEvent(
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(900),
            stage: "asleepDeep",
            sourceBundleID: "com.apple.health",
            sourceName: "Apple Watch"
        )
        context.insert(q1)
        context.insert(q2)
        context.insert(s1)
        try context.save()

        try SyncService().markSamplesSynced(
            UploadedSyncedIDs(
                quantitySamples: [q1.id, q2.id],
                sleepStageEvents: [s1.id]
            ),
            modelContext: context
        )

        #expect(q1.syncedToServer == true)
        #expect(q2.syncedToServer == true)
        #expect(s1.syncedToServer == true)
    }

    // MARK: - applyPostUploadResponse

    /// Regression: a failure in `markSamplesSynced` during the post-200-OK path
    /// must NOT short-circuit the rest of `sync()`. Correlations apply and the
    /// song-catalog pull are logically independent of raw-sample flagging, so
    /// a failed flag step should still allow correlations to be applied and
    /// the catalog pull to run; the partial failure is surfaced in the
    /// returned status string instead.
    ///
    /// We exercise the extracted `applyPostUploadResponse(...)` helper directly
    /// to avoid standing up a mock URLSession. The helper is the exact body
    /// `sync()` runs after a 200 OK.
    @Test("applyPostUploadResponse applies correlations even when sample-flagging fails")
    @MainActor
    func postUploadAppliesCorrelationsWhenFlaggingFails() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Server response with a real correlations payload — the assertion is
        // that this is applied even though sample-flagging throws.
        let responseJSON: [String: Any] = [
            "correlations": [
                [
                    "signal_name": "hrv_low",
                    "correlation": 0.42,
                    "p_value": 0.01,
                    "sample_count": 50,
                    "computed_at": "2025-01-01T00:00:00Z"
                ]
            ]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseJSON)

        struct ForcedSaveError: Error, LocalizedError {
            var errorDescription: String? { "forced save failure for regression test" }
        }

        // Inject a marker closure that throws — exactly the "save error" path
        // the regression covers. Real production code path uses `markSamplesSynced`
        // (default nil → real implementation runs); the closure injection only
        // exists for test-time fault injection.
        let outcome = await SyncService().applyPostUploadResponse(
            responseData: responseData,
            payloadByteCount: 1024,
            uploadedIDs: UploadedSyncedIDs(
                quantitySamples: [UUID()],
                sleepStageEvents: [UUID()]
            ),
            modelContext: context,
            markSamples: { _, _ in throw ForcedSaveError() }
        )

        // Correlations were applied despite the sample-flag failure.
        let correlations = try context.fetch(FetchDescriptor<PhysiologicalCorrelation>())
        #expect(correlations.count == 1, "Correlations apply must run even when sample-flagging fails")
        #expect(correlations.first?.signalName == "hrv_low")

        // Outcome signals the partial failure so the drain loop can break
        // instead of re-uploading the same unflagged rows forever.
        #expect(!outcome.flaggingSucceeded, "Outcome must report flagging failure to the caller")
        #expect(
            outcome.message.contains("failed to flag samples"),
            "Partial-failure status must surface the sample-flag failure: got \(outcome.message)"
        )
        #expect(
            outcome.message.contains("forced save failure"),
            "Partial-failure status must include the underlying error description: got \(outcome.message)"
        )
    }

    /// Companion: with the same helper but a working schema and empty ID
    /// lists, the happy-path string is returned. Pins the success branch so a
    /// regression in the partial-failure branch is distinguishable from a
    /// regression in the helper's overall structure.
    @Test("applyPostUploadResponse returns the success status when sample-flagging succeeds")
    @MainActor
    func postUploadSuccessStatusWhenFlaggingSucceeds() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let responseData = try JSONSerialization.data(withJSONObject: [String: Any]())

        let outcome = await SyncService().applyPostUploadResponse(
            responseData: responseData,
            payloadByteCount: 512,
            uploadedIDs: UploadedSyncedIDs(),
            modelContext: context
        )

        #expect(outcome.flaggingSucceeded)
        #expect(outcome.message.hasPrefix("Synced "))
        #expect(!outcome.message.contains("failed to flag samples"))
    }

    @Test("buildPayload includes the standard wrapper metadata")
    @MainActor
    func payloadIncludesWrapperMetadata() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        // syncType depends on whether lastSyncDate is set — clear it to
        // make the "full" assertion deterministic regardless of prior state.
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["syncType"] as? String == "full")
        #expect(json?["clientVersion"] as? String == "1.0")
        #expect((json?["deviceName"] as? String)?.hasPrefix("iOS ") == true)
    }

    // MARK: - Phase 3b: SensorSession + HRVReading payload shape

    @Test("buildPayload includes unsynced SensorSession rows with decoded summaryJSON")
    @MainActor
    func payloadIncludesSensorSessions() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        let session = SensorSession(startTime: baseDate, batteryAtStart: 95)
        session.endTime = baseDate.addingTimeInterval(3600)
        session.source = "polar_h10"
        // summaryJSON is stored as String? on disk but is sent on the wire
        // as a decoded dict so `summary_json->>'rmssdMean'` works server-side
        // without an intermediate unwrap.
        session.summaryJSON = #"{"rmssdMean":42.5,"rrCount":3600}"#
        context.insert(session)
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = json?["sensorSessions"] as? [[String: Any]]
        #expect(array?.count == 1)

        let row = array?.first
        #expect(row?["id"] as? String == session.id.uuidString)
        #expect(row?["source"] as? String == "polar_h10")
        #expect(row?["batteryAtStart"] as? Int == 95)
        #expect(row?["interruptionCount"] as? Int == 0)
        #expect((row?["startTime"] as? String)?.contains("T") == true)
        #expect((row?["endTime"] as? String)?.contains("T") == true)

        let summary = row?["summaryJSON"] as? [String: Any]
        #expect(summary?["rmssdMean"] as? Double == 42.5)
        #expect(summary?["rrCount"] as? Int == 3600)
    }

    @Test("buildPayload sets source='unknown' when SensorSession.source is nil")
    @MainActor
    func payloadSensorSessionDefaultsUnknownSource() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Pre-source-tracking rows and Watch-side captures have nil source.
        // Server schema 0005 requires the column non-null, so the sentinel
        // avoids silent upsert failures on the server side.
        let session = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_711_300_000),
            batteryAtStart: 80
        )
        context.insert(session)
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let row = (json?["sensorSessions"] as? [[String: Any]])?.first
        #expect(row?["source"] as? String == "unknown")
    }

    @Test("buildPayload includes unsynced HRVReading rows")
    @MainActor
    func payloadIncludesHRVReadings() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let sessionID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        let reading = HRVReading(
            timestamp: baseDate,
            rmssd: 45.2,
            sdnn: 51.3,
            pnn50: 12.5,
            lfPower: 320.0,
            hfPower: 410.0,
            lfHfRatio: 0.78,
            sensorSessionID: sessionID,
            source: "polar_h10"
        )
        context.insert(reading)
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = json?["hrvReadings"] as? [[String: Any]]
        #expect(array?.count == 1)

        let row = array?.first
        #expect(row?["id"] as? String == reading.id.uuidString)
        #expect(row?["rmssd"] as? Double == 45.2)
        #expect(row?["sdnn"] as? Double == 51.3)
        #expect(row?["pnn50"] as? Double == 12.5)
        #expect(row?["lfPower"] as? Double == 320.0)
        #expect(row?["hfPower"] as? Double == 410.0)
        #expect(row?["lfHfRatio"] as? Double == 0.78)
        // Wire key is `sessionId` (matches server `_upsert_hrv_readings`,
        // which reads `r["sessionId"]` and FK column `hrv_readings.session_id`).
        // The iOS model field is `sensorSessionID` but the on-wire name
        // follows the server contract.
        #expect(row?["sessionId"] as? String == sessionID.uuidString)
        #expect(row?["source"] as? String == "polar_h10")
        #expect((row?["timestamp"] as? String)?.contains("T") == true)
    }

    @Test("buildPayload sets source='unknown' when HRVReading.source is nil")
    @MainActor
    func payloadHRVReadingDefaultsUnknownSource() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Server schema 0005 makes `source` NOT NULL and the upsert reads
        // `r["source"]` (raises KeyError on missing). Pre-source-tracking
        // rows and Watch-side captures have nil; the sentinel keeps the
        // batch from 500'ing the whole sync.
        let reading = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_711_300_000),
            rmssd: 40, sdnn: 50, pnn50: 10,
            lfPower: 300, hfPower: 400, lfHfRatio: 0.75
        )
        context.insert(reading)
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let row = (json?["hrvReadings"] as? [[String: Any]])?.first
        #expect(row?["source"] as? String == "unknown")
    }

    @Test("buildPayload omits already-synced SensorSession rows")
    @MainActor
    func payloadOmitsAlreadySyncedSensorSessions() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        for i in 0..<4 {
            let session = SensorSession(
                startTime: baseDate.addingTimeInterval(TimeInterval(i * 60)),
                batteryAtStart: 90
            )
            session.syncedToServer = i < 3  // first 3 already synced
            context.insert(session)
        }
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = json?["sensorSessions"] as? [[String: Any]]
        #expect(array?.count == 1)
    }

    @Test("buildPayload omits already-synced HRVReading rows")
    @MainActor
    func payloadOmitsAlreadySyncedHRVReadings() throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        for i in 0..<5 {
            let reading = HRVReading(
                timestamp: baseDate.addingTimeInterval(TimeInterval(i * 60)),
                rmssd: 40 + Double(i),
                sdnn: 50,
                pnn50: 10,
                lfPower: 300,
                hfPower: 400,
                lfHfRatio: 0.75
            )
            reading.syncedToServer = i < 2  // first 2 already synced
            context.insert(reading)
        }
        try context.save()

        let data = try SyncService().buildPayload(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = json?["hrvReadings"] as? [[String: Any]]
        #expect(array?.count == 3)
    }

    @Test("markSamplesSynced flips syncedToServer on SensorSession rows")
    @MainActor
    func markSyncedFlipsSensorSessions() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        let s1 = SensorSession(startTime: baseDate, batteryAtStart: 90)
        let s2 = SensorSession(startTime: baseDate.addingTimeInterval(60), batteryAtStart: 85)
        context.insert(s1)
        context.insert(s2)
        try context.save()

        try SyncService().markSamplesSynced(
            UploadedSyncedIDs(sensorSessions: [s1.id, s2.id]),
            modelContext: context
        )

        #expect(s1.syncedToServer == true)
        #expect(s2.syncedToServer == true)
    }

    @Test("markSamplesSynced flips syncedToServer on HRVReading rows")
    @MainActor
    func markSyncedFlipsHRVReadings() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let baseDate = Date(timeIntervalSince1970: 1_711_300_000)
        let r1 = HRVReading(
            timestamp: baseDate,
            rmssd: 40, sdnn: 50, pnn50: 10,
            lfPower: 300, hfPower: 400, lfHfRatio: 0.75
        )
        let r2 = HRVReading(
            timestamp: baseDate.addingTimeInterval(60),
            rmssd: 42, sdnn: 52, pnn50: 11,
            lfPower: 320, hfPower: 410, lfHfRatio: 0.78
        )
        context.insert(r1)
        context.insert(r2)
        try context.save()

        try SyncService().markSamplesSynced(
            UploadedSyncedIDs(hrvReadings: [r1.id, r2.id]),
            modelContext: context
        )

        #expect(r1.syncedToServer == true)
        #expect(r2.syncedToServer == true)
    }

    // MARK: - Phase 3b: RR-archive upload

    /// Reference-type recorder for the injected `postArchive` closure.
    /// `@MainActor` so mutation from inside the `@MainActor`-isolated
    /// `uploadPendingRRArchives` is race-free without `@Sendable` annotations.
    @MainActor
    private final class RRPostRecorder {
        var calls: [(sessionID: UUID, byteCount: Int)] = []
        var shouldThrow: Error?
    }

    @Test("uploadPendingRRArchives posts and stamps rrArchiveUploadedAt on success")
    @MainActor
    func uploadPendingRRArchivesHappyPath() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        // `isConfigured` is a precondition for the upload to proceed; without
        // it the function short-circuits before invoking the closure.
        UserDefaults.standard.set("http://example.com", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let session = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_711_300_000),
            batteryAtStart: 90
        )
        context.insert(session)
        try context.save()

        // Real on-disk archive at the canonical path. `RRArchiveWriter`
        // derives the path purely from `sessionID`, so each test's fresh
        // UUID keeps fixtures isolated.
        let url = RRArchiveWriter.archiveURL(for: session.id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: 200).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = RRPostRecorder()
        await SyncService().uploadPendingRRArchives(
            sessionIDs: [session.id],
            modelContext: context,
            postArchive: { id, body in
                recorder.calls.append((id, body.count))
            }
        )

        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.sessionID == session.id)
        #expect((recorder.calls.first?.byteCount ?? 0) > 0)
        #expect(session.rrArchiveUploadedAt != nil)
    }

    @Test("uploadPendingRRArchives leaves rrArchiveUploadedAt nil on post failure")
    @MainActor
    func uploadPendingRRArchivesLeavesUploadedAtNilOnFailure() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.set("http://example.com", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let session = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_711_300_000),
            batteryAtStart: 90
        )
        context.insert(session)
        try context.save()

        let url = RRArchiveWriter.archiveURL(for: session.id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xCD, count: 200).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        struct InjectedFailure: Error {}
        let recorder = RRPostRecorder()
        recorder.shouldThrow = InjectedFailure()
        await SyncService().uploadPendingRRArchives(
            sessionIDs: [session.id],
            modelContext: context,
            postArchive: { id, body in
                recorder.calls.append((id, body.count))
                if let err = recorder.shouldThrow { throw err }
            }
        )

        #expect(recorder.calls.count == 1, "Closure still called once before throwing")
        #expect(
            session.rrArchiveUploadedAt == nil,
            "Failure must leave rrArchiveUploadedAt nil so next sync retries"
        )
    }

    @Test("uploadPendingRRArchives skips sessions whose archive already uploaded")
    @MainActor
    func uploadPendingRRArchivesSkipsAlreadyUploaded() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.set("http://example.com", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let session = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_711_300_000),
            batteryAtStart: 90
        )
        let priorUpload = Date(timeIntervalSince1970: 1_711_310_000)
        session.rrArchiveUploadedAt = priorUpload
        context.insert(session)
        try context.save()

        let url = RRArchiveWriter.archiveURL(for: session.id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xEF, count: 200).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = RRPostRecorder()
        await SyncService().uploadPendingRRArchives(
            sessionIDs: [session.id],
            modelContext: context,
            postArchive: { id, body in
                recorder.calls.append((id, body.count))
            }
        )

        #expect(
            recorder.calls.isEmpty,
            "Already-uploaded session must short-circuit before invoking the post closure"
        )
        #expect(
            session.rrArchiveUploadedAt == priorUpload,
            "Prior upload timestamp must be preserved"
        )
    }

}
