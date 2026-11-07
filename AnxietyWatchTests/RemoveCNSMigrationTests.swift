import Foundation
import SwiftData
import Testing
@testable import AnxietyWatch

/// Tests for the V1→V2 schema migration that removes CNS models.
///
/// These tests verify that:
/// 1. A fresh V2 store can be created and used normally.
/// 2. An existing V1 store (with CNS models) migrates successfully.
/// 3. Non-CNS data survives the migration intact.
/// 4. Migration is idempotent (reopen migrated store works).
@Suite("Remove CNS Migration")
struct RemoveCNSMigrationTests {

    // MARK: - Fresh Store Tests

    @Test("Fresh V2 store can be created")
    func freshV2StoreCreation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("fresh.store")
        let container = try AnxietyWatchContainerFactory.makeContainer(storeURL: storeURL)

        // Insert test data
        let context = ModelContext(container)
        let entry = AnxietyEntry(timestamp: Date(), severity: 5, notes: "Test")
        context.insert(entry)
        try context.save()

        // Verify data persists
        let fetched = try context.fetch(FetchDescriptor<AnxietyEntry>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.severity == 5)
    }

    @Test("Fresh V2 store excludes CNS models from schema")
    func freshV2SchemaExcludesCNS() throws {
        let container = try AnxietyWatchContainerFactory.makeContainer(storeURL: nil)

        // The V2 schema should have exactly 20 models (the retained ones)
        let schema = container.schema
        let entityNames = schema.entities.map(\.name)

        // Should NOT contain retired CNS entities
        #expect(!entityNames.contains("MonitoringSession"))
        #expect(!entityNames.contains("CNSRiskSampleRecord"))
        #expect(!entityNames.contains("LegacyMonitoringSession"))
        #expect(!entityNames.contains("LegacyCNSRiskSampleRecord"))

        // Should contain retained entities
        #expect(entityNames.contains("AnxietyEntry"))
        #expect(entityNames.contains("MedicationDefinition"))
        #expect(entityNames.contains("HealthSnapshot"))
        #expect(entityNames.contains("QuantityHealthSample"))
    }

    @Test("In-memory container works for testing")
    func inMemoryContainerWorks() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Insert and verify
        let med = MedicationDefinition(name: "TestMed", defaultDoseMg: 10.0, category: "test")
        context.insert(med)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MedicationDefinition>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "TestMed")

        // Verify inert legacy field is nil
        #expect(fetched.first?.cnsDepressantClass == nil)
    }

    // MARK: - V1 Store Migration Tests

    @Test("V1 store with CNS data migrates successfully")
    func v1StoreMigration() throws {
        // Create a temporary V1 store using the legacy schema
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("v1.store")

        // Step 1: Create a V1 store with the legacy schema
        let v1Schema = Schema(versionedSchema: AnxietyWatchSchemaV1.self)
        let v1Config = ModelConfiguration(schema: v1Schema, url: storeURL)
        let v1Container = try ModelContainer(for: v1Schema, configurations: [v1Config])

        // Insert test data including a legacy CNS session
        let v1Context = ModelContext(v1Container)

        // Insert retained model data
        let entry = AnxietyEntry(timestamp: Date(), severity: 7, notes: "Pre-migration")
        v1Context.insert(entry)

        let med = MedicationDefinition(name: "Aspirin", defaultDoseMg: 325.0, category: "analgesic")
        v1Context.insert(med)

        // Insert legacy CNS data (will be dropped by migration)
        let session = AnxietyWatchSchemaV1.LegacyMonitoringSession(
            startedAt: Date(),
            activationTriggers: ["manual"],
            companionPresent: false,
            peakTier: 2
        )
        v1Context.insert(session)

        let sample = AnxietyWatchSchemaV1.LegacyCNSRiskSampleRecord(
            timestamp: Date(),
            riskScore: 0.75,
            tier: 2,
            canAssess: true,
            session: session
        )
        v1Context.insert(sample)

        try v1Context.save()

        // Verify V1 data was inserted
        let v1Sessions = try v1Context.fetch(
            FetchDescriptor<AnxietyWatchSchemaV1.LegacyMonitoringSession>()
        )
        #expect(v1Sessions.count == 1)

        // Close V1 container (release file handles)
        // Note: Swift doesn't have explicit close, but creating a new container
        // with migration plan will handle the upgrade.

        // Step 2: Open with V2 schema + migration plan
        let v2Container = try AnxietyWatchContainerFactory.makeContainer(storeURL: storeURL)
        let v2Context = ModelContext(v2Container)

        // Verify retained data survived
        let entries = try v2Context.fetch(FetchDescriptor<AnxietyEntry>())
        #expect(entries.count == 1)
        #expect(entries.first?.severity == 7)
        #expect(entries.first?.notes == "Pre-migration")

        let meds = try v2Context.fetch(FetchDescriptor<MedicationDefinition>())
        #expect(meds.count == 1)
        #expect(meds.first?.name == "Aspirin")

        // CNS data should no longer be accessible (tables dropped)
        // We can't directly query dropped entities, but we can verify the
        // schema no longer references them
        let v2EntityNames = v2Container.schema.entities.map(\.name)
        #expect(!v2EntityNames.contains("MonitoringSession"))
        #expect(!v2EntityNames.contains("CNSRiskSampleRecord"))
    }

    @Test("Migrated store can be reopened")
    func migratedStoreIdempotent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("reopen.store")

        // Create and migrate
        let container1 = try AnxietyWatchContainerFactory.makeContainer(storeURL: storeURL)
        let context1 = ModelContext(container1)
        let entry = AnxietyEntry(timestamp: Date(), severity: 3, notes: "Idempotent test")
        context1.insert(entry)
        try context1.save()

        // Reopen (should not fail or corrupt data)
        let container2 = try AnxietyWatchContainerFactory.makeContainer(storeURL: storeURL)
        let context2 = ModelContext(container2)

        let entries = try context2.fetch(FetchDescriptor<AnxietyEntry>())
        #expect(entries.count == 1)
        #expect(entries.first?.severity == 3)
    }

    // MARK: - Medication Legacy Field Tests

    @Test("MedicationDefinition.cnsDepressantClass is inert")
    func medicationLegacyFieldInert() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Create medication - no CNS parameter needed
        let med = MedicationDefinition(
            name: "Ibuprofen",
            defaultDoseMg: 400.0,
            category: "nsaid"
        )
        context.insert(med)
        try context.save()

        // Verify the inert legacy field is nil and unused
        let fetched = try context.fetch(FetchDescriptor<MedicationDefinition>())
        #expect(fetched.first?.cnsDepressantClass == nil)

        // Even if we set it directly, it should persist but is never read
        // by any product code (verified by separate export/restore tests)
        fetched.first?.cnsDepressantClass = "legacy_value"
        try context.save()

        let refetched = try context.fetch(FetchDescriptor<MedicationDefinition>())
        #expect(refetched.first?.cnsDepressantClass == "legacy_value")
    }
}
