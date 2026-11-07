import Foundation
import SwiftData

// MARK: - Schema Version 1 (historical, migration-only)

/// Historical schema version. Contains the retired CNS models
/// (`MonitoringSession` and `CNSRiskSampleRecord`) that existed before
/// `remove-cns-klaxon`. These migration-only types preserve the exact
/// persisted shape so SwiftData can perform a lightweight migration.
enum AnxietyWatchSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            AnxietyEntry.self,
            MedicationDefinition.self,
            MedicationDose.self,
            CPAPSession.self,
            BarometricReading.self,
            HealthSnapshot.self,
            ClinicalLabResult.self,
            Pharmacy.self,
            Prescription.self,
            PharmacyCallLog.self,
            HealthSample.self,
            PhysiologicalCorrelation.self,
            Song.self,
            SongOccurrence.self,
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
            QuantityHealthSample.self,
            SleepStageEvent.self,
            // Retired CNS models (migration-only):
            LegacyMonitoringSession.self,
            LegacyCNSRiskSampleRecord.self,
        ]
    }

    // MARK: - Migration-only models (exact historical shapes)

    /// Historical `MonitoringSession` model for migration purposes only.
    /// Preserves the exact persisted shape at commit `dba3049607`.
    /// Must use `originalName` because SwiftData matches by entity name.
    @Model
    final class LegacyMonitoringSession {
        static let schemaName = "MonitoringSession"

        var id: UUID
        var startedAt: Date
        var endedAt: Date?
        var activationTriggers: [String]
        var companionPresent: Bool
        var companionLogData: Data?
        var endReason: String?
        var peakTier: Int
        @Relationship(deleteRule: .cascade, inverse: \LegacyCNSRiskSampleRecord.session)
        var samples: [LegacyCNSRiskSampleRecord]?

        init(
            id: UUID = UUID(),
            startedAt: Date,
            endedAt: Date? = nil,
            activationTriggers: [String],
            companionPresent: Bool,
            companionLogData: Data? = nil,
            endReason: String? = nil,
            peakTier: Int = 0
        ) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.activationTriggers = activationTriggers
            self.companionPresent = companionPresent
            self.companionLogData = companionLogData
            self.endReason = endReason
            self.peakTier = peakTier
            self.samples = nil
        }
    }

    /// Historical `CNSRiskSampleRecord` model for migration purposes only.
    /// Preserves the exact persisted shape at commit `dba3049607`.
    @Model
    final class LegacyCNSRiskSampleRecord {
        static let schemaName = "CNSRiskSampleRecord"

        var id: UUID
        var timestamp: Date
        var riskScore: Double?
        var tier: Int
        var canAssess: Bool
        var assessmentReason: String?
        var contributionsData: Data?
        var session: LegacyMonitoringSession?

        init(
            timestamp: Date,
            riskScore: Double? = nil,
            tier: Int,
            canAssess: Bool,
            assessmentReason: String? = nil,
            contributionsData: Data? = nil,
            session: LegacyMonitoringSession? = nil
        ) {
            self.id = UUID()
            self.timestamp = timestamp
            self.riskScore = riskScore
            self.tier = tier
            self.canAssess = canAssess
            self.assessmentReason = assessmentReason
            self.contributionsData = contributionsData
            self.session = session
        }
    }
}

// MARK: - Schema Version 2 (current)

/// Current schema version after `remove-cns-klaxon`. The retired CNS models
/// (`MonitoringSession` and `CNSRiskSampleRecord`) are removed.
enum AnxietyWatchSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            AnxietyEntry.self,
            MedicationDefinition.self,
            MedicationDose.self,
            CPAPSession.self,
            BarometricReading.self,
            HealthSnapshot.self,
            ClinicalLabResult.self,
            Pharmacy.self,
            Prescription.self,
            PharmacyCallLog.self,
            HealthSample.self,
            PhysiologicalCorrelation.self,
            Song.self,
            SongOccurrence.self,
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
            QuantityHealthSample.self,
            SleepStageEvent.self,
        ]
    }
}

// MARK: - Migration Plan

/// Migration plan that upgrades V1 stores (with CNS models) to V2 (without).
/// Uses lightweight migration: SwiftData automatically drops the retired
/// tables when the new schema no longer references them.
enum AnxietyWatchMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AnxietyWatchSchemaV1.self, AnxietyWatchSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Lightweight migration from V1 to V2. No custom data transformation
    /// needed — the retired CNS entities are simply dropped.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: AnxietyWatchSchemaV1.self,
        toVersion: AnxietyWatchSchemaV2.self
    )
}

// MARK: - Container Factory

/// Production container factory. Both the app and migration tests use this
/// to ensure identical migration behavior.
enum AnxietyWatchContainerFactory {
    /// Creates a model container with versioned schema and migration plan.
    /// - Parameter storeURL: The SQLite store location (omit for in-memory).
    /// - Returns: A configured `ModelContainer` that can migrate V1 stores.
    static func makeContainer(storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: AnxietyWatchSchemaV2.self)
        let config: ModelConfiguration
        if let storeURL {
            config = ModelConfiguration(schema: schema, url: storeURL)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: AnxietyWatchMigrationPlan.self,
            configurations: [config]
        )
    }
}
