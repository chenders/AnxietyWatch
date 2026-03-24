import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct SyncServiceTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: AnxietyEntry.self, MedicationDefinition.self, MedicationDose.self,
            CPAPSession.self, HealthSnapshot.self, BarometricReading.self,
            ClinicalLabResult.self,
            configurations: config
        )
    }

    // MARK: - isConfigured

    @Test("Not configured when both URL and key are empty")
    func notConfiguredEmpty() {
        let service = SyncService()
        // Clear any existing config
        UserDefaults.standard.removeObject(forKey: "syncServerURL")
        UserDefaults.standard.removeObject(forKey: "syncApiKey")

        #expect(service.isConfigured == false)
    }

    @Test("Not configured when URL is set but key is empty")
    func notConfiguredNoKey() {
        let service = SyncService()
        UserDefaults.standard.set("http://example.com", forKey: "syncServerURL")
        UserDefaults.standard.removeObject(forKey: "syncApiKey")
        defer {
            UserDefaults.standard.removeObject(forKey: "syncServerURL")
        }

        #expect(service.isConfigured == false)
    }

    @Test("Not configured when key is set but URL is empty")
    func notConfiguredNoURL() {
        let service = SyncService()
        UserDefaults.standard.removeObject(forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")
        defer {
            UserDefaults.standard.removeObject(forKey: "syncApiKey")
        }

        #expect(service.isConfigured == false)
    }

    @Test("Configured when both URL and key are set")
    func configuredBoth() {
        let service = SyncService()
        UserDefaults.standard.set("http://example.com", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")
        defer {
            UserDefaults.standard.removeObject(forKey: "syncServerURL")
            UserDefaults.standard.removeObject(forKey: "syncApiKey")
        }

        #expect(service.isConfigured == true)
    }

    @Test("Not configured when URL is whitespace only")
    func notConfiguredWhitespaceURL() {
        let service = SyncService()
        UserDefaults.standard.set("   ", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")
        defer {
            UserDefaults.standard.removeObject(forKey: "syncServerURL")
            UserDefaults.standard.removeObject(forKey: "syncApiKey")
        }

        #expect(service.isConfigured == false)
    }

    // MARK: - lastSyncDate persistence

    @Test("lastSyncDate round-trips through UserDefaults")
    func lastSyncDateRoundTrip() {
        let service = SyncService()
        let date = Date(timeIntervalSince1970: 1_711_300_000)
        service.lastSyncDate = date
        defer { UserDefaults.standard.removeObject(forKey: "lastSyncDate") }

        #expect(service.lastSyncDate?.timeIntervalSince1970 == 1_711_300_000)
    }

    @Test("lastSyncDate is nil when not set")
    func lastSyncDateNilByDefault() {
        let service = SyncService()
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        #expect(service.lastSyncDate == nil)
    }

    @Test("lastSyncDate can be cleared")
    func lastSyncDateClear() {
        let service = SyncService()
        service.lastSyncDate = .now
        service.lastSyncDate = nil

        #expect(service.lastSyncDate == nil)
    }

    // MARK: - SyncError descriptions

    @Test("SyncError.notConfigured has description")
    func errorNotConfigured() {
        let error = SyncService.SyncError.notConfigured
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("SyncError.invalidURL has description")
    func errorInvalidURL() {
        let error = SyncService.SyncError.invalidURL
        #expect(error.errorDescription?.isEmpty == false)
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
        let error = SyncService.SyncError.noConnection
        #expect(error.errorDescription?.isEmpty == false)
    }

    // MARK: - Sync guards

    @Test("Sync sets 'Not configured' when not configured")
    func syncNotConfigured() async {
        let service = SyncService()
        UserDefaults.standard.removeObject(forKey: "syncServerURL")
        UserDefaults.standard.removeObject(forKey: "syncApiKey")

        let container = try! makeContainer()
        let context = ModelContext(container)
        await service.sync(modelContext: context)

        #expect(service.lastSyncResult == "Not configured")
    }
}
