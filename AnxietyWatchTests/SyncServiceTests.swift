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

    @Test("buildPayload includes syncSchemaVersion=3 in the wrapper metadata")
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
        // v3 adds raw quantitySamples + sleepStageEvents arrays plus the
        // dataQuality JSONB on each snapshot. The server uses the version flag
        // to decide whether a missing dataQuality key is "clear-on-conflict"
        // (v3+) or "preserve via COALESCE" (older clients).
        #expect((json?["syncSchemaVersion"] as? Int) == 3)
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
            quantityIDs: allIDs,
            sleepIDs: [],
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
            quantityIDs: [q1.id, q2.id],
            sleepIDs: [s1.id],
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
        let result = await SyncService().applyPostUploadResponse(
            responseData: responseData,
            payloadByteCount: 1024,
            uploadedQuantityIDs: [UUID()],
            uploadedSleepIDs: [UUID()],
            modelContext: context,
            markSamples: { _, _, _ in throw ForcedSaveError() }
        )

        // Correlations were applied despite the sample-flag failure.
        let correlations = try context.fetch(FetchDescriptor<PhysiologicalCorrelation>())
        #expect(correlations.count == 1, "Correlations apply must run even when sample-flagging fails")
        #expect(correlations.first?.signalName == "hrv_low")

        // Result string surfaces the partial failure rather than reporting clean success.
        #expect(
            result.contains("failed to flag samples"),
            "Partial-failure status must surface the sample-flag failure: got \(result)"
        )
        #expect(
            result.contains("forced save failure"),
            "Partial-failure status must include the underlying error description: got \(result)"
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

        let result = await SyncService().applyPostUploadResponse(
            responseData: responseData,
            payloadByteCount: 512,
            uploadedQuantityIDs: [],
            uploadedSleepIDs: [],
            modelContext: context
        )

        #expect(result.hasPrefix("Synced "))
        #expect(!result.contains("failed to flag samples"))
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

}
