import SwiftData
import Testing
@testable import AnxietyWatch

struct SampleDataTests {
    @Test("Seeded container has expected data counts")
    func seededContainerPopulated() throws {
        let container = try SampleData.makeSeededContainer()
        let context = ModelContext(container)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.count == 30)

        let entries = try context.fetch(FetchDescriptor<AnxietyEntry>())
        #expect(entries.count == 15)

        let meds = try context.fetch(FetchDescriptor<MedicationDefinition>())
        #expect(meds.count == 1)

        let doses = try context.fetch(FetchDescriptor<MedicationDose>())
        #expect(doses.count == 10)

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>())
        #expect(sessions.count == 5)
    }
}
