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

        do {
            // Read HealthKit demographics before entering the sync payload build
            // (HealthKitManager is an actor, so these calls require await)
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

            // Incremental: only records since last sync
            let payload = try buildPayload(from: modelContext, demographics: demographics.isEmpty ? nil : demographics)
            // Capture the ids included in the payload so we can flip
            // syncedToServer = true after the server confirms 200 OK.
            let (uploadedQuantityIDs, uploadedSleepIDs) = extractUploadedSampleIDs(from: payload)

            guard var urlComponents = URLComponents(string: serverURL) else {
                throw SyncError.invalidURL
            }
            // Append /api/sync if the URL doesn't already have a path
            if urlComponents.path.isEmpty || urlComponents.path == "/" {
                urlComponents.path = "/api/sync"
            }
            guard let url = urlComponents.url else {
                throw SyncError.invalidURL
            }

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

            lastSyncDate = .now

            lastSyncResult = await applyPostUploadResponse(
                responseData: responseData,
                payloadByteCount: payload.count,
                uploadedQuantityIDs: uploadedQuantityIDs,
                uploadedSleepIDs: uploadedSleepIDs,
                modelContext: modelContext
            )
        } catch is URLError {
            lastSyncResult = "Connection failed — check server URL"
        } catch {
            lastSyncResult = error.localizedDescription
        }

        isSyncing = false
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
    @MainActor
    func applyPostUploadResponse(
        responseData: Data,
        payloadByteCount: Int,
        uploadedQuantityIDs: [UUID],
        uploadedSleepIDs: [UUID],
        modelContext: ModelContext,
        markSamples: ((_ qIDs: [UUID], _ sIDs: [UUID], _ ctx: ModelContext) throws -> Void)? = nil
    ) async -> String {
        // Mark uploaded raw samples as synced so we don't resend them.
        // Failures here used to be swallowed via `try?`, which meant the
        // app would re-upload the same first 1000 samples forever if the
        // save failed. Surface the error explicitly so it's diagnosable
        // even though the upload itself succeeded — but do NOT short-circuit
        // the rest of the post-200-OK flow. Correlations apply and the
        // song-catalog pull are logically independent of raw-sample
        // flagging, so they should still run; we just record the partial
        // failure to surface in the result string at the end.
        var sampleFlagError: Error?
        do {
            if let markSamples {
                try markSamples(uploadedQuantityIDs, uploadedSleepIDs, modelContext)
            } else {
                try markSamplesSynced(
                    quantityIDs: uploadedQuantityIDs,
                    sleepIDs: uploadedSleepIDs,
                    modelContext: modelContext
                )
            }
        } catch {
            Log.data.error("markSamplesSynced failed after successful upload: \(error, privacy: .public)")
            sampleFlagError = error
        }

        // Parse correlations from sync response if present
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let correlationList = json["correlations"] as? [[String: Any]] {
            upsertCorrelations(correlationList, modelContext: modelContext)
        }

        // Pull songs catalog (server → iOS)
        try? await SongService.fetchCatalog(into: modelContext)

        let size = ByteCountFormatter.string(fromByteCount: Int64(payloadByteCount), countStyle: .file)
        if let sampleFlagError {
            return "Synced \(size), but failed to flag samples — will re-send: \(sampleFlagError.localizedDescription)"
        } else {
            return "Synced \(size) at \(Date.now.formatted(.dateTime.hour().minute()))"
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
    @discardableResult
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
    func buildPayload(from context: ModelContext, demographics: [String: String]? = nil) throws -> Data {
        let since = lastSyncDate

        // Reuse DataExporter's JSON format — the server gets the same schema as file exports
        let jsonData = try DataExporter.exportJSON(from: context, start: since, end: nil)

        // Wrap with sync metadata
        guard var json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return jsonData
        }
        json["syncType"] = since == nil ? "full" : "incremental"
        if let since {
            json["since"] = ISO8601DateFormatter().string(from: since)
        }
        json["clientVersion"] = "1.0"
        // syncSchemaVersion 3 adds raw quantitySamples + sleepStageEvents arrays
        // and the dataQuality JSONB on each HealthSnapshot. The server uses the
        // version flag to interpret missing dataQuality keys as intentional nils
        // (clear-on-conflict) on v3+ clients vs. preserve-via-COALESCE on older.
        // v2 added the seven overnight clinical stats fields (spo2NadirOvernight,
        // spo2TimeBelow90Min, spo2DesatsCount, glucoseStdDev/CV/Min/Max) under
        // the same clear-on-conflict semantics.
        json["syncSchemaVersion"] = 3
        json["deviceName"] = "iOS \(UIDevice.current.systemVersion)"
        if let demographics {
            json["demographics"] = demographics
        }

        // v3: include un-synced raw samples (capped at 1000 each per request)
        json["quantitySamples"] = try fetchUnsyncedQuantitySamples(from: context)
        json["sleepStageEvents"] = try fetchUnsyncedSleepStageEvents(from: context)

        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Flip `syncedToServer = true` on the rows whose ids match. Called from
    /// `sync()` after the server returns 200 OK so subsequent payloads only
    /// include newly-mirrored samples.
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
        quantityIDs: [UUID],
        sleepIDs: [UUID],
        modelContext: ModelContext
    ) throws {
        if !quantityIDs.isEmpty {
            let qSet = Set(quantityIDs)
            try Self.flagSyncedInChunks(ids: qSet, in: modelContext) { batch in
                FetchDescriptor<QuantityHealthSample>(
                    predicate: #Predicate { batch.contains($0.id) }
                )
            }
        }
        if !sleepIDs.isEmpty {
            let sSet = Set(sleepIDs)
            try Self.flagSyncedInChunks(ids: sSet, in: modelContext) { batch in
                FetchDescriptor<SleepStageEvent>(
                    predicate: #Predicate { batch.contains($0.id) }
                )
            }
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
    @MainActor
    private static func flagSyncedInChunks<Row: PersistentModel>(
        ids: Set<UUID>,
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
            for row in rows { row.syncedToServer = true }
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
            return dict
        }
    }

    /// Pull the `id` strings out of the just-built payload so we can flip
    /// their `syncedToServer` flag after the server returns 200. Reading from
    /// the payload (instead of re-querying SwiftData) guarantees we mark
    /// exactly what was uploaded — no race with new mirrored samples.
    private func extractUploadedSampleIDs(from payload: Data) -> (quantity: [UUID], sleep: [UUID]) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return ([], [])
        }
        let qIDs = (json["quantitySamples"] as? [[String: Any]])?.compactMap { dict in
            (dict["id"] as? String).flatMap(UUID.init(uuidString:))
        } ?? []
        let sIDs = (json["sleepStageEvents"] as? [[String: Any]])?.compactMap { dict in
            (dict["id"] as? String).flatMap(UUID.init(uuidString:))
        } ?? []
        return (qIDs, sIDs)
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
            return dict
        }
    }
}

/// Models that carry a `syncedToServer` flag flipped by `markSamplesSynced`
/// after a successful upload. Conformance is added in extensions next to
/// each `@Model` so the chunked-flag helper can mutate the field generically
/// without losing the per-model `@Model` storage semantics.
protocol SyncableSample: AnyObject {
    var syncedToServer: Bool { get set }
}

extension QuantityHealthSample: SyncableSample {}
extension SleepStageEvent: SyncableSample {}
