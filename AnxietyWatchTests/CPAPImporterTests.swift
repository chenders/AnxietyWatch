import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct CPAPImporterTests {

    private func writeTempCSV(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Valid data

    @Test("Imports valid CSV with multiple sessions")
    func importValidCSV() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-20,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        2026-03-21,1.8,390,15.1,6.0,11.5,9.2,2,0,1
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let count = try CPAPImporter.importCSV(from: url, into: context)
        #expect(count == 2)

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>(sortBy: [SortDescriptor(\.date)]))
        #expect(sessions.count == 2)
        #expect(sessions[0].ahi == 2.5)
        #expect(sessions[0].totalUsageMinutes == 420)
        #expect(sessions[1].leakRate95th == 15.1)
        #expect(sessions[1].importSource == "csv")
    }

    @Test("Parses all 10 fields correctly")
    func allFieldsParsed() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-22,3.1,480,20.0,5.5,13.0,10.0,4,2,3
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        _ = try CPAPImporter.importCSV(from: url, into: context)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        #expect(session.ahi == 3.1)
        #expect(session.totalUsageMinutes == 480)
        #expect(session.leakRate95th == 20.0)
        #expect(session.pressureMin == 5.5)
        #expect(session.pressureMax == 13.0)
        #expect(session.pressureMean == 10.0)
        #expect(session.obstructiveEvents == 4)
        #expect(session.centralEvents == 2)
        #expect(session.hypopneaEvents == 3)
    }

    // MARK: - Error cases

    @Test("Throws noData for header-only CSV")
    func headerOnly() throws {
        let csv = "date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea\n"
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        #expect(throws: CPAPImporter.ImportError.noData) {
            try CPAPImporter.importCSV(from: url, into: context)
        }
    }

    @Test("Throws noData for empty file")
    func emptyFile() throws {
        let url = try writeTempCSV("")
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        #expect(throws: CPAPImporter.ImportError.noData) {
            try CPAPImporter.importCSV(from: url, into: context)
        }
    }

    @Test("Skips rows with fewer than 10 fields")
    func skipsMalformedRows() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-20,2.5,420
        2026-03-21,1.8,390,15.1,6.0,11.5,9.2,2,0,1
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let count = try CPAPImporter.importCSV(from: url, into: context)
        #expect(count == 1)
    }

    @Test("Skips rows with unparseable values")
    func skipsUnparseableValues() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        bad-date,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        2026-03-21,1.8,390,15.1,6.0,11.5,9.2,2,0,1
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let count = try CPAPImporter.importCSV(from: url, into: context)
        #expect(count == 1)
    }

    @Test("Handles whitespace in fields")
    func handlesWhitespace() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
         2026-03-20 , 2.5 , 420 , 18.3 , 6.0 , 12.0 , 9.5 , 3 , 1 , 2
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let count = try CPAPImporter.importCSV(from: url, into: context)
        #expect(count == 1)
    }

    // MARK: - OSCAR format

    @Test("Imports OSCAR Summary CSV format")
    func importOSCARFormat() throws {
        let csv = """
        Date,Session Count,Start,End,Total Time,AHI,CA Count,A Count,OA Count,H Count,UA Count,VS Count,VS2 Count,RE Count,FL Count,SA Count,NR Count,EP Count,LF Count,UF1 Count,UF2 Count,PP Count,Median Pressure,Median Pressure Set,Median IPAP,Median IPAP Set,Median EPAP,Median EPAP Set,Median Flow Limit.,95% Pressure,95% Pressure Set,95% IPAP,95% IPAP Set,95% EPAP,95% EPAP Set,95% Flow Limit.,99.5% Pressure,99.5% Pressure Set,99.5% IPAP,99.5% IPAP Set,99.5% EPAP,99.5% EPAP Set,99.5% Flow Limit.
        2007-12-31,4,2008-01-01T01:16:28,2008-01-01T10:28:09,09:04:59,4.073,15,0,22,0,0,0,0,0,0,0,0,0,0,0,0,0,11.52,0,0,0,11.52,0,0,13.86,0,0,0,13.86,0,0.08,16.66,0,0,0,16.66,0,0.2
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let count = try CPAPImporter.importCSV(from: url, into: context)
        #expect(count == 1)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        #expect(session.ahi == 4.073)
        #expect(session.totalUsageMinutes == 544) // 9*60 + 4 = 544 (truncated seconds)
        #expect(session.leakRate95th == nil)
        #expect(session.obstructiveEvents == 22)
        #expect(session.centralEvents == 15)
        #expect(session.hypopneaEvents == 0)
        #expect(session.pressureMean == 11.52)
        #expect(session.pressureMax == 16.66)
        #expect(session.importSource == "oscar")
    }

    @Test("Auto-detects simple format vs OSCAR format")
    func autoDetectsFormat() throws {
        let simpleCSV = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-20,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        """
        let url1 = try writeTempCSV(simpleCSV)
        defer { try? FileManager.default.removeItem(at: url1) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let count = try CPAPImporter.importCSV(from: url1, into: context)
        #expect(count == 1)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        #expect(session.importSource == "csv")
        #expect(session.leakRate95th == 18.3)
    }

    @Test("Parses OSCAR Total Time HH:MM:SS correctly")
    func parsesOSCARTotalTime() throws {
        let csv = """
        Date,Session Count,Start,End,Total Time,AHI,CA Count,A Count,OA Count,H Count,UA Count,VS Count,VS2 Count,RE Count,FL Count,SA Count,NR Count,EP Count,LF Count,UF1 Count,UF2 Count,PP Count,Median Pressure,Median Pressure Set,Median IPAP,Median IPAP Set,Median EPAP,Median EPAP Set,Median Flow Limit.,95% Pressure,95% Pressure Set,95% IPAP,95% IPAP Set,95% EPAP,95% EPAP Set,95% Flow Limit.,99.5% Pressure,99.5% Pressure Set,99.5% IPAP,99.5% IPAP Set,99.5% EPAP,99.5% EPAP Set,99.5% Flow Limit.
        2008-01-15,1,2008-01-15T22:00:00,2008-01-16T05:30:00,07:30:00,1.5,2,0,5,3,0,0,0,0,0,0,0,0,0,0,0,0,10.0,0,0,0,10.0,0,0,12.0,0,0,0,12.0,0,0,14.0,0,0,0,14.0,0,0
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        _ = try CPAPImporter.importCSV(from: url, into: context)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        #expect(session.totalUsageMinutes == 450) // 7*60 + 30
    }

    @Test("Rejects unrecognized CSV format")
    func rejectsUnknownFormat() throws {
        let csv = """
        foo,bar,baz
        1,2,3
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        #expect(throws: CPAPImporter.ImportError.invalidFormat) {
            try CPAPImporter.importCSV(from: url, into: context)
        }
    }
}
