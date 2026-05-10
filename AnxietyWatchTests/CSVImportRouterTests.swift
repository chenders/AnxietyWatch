import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct CSVImportRouterTests {

    private func writeTempCSV(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Routes EMAY header to EMAY importer")
    func routesEMAY() throws {
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,4:46:58 PM,98,52
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CSVImportRouter.importCSV(from: url, into: context)
        #expect(result.kind == .emay)
        #expect(result.inserted == 2) // SpO2 + HR
        #expect(result.updated == 0)
    }

    @Test("Routes simple CPAP header to CPAP importer")
    func routesCPAPSimple() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-20,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CSVImportRouter.importCSV(from: url, into: context)
        #expect(result.kind == .cpap)
        #expect(result.inserted == 1)
    }

    @Test("Routes OSCAR Summary header to CPAP importer")
    func routesCPAPOSCAR() throws {
        let csv = """
        Date,Session Count,Start,End,Total Time,AHI,CA Count,A Count,OA Count,H Count,UA Count,VS Count,VS2 Count,RE Count,FL Count,SA Count,NR Count,EP Count,LF Count,UF1 Count,UF2 Count,PP Count,Median Pressure,Median Pressure Set,Median IPAP,Median IPAP Set,Median EPAP,Median EPAP Set,Median Flow Limit.,95% Pressure,95% Pressure Set,95% IPAP,95% IPAP Set,95% EPAP,95% EPAP Set,95% Flow Limit.,99.5% Pressure,99.5% Pressure Set,99.5% IPAP,99.5% IPAP Set,99.5% EPAP,99.5% EPAP Set,99.5% Flow Limit.
        2026-03-20,1,2026-03-20T00:00:00,2026-03-20T07:00:00,07:00:00,2.5,1,0,3,2,0,0,0,0,0,0,0,0,0,0,0,0,9.5,0,0,0,9.5,0,0,11.0,0,0,0,11.0,0,0,12.0,0,0,0,12.0,0,0
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CSVImportRouter.importCSV(from: url, into: context)
        #expect(result.kind == .cpap)
        #expect(result.inserted == 1)
    }

    @Test("Throws unrecognizedFormat for unknown header")
    func unknownFormat() throws {
        let csv = """
        foo,bar,baz
        1,2,3
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        do {
            _ = try CSVImportRouter.importCSV(from: url, into: context)
            Issue.record("Expected unrecognizedFormat throw")
        } catch CSVImportRouter.ImportError.unrecognizedFormat {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Skip diagnostics flow through router result")
    func skipDiagnosticsPropagate() throws {
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        bad-date,4:46:58 PM,98,52
        5/8/2026,4:46:59 PM,97,53
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CSVImportRouter.importCSV(from: url, into: context)
        #expect(result.kind == .emay)
        #expect(result.inserted == 2)
        #expect(result.skippedRowCount == 1)
        try #require(result.warnings.count == 1)
        #expect(result.warnings[0].contains("Row 2"))
    }

    @Test("EMAY sniff requires the full header shape, not just the date,time,spo2 prefix")
    func rejectsEMAYLookalikes() throws {
        // Different oximeter that happens to start with date,time,spo2 but
        // uses HR(bpm) instead of EMAY's PR(bpm). Should NOT be routed to
        // EMAYImporter — it should fall through to unrecognizedFormat.
        let csv = """
        Date,Time,SpO2(%),HR(bpm)
        5/8/2026,4:46:58 PM,98,52
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        do {
            _ = try CSVImportRouter.importCSV(from: url, into: context)
            Issue.record("Expected unrecognizedFormat throw")
        } catch CSVImportRouter.ImportError.unrecognizedFormat {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Header detection ignores BOM and case")
    func headerNormalization() throws {
        // BOM + uppercase should still match EMAY.
        let csv = "\u{feff}DATE,TIME,SPO2(%),PR(BPM)\n5/8/2026,4:46:58 PM,98,52\n"
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CSVImportRouter.importCSV(from: url, into: context)
        #expect(result.kind == .emay)
    }
}
