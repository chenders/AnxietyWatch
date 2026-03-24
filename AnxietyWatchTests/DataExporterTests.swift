import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct DataExporterTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: AnxietyEntry.self, MedicationDefinition.self, MedicationDose.self,
            CPAPSession.self, HealthSnapshot.self, BarometricReading.self,
            ClinicalLabResult.self,
            configurations: config
        )
    }

    private func seedData(into context: ModelContext) {
        let entry = AnxietyEntry(
            timestamp: Date(timeIntervalSince1970: 1_711_300_000),
            severity: 7
        )
        entry.notes = "Stressful day"
        entry.tags = ["work", "sleep"]
        context.insert(entry)

        let snapshot = HealthSnapshot(date: Date(timeIntervalSince1970: 1_711_300_000))
        snapshot.hrvAvg = 42.0
        snapshot.restingHR = 62.0
        snapshot.steps = 8500
        context.insert(snapshot)

        let session = CPAPSession(
            date: Date(timeIntervalSince1970: 1_711_300_000),
            ahi: 2.1, totalUsageMinutes: 420, leakRate95th: 15.0,
            pressureMin: 6.0, pressureMax: 12.0, pressureMean: 9.5,
            obstructiveEvents: 3, centralEvents: 1, hypopneaEvents: 2,
            importSource: "csv"
        )
        context.insert(session)

        let reading = BarometricReading(
            pressureKPa: 101.3, relativeAltitudeM: 0.5
        )
        context.insert(reading)
    }

    // MARK: - JSON Export

    @Test("JSON export produces valid JSON with all entity types")
    func jsonExportValid() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        seedData(into: context)
        try context.save()

        let data = try DataExporter.exportJSON(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["exportDate"] != nil)
        #expect((json["anxietyEntries"] as? [Any])?.count == 1)
        #expect((json["healthSnapshots"] as? [Any])?.count == 1)
        #expect((json["cpapSessions"] as? [Any])?.count == 1)
        #expect((json["barometricReadings"] as? [Any])?.count == 1)
    }

    @Test("JSON export with empty database returns empty arrays")
    func jsonExportEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let data = try DataExporter.exportJSON(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect((json["anxietyEntries"] as? [Any])?.isEmpty == true)
        #expect((json["healthSnapshots"] as? [Any])?.isEmpty == true)
    }

    @Test("JSON export encodes anxiety entry fields correctly")
    func jsonAnxietyFields() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        seedData(into: context)
        try context.save()

        let data = try DataExporter.exportJSON(from: context)
        let bundle = try JSONDecoder().decode(DataExporter.ExportBundle.self, from: data)

        let entry = bundle.anxietyEntries.first!
        #expect(entry.severity == 7)
        #expect(entry.notes == "Stressful day")
        #expect(entry.tags == ["work", "sleep"])
    }

    // MARK: - CSV Export

    @Test("CSV export produces files for all entity types")
    func csvExportAllFiles() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        seedData(into: context)
        try context.save()

        let files = try DataExporter.exportCSV(from: context)
        let filenames = files.map(\.0)

        #expect(filenames.contains("anxiety_entries.csv"))
        #expect(filenames.contains("health_snapshots.csv"))
        #expect(filenames.contains("cpap_sessions.csv"))
        #expect(filenames.contains("barometric_readings.csv"))
        #expect(filenames.contains("clinical_lab_results.csv"))
        #expect(filenames.contains("medication_definitions.csv"))
        #expect(filenames.contains("medication_doses.csv"))
    }

    @Test("CSV files have header rows")
    func csvHeaders() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let files = try DataExporter.exportCSV(from: context)

        for (filename, data) in files {
            let csv = String(data: data, encoding: .utf8)!
            let firstLine = csv.components(separatedBy: "\n").first!
            #expect(firstLine.contains(","), "Header missing in \(filename)")
        }
    }

    @Test("CSV anxiety entries contain data row")
    func csvAnxietyData() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        seedData(into: context)
        try context.save()

        let files = try DataExporter.exportCSV(from: context)
        let anxietyCSV = files.first(where: { $0.0 == "anxiety_entries.csv" })!.1
        let csv = String(data: anxietyCSV, encoding: .utf8)!
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Header + 1 data row
        #expect(lines.count == 2)
        #expect(lines[1].contains("7"))
        #expect(lines[1].contains("Stressful day"))
    }

    // MARK: - Date range filtering

    @Test("Date range filters entries correctly")
    func dateRangeFiltering() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Insert entries at different times
        let oldEntry = AnxietyEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            severity: 3
        )
        let newEntry = AnxietyEntry(
            timestamp: Date(timeIntervalSince1970: 1_711_300_000),
            severity: 7
        )
        context.insert(oldEntry)
        context.insert(newEntry)
        try context.save()

        let cutoff = Date(timeIntervalSince1970: 1_710_000_000)
        let data = try DataExporter.exportJSON(from: context, start: cutoff)
        let bundle = try JSONDecoder().decode(DataExporter.ExportBundle.self, from: data)

        #expect(bundle.anxietyEntries.count == 1)
        #expect(bundle.anxietyEntries.first?.severity == 7)
    }
}
