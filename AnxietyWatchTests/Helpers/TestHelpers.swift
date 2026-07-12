import Foundation
import SwiftData
@testable import AnxietyWatch

/// Shared test infrastructure. All test files should use these helpers
/// instead of defining their own `makeContainer()`.
enum TestHelpers {
    /// An isolated `UserDefaults` suite with `RestoreMigrationGate` already
    /// resolved — i.e. the normal steady state of any real install that has
    /// finished its restore-vs-fresh decision.
    ///
    /// `SnapshotAggregator.aggregateDay` refuses to write while that decision is
    /// pending (a snapshot row makes the store non-empty and permanently blocks
    /// the restore the gate exists to enable). Aggregator tests are testing
    /// aggregation, not the gate, so they must opt into the resolved state — the
    /// default `.standard` suite has the key unset and every write would no-op.
    ///
    /// Each caller gets its own suite name so state can't leak between tests, or
    /// — because the simulator persists `.standard` across runs — between runs.
    /// The gate test that needs the *unresolved* state uses `gateUnresolvedDefaults`.
    static func gateResolvedDefaults(suite: String = #function) -> UserDefaults {
        let defaults = gateUnresolvedDefaults(suite: suite)
        RestoreMigrationGate.resolve(defaults: defaults)
        return defaults
    }

    /// A pristine, isolated `UserDefaults` suite — gate NOT resolved.
    /// Models a fresh install sitting on the "Restore or Start Fresh?" prompt.
    static func gateUnresolvedDefaults(suite: String = #function) -> UserDefaults {
        let name = "test.\(suite).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("could not create UserDefaults suite \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Creates an in-memory ModelContainer with the full app schema.
    /// Matches the schema in AnxietyWatchApp.sharedModelContainer exactly.
    /// Using the full schema prevents relationship crashes when tests
    /// touch models that reference other model types.
    static func makeFullContainer() throws -> ModelContainer {
        let schema = Schema([
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
            MonitoringSession.self,
            CNSRiskSampleRecord.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
