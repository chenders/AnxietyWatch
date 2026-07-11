import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for the OSCAR by-session CSV import path: format detection,
/// per-day aggregation math, null-honesty, the >24h clock-integrity
/// quarantine, and the cross-date value-match dedupe.
/// All fixture data is fictional (fictional dates, generic machine name).
struct CPAPBySessionImportTests {

    private static let header =
        "Date,Start,AHI,RDI,OA,UA,H,CA,RERA,Pressure_Avg,Pressure_Min,Pressure_Max,Pressure_95th,"
        + "Leak_Avg,Leak_Max,Leak_95th,SpO2_Avg,SpO2_Min,Pulse_Avg,Hours,Hours_Used,Machine"

    private func writeTempCSV(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func importCSV(_ csv: String, into context: ModelContext) throws -> CPAPImporter.ImportResult {
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }
        return try CPAPImporter.importCSV(from: url, into: context)
    }

    private func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return Calendar.current.startOfDay(for: formatter.date(from: string)!)
    }

    // MARK: - Format detection

    @Test("Detects the by-session header (and the daily headers stay distinct)")
    func detectsBySessionHeader() {
        #expect(CPAPImporter.isOSCARBySessionFormat(Self.header))
        #expect(CPAPImporter.isOSCARBySessionFormat("date,start,ahi,rdi,oa,..."))
        #expect(CPAPImporter.isCPAPFormat(Self.header))
        // Daily OSCAR and simple headers must NOT match by-session.
        #expect(!CPAPImporter.isOSCARBySessionFormat("Date,Session Count,Start,End,Total Time,AHI"))
        #expect(!CPAPImporter.isOSCARBySessionFormat("date,ahi,usage_minutes,leak_95th"))
    }

    // MARK: - Single-session day: field mapping + AHI formula

    @Test("Single-session day maps every field and matches the stated per-session AHI")
    func singleSessionDayMapsAllFields() throws {
        // 2 OA + 1 UA + 3 H + 1 CA = 7 events over 7.0 h used -> AHI 1.0,
        // which is exactly the stated per-session AHI column value.
        let csv = """
        \(Self.header)
        2026-03-20,22:15:00,1.0,1.43,2,1,3,1,3,8.2,5.0,11.4,9.8,2.1,24.0,10.5,94.2,88.0,61.5,7.50,7.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 1)
        #expect(result.updated == 0)
        #expect(result.warnings.isEmpty)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        // Computed daily AHI must agree with OSCAR's stated per-session AHI.
        let ahi = try #require(session.ahi)
        #expect(abs(ahi - 1.0) < 0.001)
        #expect(session.totalUsageMinutes == 420)
        #expect(session.obstructiveEvents == 3)   // OA 2 + UA 1 folds in
        #expect(session.centralEvents == 1)
        #expect(session.hypopneaEvents == 3)
        #expect(session.reraEvents == 3)
        #expect(abs((session.rdiEvents ?? -1) - 1.43) < 0.001)
        #expect(abs(session.pressureMin - 5.0) < 0.001)
        #expect(abs(session.pressureMax - 11.4) < 0.001)
        #expect(abs(session.pressureMean - 8.2) < 0.001)
        #expect(abs((session.pressure95th ?? -1) - 9.8) < 0.001)
        #expect(abs((session.leakAvg ?? -1) - 2.1) < 0.001)
        #expect(abs((session.leakMax ?? -1) - 24.0) < 0.001)
        #expect(abs((session.leakRate95th ?? -1) - 10.5) < 0.001)
        #expect(abs((session.spo2Avg ?? -1) - 94.2) < 0.001)
        #expect(abs((session.spo2Min ?? -1) - 88.0) < 0.001)
        #expect(abs((session.pulseAvg ?? -1) - 61.5) < 0.001)
        #expect(session.importSource == "oscar")
        #expect(session.date == day("2026-03-20"))
    }

    // MARK: - Multi-session aggregation math

    @Test("Two sessions on one sleep-date aggregate with usage weighting")
    func multiSessionAggregation() throws {
        // Both rows carry the same sleep-date (the Date column already applies
        // OSCAR's noon-to-noon convention, so a 04:00 session belongs to the
        // previous night's date).
        // s1: 6.0 h used, 6 events (3 OA, 0 UA, 2 H, 1 CA), RERA 2
        // s2: 2.0 h used, 2 events (1 OA, 1 UA, 0 H, 0 CA), RERA 1
        let grouped = """
        \(Self.header)
        2026-03-21,21:00:00,1.0,2.0,3,0,2,1,2,8.0,5.0,11.0,9.5,2.0,20.0,10.0,94.0,88.0,60.0,6.20,6.0,Test Machine
        2026-03-21,04:00:00,1.0,4.0,1,1,0,0,1,9.0,6.0,12.0,10.5,4.0,30.0,14.0,92.0,90.0,70.0,2.10,2.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try importCSV(grouped, into: context)
        #expect(result.inserted == 1)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        // AHI = total events / total hours = 8 / 8.0 = 1.0
        #expect(abs((session.ahi ?? -1) - 1.0) < 0.001)
        #expect(session.totalUsageMinutes == 480)
        #expect(session.obstructiveEvents == 5)   // (3+0) + (1+1) OA+UA
        #expect(session.centralEvents == 1)
        #expect(session.hypopneaEvents == 2)
        #expect(session.reraEvents == 3)
        // Usage-weighted means, weights 6 h and 2 h:
        #expect(abs((session.rdiEvents ?? -1) - 2.5) < 0.001)          // (2*6+4*2)/8
        #expect(abs(session.pressureMean - 8.25) < 0.001)              // (8*6+9*2)/8
        #expect(abs((session.pressure95th ?? -1) - 9.75) < 0.001)      // (9.5*6+10.5*2)/8
        #expect(abs((session.leakAvg ?? -1) - 2.5) < 0.001)            // (2*6+4*2)/8
        #expect(abs((session.leakRate95th ?? -1) - 11.0) < 0.001)      // (10*6+14*2)/8
        #expect(abs((session.spo2Avg ?? -1) - 93.5) < 0.001)           // (94*6+92*2)/8
        #expect(abs((session.pulseAvg ?? -1) - 62.5) < 0.001)          // (60*6+70*2)/8
        // Min of mins / max of maxes:
        #expect(abs(session.pressureMin - 5.0) < 0.001)
        #expect(abs(session.pressureMax - 12.0) < 0.001)
        #expect(abs((session.leakMax ?? -1) - 30.0) < 0.001)
        #expect(abs((session.spo2Min ?? -1) - 88.0) < 0.001)
    }

    // MARK: - Null-honesty

    @Test("Empty oximeter/RDI/RERA columns stay nil — never 0")
    func emptyColumnsStayNil() throws {
        let csv = """
        \(Self.header)
        2026-03-23,22:00:00,0.5,,2,0,1,0,,9.0,6.0,12.0,10.0,3.0,25.0,12.0,,,,7.10,7.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        _ = try importCSV(csv, into: context)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        #expect(session.spo2Avg == nil)
        #expect(session.spo2Min == nil)
        #expect(session.pulseAvg == nil)
        #expect(session.rdiEvents == nil)
        #expect(session.reraEvents == nil)
        // Fields that WERE reported still come through.
        #expect(session.ahi != nil)
        #expect(abs((session.leakAvg ?? -1) - 3.0) < 0.001)
    }

    @Test("An unscored session's hours don't dilute the day's AHI denominator")
    func unscoredSessionExcludedFromAHIDenominator() throws {
        // s1: 6.0 h used, 6 scored events (3 OA, 0 UA, 2 H, 1 CA).
        // s2: 6.0 h used, NO scored event cells (all empty) — a mask-on/off
        // blip OSCAR didn't score. Its hours must NOT enter the AHI
        // denominator (that would halve the AHI to a fabricated 0.5), but its
        // usage still counts toward total therapy minutes.
        let csv = """
        \(Self.header)
        2026-06-01,21:00:00,1.0,,3,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,6.20,6.0,Test Machine
        2026-06-01,05:00:00,,,,,,,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,6.10,6.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        _ = try importCSV(csv, into: context)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        // AHI = 6 events / 6.0 scored hours = 1.0 (NOT 6 / 12.0 = 0.5).
        #expect(abs((session.ahi ?? -1) - 1.0) < 0.001)
        // Usage still sums both sessions: 12.0 h -> 720 min.
        #expect(session.totalUsageMinutes == 720)
        #expect(session.obstructiveEvents == 3)
        #expect(session.hypopneaEvents == 2)
        #expect(session.centralEvents == 1)
    }

    @Test("A day with no scored event counts gets nil AHI, not 0")
    func unscoredDayHasNilAHI() throws {
        let csv = """
        \(Self.header)
        2026-03-24,22:00:00,,,,,,,,9.0,6.0,12.0,10.0,3.0,25.0,12.0,,,,7.10,7.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        _ = try importCSV(csv, into: context)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        #expect(session.ahi == nil)
        #expect(session.obstructiveEvents == 0)
        #expect(session.centralEvents == 0)
        #expect(session.hypopneaEvents == 0)
    }

    @Test("Weighted means cover only the sessions that report the value")
    func mixedNilValueWeighting() throws {
        // s1 (6 h) reports SpO2 94.0; s2 (2 h) reports none. The average must
        // be 94.0 — weighted over the reporting session only, NOT dragged
        // down by a phantom 0 from the non-reporting one.
        let csv = """
        \(Self.header)
        2026-03-25,21:00:00,1.0,2.0,3,0,2,1,2,8.0,5.0,11.0,9.5,2.0,20.0,10.0,94.0,88.0,60.0,6.20,6.0,Test Machine
        2026-03-25,04:30:00,1.0,2.0,1,1,0,0,1,9.0,6.0,12.0,10.5,4.0,30.0,14.0,,,,2.10,2.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        _ = try importCSV(csv, into: context)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        #expect(abs((session.spo2Avg ?? -1) - 94.0) < 0.001)
        #expect(abs((session.spo2Min ?? -1) - 88.0) < 0.001)
        #expect(abs((session.pulseAvg ?? -1) - 60.0) < 0.001)
    }

    // MARK: - Clock-integrity quarantine

    @Test("A sleep-date with more than 24h of usage is quarantined whole")
    func quarantinesImpossibleDate() throws {
        // 2026-04-01 sums to 25.0 h used (impossible — clock reset compressed
        // several real days onto it); 2026-04-02 sums to 23.9 h (extreme but
        // physically possible) and must import.
        let csv = """
        \(Self.header)
        2026-04-01,20:00:00,1.0,,4,0,3,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,9.10,9.0,Test Machine
        2026-04-01,06:00:00,1.0,,4,0,3,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,9.10,9.0,Test Machine
        2026-04-01,16:00:00,1.0,,4,0,3,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.10,7.0,Test Machine
        2026-04-02,20:00:00,0.5,,2,0,2,0,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,12.10,12.0,Test Machine
        2026-04-02,09:00:00,0.5,,2,0,2,0,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,12.00,11.9,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 1)
        #expect(result.warnings.contains { $0.contains("quarantined 1 impossible date") && $0.contains("2026-04-01") })

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.date == day("2026-04-02"))
        // 23.9 h -> 1434 minutes
        #expect(sessions.first?.totalUsageMinutes == 1434)
    }

    @Test("Exactly 24h of usage is legitimate and imports")
    func exactly24HoursImports() throws {
        let csv = """
        \(Self.header)
        2026-04-03,20:00:00,0.5,,2,0,2,0,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,8.10,8.0,Test Machine
        2026-04-03,05:00:00,0.5,,2,0,2,0,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,8.20,8.1,Test Machine
        2026-04-03,14:00:00,0.5,,2,0,2,0,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,8.00,7.9,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // 8.0 + 8.1 + 7.9 = 24.0 exactly (with float summing noise) — must import.
        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 1)
        #expect(!result.warnings.contains { $0.contains("quarantined") })
    }

    @Test("A file whose only date is quarantined returns inserted:0 with a warning, not noData")
    func allQuarantinedFileDoesNotThrow() throws {
        // One sleep-date summing to 26h (>24 -> impossible). It's the ONLY
        // date, so nothing imports — but that's a clean, warned result, not a
        // garbage/empty file. Must NOT throw noData.
        let csv = """
        \(Self.header)
        2026-07-07,20:00:00,1.0,,4,0,3,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,13.00,13.0,Test Machine
        2026-07-07,10:00:00,1.0,,4,0,3,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,13.00,13.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 0)
        #expect(result.updated == 0)
        #expect(result.total == 0)
        #expect(result.dateRange == nil)
        #expect(result.warnings.contains { $0.contains("quarantined 1 impossible date") && $0.contains("2026-07-07") })
        #expect(try context.fetch(FetchDescriptor<CPAPSession>()).isEmpty)
    }

    // MARK: - Cross-date value dedupe

    @Test("Two same-file dates that aggregate to the same night dedupe against each other")
    func sameFileDuplicateDatesAreDeduped() throws {
        // The regression the frozen-snapshot bug missed: two DIFFERENT dates
        // within ONE file that aggregate to the same physical night (clock
        // reset re-logged the night under two dates) against an EMPTY DB. The
        // second must be recognized as a duplicate of the first inserted this
        // same pass, not both inserted.
        let csv = """
        \(Self.header)
        2026-07-01,22:00:00,1.0,,3,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.00,7.0,Test Machine
        2026-07-02,22:00:00,1.0,,3,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.00,7.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 1)
        #expect(result.warnings.contains {
            $0.contains("already imported under a different date") && $0.contains("2026-07-02")
        })

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>())
        #expect(sessions.count == 1)
        // The earlier date (first seen in the ascending-sorted pass) is kept.
        #expect(sessions.first?.date == day("2026-07-01"))
    }

    @Test("A day whose values match an existing session at another date is skipped")
    func dedupeSkipsValueMatchAtDifferentDate() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        // The same physical night, previously imported under a clock-reset
        // date: AHI within 0.05, usage within 2 min, event counts exact.
        context.insert(CPAPSession(
            date: day("2026-01-15"), ahi: 1.02, totalUsageMinutes: 481,
            leakRate95th: 10.0, pressureMin: 5.0, pressureMax: 12.0, pressureMean: 8.25,
            obstructiveEvents: 5, centralEvents: 1, hypopneaEvents: 2, importSource: "oscar"
        ))
        try context.save()

        // Day 2026-05-10 aggregates to ahi 1.0, usage 480, events 5/1/2 —
        // a value match. Day 2026-05-11 is genuinely new.
        let csv = """
        \(Self.header)
        2026-05-10,21:00:00,1.0,,3,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,6.20,6.0,Test Machine
        2026-05-10,04:00:00,1.0,,1,1,0,0,,9.0,6.0,12.0,10.5,4.0,30.0,14.0,,,,2.10,2.0,Test Machine
        2026-05-11,22:00:00,0.25,,1,0,1,0,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,8.10,8.0,Test Machine
        """
        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 1)
        #expect(result.updated == 0)
        #expect(result.warnings.contains {
            $0.contains("already imported under a different date") && $0.contains("2026-05-10")
        })

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>(sortBy: [SortDescriptor(\.date)]))
        #expect(sessions.count == 2)
        #expect(!sessions.contains { $0.date == day("2026-05-10") })
    }

    @Test("A file whose only day is a cross-date duplicate returns 0 imported without throwing")
    func allDedupedFileDoesNotThrow() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        // The incoming day aggregates to AHI (3+0+2+1)/8.0 h = 0.75 — the
        // existing row must sit within the ±0.05 tolerance of that.
        context.insert(CPAPSession(
            date: day("2026-01-15"), ahi: 0.75, totalUsageMinutes: 480,
            leakRate95th: nil, pressureMin: 5.0, pressureMax: 11.0, pressureMean: 8.0,
            obstructiveEvents: 3, centralEvents: 1, hypopneaEvents: 2, importSource: "oscar"
        ))
        try context.save()

        let csv = """
        \(Self.header)
        2026-05-12,21:00:00,0.75,,3,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,8.10,8.0,Test Machine
        """
        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 0)
        #expect(result.updated == 0)
        #expect(result.warnings.contains { $0.contains("already imported under a different date") })
    }

    @Test("Two different clean nights that share the coarse tuple but differ in pressure do NOT dedupe")
    func differentCleanNightsWithDifferentPressureAreNotDeduped() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        // A prior clean night: AHI 0.0, usage 465, 0/0/0 events, mean pressure 8.0.
        context.insert(CPAPSession(
            date: day("2026-02-01"), ahi: 0.0, totalUsageMinutes: 465,
            leakRate95th: nil, pressureMin: 5.0, pressureMax: 11.0, pressureMean: 8.0,
            obstructiveEvents: 0, centralEvents: 0, hypopneaEvents: 0, importSource: "oscar"
        ))
        try context.save()

        // A DIFFERENT clean night: same coarse tuple (AHI 0.0, usage ~465,
        // 0/0/0 events) but a distinct pressure curve (mean 9.5). Must import,
        // not be mistaken for the prior night and dropped.
        let csv = """
        \(Self.header)
        2026-06-10,22:00:00,0.0,,0,0,0,0,,9.5,7.0,12.0,10.8,2.0,20.0,10.0,,,,7.75,7.75,Test Machine
        """
        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 1)
        #expect(!result.warnings.contains { $0.contains("already imported under a different date") })

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>())
        #expect(sessions.count == 2)
    }

    @Test("Two distinct unscored nights are not collapsed by the dedupe")
    func unscoredNightsAreNotDeduped() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        // A prior unscored night (nil AHI) with similar usage.
        context.insert(CPAPSession(
            date: day("2026-02-02"), ahi: nil, totalUsageMinutes: 466,
            leakRate95th: nil, pressureMin: 5.0, pressureMax: 11.0, pressureMean: 8.0,
            obstructiveEvents: 0, centralEvents: 0, hypopneaEvents: 0, importSource: "oscar"
        ))
        try context.save()

        // A different unscored night (empty event cells -> nil AHI). nil AHI
        // must never dedupe, so this imports.
        let csv = """
        \(Self.header)
        2026-06-11,22:00:00,,,,,,,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.77,7.77,Test Machine
        """
        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 1)
        #expect(!result.warnings.contains { $0.contains("already imported under a different date") })
    }

    @Test("An exact-date match that does NOT value-match updates in place")
    func exactDateUpsertStillUpdates() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        context.insert(CPAPSession(
            date: day("2026-05-13"), ahi: 9.9, totalUsageMinutes: 100,
            leakRate95th: nil, pressureMin: 4.0, pressureMax: 10.0, pressureMean: 7.0,
            obstructiveEvents: 40, centralEvents: 9, hypopneaEvents: 8, importSource: "manual"
        ))
        try context.save()

        let csv = """
        \(Self.header)
        2026-05-13,21:00:00,0.75,1.0,3,0,2,1,2,8.0,5.0,11.0,9.5,2.0,20.0,10.0,94.0,88.0,60.0,8.10,8.0,Test Machine
        """
        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 0)
        #expect(result.updated == 1)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        #expect(abs((session.ahi ?? -1) - 0.75) < 0.001)
        #expect(session.totalUsageMinutes == 480)
        // The by-session fields are written on update too.
        #expect(abs((session.spo2Avg ?? -1) - 94.0) < 0.001)
        #expect(session.reraEvents == 2)
        // Provenance is preserved on update (F-040).
        #expect(session.importSource == "manual")
    }

    // MARK: - Malformed rows

    @Test("A corrupt non-empty cell skips the row instead of coercing to nil")
    func corruptCellSkipsRow() throws {
        let csv = """
        \(Self.header)
        2026-05-14,21:00:00,0.75,,3,0,2,1,,garbled,5.0,11.0,9.5,2.0,20.0,10.0,,,,8.10,8.0,Test Machine
        2026-05-15,21:00:00,0.75,,3,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,8.10,8.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 1)
        #expect(result.skippedRowCount == 1)
        #expect(result.warnings.contains { $0.contains("Pressure_Avg") })
    }

    @Test("Non-finite cells (inf/nan) are skipped as malformed, never crash on Int(inf)")
    func nonFiniteCellsAreSkippedNotCrashed() throws {
        // "inf"/"nan" parse via Double(_:) but must NOT reach Int(_.rounded())
        // (a non-catchable Swift trap) or poison a Double field. Each bad row
        // is skipped; the clean row imports. Reaching the assertions at all
        // proves no trap fired.
        let csv = """
        \(Self.header)
        2026-07-03,22:00:00,1.0,,inf,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.00,7.0,Test Machine
        2026-07-04,22:00:00,nan,,3,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.00,7.0,Test Machine
        2026-07-05,22:00:00,1.0,,3,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.00,inf,Test Machine
        2026-07-06,22:00:00,1.0,,3,0,2,1,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.00,7.0,Test Machine
        """
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try importCSV(csv, into: context)
        #expect(result.inserted == 1)          // only 2026-07-06 is clean
        #expect(result.skippedRowCount == 3)   // inf-OA, nan-AHI, inf-Hours_Used
        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        #expect(session.date == day("2026-07-06"))
        #expect(session.ahi?.isFinite == true)
    }

    // MARK: - Update-path guards (don't clobber real data with a blank re-import)

    @Test("A by-session re-import with blank pressure columns keeps the stored real pressure")
    func blankPressureReimportPreservesRealPressure() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        context.insert(CPAPSession(
            date: day("2026-07-08"), ahi: 2.0, totalUsageMinutes: 400,
            leakRate95th: 16.0, pressureMin: 6.0, pressureMax: 12.0, pressureMean: 9.0,
            obstructiveEvents: 2, centralEvents: 1, hypopneaEvents: 1, importSource: "csv"
        ))
        try context.save()

        // Same date, events present (so AHI is real) but ALL pressure columns
        // blank -> aggregates to the pressure-unavailable sentinel. The update
        // must NOT overwrite the stored 6/12/9 with a fabricated 0.
        let csv = """
        \(Self.header)
        2026-07-08,22:00:00,,,3,0,2,1,,,,,,2.0,20.0,10.0,,,,7.00,7.0,Test Machine
        """
        let result = try importCSV(csv, into: context)
        #expect(result.updated == 1)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        #expect(abs(session.pressureMin - 6.0) < 0.001)
        #expect(abs(session.pressureMax - 12.0) < 0.001)
        #expect(abs(session.pressureMean - 9.0) < 0.001)
        // Provenance preserved (F-040).
        #expect(session.importSource == "csv")
    }

    @Test("A by-session re-import that recomputes nil AHI keeps the stored real AHI")
    func unscoredReimportPreservesRealAHI() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        context.insert(CPAPSession(
            date: day("2026-07-09"), ahi: 2.0, totalUsageMinutes: 400,
            leakRate95th: 16.0, pressureMin: 6.0, pressureMax: 12.0, pressureMean: 9.0,
            obstructiveEvents: 2, centralEvents: 1, hypopneaEvents: 1, importSource: "csv"
        ))
        try context.save()

        // Same date, but this file has NO scored event cells -> aggregate AHI
        // is nil (unscored). Don't downgrade the stored real 2.0 to "unknown".
        let csv = """
        \(Self.header)
        2026-07-09,22:00:00,,,,,,,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.00,7.0,Test Machine
        """
        let result = try importCSV(csv, into: context)
        #expect(result.updated == 1)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        #expect(abs((session.ahi ?? -1) - 2.0) < 0.001)
        // Pressure WAS reported this time, so it updates to the new real value.
        #expect(abs(session.pressureMean - 8.0) < 0.001)
    }

    @Test("A by-session re-import that is unscored preserves stored event counts (no 0/0/0 clobber)")
    func unscoredReimportPreservesRealEventCounts() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let existing = CPAPSession(
            date: day("2026-07-12"), ahi: 3.0, totalUsageMinutes: 400,
            leakRate95th: 16.0, pressureMin: 6.0, pressureMax: 12.0, pressureMean: 9.0,
            obstructiveEvents: 12, centralEvents: 4, hypopneaEvents: 8, importSource: "csv"
        )
        existing.reraEvents = 5
        context.insert(existing)
        try context.save()

        // Same date, unscored (no event cells) -> aggregate events 0/0/0 and
        // nil RERA/AHI. The stored real counts must be preserved, not zeroed,
        // so the row never ends up with a nonzero AHI but 0/0/0 events.
        let csv = """
        \(Self.header)
        2026-07-12,22:00:00,,,,,,,,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,7.00,7.0,Test Machine
        """
        let result = try importCSV(csv, into: context)
        #expect(result.updated == 1)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        #expect(session.obstructiveEvents == 12)
        #expect(session.centralEvents == 4)
        #expect(session.hypopneaEvents == 8)
        #expect(session.reraEvents == 5)
        // AHI preserved too (its own guard); the two stay mutually consistent.
        #expect(abs((session.ahi ?? -1) - 3.0) < 0.001)
    }

    @Test("A scored by-session re-import still updates event counts to the new real values")
    func scoredReimportStillUpdatesEventCounts() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let existing = CPAPSession(
            date: day("2026-07-13"), ahi: 9.0, totalUsageMinutes: 300,
            leakRate95th: 16.0, pressureMin: 6.0, pressureMax: 12.0, pressureMean: 9.0,
            obstructiveEvents: 40, centralEvents: 9, hypopneaEvents: 8, importSource: "csv"
        )
        existing.reraEvents = 20
        context.insert(existing)
        try context.save()

        // Same date, genuinely scored this time with LOWER (real) counts —
        // the guard must not block a legitimate downward correction. 6 scored
        // events over 8.0 h -> computed AHI 0.75 (the stated AHI column is
        // ignored; the importer recomputes from events/hours).
        let csv = """
        \(Self.header)
        2026-07-13,22:00:00,0.75,1.0,3,0,2,1,4,8.0,5.0,11.0,9.5,2.0,20.0,10.0,,,,8.00,8.0,Test Machine
        """
        let result = try importCSV(csv, into: context)
        #expect(result.updated == 1)

        let session = try #require(try context.fetch(FetchDescriptor<CPAPSession>()).first)
        #expect(session.obstructiveEvents == 3)   // OA 3 + UA 0
        #expect(session.centralEvents == 1)
        #expect(session.hypopneaEvents == 2)
        #expect(session.reraEvents == 4)
        #expect(abs((session.ahi ?? -1) - 0.75) < 0.001)
    }

    // MARK: - Export / restore round-trip of the new fields

    @Test("Restore from server carries the by-session fields nil-safely")
    func restoreCarriesBySessionFields() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rows: [[String: Any]] = [
            [
                "date": "2026-05-16", "ahi": 1.5, "total_usage_minutes": 420,
                "pressure_min": 5.0, "pressure_max": 11.0, "pressure_mean": 8.0,
                "obstructive_events": 3, "central_events": 1, "hypopnea_events": 2,
                "rdi_events": 2.1, "rera_events": 4, "spo2_avg": 93.5, "spo2_min": 87.0,
                "pulse_avg": 62.0, "pressure_95th": 9.9, "leak_avg": 2.4, "leak_max": 28.0
            ],
            // Legacy row without the 0010 columns: all new fields stay nil.
            [
                "date": "2026-05-17", "ahi": 2.0, "total_usage_minutes": 400,
                "pressure_min": 5.0, "pressure_max": 11.0, "pressure_mean": 8.0,
                "obstructive_events": 2, "central_events": 0, "hypopnea_events": 1
            ]
        ]
        let count = try SyncService.importCPAPSessions(rows, shift: 0, into: context)
        #expect(count == 2)

        let sessions = try context.fetch(FetchDescriptor<CPAPSession>(sortBy: [SortDescriptor(\.date)]))
        #expect(abs((sessions[0].rdiEvents ?? -1) - 2.1) < 0.001)
        #expect(sessions[0].reraEvents == 4)
        #expect(abs((sessions[0].spo2Avg ?? -1) - 93.5) < 0.001)
        #expect(abs((sessions[0].spo2Min ?? -1) - 87.0) < 0.001)
        #expect(abs((sessions[0].pulseAvg ?? -1) - 62.0) < 0.001)
        #expect(abs((sessions[0].pressure95th ?? -1) - 9.9) < 0.001)
        #expect(abs((sessions[0].leakAvg ?? -1) - 2.4) < 0.001)
        #expect(abs((sessions[0].leakMax ?? -1) - 28.0) < 0.001)
        #expect(sessions[1].rdiEvents == nil)
        #expect(sessions[1].reraEvents == nil)
        #expect(sessions[1].spo2Avg == nil)
        #expect(sessions[1].leakMax == nil)
    }

    @Test("Export JSON carries the by-session fields (and nils for legacy rows)")
    func exportJSONCarriesBySessionFields() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        context.insert(CPAPSession(
            date: day("2026-05-18"), ahi: 1.5, totalUsageMinutes: 420,
            leakRate95th: 10.0, pressureMin: 5.0, pressureMax: 11.0, pressureMean: 8.0,
            obstructiveEvents: 3, centralEvents: 1, hypopneaEvents: 2, importSource: "oscar",
            rdiEvents: 2.1, reraEvents: 4, spo2Avg: 93.5, spo2Min: 87.0,
            pulseAvg: 62.0, pressure95th: 9.9, leakAvg: 2.4, leakMax: 28.0
        ))
        try context.save()

        let data = try DataExporter.exportJSON(from: context)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try #require(json["cpapSessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(abs((session["rdiEvents"] as? Double ?? -1) - 2.1) < 0.001)
        #expect(session["reraEvents"] as? Int == 4)
        #expect(abs((session["spo2Avg"] as? Double ?? -1) - 93.5) < 0.001)
        #expect(abs((session["spo2Min"] as? Double ?? -1) - 87.0) < 0.001)
        #expect(abs((session["pulseAvg"] as? Double ?? -1) - 62.0) < 0.001)
        #expect(abs((session["pressure95th"] as? Double ?? -1) - 9.9) < 0.001)
        #expect(abs((session["leakAvg"] as? Double ?? -1) - 2.4) < 0.001)
        #expect(abs((session["leakMax"] as? Double ?? -1) - 28.0) < 0.001)
    }
}
