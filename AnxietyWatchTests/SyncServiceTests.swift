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

}
