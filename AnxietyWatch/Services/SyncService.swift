import Foundation
import HealthKit
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

            // Parse correlations from sync response if present
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let correlationList = json["correlations"] as? [[String: Any]] {
                upsertCorrelations(correlationList, modelContext: modelContext)
            }

            // Pull songs catalog (server → iOS)
            try? await SongService.fetchCatalog(into: modelContext)

            let size = ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .file)
            lastSyncResult = "Synced \(size) at \(Date.now.formatted(.dateTime.hour().minute()))"
        } catch is URLError {
            lastSyncResult = "Connection failed — check server URL"
        } catch {
            lastSyncResult = error.localizedDescription
        }

        isSyncing = false
    }

    /// Full sync — resets the last sync date and sends everything.
    ///
    /// Runs every guard `sync()` would hit *before* clearing `lastSyncDate` so
    /// that any aborted full sync leaves the incremental-sync cursor intact.
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

        // Remove correlations no longer returned by server
        let allLocal = (try? modelContext.fetch(FetchDescriptor<PhysiologicalCorrelation>())) ?? []
        for local in allLocal where !seenSignals.contains(local.signalName) {
            modelContext.delete(local)
        }

        try? modelContext.save()
    }

    // MARK: - Private

    private func buildPayload(from context: ModelContext, demographics: [String: String]? = nil) throws -> Data {
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
        json["deviceName"] = "iOS \(UIDevice.current.systemVersion)"
        if let demographics {
            json["demographics"] = demographics
        }

        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}
