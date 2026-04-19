import SwiftData
@testable import AnxietyWatch

/// Shared test infrastructure. All test files should use these helpers
/// instead of defining their own `makeContainer()`.
enum TestHelpers {
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
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
