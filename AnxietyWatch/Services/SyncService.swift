import Foundation
import HealthKit
import os
import SwiftData
import UIKit

/// Push-only sync to a personal server. The app is the source of truth;
/// the server is a mirror for viewing on larger displays and Claude analysis.
@Observable
final class SyncService {
    static let shared = SyncService()

    var isSyncing = false
    var lastSyncResult: String?

    // MARK: - Configuration (stored properties, persisted to UserDefaults via didSet)
    //
    // These are stored `var`s rather than computed properties so `@Observable` can
    // track them — SwiftUI won't re-render on changes to computed UserDefaults-backed
    // properties because the macro only instruments stored storage.

    var serverURL: String = UserDefaults.standard.string(forKey: "syncServerURL") ?? "" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "syncServerURL") }
    }

    var apiKey: String = UserDefaults.standard.string(forKey: "syncApiKey") ?? "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "syncApiKey") }
    }

    var autoSyncEnabled: Bool = UserDefaults.standard.bool(forKey: "syncAutoEnabled") {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: "syncAutoEnabled") }
    }

    var lastSyncDate: Date? = {
        let ts = UserDefaults.standard.double(forKey: "lastSyncDate")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }() {
        didSet {
            if let date = lastSyncDate {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "lastSyncDate")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastSyncDate")
            }
        }
    }

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Sync

    enum SyncError: Error, LocalizedError {
        case notConfigured
        case invalidURL
        case serverError(Int, String?)
        case noConnection

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Server URL and API key not configured"
            case .invalidURL: return "Invalid server URL"
            case .serverError(let code, let body):
                return "Server returned \(code)\(body.map { ": \($0)" } ?? "")"
            case .noConnection: return "Could not connect to server"
            }
        }
    }

    /// Sync all data created since the last successful sync.
    /// If no prior sync, sends everything.
    ///
    /// Pinned to `@MainActor` because the body touches `ModelContext` both
    /// before and after the `await URLSession.shared.data(for:)` and
    /// `await SongService.fetchCatalog(...)` suspension points. Without the
    /// annotation, execution could resume off the main executor and mutate
    /// SwiftData from a non-main task — undefined behavior. Most call sites
    /// (SwiftUI views, `DashboardViewModel`) are already `@MainActor`-isolated,
    /// so this is net-zero for callers.
    @MainActor
    func sync(modelContext: ModelContext) async {
        guard isConfigured else {
            lastSyncResult = "Not configured"
            return
        }
        guard !isSyncing else {
            // Surface the busy state so users see *why* nothing happened —
            // silent early-returns previously masked wedged isSyncing mutexes.
            lastSyncResult = "Sync already in progress"
            return
        }

        isSyncing = true
        lastSyncResult = "Syncing..."

        // Resolve the /api/sync URL up front; reused for every round-trip below.
        let url: URL
        do {
            guard var urlComponents = URLComponents(string: serverURL) else {
                throw SyncError.invalidURL
            }
            if urlComponents.path.isEmpty || urlComponents.path == "/" {
                urlComponents.path = "/api/sync"
            }
            guard let resolved = urlComponents.url else {
                throw SyncError.invalidURL
            }
            url = resolved
        } catch {
            lastSyncResult = error.localizedDescription
            isSyncing = false
            return
        }

        let demographics = await readDemographicsForSync()

        // Drain loop. Each iteration ships up to `sampleBatchLimit` rows of
        // each bulk type (quantitySamples, sleepStageEvents, sensorSessions,
        // hrvReadings). When an iteration hits that cap on any type, there
        // might be more behind it — loop until the queue drains, a round
        // trip fails, or `markSamplesSynced` fails (which would otherwise
        // cause us to re-upload the same 1000 rows forever).
        //
        // `lastSyncDate` is advanced after each successful round trip so
        // subsequent iterations only carry bulk rows (the incremental
        // small-volume tables filter out by lastSyncDate). Bulk types
        // filter by `syncedToServer == false` (not by date), so a flag
        // failure on iteration N means the same rows would be fetched
        // again on iteration N+1 — that's the loop-forever risk this code
        // explicitly breaks on below.
        //
        // The hard cap of `maxRoundTrips` matches `sampleBatchLimit` as a
        // safety belt: 1000 rows × 4 bulk types × 1000 trips = 4M rows per
        // `sync()` invocation, well beyond any realistic backlog.
        let maxRoundTrips = Self.sampleBatchLimit
        var roundTrips = 0
        var totalBytes = 0
        var lastTripOutcome: PostUploadOutcome?

        do {
            while roundTrips < maxRoundTrips {
                // Capture the cursor upper bound BEFORE building the payload
                // so records created during the round trip don't fall into a
                // hole. The naive pattern `lastSyncDate = .now` post-trip
                // would have skipped any record whose timestamp landed
                // between buildPayload and the cursor assignment: not in the
                // current payload (created after the fetch returned) AND
                // less than the new cursor (so the next sync's `since`
                // filter would exclude it). Pinning the upper bound at
                // payload-build time keeps the cursor in lockstep with what
                // we actually sent. Bulk types filter by `syncedToServer`
                // (not by date) so they're unaffected by this race either way.
                let cursorUpperBound = Date.now
                // First iteration carries the small-volume tables. Subsequent
                // iterations request bulk-only payloads: `DataExporter`
                // scans every row of every small-volume table with no
                // predicate, so re-running it per iteration would turn a
                // multi-batch drain into N full-table scans on the MainActor.
                let iterationIsBulkOnly = roundTrips > 0
                let payload = try buildPayload(
                    from: modelContext,
                    demographics: demographics.isEmpty ? nil : demographics,
                    upperBound: cursorUpperBound,
                    bulkOnly: iterationIsBulkOnly
                )
                let uploadedIDs = extractUploadedSyncedIDs(from: payload)

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = payload
                request.timeoutInterval = 30

                let (responseData, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SyncError.noConnection
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    let body = String(data: responseData, encoding: .utf8)
                    throw SyncError.serverError(httpResponse.statusCode, body)
                }

                // Advance the small-volume cursor ONLY when this iteration
                // actually exported the small-volume tables. Bulk-only
                // iterations don't carry anxiety entries / med doses / etc.,
                // so advancing past them here would silently skip any
                // small-volume record created between iter 1's upperBound
                // and a later iter's cursor — the same race the round-1 fix
                // closed, just with a smaller window. Bulk types filter by
                // `syncedToServer == false` (not by date) so their progress
                // is tracked by the post-upload flag, not by `lastSyncDate`.
                if !iterationIsBulkOnly {
                    lastSyncDate = cursorUpperBound
                }

                let outcome = await applyPostUploadResponse(
                    responseData: responseData,
                    payloadByteCount: payload.count,
                    uploadedIDs: uploadedIDs,
                    modelContext: modelContext
                )
                lastTripOutcome = outcome

                roundTrips += 1
                totalBytes += payload.count

                // If flagging failed, the SAME rows would be fetched and
                // POSTed on the next iteration — silent perpetual re-upload
                // until `maxRoundTrips`. Bail to surface the partial-failure
                // message and let the next sync invocation retry from a
                // clean state.
                if !outcome.flaggingSucceeded {
                    break
                }

                // No bulk type hit its cap on this round → queue drained.
                if !uploadedIDs.hitBulkLimit(Self.sampleBatchLimit) {
                    break
                }

                // Long-running drain — surface progress so users don't think
                // the app is hung. `roundTrips` was just incremented, so this
                // reads as "N batches sent" referring to completed work.
                let bytesFmt = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
                lastSyncResult = "Syncing… \(roundTrips) batch\(roundTrips == 1 ? "" : "es") sent (\(bytesFmt))"
            }

            // Final status. Flag-failure paths preserve the detailed
            // single-trip message (which includes the underlying error).
            // Multi-batch successes get a rolled-up summary; single-batch
            // successes keep the per-trip message verbatim.
            if let outcome = lastTripOutcome, !outcome.flaggingSucceeded {
                lastSyncResult = outcome.message
            } else if roundTrips > 1 {
                let bytesFmt = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
                let time = Date.now.formatted(.dateTime.hour().minute())
                lastSyncResult = "Synced \(roundTrips) batches (\(bytesFmt)) at \(time)"
            } else if let outcome = lastTripOutcome {
                lastSyncResult = outcome.message
            }
        } catch is URLError {
            // Network failure. If earlier iterations committed, surface that
            // partial progress rather than erasing it in the status line.
            if roundTrips > 0 {
                lastSyncResult = "Synced \(roundTrips) batch\(roundTrips == 1 ? "" : "es"), then connection failed — will retry"
            } else {
                lastSyncResult = "Connection failed — check server URL"
            }
        } catch {
            if roundTrips > 0 {
                lastSyncResult = "Synced \(roundTrips) batch\(roundTrips == 1 ? "" : "es"), then failed: \(error.localizedDescription)"
            } else {
                lastSyncResult = error.localizedDescription
            }
        }

        isSyncing = false
    }

    /// Read HealthKit demographics for the sync payload. Both reads tolerate
    /// HealthKit access denial — the resulting demographics dict is just
    /// smaller, never thrown.
    @MainActor
    private func readDemographicsForSync() async -> [String: String] {
        var demographics: [String: String] = [:]
        let hkManager = HealthKitManager.shared
        do {
            if let dobComponents = try await hkManager.dateOfBirth(),
               let year = dobComponents.year,
               let month = dobComponents.month,
               let day = dobComponents.day {
                demographics["dateOfBirth"] = String(format: "%04d-%02d-%02d", year, month, day)
            }
        } catch {
            // HealthKit may deny access — non-fatal
        }
        do {
            let sex = try await hkManager.biologicalSex()
            switch sex {
            case .male: demographics["biologicalSex"] = "male"
            case .female: demographics["biologicalSex"] = "female"
            case .other: demographics["biologicalSex"] = "other"
            case .notSet: break
            @unknown default: break
            }
        } catch {
            // HealthKit may deny access — non-fatal
        }
        return demographics
    }

    /// Run the post-200-OK side effects: flag uploaded samples as synced,
    /// apply any correlations the server returned, and pull the song catalog.
    /// Returns the user-facing summary string for `lastSyncResult`.
    ///
    /// `internal` (not private) so SyncServiceTests can drive this path
    /// without standing up a mock URLSession. Each side effect is logically
    /// independent of the others — a failure in `markSamplesSynced` must NOT
    /// short-circuit correlation apply or the catalog pull, and is instead
    /// surfaced as a partially-failed result string.
    ///
    /// `markSamples` is injectable so the regression test can simulate a
    /// save error without standing up a doomed ModelContext.
    ///
    /// Pinned to `@MainActor` for the same reason as `sync(modelContext:)` —
    /// the body fetches/mutates via `ModelContext` after the
    /// `await SongService.fetchCatalog(...)` suspension point, so isolation
    /// must be guaranteed regardless of which task suspended.
    /// Outcome of a single post-upload step. The drain loop in `sync()` uses
    /// `flaggingSucceeded` to decide whether to attempt another round trip:
    /// if `markSamplesSynced` failed, looping would re-fetch the same unsynced
    /// rows and POST them again indefinitely. The loop breaks instead so the
    /// next `sync()` invocation can retry from a clean state.
    struct PostUploadOutcome: Equatable {
        let message: String
        let flaggingSucceeded: Bool
    }

    @MainActor
    func applyPostUploadResponse(
        responseData: Data,
        payloadByteCount: Int,
        uploadedIDs: UploadedSyncedIDs,
        modelContext: ModelContext,
        markSamples: ((_ ids: UploadedSyncedIDs, _ ctx: ModelContext) throws -> Void)? = nil
    ) async -> PostUploadOutcome {
        // Mark uploaded raw rows as synced so we don't resend them.
        // Failures here used to be swallowed via `try?`, which meant the
        // app would re-upload the same first 1000 rows forever if the
        // save failed. Surface the error explicitly so it's diagnosable
        // even though the upload itself succeeded — but do NOT short-circuit
        // the rest of the post-200-OK flow. Correlations apply and the
        // song-catalog pull are logically independent of raw-row
        // flagging, so they should still run; we just record the partial
        // failure to surface in the result string at the end.
        var sampleFlagError: Error?
        do {
            if let markSamples {
                try markSamples(uploadedIDs, modelContext)
            } else {
                try markSamplesSynced(uploadedIDs, modelContext: modelContext)
            }
        } catch {
            Log.data.error("markSamplesSynced failed after successful upload: \(error, privacy: .public)")
            sampleFlagError = error
        }

        // For each session whose row just landed on the server, push the
        // binary RR-interval archive if it hasn't been uploaded yet. The
        // /api/sync POST creates the server-side row; this second call
        // attaches the blob (~80–120 KB gzipped). Failures are non-fatal:
        // `rrArchiveUploadedAt` stays nil so the next sync retries.
        await uploadPendingRRArchives(
            sessionIDs: uploadedIDs.sensorSessions,
            modelContext: modelContext
        )

        // Parse correlations from sync response if present
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let correlationList = json["correlations"] as? [[String: Any]] {
            upsertCorrelations(correlationList, modelContext: modelContext)
        }

        // Pull songs catalog (server → iOS). Failures here are non-fatal
        // for the sync; the explicit `_ = try?` silences the "result of
        // 'try?' is unused" warning while preserving the swallow-and-move-on
        // semantics this call needs.
        _ = try? await SongService.fetchCatalog(into: modelContext)

        let size = ByteCountFormatter.string(fromByteCount: Int64(payloadByteCount), countStyle: .file)
        if let sampleFlagError {
            return PostUploadOutcome(
                message: "Synced \(size), but failed to flag samples — will re-send: \(sampleFlagError.localizedDescription)",
                flaggingSucceeded: false
            )
        } else {
            return PostUploadOutcome(
                message: "Synced \(size) at \(Date.now.formatted(.dateTime.hour().minute()))",
                flaggingSucceeded: true
            )
        }
    }

    /// Full sync — resets the last sync date and sends everything.
    ///
    /// Runs every guard `sync()` would hit *before* clearing `lastSyncDate` so
    /// that any aborted full sync leaves the incremental-sync cursor intact.
    ///
    /// `@MainActor` because it delegates to `sync(modelContext:)`, which is
    /// itself MainActor-pinned for safe `ModelContext` access across `await`s.
    @MainActor
    func fullSync(modelContext: ModelContext) async {
        guard !isSyncing else {
            lastSyncResult = "Sync already in progress"
            return
        }
        guard isConfigured else {
            lastSyncResult = "Not configured"
            return
        }
        lastSyncDate = nil
        await sync(modelContext: modelContext)
    }

    // MARK: - Fetch prescriptions from server

    /// Pull prescriptions from the server and upsert into SwiftData.
    /// Returns the number of prescriptions added or updated.
    ///
    /// `@MainActor`-isolated because the body fetches/inserts/saves on the
    /// caller's main-context `ModelContext`; running that from the global
    /// executor is the SwiftData data race documented in F-016.
    @discardableResult
    @MainActor
    func fetchPrescriptions(modelContext: ModelContext) async throws -> Int {
        guard isConfigured else { throw SyncError.notConfigured }

        guard var urlComponents = URLComponents(string: serverURL) else {
            throw SyncError.invalidURL
        }
        urlComponents.path = "/api/data/prescriptions"
        guard let url = urlComponents.url else {
            throw SyncError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.noConnection
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw SyncError.serverError(httpResponse.statusCode, body)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let records = json?["prescriptions"] as? [[String: Any]] else {
            return 0
        }

        return try PrescriptionImporter.importRecords(records, into: modelContext)
    }

    // MARK: - Fetch songs from server

    /// Pull the song catalog from the server and upsert into SwiftData.
    /// Returns the number of songs added or updated.
    @discardableResult
    func fetchSongs(modelContext: ModelContext) async throws -> Int {
        guard isConfigured else { throw SyncError.notConfigured }
        return try await SongService.fetchCatalog(into: modelContext)
    }

    /// Find existing MedicationDefinition by name (case-insensitive) or create a new one.
    /// Reactivates inactive medications when a new prescription arrives.
    /// Returns nil if the medication name is empty.
    @discardableResult
    static func findOrCreateMedication(
        name: String,
        doseMg: Double,
        in modelContext: ModelContext
    ) throws -> MedicationDefinition? {
        try PrescriptionImporter.findOrCreateMedication(name: name, doseMg: doseMg, in: modelContext)
    }

    /// Link existing prescriptions that have no MedicationDefinition.
    /// Call once on app startup to backfill records imported before auto-linking was added.
    static func backfillMedicationLinks(modelContext: ModelContext) throws {
        let unlinked = try modelContext.fetch(
            FetchDescriptor<Prescription>(
                predicate: #Predicate { $0.medication == nil }
            )
        )
        for rx in unlinked {
            rx.medication = try findOrCreateMedication(
                name: rx.medicationName, doseMg: rx.doseMg, in: modelContext
            )
        }
        if !unlinked.isEmpty {
            try modelContext.save()
        }
    }

    // MARK: - Correlations

    @MainActor
    private func upsertCorrelations(_ correlations: [[String: Any]], modelContext: ModelContext) {
        let iso = ISO8601DateFormatter()
        var seenSignals = Set<String>()

        for c in correlations {
            guard let signalName = c["signal_name"] as? String,
                  let corr = c["correlation"] as? Double,
                  let pValue = c["p_value"] as? Double,
                  let sampleCount = c["sample_count"] as? Int else { continue }

            seenSignals.insert(signalName)
            let serverDate = (c["computed_at"] as? String).flatMap { iso.date(from: $0) } ?? .now

            let descriptor = FetchDescriptor<PhysiologicalCorrelation>(
                predicate: #Predicate { $0.signalName == signalName }
            )
            let existing = try? modelContext.fetch(descriptor).first

            if let existing {
                existing.correlation = corr
                existing.pValue = pValue
                existing.sampleCount = sampleCount
                existing.meanSeverityWhenAbnormal = c["mean_severity_when_abnormal"] as? Double
                existing.meanSeverityWhenNormal = c["mean_severity_when_normal"] as? Double
                existing.computedAt = serverDate
            } else {
                let record = PhysiologicalCorrelation(
                    signalName: signalName,
                    correlation: corr,
                    pValue: pValue,
                    sampleCount: sampleCount,
                    meanSeverityWhenAbnormal: c["mean_severity_when_abnormal"] as? Double,
                    meanSeverityWhenNormal: c["mean_severity_when_normal"] as? Double,
                    computedAt: serverDate
                )
                modelContext.insert(record)
            }
        }

        // Remove correlations no longer returned by server — but only if the server
        // actually returned data. An empty array likely means the endpoint had no data
        // yet, not that all correlations should be wiped.
        if !correlations.isEmpty {
            let allLocal = (try? modelContext.fetch(FetchDescriptor<PhysiologicalCorrelation>())) ?? []
            for local in allLocal where !seenSignals.contains(local.signalName) {
                modelContext.delete(local)
            }
        }

        try? modelContext.save()
    }

    // MARK: - Payload construction (internal for testing)

    /// Internal (not private) so SyncServiceTests can verify the wrapper
    /// metadata without invoking a real network sync. The payload is the
    /// authoritative source of `syncSchemaVersion` for the server's
    /// per-version semantics, so it deserves direct test coverage.
    ///
    /// `@MainActor` because it fetches via `ModelContext` (through
    /// `DataExporter` and the unsynced-samples helpers). Called from
    /// `sync(modelContext:)`, which is itself MainActor.
    @MainActor
    func buildPayload(
        from context: ModelContext,
        demographics: [String: String]? = nil,
        upperBound: Date? = nil,
        bulkOnly: Bool = false
    ) throws -> Data {
        let since = lastSyncDate

        // `bulkOnly`: subsequent iterations of the drain loop skip the
        // `DataExporter.exportJSON` call entirely. `DataExporter.buildBundle`
        // fetches every row of every small-volume table (anxiety entries,
        // medication doses, CPAP sessions, barometric readings, lab results,
        // …) with no predicate and filters in memory — so a 100-iteration
        // drain would do 100 full table scans across 12+ tables on the
        // MainActor. After iteration 1 has already drained the small-volume
        // window through `upperBound`, iterations 2+ only need the bulk
        // arrays (which use indexed `syncedToServer == false` predicates).
        // The trade-off: small-volume records modified DURING a long drain
        // wait until the next `sync()` invocation rather than syncing
        // mid-drain. Acceptable: drain windows are bounded, and the next
        // sync correctly picks them up via the advanced `lastSyncDate`.
        var json: [String: Any]
        if bulkOnly {
            json = [:]
        } else {
            // Reuse DataExporter's JSON format — the server gets the same schema as file exports.
            // `upperBound` (when supplied) caps the small-volume range so the sync
            // loop can advance `lastSyncDate` to a known upper edge without skipping
            // records created during the round trip. See `sync()` for the rationale.
            //
            // `omitHealthSnapshots`: incremental syncs overwrite the
            // `healthSnapshots` key below with the dirty-flag selection
            // (cheap, capped, sufficient post-migration), so DataExporter's
            // unbounded snapshot fetch + DTO encode would be discarded
            // work. A full sync (`since == nil`) instead falls back to
            // DataExporter's date-range snapshot export: existing pre-
            // migration rows default to `syncedToServer = true` to avoid
            // a migration-time dirty storm, which means the dirty-flag
            // path would silently ship zero snapshots on a fullSync even
            // though the user explicitly asked to re-send everything.
            // The date-range path preserves the pre-migration "full
            // sync = upload everything" semantic for that case.
            let isFullSync = since == nil
            let jsonData = try DataExporter.exportJSON(
                from: context, start: since, end: upperBound,
                omitHealthSnapshots: !isFullSync
            )
            guard let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return jsonData
            }
            json = parsed
        }
        json["syncType"] = since == nil ? "full" : "incremental"
        if let since {
            json["since"] = ISO8601DateFormatter().string(from: since)
        }
        json["clientVersion"] = "1.0"
        // syncSchemaVersion 4 adds top-level `sensorSessions` + `hrvReadings`
        // arrays from the Polar H10 BLE pipeline. v3 added raw quantitySamples
        // + sleepStageEvents arrays and the dataQuality JSONB on each
        // HealthSnapshot; the server uses the version flag to interpret missing
        // dataQuality keys as intentional nils (clear-on-conflict) on v3+
        // clients vs. preserve-via-COALESCE on older. v2 added the seven
        // overnight clinical stats fields (spo2NadirOvernight, spo2TimeBelow90Min,
        // spo2DesatsCount, glucoseStdDev/CV/Min/Max) under the same
        // clear-on-conflict semantics.
        json["syncSchemaVersion"] = 4
        json["deviceName"] = "iOS \(UIDevice.current.systemVersion)"
        if let demographics {
            json["demographics"] = demographics
        }

        // v3: include un-synced raw samples (capped at 1000 each per request)
        json["quantitySamples"] = try fetchUnsyncedQuantitySamples(from: context)
        json["sleepStageEvents"] = try fetchUnsyncedSleepStageEvents(from: context)
        // v4: Polar H10 sensor sessions + per-window HRV readings. Server
        // accepts both since 0005_polar_h10_sessions; the version bump signals
        // intent to receive them on the next round-trip.
        json["sensorSessions"] = try fetchUnsyncedSensorSessions(from: context)
        json["hrvReadings"] = try fetchUnsyncedHRVReadings(from: context)
        // Overwrite `healthSnapshots` with the capped `!syncedToServer`
        // selection ONLY on incremental syncs. DataExporter has supplied
        // a date-range-filtered copy intended for file exports; for
        // incremental sync we want the dirty-flag set instead, with the
        // same per-call cap as the other bulk types so a multi-year
        // "Rebuild All History" doesn't blow the payload size limit on
        // a single request. Server upserts by `date`, so a row that's
        // both in the date-range AND dirty (the common overlap case)
        // simply lands once.
        //
        // On a full sync (`since == nil`) we leave DataExporter's
        // date-range export in place — see the comment up top about
        // pre-migration rows defaulting to `syncedToServer = true`.
        if since != nil {
            json["healthSnapshots"] = try fetchUnsyncedHealthSnapshots(from: context)
        }

        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Flip `syncedToServer = true` on the rows whose ids are in `uploaded`.
    /// Called from `sync()` after the server returns 200 OK so subsequent
    /// payloads only include newly-mirrored rows.
    ///
    /// Chunks the IN(...) lookup and the save under SQLite's 999-parameter
    /// limit so a 1000-ID upload doesn't cause the flag step to silently fail
    /// and trigger perpetual re-uploads of the same window.
    ///
    /// `@MainActor` because it fetches/mutates SwiftData rows and is invoked
    /// from `applyPostUploadResponse(...)` (also MainActor). Pinning the helper
    /// keeps `ModelContext` access on the same actor as its caller.
    @MainActor
    func markSamplesSynced(
        _ uploaded: UploadedSyncedIDs,
        modelContext: ModelContext
    ) throws {
        if !uploaded.quantitySamples.isEmpty {
            let ids = Set(uploaded.quantitySamples)
            try Self.flagSyncedInChunks(
                ids: ids, expectedVersions: uploaded.bulkRowVersions, in: modelContext
            ) { batch in
                FetchDescriptor<QuantityHealthSample>(
                    predicate: #Predicate { batch.contains($0.id) }
                )
            }
        }
        if !uploaded.sleepStageEvents.isEmpty {
            let ids = Set(uploaded.sleepStageEvents)
            try Self.flagSyncedInChunks(
                ids: ids, expectedVersions: uploaded.bulkRowVersions, in: modelContext
            ) { batch in
                FetchDescriptor<SleepStageEvent>(
                    predicate: #Predicate { batch.contains($0.id) }
                )
            }
        }
        if !uploaded.sensorSessions.isEmpty {
            let ids = Set(uploaded.sensorSessions)
            try Self.flagSyncedInChunks(
                ids: ids, expectedVersions: uploaded.bulkRowVersions, in: modelContext
            ) { batch in
                FetchDescriptor<SensorSession>(
                    predicate: #Predicate { batch.contains($0.id) }
                )
            }
        }
        if !uploaded.hrvReadings.isEmpty {
            let ids = Set(uploaded.hrvReadings)
            try Self.flagSyncedInChunks(
                ids: ids, expectedVersions: uploaded.bulkRowVersions, in: modelContext
            ) { batch in
                FetchDescriptor<HRVReading>(
                    predicate: #Predicate { batch.contains($0.id) }
                )
            }
        }
        if !uploaded.healthSnapshotDates.isEmpty {
            try Self.flagSnapshotsSynced(
                dates: uploaded.healthSnapshotDates,
                expectedVersions: uploaded.healthSnapshotVersions,
                in: modelContext
            )
        }
    }

    /// Flip `syncedToServer = true` on `HealthSnapshot` rows whose `date`
    /// matches one of `dates`. Dates come from a round-trip through
    /// `Self.snapshotDateFormatter` (in both directions — the sync path
    /// formats snapshot dates via `fetchUnsyncedHealthSnapshots` and
    /// parses them back via `extractUploadedSyncedIDs`). The format
    /// matches `DataExporter`'s ISO8601 whole-second format so a future
    /// switch back to date-range-based snapshot export would still
    /// round-trip cleanly. No fractional-second component on either
    /// side, so the absolute instant is preserved byte-for-byte.
    ///
    /// **No `Calendar.startOfDay` normalization on either side.** The stored
    /// `row.date` is already `Calendar.current.startOfDay(for:)` of the
    /// snapshot's calendar day in the *creation-time* timezone; the parsed
    /// date is the identical absolute instant from the payload. Re-running
    /// `Calendar.current.startOfDay(for:)` here would shift the date if the
    /// user travels between creation and sync (e.g. a PT-created snapshot
    /// at `00:00 PT == 08:00 UTC`, normalized in ET, becomes `00:00 ET ==
    /// 05:00 UTC` — no match against the original 08:00 UTC row → row never
    /// flips synced → perpetual re-uploads). Compare absolute `Date`
    /// equality directly.
    ///
    /// Fetches by `$0.date >= min && $0.date <= max` (the smallest range
    /// containing every uploaded date) and applies the `!syncedToServer`
    /// filter in memory afterwards, rather than `#Predicate { batch.contains($0.date) }`.
    /// `Set<UUID>.contains` in `#Predicate` translates cleanly through the
    /// SwiftData predicate compiler (used elsewhere in this file for sample-id
    /// flag flipping), but `Set<Date>.contains` rides a less-exercised path
    /// over SQLite `REAL`-typed columns that has produced silent zero-row
    /// matches in some iOS 17/18 builds. The range-bounded fetch keeps the
    /// predicate over indexed primitive `Date` comparisons — matching the
    /// safe pattern used in `SnapshotAggregator.apply*Precedence` — while
    /// still narrowing the candidate set far below "every dirty row in the
    /// table" for the common-case incremental upload.
    @MainActor
    private static func flagSnapshotsSynced(
        dates: [Date],
        expectedVersions: [Int],
        in context: ModelContext
    ) throws {
        // Build per-date version expectations. Empty expectedVersions
        // (full-sync path / pre-version payloads) maps every date to
        // `nil`, which `flagSnapshotsSynced` treats as "no check, flip
        // unconditionally" — matching pre-race-fix behavior for the
        // full-sync path where the version isn't carried.
        var expectedByDate: [Date: Int] = [:]
        if expectedVersions.count == dates.count {
            for (date, version) in zip(dates, expectedVersions) where version >= 0 {
                // Last-write wins if the same date appears twice; in
                // practice the payload doesn't duplicate dates.
                expectedByDate[date] = version
            }
        }
        let uploadedDates = Set(dates)
        guard let minDate = uploadedDates.min(),
              let maxDate = uploadedDates.max() else { return }
        // Date-range predicate narrows the fetch to the smallest box
        // containing every uploaded date. A multi-year incremental sync
        // upload typically spans a contiguous run of days so this is
        // tight; a sparse upload still bounds the fetch to a known
        // calendar range rather than scanning every dirty row in the
        // table. The `!$0.syncedToServer` filter is applied in memory
        // afterwards.
        //
        // The compound `&&` here is safe because both captured locals
        // are `Date` (a value-type wrapper around `Double`) — the iOS 26
        // SwiftData footgun documented in CLAUDE.md is specifically
        // about compound predicates capturing **non-primitive** locals
        // (`UUID`, `String`), which trip a pathologically slow translator
        // path. The matching pattern in
        // `SnapshotAggregator.applyOvernightSpO2Precedence` uses the
        // same shape (two Date clauses) and is the canonical reference.
        // Don't add a third-clause `Bool` predicate here without
        // re-checking — keep the bool filter in memory.
        let descriptor = FetchDescriptor<HealthSnapshot>(
            predicate: #Predicate { $0.date >= minDate && $0.date <= maxDate }
        )
        let candidates = try context.fetch(descriptor)
        var didChange = false
        for row in candidates where !row.syncedToServer && uploadedDates.contains(row.date) {
            // Race-window guard: if the row's `pendingSyncVersion`
            // advanced between payload-build and now, a concurrent
            // `aggregateDay` (running while `sync()` was suspended on
            // its URLSession await) mutated the row out from under the
            // payload. Leave it dirty so the new changes still sync.
            // `nil` means the payload didn't carry a version (full-sync
            // / DataExporter path) — fall through to the date-only
            // unconditional flip, matching pre-race-fix behavior.
            if let expected = expectedByDate[row.date], expected != row.pendingSyncVersion {
                continue
            }
            row.syncedToServer = true
            didChange = true
        }
        if didChange {
            try context.save()
        }
    }

    /// Fetch the rows whose ids are in `ids` in batches of
    /// `SQLiteLimits.predicateBatchSize`, flip `syncedToServer = true`, and save
    /// each batch independently. Saving per-batch keeps the SwiftData change-set
    /// bounded so even a large flag pass doesn't accumulate 1000+ pending
    /// updates in a single save. The generic `Row` constraint is `AnyObject &
    /// PersistentModel` so we can mutate the fetched row's `syncedToServer`
    /// in place via a key path. The upload payload is capped at 1000 IDs per
    /// call (`sampleBatchLimit`), so without chunking `markSamplesSynced` would
    /// silently exceed SQLite's 999-parameter limit, fail to flag the rows, and
    /// the next `sync()` would re-upload the same first 1000 samples forever.
    ///
    /// `expectedVersions` carries each uploaded row's `pendingSyncVersion`
    /// as captured at payload-build time. A row whose CURRENT version no
    /// longer matches was mutated while `sync()` was suspended on its
    /// network await (e.g. a `finalize()` landing between payload build and
    /// this flip) — the in-flight payload does NOT contain that mutation, so
    /// the row must stay dirty for the next sync. Skipping the flip here is
    /// the `flagSnapshotsSynced` race guard generalized to the UUID-keyed
    /// bulk types. A missing entry means the payload didn't carry a version
    /// for the row — flip unconditionally, matching pre-guard behavior.
    @MainActor
    private static func flagSyncedInChunks<Row: PersistentModel>(
        ids: Set<UUID>,
        expectedVersions: [UUID: Int],
        in context: ModelContext,
        descriptorBuilder: (Set<UUID>) -> FetchDescriptor<Row>
    ) throws where Row: SyncableSample {
        guard !ids.isEmpty else { return }
        let allIDs = Array(ids)
        var index = 0
        while index < allIDs.count {
            let end = min(index + SQLiteLimits.predicateBatchSize, allIDs.count)
            let batch = Set(allIDs[index..<end])
            let rows = try context.fetch(descriptorBuilder(batch))
            for row in rows {
                if let expected = expectedVersions[row.id], expected != row.pendingSyncVersion {
                    // Log the held-back row so a session stuck dirty across
                    // syncs is diagnosable — a silent skip here would look
                    // identical to a flag-flip bug from the outside.
                    Log.sync.info("""
                        Post-upload flip skipped for \(row.id.uuidString, privacy: .public): \
                        row mutated during sync (version \(expected) → \(row.pendingSyncVersion)); \
                        stays dirty and re-syncs next pass
                        """)
                    continue
                }
                row.syncedToServer = true
            }
            try context.save()
            index = end
        }
    }

    // MARK: - Sample fetch helpers (private)

    private static let sampleBatchLimit = 1000
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Used by `fetchUnsyncedHealthSnapshots` (formats `HealthSnapshot.date`
    /// into the outgoing payload) AND `extractUploadedSyncedIDs` (parses
    /// those dates back out so `flagSnapshotsSynced` can match by absolute
    /// `Date`). No fractional seconds so the round-trip preserves the
    /// stored start-of-day instant byte-for-byte.
    ///
    /// Format matches `DataExporter.isoFormatter` deliberately — DataExporter
    /// uses the same whole-second ISO8601 for file-export snapshots, so the
    /// server sees one consistent date format regardless of which export
    /// path produced the payload. Sample timestamps elsewhere in the sync
    /// payload go through the fractional-seconds `isoFormatter` above; the
    /// two formats coexist because they serve different keys.
    private static let snapshotDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fetch up to `sampleBatchLimit` dirty `HealthSnapshot` rows ordered by
    /// `date` ascending, formatted as dicts the server upserts into the
    /// `health_snapshots` table.
    ///
    /// The on-wire shape is a superset of `DataExporter.HealthSnapshotDTO`:
    /// every field the DTO encodes, plus `dataQuality` (the JSON-encoded
    /// reliability/source breakdown). The DTO doesn't currently include
    /// `dataQuality` — a pre-existing gap in the file-export schema — but
    /// the server's upsert *does* read it (treats a missing key as
    /// `EXCLUDED.data_quality` → NULL), so omitting it from the sync
    /// payload would silently null the column on every push. We emit it
    /// here even though DTO doesn't; the file-export DTO is the part
    /// that's stale, not this dict. (If a future change extends the DTO
    /// to include `dataQuality`, this divergence collapses.)
    ///
    /// Cap means a multi-year rebuild streams across multiple drain-loop
    /// iterations rather than blowing the payload limit in one shot; the
    /// post-upload `flagSnapshotsSynced` step flips the uploaded rows clean
    /// so the next iteration's fetch returns the next batch. Counted by
    /// `hitBulkLimit` so the loop keeps going while batches are at the cap.
    @MainActor
    private func fetchUnsyncedHealthSnapshots(from context: ModelContext) throws -> [[String: Any]] {
        var descriptor = FetchDescriptor<HealthSnapshot>(
            predicate: #Predicate { !$0.syncedToServer },
            sortBy: [SortDescriptor(\.date)]
        )
        descriptor.fetchLimit = Self.sampleBatchLimit
        let rows = try context.fetch(descriptor)
        return rows.map { s in
            var dict: [String: Any] = [
                "date": Self.snapshotDateFormatter.string(from: s.date)
            ]
            // Optional fields only emit when present so the on-wire shape
            // matches `JSONEncoder`'s default-encode-with-omitted-nils
            // behavior on `HealthSnapshotDTO`.
            func put<V>(_ key: String, _ value: V?) {
                if let value { dict[key] = value }
            }
            put("hrvAvg", s.hrvAvg)
            put("hrvMin", s.hrvMin)
            put("restingHR", s.restingHR)
            put("sleepDurationMin", s.sleepDurationMin)
            put("sleepDeepMin", s.sleepDeepMin)
            put("sleepREMMin", s.sleepREMMin)
            put("sleepCoreMin", s.sleepCoreMin)
            put("sleepAwakeMin", s.sleepAwakeMin)
            put("skinTempDeviation", s.skinTempDeviation)
            put("skinTempWrist", s.skinTempWrist)
            put("respiratoryRate", s.respiratoryRate)
            put("spo2Avg", s.spo2Avg)
            put("spo2NadirOvernight", s.spo2NadirOvernight)
            put("spo2NadirOpportunistic", s.spo2NadirOpportunistic)
            put("spo2TimeBelow90Min", s.spo2TimeBelow90Min)
            put("spo2DesatsCount", s.spo2DesatsCount)
            put("steps", s.steps)
            put("activeCalories", s.activeCalories)
            put("exerciseMinutes", s.exerciseMinutes)
            put("environmentalSoundAvg", s.environmentalSoundAvg)
            put("bpSystolic", s.bpSystolic)
            put("bpDiastolic", s.bpDiastolic)
            put("bloodGlucoseAvg", s.bloodGlucoseAvg)
            put("glucoseStdDev", s.glucoseStdDev)
            put("glucoseCV", s.glucoseCV)
            put("glucoseMin", s.glucoseMin)
            put("glucoseMax", s.glucoseMax)
            put("cpapAHI", s.cpapAHI)
            put("cpapUsageMinutes", s.cpapUsageMinutes)
            put("barometricPressureAvgKPa", s.barometricPressureAvgKPa)
            put("barometricPressureChangeKPa", s.barometricPressureChangeKPa)
            // The server treats a missing `dataQuality` on syncSchemaVersion>=3
            // as an intentional clear (`data_quality = EXCLUDED.data_quality`),
            // so omitting this key on every sync would silently null out the
            // column. Emit when non-nil; emitting an absent key for a locally
            // nil value still matches local state (both become NULL server-side).
            put("dataQuality", s.dataQuality)
            // Client-internal token for the race-window check in
            // `flagSnapshotsSynced` — the server ignores it. Underscored
            // so a future schema review treats it as deliberately
            // out-of-band rather than a stray field. Captured at fetch
            // time so a concurrent `aggregateDay` running during the
            // sync's URLSession await can bump the field, and the
            // post-upload step will notice the mismatch.
            dict["_pendingSyncVersion"] = s.pendingSyncVersion
            return dict
        }
    }

    @MainActor
    private func fetchUnsyncedQuantitySamples(from context: ModelContext) throws -> [[String: Any]] {
        var descriptor = FetchDescriptor<QuantityHealthSample>(
            predicate: #Predicate { !$0.syncedToServer },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = Self.sampleBatchLimit
        let rows = try context.fetch(descriptor)
        return rows.map { row in
            var dict: [String: Any] = [
                "id": row.id.uuidString,
                "timestamp": Self.isoFormatter.string(from: row.timestamp),
                "metricType": row.metricType,
                "value": row.value,
                "unitString": row.unitString,
                "sourceBundleID": row.sourceBundleID,
                "sourceName": row.sourceName,
            ]
            if let deviceModel = row.deviceModel {
                dict["deviceModel"] = deviceModel
            }
            if let groupID = row.groupID {
                dict["groupId"] = groupID.uuidString
            }
            // Client-internal staleness token for the post-upload flag flip
            // (see `flagSyncedInChunks`); the server reads named keys only
            // and ignores it. Underscored to match `_pendingSyncVersion` on
            // health snapshots — deliberately out-of-band, not schema.
            dict["_pendingSyncVersion"] = row.pendingSyncVersion
            return dict
        }
    }

    /// Pull the `id` strings out of the just-built payload so we can flip
    /// their `syncedToServer` flag after the server returns 200. Reading from
    /// the payload (instead of re-querying SwiftData) guarantees we mark
    /// exactly what was uploaded — no race with new mirrored rows.
    /// Internal (not private) so `SyncServiceTests` can directly verify the
    /// payload → ID-extraction step without invoking a real network sync.
    /// The post-upload mark-synced flow depends on this returning a faithful
    /// breakdown of what's actually in the payload, including the
    /// non-UUID-keyed `healthSnapshotDates`.
    func extractUploadedSyncedIDs(from payload: Data) -> UploadedSyncedIDs {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return UploadedSyncedIDs()
        }
        // Alongside each row's id, capture the `_pendingSyncVersion` the
        // fetch helpers embedded at payload-build time. `flagSyncedInChunks`
        // compares it against the row's CURRENT version so rows mutated
        // during the network await (finalize, retroactive HealthKit
        // correction) stay dirty. Rows without the key (none today — every
        // bulk fetch helper emits it) simply skip the check.
        var versions: [UUID: Int] = [:]
        func ids(forKey key: String) -> [UUID] {
            ((json[key] as? [[String: Any]]) ?? []).compactMap { dict in
                guard let id = (dict["id"] as? String).flatMap(UUID.init(uuidString:)) else {
                    return nil
                }
                if let version = dict["_pendingSyncVersion"] as? Int {
                    versions[id] = version
                }
                return id
            }
        }
        // Snapshot dates can come from either of two formatters depending
        // on sync mode:
        //   - Incremental (`since != nil`): formatted by
        //     `fetchUnsyncedHealthSnapshots` via `Self.snapshotDateFormatter`.
        //   - Full (`since == nil`): formatted by `DataExporter.isoFormatter`.
        // Both use `[.withInternetDateTime]` (whole-second, no fractional
        // component) — deliberately, so this single-formatter parse works
        // for either source. `Self.isoFormatter` is the strict
        // fractional-seconds variant used for sample timestamps and would
        // fail to parse the snapshot's whole-second format, hence the
        // separate non-fractional `snapshotDateFormatter` used here.
        // Parsing failures drop the entry — the row stays dirty and
        // re-uploads next time, which beats silently marking the wrong
        // day clean.
        // Snapshot payloads carry both `date` (ISO8601 string) and
        // `_pendingSyncVersion` (Int, client-internal — see
        // `fetchUnsyncedHealthSnapshots`). Pull them in lockstep so the
        // index alignment between `healthSnapshotDates` and
        // `healthSnapshotVersions` is preserved. A snapshot from the
        // full-sync (DataExporter) path won't carry the version key;
        // it gets a parallel slot, treated as "no check" downstream.
        var snapshotDates: [Date] = []
        var snapshotVersions: [Int] = []
        for dict in (json["healthSnapshots"] as? [[String: Any]]) ?? [] {
            guard let dateString = dict["date"] as? String,
                  let date = Self.snapshotDateFormatter.date(from: dateString) else {
                continue
            }
            snapshotDates.append(date)
            snapshotVersions.append((dict["_pendingSyncVersion"] as? Int) ?? -1)
        }
        return UploadedSyncedIDs(
            quantitySamples: ids(forKey: "quantitySamples"),
            sleepStageEvents: ids(forKey: "sleepStageEvents"),
            sensorSessions: ids(forKey: "sensorSessions"),
            hrvReadings: ids(forKey: "hrvReadings"),
            healthSnapshotDates: snapshotDates,
            healthSnapshotVersions: snapshotVersions,
            bulkRowVersions: versions
        )
    }

    @MainActor
    private func fetchUnsyncedSleepStageEvents(from context: ModelContext) throws -> [[String: Any]] {
        var descriptor = FetchDescriptor<SleepStageEvent>(
            predicate: #Predicate { !$0.syncedToServer },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = Self.sampleBatchLimit
        let rows = try context.fetch(descriptor)
        return rows.map { row in
            var dict: [String: Any] = [
                "id": row.id.uuidString,
                "startTime": Self.isoFormatter.string(from: row.startTime),
                "endTime": Self.isoFormatter.string(from: row.endTime),
                "stage": row.stage,
                "sourceBundleID": row.sourceBundleID,
                "sourceName": row.sourceName,
            ]
            if let deviceModel = row.deviceModel {
                dict["deviceModel"] = deviceModel
            }
            // Client-internal staleness token; see fetchUnsyncedQuantitySamples.
            dict["_pendingSyncVersion"] = row.pendingSyncVersion
            return dict
        }
    }

    @MainActor
    private func fetchUnsyncedSensorSessions(from context: ModelContext) throws -> [[String: Any]] {
        var descriptor = FetchDescriptor<SensorSession>(
            predicate: #Predicate { !$0.syncedToServer },
            sortBy: [SortDescriptor(\.startTime)]
        )
        descriptor.fetchLimit = Self.sampleBatchLimit
        let rows = try context.fetch(descriptor)
        return rows.map { row in
            var dict: [String: Any] = [
                "id": row.id.uuidString,
                "startTime": Self.isoFormatter.string(from: row.startTime),
                "interruptionCount": row.interruptions.count,
                "batteryAtStart": row.batteryAtStart,
            ]
            if let endTime = row.endTime {
                dict["endTime"] = Self.isoFormatter.string(from: endTime)
            }
            if let source = row.source {
                dict["source"] = source
            } else {
                // Server requires `source` per schema 0005. Use a stable
                // sentinel when the field is nil so we never silently fail
                // the upsert on the server side.
                dict["source"] = "unknown"
            }
            // Decode the on-disk `String?` into a dict before sending. The
            // server tolerates both shapes (see `_coerce_summary_json` in
            // server.py), but the dict path is the cleaner contract — no
            // double-encoding ambiguity, and lookups like
            // `summary_json->>'rmssdMean'` work without an intermediate
            // unwrap. A malformed string falls through as nil so one bad
            // row doesn't break the batch.
            if let summary = row.summaryJSON,
               let data = summary.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                dict["summaryJSON"] = parsed
            }
            // Client-internal staleness token; see fetchUnsyncedQuantitySamples.
            // This is the guard that keeps a finalize() interleaving with an
            // in-flight sync from being marked synced with a stale payload.
            dict["_pendingSyncVersion"] = row.pendingSyncVersion
            return dict
        }
    }

    @MainActor
    private func fetchUnsyncedHRVReadings(from context: ModelContext) throws -> [[String: Any]] {
        var descriptor = FetchDescriptor<HRVReading>(
            predicate: #Predicate { !$0.syncedToServer },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        descriptor.fetchLimit = Self.sampleBatchLimit
        let rows = try context.fetch(descriptor)
        return rows.map { row in
            var dict: [String: Any] = [
                "id": row.id.uuidString,
                "timestamp": Self.isoFormatter.string(from: row.timestamp),
                "rmssd": row.rmssd,
                "sdnn": row.sdnn,
                "pnn50": row.pnn50,
                "lfPower": row.lfPower,
                "hfPower": row.hfPower,
                "lfHfRatio": row.lfHfRatio,
                // Server schema 0005 requires source non-null and reads
                // `r["source"]` (raises KeyError on missing). Fall back to
                // the same "unknown" sentinel sensorSessions uses so legacy
                // / Watch-side rows don't 500 the whole batch.
                "source": row.source ?? "unknown",
            ]
            // Server key is `sessionId` (matches the parent table FK column
            // `hrv_readings.session_id`). The iOS model field happens to be
            // `sensorSessionID`; only the wire name follows the server
            // contract.
            if let sessionID = row.sensorSessionID {
                dict["sessionId"] = sessionID.uuidString
            }
            // Client-internal staleness token; see fetchUnsyncedQuantitySamples.
            dict["_pendingSyncVersion"] = row.pendingSyncVersion
            return dict
        }
    }

    // MARK: - RR-archive upload (Phase 3b)

    /// For each session that just landed on the server via /api/sync, push
    /// the binary RR-interval archive if it hasn't been uploaded yet. The
    /// archive is a separate POST because it's a multi-hundred-KB binary
    /// blob and shouldn't bloat the JSON sync payload.
    ///
    /// Skip semantics:
    /// - Already uploaded (`rrArchiveUploadedAt != nil`) — skip.
    /// - No on-disk file — skip (no archive to attach; session metadata
    ///   alone is sufficient).
    /// - Empty file (`fileSize == 0`) — skip (server returns 400 for empty
    ///   payloads; an empty archive is the same as "no archive").
    ///
    /// Each upload is independent — a single failure doesn't abort the
    /// rest. Failures leave `rrArchiveUploadedAt` nil so the next sync
    /// retries.
    ///
    /// `postArchive` is injectable so tests can drive the upload-decision
    /// logic without standing up a real URLSession. When nil, the private
    /// `postRRArchive` (real network impl) runs. Matches the `markSamples`
    /// closure-injection pattern on `applyPostUploadResponse`.
    @MainActor
    func uploadPendingRRArchives(
        sessionIDs: [UUID],
        modelContext: ModelContext,
        postArchive: ((_ sessionID: UUID, _ body: Data) async throws -> Void)? = nil
    ) async {
        guard !sessionIDs.isEmpty, isConfigured else { return }
        let ids = Set(sessionIDs)
        let sessions: [SensorSession]
        do {
            sessions = try modelContext.fetch(
                FetchDescriptor<SensorSession>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
            )
        } catch {
            Log.sync.error("RR archive: failed to fetch sessions: \(error, privacy: .public)")
            return
        }

        // Only upload archives of FINALIZED sessions (endTime != nil). Uploading a
        // still-recording session's archive stamps rrArchiveUploadedAt on a
        // truncated file, permanently omitting everything recorded after this sync
        // (the skip guard never re-examines it). See F-014.
        for session in sessions where session.rrArchiveUploadedAt == nil && session.endTime != nil {
            let url = RRArchiveWriter.archiveURL(for: session.id)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let raw = try? Data(contentsOf: url), !raw.isEmpty else { continue }
            guard let compressed = try? (raw as NSData).compressed(using: .zlib) as Data else {
                Log.sync.error(
                    "RR archive: zlib compression failed for session \(session.id.uuidString, privacy: .public)"
                )
                continue
            }
            do {
                if let postArchive {
                    try await postArchive(session.id, compressed)
                } else {
                    try await postRRArchive(sessionID: session.id, body: compressed)
                }
                session.rrArchiveUploadedAt = .now
                try modelContext.save()
            } catch {
                Log.sync.error(
                    "RR archive upload failed for session \(session.id.uuidString, privacy: .public): \(error, privacy: .public)"
                )
                // rrArchiveUploadedAt stays nil — next sync retries.
            }
        }
    }

    private func postRRArchive(sessionID: UUID, body: Data) async throws {
        guard var components = URLComponents(string: serverURL) else {
            throw SyncError.invalidURL
        }
        components.path = "/api/sensor_sessions/\(sessionID.uuidString)/rr_archive"
        guard let url = components.url else { throw SyncError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.noConnection
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8)
            throw SyncError.serverError(http.statusCode, bodyText)
        }
    }
}

/// Models that carry a `syncedToServer` flag flipped by `markSamplesSynced`
/// after a successful upload. Conformance is added in extensions next to
/// each `@Model` so the chunked-flag helper can mutate the field generically
/// without losing the per-model `@Model` storage semantics.
protocol SyncableSample: AnyObject {
    var id: UUID { get }
    var syncedToServer: Bool { get set }
    /// Staleness token captured into the payload at build time
    /// (`_pendingSyncVersion`) and re-checked by `flagSyncedInChunks`
    /// before flipping `syncedToServer` — rows mutated during the sync's
    /// network await keep their dirty flag so the new state still syncs.
    var pendingSyncVersion: Int { get }
}

extension QuantityHealthSample: SyncableSample {}
extension SleepStageEvent: SyncableSample {}
extension SensorSession: SyncableSample {}
extension HRVReading: SyncableSample {}

/// Bundle of ids the sync payload uploaded, captured before the POST so
/// `markSamplesSynced` flips the local flag for exactly what made it onto
/// the wire — never less (would re-upload) and never more (would mark
/// in-flight rows as synced and lose them on the next sync).
///
/// New synced types add fields here rather than spreading through the
/// `applyPostUploadResponse` / `markSamples` signature.
struct UploadedSyncedIDs: Equatable {
    var quantitySamples: [UUID] = []
    var sleepStageEvents: [UUID] = []
    var sensorSessions: [UUID] = []
    var hrvReadings: [UUID] = []
    /// `HealthSnapshot` uses `date` as its server-side primary key (not a UUID),
    /// so post-upload flag-flipping for snapshots happens by date rather than ID.
    /// Carried separately so the existing UUID-keyed path stays untouched.
    var healthSnapshotDates: [Date] = []

    /// Per-row `pendingSyncVersion` captured at fetch time for the rows
    /// in `healthSnapshotDates`. Same-index alignment: index `i` of this
    /// array is the version that was on the row at index `i` of the date
    /// array when the payload was built. `flagSnapshotsSynced` compares
    /// the captured version against each row's CURRENT version to detect
    /// snapshots that got re-aggregated during the sync's URLSession
    /// await window — those rows stay dirty so their new changes still
    /// sync. Empty for the full-sync path (DataExporter doesn't emit
    /// `_pendingSyncVersion`); flagSnapshotsSynced treats a missing
    /// version as "no check" and flips by date alone (matching pre-PR
    /// full-sync semantics where this race wasn't addressable).
    var healthSnapshotVersions: [Int] = []

    /// Per-row `pendingSyncVersion` captured at payload-build time for every
    /// UUID-keyed bulk row (quantity samples, sleep stage events, sensor
    /// sessions, HRV readings). One map for all four types — UUIDs don't
    /// collide across tables, and `flagSyncedInChunks` looks rows up by id
    /// anyway. Same role as `healthSnapshotVersions` plays for the date-keyed
    /// snapshot path: the post-upload flip skips any row whose current
    /// version drifted from the captured one, keeping mid-sync mutations
    /// (finalize, retroactive corrections) dirty so they re-sync.
    var bulkRowVersions: [UUID: Int] = [:]

    /// True if any bulk-type array filled the per-call cap. The sync loop uses
    /// this as the signal that another round-trip is worth attempting: if we
    /// just shipped `cap` rows of any type, there might be `cap` more behind
    /// them. Includes `healthSnapshotDates`: `fetchUnsyncedHealthSnapshots`
    /// caps the per-call selection at `sampleBatchLimit` so a multi-year
    /// rebuild streams across iterations instead of blowing the payload in
    /// one shot.
    func hitBulkLimit(_ cap: Int) -> Bool {
        quantitySamples.count >= cap
            || sleepStageEvents.count >= cap
            || sensorSessions.count >= cap
            || hrvReadings.count >= cap
            || healthSnapshotDates.count >= cap
    }
}
