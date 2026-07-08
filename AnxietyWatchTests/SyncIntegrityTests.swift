import Foundation
import SwiftData
import Testing
@testable import AnxietyWatch

/// Regression coverage for Phase 3 Batch B sync-integrity findings.
///
/// `.serialized` because several tests mutate the shared UserDefaults keys
/// backing `SyncService` configuration (`lastSyncDate`, `syncServerURL`,
/// `syncApiKey`) — the same reason `SyncServiceTests` is serialized. Parallel
/// execution could interleave mutations of those process-global keys mid-test.
@Suite(.serialized)
@MainActor
struct SyncIntegrityTests {

    /// Save the sync cursor UserDefaults key and return a restore closure —
    /// `SyncService.lastSyncDate` persists via UserDefaults, so tests that
    /// set it must not leak state into other suites.
    private func saveSyncCursor() -> (() -> Void) {
        let saved = UserDefaults.standard.object(forKey: "lastSyncDate")
        return {
            if let saved { UserDefaults.standard.set(saved, forKey: "lastSyncDate") }
            else { UserDefaults.standard.removeObject(forKey: "lastSyncDate") }
        }
    }

    // F-013: a SensorSession synced mid-recording is flagged syncedToServer;
    // finalize must re-dirty it so the finalized endTime + summaryJSON reach
    // the server on the next sync.
    @Test func finalizeReDirtiesSyncedSessionSoItReSyncs() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)
        for i in 0..<60 {
            await buffer.append(timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), rrMs: 800)
        }
        let recorder = HRVSessionRecorder(modelContext: context, buffer: buffer, source: PolarHRMService.sourceLabel)
        try recorder.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        try await recorder.tick(at: Date(timeIntervalSince1970: 1_700_000_060))

        // Simulate an auto-sync that uploaded the still-open session and marked it synced.
        let session = try #require(try context.fetch(FetchDescriptor<SensorSession>()).first)
        session.syncedToServer = true
        try context.save()

        try recorder.finalize(at: Date(timeIntervalSince1970: 1_700_000_120))

        #expect(session.endTime != nil)
        #expect(session.summaryJSON != nil)
        // Re-dirtied → the completed session is picked up by the next sync.
        #expect(session.syncedToServer == false)
        // Staleness token bumped alongside the re-dirty so an in-flight
        // sync's post-upload flip can't clobber it (see the race test below).
        #expect(session.pendingSyncVersion == 1)
    }

    // Every finalize path must re-dirty AND bump the staleness token.
    // `finalizeOrphan` is the second of the two paths that set `endTime`;
    // a future third path that forgets either step would strand the
    // finalized state (F-013) or lose it to the in-flight-sync race.
    @Test func finalizeOrphanReDirtiesAndBumpsVersion() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = PolarHRMService(modelContext: context)

        let session = SensorSession(startTime: Date(timeIntervalSince1970: 1_700_000_000), batteryAtStart: 80)
        // Simulate an auto-sync having flagged the still-open orphan synced.
        session.syncedToServer = true
        context.insert(session)
        try context.save()

        service.finalizeOrphan(session, at: Date(timeIntervalSince1970: 1_700_003_600))

        #expect(session.endTime != nil)
        #expect(session.syncedToServer == false)
        #expect(session.pendingSyncVersion == 1)
    }

    // ⛔ Batch B blocking race: `sync()` extracts uploaded IDs BEFORE its
    // network await; if a finalize interleaves at that suspension point, the
    // post-upload flag flip must NOT mark the session synced — the in-flight
    // payload doesn't contain the finalized endTime/summaryJSON, so flipping
    // would strand an unfinished session server-side forever (never retried,
    // and RestoreFromServer would replicate the truncated state onto new
    // devices). The `pendingSyncVersion` captured at payload-build time
    // detects the drift.
    @Test func finalizeDuringInFlightSyncKeepsSessionDirty() async throws {
        let restore = saveSyncCursor()
        defer { restore() }
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)
        for i in 0..<60 {
            await buffer.append(timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), rrMs: 800)
        }
        let recorder = HRVSessionRecorder(modelContext: context, buffer: buffer, source: PolarHRMService.sourceLabel)
        try recorder.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        try await recorder.tick(at: Date(timeIntervalSince1970: 1_700_000_060))
        let session = try #require(try context.fetch(FetchDescriptor<SensorSession>()).first)

        // Payload built while the session is still recording — this is the
        // state `sync()` has in hand when it suspends on URLSession.
        let service = SyncService()
        service.lastSyncDate = Date(timeIntervalSince1970: 1_699_999_000)
        let payload = try service.buildPayload(
            from: context, upperBound: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let uploaded = service.extractUploadedSyncedIDs(from: payload)
        #expect(uploaded.sensorSessions.contains(session.id))
        #expect(uploaded.bulkRowVersions[session.id] == 0)

        // Interleave: the user taps Stop while the sync is awaiting the
        // server response (e.g. autosync timer fired just before).
        try recorder.finalize(at: Date(timeIntervalSince1970: 1_700_000_120))

        // Server said 200 OK for the PRE-finalize payload; the flip runs now.
        try service.markSamplesSynced(uploaded, modelContext: context)

        // The session stays dirty — the finalized endTime + summaryJSON +
        // interruption data still reach the server on the next sync.
        #expect(session.syncedToServer == false)
        // The HRVReading from the tick was NOT mutated during the await, so
        // its flip proceeds normally — the guard only holds back drifted rows.
        let reading = try #require(try context.fetch(FetchDescriptor<HRVReading>()).first)
        #expect(reading.syncedToServer == true)
    }

    // Happy path for the staleness guard: when nothing interleaves, the
    // captured version matches and the flip works — the guard must not
    // degrade into "never flip" (perpetual re-upload).
    @Test func unchangedSessionFlipsSyncedAfterUpload() async throws {
        let restore = saveSyncCursor()
        defer { restore() }
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)
        for i in 0..<60 {
            await buffer.append(timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), rrMs: 800)
        }
        let recorder = HRVSessionRecorder(modelContext: context, buffer: buffer, source: PolarHRMService.sourceLabel)
        try recorder.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        try await recorder.tick(at: Date(timeIntervalSince1970: 1_700_000_060))
        // Finalize BEFORE the payload is built — the payload carries the
        // bumped version, so the post-upload check sees a match.
        try recorder.finalize(at: Date(timeIntervalSince1970: 1_700_000_120))
        let session = try #require(try context.fetch(FetchDescriptor<SensorSession>()).first)
        #expect(session.pendingSyncVersion == 1)

        let service = SyncService()
        service.lastSyncDate = Date(timeIntervalSince1970: 1_699_999_000)
        let payload = try service.buildPayload(
            from: context, upperBound: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let uploaded = service.extractUploadedSyncedIDs(from: payload)
        #expect(uploaded.bulkRowVersions[session.id] == 1)

        try service.markSamplesSynced(uploaded, modelContext: context)

        #expect(session.syncedToServer == true)
    }

    // Same race family for the HealthKit mirror: a retroactive correction
    // updating a QuantityHealthSample in place during the sync's network
    // await must survive the post-upload flip. Without the guard the
    // correction is stranded permanently — the mirror pass's `changed`
    // comparison sees the already-applied new values and never re-dirties.
    @Test func sampleCorrectionDuringInFlightSyncKeepsSampleDirty() async throws {
        let restore = saveSyncCursor()
        defer { restore() }
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let sample = QuantityHealthSample(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            metricType: "HKQuantityTypeIdentifierHeartRate",
            value: 62,
            unitString: "count/min",
            sourceBundleID: "com.example.test",
            sourceName: "Test Apple Watch"
        )
        context.insert(sample)
        try context.save()

        let service = SyncService()
        service.lastSyncDate = Date(timeIntervalSince1970: 1_699_999_000)
        let payload = try service.buildPayload(
            from: context, upperBound: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let uploaded = service.extractUploadedSyncedIDs(from: payload)
        #expect(uploaded.bulkRowVersions[sample.id] == 0)

        // Interleave: HealthDataCoordinator's mirror pass applies a
        // retroactive HealthKit correction (same mutation set as the
        // coordinator's update-in-place path, including the version bump).
        sample.value = 63
        sample.syncedToServer = false
        sample.pendingSyncVersion &+= 1
        try context.save()

        try service.markSamplesSynced(uploaded, modelContext: context)

        // Correction stays dirty → re-syncs with the corrected value.
        #expect(sample.syncedToServer == false)
    }

    // F-014: uploadPendingRRArchives must skip sessions that are still recording
    // (endTime == nil) so it never stamps rrArchiveUploadedAt on a truncated file.
    @Test func uploadPendingRRArchivesSkipsUnfinalizedSessions() async throws {
        let defaults = UserDefaults.standard
        let prevURL = defaults.string(forKey: "syncServerURL")
        let prevKey = defaults.string(forKey: "syncApiKey")
        defaults.set("http://example.com", forKey: "syncServerURL")
        defaults.set("test-key", forKey: "syncApiKey")
        defer {
            if let prevURL { defaults.set(prevURL, forKey: "syncServerURL") } else { defaults.removeObject(forKey: "syncServerURL") }
            if let prevKey { defaults.set(prevKey, forKey: "syncApiKey") } else { defaults.removeObject(forKey: "syncApiKey") }
        }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let finalized = SensorSession(startTime: Date(timeIntervalSince1970: 1_700_000_000), batteryAtStart: 90)
        finalized.endTime = Date(timeIntervalSince1970: 1_700_003_600)
        let recording = SensorSession(startTime: Date(timeIntervalSince1970: 1_700_010_000), batteryAtStart: 90)
        // recording.endTime intentionally left nil (still recording)
        context.insert(finalized)
        context.insert(recording)
        try context.save()

        let ids = [finalized.id, recording.id]
        for id in ids {
            let url = RRArchiveWriter.archiveURL(for: id)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]).write(to: url)
        }
        defer { for id in ids { try? FileManager.default.removeItem(at: RRArchiveWriter.archiveURL(for: id)) } }

        var uploadedIDs: [UUID] = []
        let service = SyncService()
        await service.uploadPendingRRArchives(sessionIDs: ids, modelContext: context) { id, _ in
            uploadedIDs.append(id)
        }

        // Only the finalized session's archive was uploaded.
        #expect(uploadedIDs == [finalized.id])
        #expect(finalized.rrArchiveUploadedAt != nil)
        // The still-recording session is untouched and will retry once finalized.
        #expect(recording.rrArchiveUploadedAt == nil)
    }
}
