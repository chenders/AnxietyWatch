import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct DataExporterTests {

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
        let container = try TestHelpers.makeFullContainer()
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

    @Test("export via a separate context sees data saved through another context on the same container")
    func exportSeesDataSavedByOtherContext() throws {
        // F-056 moved the export onto a fresh background ModelContext(container).
        // That only works because a SAVED write in one context is visible to a
        // second context on the same container — the reason ExportView calls
        // modelContext.save() before spawning the background export. This
        // regression test guards that invariant: seed + save via context A,
        // then export via a brand-new context B.
        let container = try TestHelpers.makeFullContainer()
        let writer = ModelContext(container)
        seedData(into: writer)
        try writer.save()

        let exporter = ModelContext(container) // distinct from `writer`
        let data = try DataExporter.exportJSON(from: exporter)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect((json["anxietyEntries"] as? [Any])?.count == 1)
        #expect((json["healthSnapshots"] as? [Any])?.count == 1)
        #expect((json["cpapSessions"] as? [Any])?.count == 1)
        #expect((json["barometricReadings"] as? [Any])?.count == 1)
    }

    @Test("JSON export with empty database returns empty arrays")
    func jsonExportEmpty() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let data = try DataExporter.exportJSON(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect((json["anxietyEntries"] as? [Any])?.isEmpty == true)
        #expect((json["healthSnapshots"] as? [Any])?.isEmpty == true)
    }

    @Test("JSON export encodes anxiety entry fields correctly")
    func jsonAnxietyFields() throws {
        let container = try TestHelpers.makeFullContainer()
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
        let container = try TestHelpers.makeFullContainer()
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
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let files = try DataExporter.exportCSV(from: context)

        for (filename, data) in files {
            let csv = String(data: data, encoding: .utf8)!
            let firstLine = csv.components(separatedBy: "\n").first!
            #expect(firstLine.contains(","), "Header missing in \(filename)")
        }
    }

    @Test("CSV health snapshot header includes derived clinical stat columns")
    func csvHealthSnapshotDerivedColumns() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let files = try DataExporter.exportCSV(from: context)
        let healthCSV = files.first(where: { $0.0 == "health_snapshots.csv" })!.1
        let header = String(data: healthCSV, encoding: .utf8)!
            .components(separatedBy: "\n").first!

        let expected = [
            "spo2_nadir", "spo2_t90_min", "spo2_desats",
            "glucose_sd", "glucose_cv", "glucose_min", "glucose_max",
        ]
        for col in expected {
            #expect(header.contains(col), "Header missing column: \(col)")
        }
    }

    @Test("CSV health snapshot row encodes derived clinical stat values")
    func csvHealthSnapshotDerivedRow() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let snapshot = HealthSnapshot(date: Date(timeIntervalSince1970: 1_711_300_000))
        snapshot.spo2NadirOvernight = 87.5
        snapshot.spo2TimeBelow90Min = 12
        snapshot.spo2DesatsCount = 4
        snapshot.glucoseStdDev = 22.0
        snapshot.glucoseCV = 18.5
        snapshot.glucoseMin = 80
        snapshot.glucoseMax = 165
        context.insert(snapshot)
        try context.save()

        let files = try DataExporter.exportCSV(from: context)
        let healthCSV = files.first(where: { $0.0 == "health_snapshots.csv" })!.1
        let csv = String(data: healthCSV, encoding: .utf8)!
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)

        // Position-based assertions: parse header and row by column index so
        // dropping or reordering a column fails the test (substring matching
        // would let "4" match almost any row that contains a 4 anywhere).
        let headerCols = lines[0].components(separatedBy: ",")
        let rowCols = lines[1].components(separatedBy: ",")
        #expect(headerCols.count == rowCols.count)
        let valueOf: (String) -> String? = { col in
            headerCols.firstIndex(of: col).map { rowCols[$0] }
        }
        #expect(valueOf("spo2_nadir") == "87.5")
        #expect(valueOf("spo2_t90_min") == "12")
        #expect(valueOf("spo2_desats") == "4")
        #expect(valueOf("glucose_sd") == "22.0")
        #expect(valueOf("glucose_cv") == "18.5")
        #expect(valueOf("glucose_min") == "80.0")
        #expect(valueOf("glucose_max") == "165.0")
    }

    @Test("JSON health snapshot DTO encodes derived clinical stats")
    func jsonHealthSnapshotDerivedFields() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let snapshot = HealthSnapshot(date: Date(timeIntervalSince1970: 1_711_300_000))
        snapshot.spo2NadirOvernight = 87.5
        snapshot.spo2TimeBelow90Min = 12
        snapshot.spo2DesatsCount = 4
        snapshot.glucoseStdDev = 22.0
        snapshot.glucoseCV = 18.5
        snapshot.glucoseMin = 80
        snapshot.glucoseMax = 165
        context.insert(snapshot)
        try context.save()

        let data = try DataExporter.exportJSON(from: context)
        let bundle = try JSONDecoder().decode(DataExporter.ExportBundle.self, from: data)
        let dto = bundle.healthSnapshots.first!
        #expect(dto.spo2NadirOvernight == 87.5)
        #expect(dto.spo2TimeBelow90Min == 12)
        #expect(dto.spo2DesatsCount == 4)
        #expect(dto.glucoseStdDev == 22.0)
        #expect(dto.glucoseCV == 18.5)
        #expect(dto.glucoseMin == 80)
        #expect(dto.glucoseMax == 165)
    }

    @Test("CSV anxiety entries contain data row")
    func csvAnxietyData() throws {
        let container = try TestHelpers.makeFullContainer()
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
        let container = try TestHelpers.makeFullContainer()
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

    // The `end` bound is EXCLUSIVE (half-open range) — a record dated exactly
    // on the end instant belongs to the next window, not this one. This is
    // what keeps a whole-day export (end = start-of-next-day) from pulling in
    // the next day's day-keyed snapshot/CPAP rows (F-044 follow-up).
    @Test("Export end bound is exclusive")
    func endBoundExclusive() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let boundary = Date(timeIntervalSince1970: 1_711_300_000)
        let before = AnxietyEntry(timestamp: boundary.addingTimeInterval(-1), severity: 4)
        let atBoundary = AnxietyEntry(timestamp: boundary, severity: 8)
        context.insert(before)
        context.insert(atBoundary)
        try context.save()

        let data = try DataExporter.exportJSON(from: context, end: boundary)
        let bundle = try JSONDecoder().decode(DataExporter.ExportBundle.self, from: data)

        // Only the strictly-before record is in-range; the one AT the end
        // instant is excluded.
        #expect(bundle.anxietyEntries.count == 1)
        #expect(bundle.anxietyEntries.first?.severity == 4)
    }

    @Test("JSON export includes song and song occurrence data")
    func jsonExportIncludesSongs() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let song = ModelFactory.song(title: "Everybody Hurts", artist: "R.E.M.")
        song.serverId = 1
        song.geniusId = 4535
        context.insert(song)

        let entry = ModelFactory.anxietyEntry(severity: 7)
        context.insert(entry)

        let occ = ModelFactory.songOccurrence(source: "journal")
        occ.song = song
        occ.anxietyEntry = entry
        context.insert(occ)
        try context.save()

        let data = try DataExporter.exportJSON(from: context)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let songs = json["songs"] as? [Any]
        #expect(songs?.count == 1)

        let occurrences = json["songOccurrences"] as? [Any]
        #expect(occurrences?.count == 1)
    }
}
