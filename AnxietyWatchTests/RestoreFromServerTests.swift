#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for the server-restore CPAP import (F-094). `SyncService.importCPAPSessions`
/// (in RestoreFromServer.swift) is a DEBUG+simulator dev/demo tool. A server
/// row with a NULL AHI (EDF-only night — the server stores null rather than a
/// fabricated 0 per F-068) must still be imported, carrying its usage/leak/
/// pressure, with `ahi == nil`. Previously the whole row was skipped, losing
/// that night's data.
@MainActor
struct RestoreFromServerTests {

    @Test("null-AHI CPAP row is imported (not skipped) with ahi == nil")
    func nullAHIRowIsImported() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let rows: [[String: Any]] = [
            // EDF-only night: server sends "ahi": null.
            ["date": "2024-03-01", "total_usage_minutes": 420, "ahi": NSNull(),
             "leak_rate_95th": 14.0, "pressure_min": 6.0, "pressure_max": 12.0,
             "pressure_mean": 9.0, "import_source": "edf"],
            // A normally-scored night.
            ["date": "2024-03-02", "total_usage_minutes": 400, "ahi": 3.5,
             "import_source": "oscar"],
        ]

        let n = SyncService.importCPAPSessions(rows, shift: 0, into: context)
        #expect(n == 2, "both rows must import — the null-AHI row is no longer skipped")

        let sessions = try context.fetch(
            FetchDescriptor<CPAPSession>(sortBy: [SortDescriptor(\.date)])
        )
        #expect(sessions.count == 2)

        let edfNight = try #require(sessions.first { $0.importSource == "edf" })
        #expect(edfNight.ahi == nil, "unknown AHI stays nil — not coerced to 0")
        #expect(edfNight.totalUsageMinutes == 420, "usage still restored")
        #expect(edfNight.leakRate95th == 14.0, "leak still restored")

        let scoredNight = try #require(sessions.first { $0.importSource == "oscar" })
        #expect(scoredNight.ahi == 3.5)
    }

    @Test("a row missing required fields is still skipped")
    func rowMissingUsageIsSkipped() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        // No total_usage_minutes → not a usable session; skip (unchanged).
        let rows: [[String: Any]] = [["date": "2024-03-01", "ahi": NSNull()]]
        let n = SyncService.importCPAPSessions(rows, shift: 0, into: context)
        #expect(n == 0)
    }
}
#endif
