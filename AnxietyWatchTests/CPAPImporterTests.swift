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

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 2)
        #expect(result.updated == 0)
        #expect(result.total == 2)

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

    @Test("ImportResult includes skippedRowCount and warnings fields")
    func importResultDefaults() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-20,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.skippedRowCount == 0)
        #expect(result.warnings.isEmpty)
    }

    // MARK: - Error cases

    @Test("Throws noData for header-only CSV")
    func headerOnly() throws {
        let csv = "date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea\n"
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        #expect(throws: CPAPImporter.ImportError.self) {
            try CPAPImporter.importCSV(from: url, into: context)
        }
        do {
            _ = try CPAPImporter.importCSV(from: url, into: context)
            Issue.record("Expected noData throw")
        } catch CPAPImporter.ImportError.noData(let skipped, let warnings) {
            #expect(skipped == 0)
            #expect(warnings.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Throws noData for empty file")
    func emptyFile() throws {
        let url = try writeTempCSV("")
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        #expect(throws: CPAPImporter.ImportError.self) {
            try CPAPImporter.importCSV(from: url, into: context)
        }
        do {
            _ = try CPAPImporter.importCSV(from: url, into: context)
            Issue.record("Expected noData throw")
        } catch CPAPImporter.ImportError.noData(let skipped, let warnings) {
            #expect(skipped == 0)
            #expect(warnings.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
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

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 1)
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

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 1)
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

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 1)
    }

    // MARK: - OSCAR format

    @Test("Imports OSCAR Summary CSV format")
    func importOSCARFormat() throws {
        // swiftlint:disable line_length
        // Real OSCAR Summary CSVs have 40+ columns; the test fixture
        // must replicate the exact header/row layout to exercise the
        // importer's column-mapping code, so wrapping these lines
        // would change the input semantics.
        let csv = """
        Date,Session Count,Start,End,Total Time,AHI,CA Count,A Count,OA Count,H Count,UA Count,VS Count,VS2 Count,RE Count,FL Count,SA Count,NR Count,EP Count,LF Count,UF1 Count,UF2 Count,PP Count,Median Pressure,Median Pressure Set,Median IPAP,Median IPAP Set,Median EPAP,Median EPAP Set,Median Flow Limit.,95% Pressure,95% Pressure Set,95% IPAP,95% IPAP Set,95% EPAP,95% EPAP Set,95% Flow Limit.,99.5% Pressure,99.5% Pressure Set,99.5% IPAP,99.5% IPAP Set,99.5% EPAP,99.5% EPAP Set,99.5% Flow Limit.
        2007-12-31,4,2008-01-01T01:16:28,2008-01-01T10:28:09,09:04:59,4.073,15,0,22,0,0,0,0,0,0,0,0,0,0,0,0,0,11.52,0,0,0,11.52,0,0,13.86,0,0,0,13.86,0,0.08,16.66,0,0,0,16.66,0,0.2
        """
        // swiftlint:enable line_length
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 1)
        #expect(result.updated == 0)
        // The 2007-12-31 fixture date predates earliestPlausibleDate — this
        // doubles as OSCAR-path coverage for clock-reset detection.
        #expect(result.suspiciousDateCount == 1)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        #expect(session.ahi == 4.073)
        #expect(session.totalUsageMinutes == 544) // 9*60 + 4 = 544 (truncated seconds)
        #expect(session.leakRate95th == nil)
        #expect(session.obstructiveEvents == 22)
        #expect(session.centralEvents == 15)
        #expect(session.hypopneaEvents == 0)
        #expect(session.pressureMean == 11.52)
        #expect(session.pressureMax == 16.66)
        // OSCAR exports have no minimum-pressure column — the importer must
        // store the "unavailable" sentinel, not repurpose the median.
        #expect(session.pressureMin == CPAPImporter.oscarPressureMinUnavailable)
        #expect(session.importSource == "oscar")
    }

    @Test("OSCAR import does not mislabel the median pressure as the minimum")
    func oscarPressureMinIsNotMedian() throws {
        // Regression (F-007): the OSCAR path previously wrote the median
        // pressure into pressureMin, so the UI's "Min" row showed the median.
        // Median = 10.0, 99.5% = 14.0 in this fixture.
        // swiftlint:disable line_length
        let csv = """
        Date,Session Count,Start,End,Total Time,AHI,CA Count,A Count,OA Count,H Count,UA Count,VS Count,VS2 Count,RE Count,FL Count,SA Count,NR Count,EP Count,LF Count,UF1 Count,UF2 Count,PP Count,Median Pressure,Median Pressure Set,Median IPAP,Median IPAP Set,Median EPAP,Median EPAP Set,Median Flow Limit.,95% Pressure,95% Pressure Set,95% IPAP,95% IPAP Set,95% EPAP,95% EPAP Set,95% Flow Limit.,99.5% Pressure,99.5% Pressure Set,99.5% IPAP,99.5% IPAP Set,99.5% EPAP,99.5% EPAP Set,99.5% Flow Limit.
        2026-04-10,1,2026-04-10T22:00:00,2026-04-11T05:30:00,07:30:00,1.5,2,0,5,3,0,0,0,0,0,0,0,0,0,0,0,0,10.0,0,0,0,10.0,0,0,12.0,0,0,0,12.0,0,0,14.0,0,0,0,14.0,0,0
        """
        // swiftlint:enable line_length
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        _ = try CPAPImporter.importCSV(from: url, into: context)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        // Median lands in pressureMean; 99.5th percentile lands in pressureMax.
        #expect(abs(session.pressureMean - 10.0) < 0.001)
        #expect(abs(session.pressureMax - 14.0) < 0.001)
        // pressureMin carries the sentinel and specifically must NOT equal the median.
        #expect(session.pressureMin == CPAPImporter.oscarPressureMinUnavailable)
        #expect(abs(session.pressureMin - session.pressureMean) > 0.001)
    }

    @Test("OSCAR re-import of an existing session overwrites pressureMin with the sentinel")
    func oscarUpdateOverwritesPressureMin() throws {
        // The update path (updateSession) is separate code from the insert path;
        // both must stop writing the median into pressureMin. An OSCAR re-import
        // rewrites the session's data fields (leak already becomes nil), so
        // pressureMin becoming the sentinel is consistent — but provenance is
        // preserved (F-040), so importSource stays with the original creator.
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let existing = CPAPSession(
            date: formatter.date(from: "2026-04-10")!,
            ahi: 2.0, totalUsageMinutes: 400, leakRate95th: 16.0,
            pressureMin: 6.0, pressureMax: 12.0, pressureMean: 9.0,
            obstructiveEvents: 2, centralEvents: 1, hypopneaEvents: 1,
            importSource: "csv"
        )
        context.insert(existing)
        try context.save()

        // swiftlint:disable line_length
        let csv = """
        Date,Session Count,Start,End,Total Time,AHI,CA Count,A Count,OA Count,H Count,UA Count,VS Count,VS2 Count,RE Count,FL Count,SA Count,NR Count,EP Count,LF Count,UF1 Count,UF2 Count,PP Count,Median Pressure,Median Pressure Set,Median IPAP,Median IPAP Set,Median EPAP,Median EPAP Set,Median Flow Limit.,95% Pressure,95% Pressure Set,95% IPAP,95% IPAP Set,95% EPAP,95% EPAP Set,95% Flow Limit.,99.5% Pressure,99.5% Pressure Set,99.5% IPAP,99.5% IPAP Set,99.5% EPAP,99.5% EPAP Set,99.5% Flow Limit.
        2026-04-10,1,2026-04-10T22:00:00,2026-04-11T05:30:00,07:30:00,1.5,2,0,5,3,0,0,0,0,0,0,0,0,0,0,0,0,10.0,0,0,0,10.0,0,0,12.0,0,0,0,12.0,0,0,14.0,0,0,0,14.0,0,0
        """
        // swiftlint:enable line_length
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.updated == 1)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        #expect(session.pressureMin == CPAPImporter.oscarPressureMinUnavailable)
        #expect(abs(session.pressureMean - 10.0) < 0.001)
        #expect(abs(session.pressureMax - 14.0) < 0.001)
        // F-040: re-imports refresh data, never provenance.
        #expect(session.importSource == "csv")
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
        let result = try CPAPImporter.importCSV(from: url1, into: context)
        #expect(result.inserted == 1)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        #expect(session.importSource == "csv")
        #expect(session.leakRate95th == 18.3)
    }

    @Test("Parses OSCAR Total Time HH:MM:SS correctly")
    func parsesOSCARTotalTime() throws {
        // swiftlint:disable line_length
        let csv = """
        Date,Session Count,Start,End,Total Time,AHI,CA Count,A Count,OA Count,H Count,UA Count,VS Count,VS2 Count,RE Count,FL Count,SA Count,NR Count,EP Count,LF Count,UF1 Count,UF2 Count,PP Count,Median Pressure,Median Pressure Set,Median IPAP,Median IPAP Set,Median EPAP,Median EPAP Set,Median Flow Limit.,95% Pressure,95% Pressure Set,95% IPAP,95% IPAP Set,95% EPAP,95% EPAP Set,95% Flow Limit.,99.5% Pressure,99.5% Pressure Set,99.5% IPAP,99.5% IPAP Set,99.5% EPAP,99.5% EPAP Set,99.5% Flow Limit.
        2008-01-15,1,2008-01-15T22:00:00,2008-01-16T05:30:00,07:30:00,1.5,2,0,5,3,0,0,0,0,0,0,0,0,0,0,0,0,10.0,0,0,0,10.0,0,0,12.0,0,0,0,12.0,0,0,14.0,0,0,0,14.0,0,0
        """
        // swiftlint:enable line_length
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        _ = try CPAPImporter.importCSV(from: url, into: context)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        #expect(session.totalUsageMinutes == 450) // 7*60 + 30
    }

    @Test("Imports OSCAR row with fractional event counts (multi-session night)")
    func importOSCARFractionalCounts() throws {
        // OSCAR exports per-session-averaged event counts as decimals when
        // Session Count > 1. Verbatim row from a 4-session night exported by
        // OSCAR (CA=15.0433, OA=16.1067, H=0.433333). The importer must parse
        // these as Double and round to Int rather than skipping the row.
        // swiftlint:disable line_length
        let csv = """
        Date,Session Count,Start,End,Total Time,AHI,CA Count,A Count,OA Count,H Count,UA Count,VS Count,VS2 Count,RE Count,FL Count,SA Count,NR Count,EP Count,LF Count,UF1 Count,UF2 Count,PP Count,Median Pressure,Median Pressure Set,Median IPAP,Median IPAP Set,Median EPAP,Median EPAP Set,Median Flow Limit.,95% Pressure,95% Pressure Set,95% IPAP,95% IPAP Set,95% EPAP,95% EPAP Set,95% Flow Limit.,99.5% Pressure,99.5% Pressure Set,99.5% IPAP,99.5% IPAP Set,99.5% EPAP,99.5% EPAP Set,99.5% Flow Limit.
        2026-05-06,4,2026-05-06T22:52:00,2026-05-07T13:28:00,14:16:00,2.229,15.0433,0,16.1067,0.433333,0,0,0,0,0,0,0,0,0,0,0,0,11.5,0,0,0,11.5,0,0,13.5,0,0,0,13.5,0,0,15.5,0,0,0,15.5,0,0
        """
        // swiftlint:enable line_length
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 1)

        let session = try context.fetch(FetchDescriptor<CPAPSession>()).first!
        #expect(session.centralEvents == 15)      // round(15.0433)
        #expect(session.obstructiveEvents == 16)  // round(16.1067)
        #expect(session.hypopneaEvents == 0)      // round(0.433333)
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

        #expect(throws: CPAPImporter.ImportError.self) {
            try CPAPImporter.importCSV(from: url, into: context)
        }
        do {
            _ = try CPAPImporter.importCSV(from: url, into: context)
            Issue.record("Expected invalidFormat throw")
        } catch CPAPImporter.ImportError.invalidFormat {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Upsert / duplicate detection

    @Test("Updates existing session on duplicate date instead of inserting")
    func upsertOnDuplicate() throws {
        let csv1 = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-20,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        """
        let csv2 = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-20,5.0,420,18.3,6.0,12.0,9.5,3,1,2
        """
        let url1 = try writeTempCSV(csv1)
        defer { try? FileManager.default.removeItem(at: url1) }
        let url2 = try writeTempCSV(csv2)
        defer { try? FileManager.default.removeItem(at: url2) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result1 = try CPAPImporter.importCSV(from: url1, into: context)
        #expect(result1.inserted == 1)
        #expect(result1.updated == 0)

        let result2 = try CPAPImporter.importCSV(from: url2, into: context)
        #expect(result2.inserted == 0)
        #expect(result2.updated == 1)

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>())
        #expect(sessions.count == 1)
        #expect(sessions[0].ahi == 5.0)
    }

    @Test("Date range spans all imported dates")
    func dateRangeCorrect() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-18,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        2026-03-20,1.8,390,15.1,6.0,11.5,9.2,2,0,1
        2026-03-22,3.0,450,17.0,6.5,13.0,10.0,5,2,3
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CPAPImporter.importCSV(from: url, into: context)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let expectedMin = Calendar.current.startOfDay(for: formatter.date(from: "2026-03-18")!)
        let expectedMax = Calendar.current.startOfDay(for: formatter.date(from: "2026-03-22")!)

        #expect(result.dateRange != nil)
        #expect(result.dateRange?.lowerBound == expectedMin)
        #expect(result.dateRange?.upperBound == expectedMax)
    }

    @Test("Simple format populates skip count and warnings on bad rows")
    func simpleSkipsCarryDiagnostics() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        bad-date,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        2026-03-20,not-a-number,420,18.3,6.0,12.0,9.5,3,1,2
        2026-03-21,1.8,390,15.1,6.0,11.5,9.2,2,0,1
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 1)
        #expect(result.skippedRowCount == 2)
        // try #require fails the test cleanly if the count is wrong; without it,
        // the [0] / [1] subscripts below would trap and crash the test runner.
        try #require(result.warnings.count == 2)
        #expect(result.warnings[0].contains("Row 2"))
        #expect(result.warnings[1].contains("Row 3"))
    }

    @Test("Simple format caps warnings at 5 plus an overflow line")
    func simpleWarningsCappedAtFive() throws {
        var lines = ["date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea"]
        for _ in 0..<10 { lines.append("bad-date,2.5,420,18.3,6.0,12.0,9.5,3,1,2") }
        let url = try writeTempCSV(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        do {
            _ = try CPAPImporter.importCSV(from: url, into: context)
            Issue.record("Expected noData throw")
        } catch CPAPImporter.ImportError.noData(let skipped, let warnings) {
            #expect(skipped == 10)
            #expect(warnings.count == 6) // 5 + "and N more"
            #expect(warnings.last?.contains("5 more") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Suspicious date detection (CPAP clock-reset symptom)

    @Test("Flags sessions dated before earliestPlausibleDate as suspicious")
    func flagsSuspiciousDates() throws {
        // 2009-01-15 mimics an AirSense epoch-reset session; 2026-03-21 is normal.
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2009-01-15,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        2026-03-21,1.8,390,15.1,6.0,11.5,9.2,2,0,1
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 2) // both rows still imported
        #expect(result.suspiciousDateCount == 1)

        // F-028: the clock-reset date must NOT stretch the returned range —
        // callers walk it with one aggregateDay per day, so folding a ~2009
        // epoch-reset row in meant thousands of backfill iterations.
        let range = try #require(result.dateRange)
        #expect(range.lowerBound >= CPAPImporter.earliestPlausibleDate)
    }

    @Test("A file containing ONLY clock-reset dates yields a nil dateRange")
    func allSuspiciousDatesYieldNilRange() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2009-01-15,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 1)
        #expect(result.suspiciousDateCount == 1)
        // No plausible dates → no backfill range at all (callers skip the loop).
        #expect(result.dateRange == nil)
    }

    // F-040: a re-import covering the same date must not relabel a manually-
    // entered (or server-restored) session's provenance as "csv"/"oscar".
    @Test("Re-import preserves an existing session's importSource")
    func reimportPreservesImportSource() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 21
        let day = Calendar(identifier: .gregorian).date(from: comps)!
        let manual = CPAPSession(
            date: day, ahi: 2.0, totalUsageMinutes: 400,
            pressureMin: 6, pressureMax: 12, pressureMean: 9,
            obstructiveEvents: 1, centralEvents: 0, hypopneaEvents: 1,
            importSource: "manual"
        )
        context.insert(manual)
        try context.save()

        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-21,1.8,390,15.1,6.0,11.5,9.2,2,0,1
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.updated == 1)

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>())
        let session = try #require(sessions.first)
        // Data fields refresh; provenance does not.
        #expect(abs(session.ahi - 1.8) < 0.001)
        #expect(session.importSource == "manual")
    }

    @Test("Suspicious count is zero for plausible recent dates")
    func noSuspiciousDatesForRecentImport() throws {
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-20,2.5,420,18.3,6.0,12.0,9.5,3,1,2
        2026-03-21,1.8,390,15.1,6.0,11.5,9.2,2,0,1
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.suspiciousDateCount == 0)
    }

    @Test("Clock-reset warning pluralizes and is nil at zero")
    func clockResetWarningText() {
        #expect(CPAPImporter.clockResetWarning(count: 0) == nil)
        #expect(CPAPImporter.clockResetWarning(count: 1)?.contains("1 session has") == true)
        #expect(CPAPImporter.clockResetWarning(count: 3)?.contains("3 sessions have") == true)
    }

    @Test("Mixed insert and update when pre-existing session overlaps")
    func mixedInsertAndUpdate() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Pre-insert a session for 2026-03-20
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let existing = CPAPSession(
            date: formatter.date(from: "2026-03-20")!,
            ahi: 2.0, totalUsageMinutes: 400, leakRate95th: 16.0,
            pressureMin: 6.0, pressureMax: 12.0, pressureMean: 9.0,
            obstructiveEvents: 2, centralEvents: 1, hypopneaEvents: 1,
            importSource: "csv"
        )
        context.insert(existing)
        try context.save()

        // Import CSV with the same date (2026-03-20) plus a new date (2026-03-21)
        let csv = """
        date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
        2026-03-20,3.5,420,18.3,6.0,12.0,9.5,3,1,2
        2026-03-21,1.8,390,15.1,6.0,11.5,9.2,2,0,1
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try CPAPImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 1)
        #expect(result.updated == 1)
        #expect(result.total == 2)

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>(sortBy: [SortDescriptor(\.date)]))
        #expect(sessions.count == 2)
        // The pre-existing session should have been updated with the new AHI
        #expect(sessions[0].ahi == 3.5)
    }
}
