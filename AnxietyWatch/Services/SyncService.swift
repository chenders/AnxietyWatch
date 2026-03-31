import Foundation
import SwiftData
import UIKit

/// Push-only sync to a personal server. The app is the source of truth;
/// the server is a mirror for viewing on larger displays and Claude analysis.
@Observable
final class SyncService {
    static let shared = SyncService()

    var isSyncing = false
    var lastSyncResult: String?

    // MARK: - Configuration (stored in UserDefaults)

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "syncServerURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "syncServerURL") }
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "syncApiKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "syncApiKey") }
    }

    var autoSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "syncAutoEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "syncAutoEnabled") }
    }

    var lastSyncDate: Date? {
        get {
            let ts = UserDefaults.standard.double(forKey: "lastSyncDate")
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            if let date = newValue {
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
        guard !isSyncing else { return }

        isSyncing = true
        lastSyncResult = "Syncing..."

        do {
            // Incremental: only records since last sync
            let payload = try buildPayload(from: modelContext)

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
    func fullSync(modelContext: ModelContext) async {
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


    // MARK: - Private

    private func buildPayload(from context: ModelContext) throws -> Data {
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
        json["deviceName"] = UIDevice.current.name

        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}
