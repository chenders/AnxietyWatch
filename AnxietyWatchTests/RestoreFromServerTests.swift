import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for the server-restore importers in RestoreFromServer.swift — the
/// production data-migration path for a fresh install (e.g. after a bundle-ID
/// change). Fixture rows use the server's actual `/api/data` response shape:
/// `SELECT *` per table serialized by `_serialize_row`, so keys are the
/// snake_case column names in server/schema.sql and timestamps are
/// `datetime.isoformat()` strings. All values are fictional per CLAUDE.md.
@MainActor
struct RestoreFromServerTests {

    /// Parse an ISO-8601 instant (server `TIMESTAMPTZ` shape, no fractional
    /// seconds) for exact-timestamp assertions.
    private static func instant(_ s: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let d = formatter.date(from: s) else {
            fatalError("test fixture timestamp failed to parse: \(s)")
        }
        return d
    }

    /// Local-calendar date builder for day-bucketing tests (re-aggregation
    /// groups by `Calendar.current.startOfDay`).
    private static func localDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        Calendar.current.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    // MARK: - CPAP (F-094 regression coverage)

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

    // MARK: - Sensor sessions

    @Test("sensor sessions import with preserved server UUID, fields, and id map")
    func sensorSessionsImport() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let serverID = "ABABABAB-CDCD-EFEF-ABAB-CDCDCDCDCDCD"
        let rows: [[String: Any]] = [
            ["id": serverID,
             "source": "polar_h10",
             "start_time": "2024-03-01T21:30:00+00:00",
             "end_time": "2024-03-02T05:45:00+00:00",
             "battery_at_start": 87,
             "interruption_count": 0,
             "summary_json": ["rmssdMean": 42.0, "rrCount": 31000],
             "created_at": "2024-03-02T06:00:00+00:00"],
            // battery null + no end_time (in-flight when synced).
            ["id": "FEFEFEFE-DCDC-BABA-FEFE-DCDCDCDCDCDC",
             "source": "polar_h10",
             "start_time": "2024-03-03T22:00:00+00:00",
             "end_time": NSNull(),
             "battery_at_start": NSNull(),
             "summary_json": NSNull()],
        ]

        let (n, map) = SyncService.importSensorSessions(rows, shift: 0, into: context)
        #expect(n == 2)
        #expect(map.count == 2)
        #expect(map[serverID] == UUID(uuidString: serverID),
                "server UUID is preserved as the local session id")

        let sessions = try context.fetch(
            FetchDescriptor<SensorSession>(sortBy: [SortDescriptor(\.startTime)])
        )
        let first = try #require(sessions.first)
        #expect(first.id == UUID(uuidString: serverID))
        #expect(first.startTime == Self.instant("2024-03-01T21:30:00+00:00"),
                "timestamps preserved exactly with shift 0")
        #expect(first.endTime == Self.instant("2024-03-02T05:45:00+00:00"))
        #expect(first.batteryAtStart == 87)
        #expect(first.source == "polar_h10")
        let summary = try #require(first.summaryJSON)
        #expect(summary.contains("rmssdMean"))
        #expect(first.syncedToServer, "restored rows must not re-upload")

        let second = try #require(sessions.last)
        #expect(second.endTime == nil)
        #expect(second.batteryAtStart == 100, "null battery falls back to 100")
    }

    // MARK: - HRV readings

    @Test("hrv readings import with session re-link, nil-fallback, and null frequency fields")
    func hrvReadingsImport() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let serverSessionID = "ABABABAB-CDCD-EFEF-ABAB-CDCDCDCDCDCD"
        let sessionRows: [[String: Any]] = [
            ["id": serverSessionID, "source": "polar_h10",
             "start_time": "2024-03-01T21:30:00+00:00"],
        ]
        let (_, sessionMap) = SyncService.importSensorSessions(sessionRows, shift: 0, into: context)

        let readingID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let rows: [[String: Any]] = [
            ["id": readingID,
             "session_id": serverSessionID,
             "timestamp": "2024-03-01T21:31:00+00:00",
             "rmssd": 38.5, "sdnn": 52.1, "pnn50": 12.4,
             "lf_power": 820.0, "hf_power": 410.0, "lf_hf_ratio": 2.0,
             "source": "polar_h10"],
            // Sparse window: frequency-domain fields are NULL server-side;
            // session id unknown to the map (never synced as a session row).
            ["id": "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF",
             "session_id": "A0A0A0A0-B0B0-C0C0-D0D0-E0E0E0E0E0E0",
             "timestamp": "2024-03-01T21:32:00+00:00",
             "rmssd": 40.0, "sdnn": 55.0, "pnn50": 15.0,
             "lf_power": NSNull(), "hf_power": NSNull(), "lf_hf_ratio": NSNull(),
             "source": "polar_h10"],
        ]

        let n = SyncService.importHRVReadings(rows, shift: 0, sessionMap: sessionMap, into: context)
        #expect(n == 2)

        let readings = try context.fetch(
            FetchDescriptor<HRVReading>(sortBy: [SortDescriptor(\.timestamp)])
        )
        let linked = try #require(readings.first)
        #expect(linked.id == UUID(uuidString: readingID), "server UUID preserved (#Unique merge key)")
        #expect(linked.timestamp == Self.instant("2024-03-01T21:31:00+00:00"))
        #expect(abs(linked.rmssd - 38.5) < 0.001)
        #expect(abs(linked.sdnn - 52.1) < 0.001)
        #expect(abs(linked.pnn50 - 12.4) < 0.001)
        #expect(abs(linked.lfPower - 820.0) < 0.001)
        #expect(linked.sensorSessionID == UUID(uuidString: serverSessionID),
                "re-linked to the restored session via the id map")
        #expect(linked.source == "polar_h10")
        #expect(linked.syncedToServer)

        let orphan = try #require(readings.last)
        #expect(orphan.sensorSessionID == nil, "unknown session id re-links to nil, not garbage")
        #expect(abs(orphan.lfPower - 0) < 0.001, "null frequency fields default to 0")
    }

    // MARK: - Accel spectrograms

    @Test("accel spectrograms import all fields with session re-link and nil-fallback")
    func accelSpectrogramsImport() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let serverSessionID = "ABABABAB-CDCD-EFEF-ABAB-CDCDCDCDCDCD"
        let (_, sessionMap) = SyncService.importSensorSessions(
            [["id": serverSessionID, "source": "polar_h10",
              "start_time": "2024-03-01T21:30:00+00:00"]],
            shift: 0, into: context
        )

        let spectrogramID = "CCCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA"
        let rows: [[String: Any]] = [
            ["id": spectrogramID,
             "session_id": serverSessionID,
             "timestamp": "2024-03-01T21:30:10+00:00",
             "tremor_band_power": 0.042, "breathing_band_power": 0.013,
             "fidget_band_power": 0.087, "activity_level": 0.31],
            // Watch-local capture session that never synced: unknown session id.
            ["id": "DDDDDDDD-EEEE-FFFF-AAAA-BBBBBBBBBBBB",
             "session_id": "B0B0B0B0-C0C0-D0D0-E0E0-F0F0F0F0F0F0",
             "timestamp": "2024-03-01T21:30:20+00:00",
             "tremor_band_power": 0.05, "breathing_band_power": 0.02,
             "fidget_band_power": 0.09, "activity_level": 0.4],
        ]

        let n = SyncService.importAccelSpectrograms(rows, shift: 0, sessionMap: sessionMap, into: context)
        #expect(n == 2)

        let spectrograms = try context.fetch(
            FetchDescriptor<AccelSpectrogram>(sortBy: [SortDescriptor(\.timestamp)])
        )
        let linked = try #require(spectrograms.first)
        #expect(linked.id == UUID(uuidString: spectrogramID))
        #expect(linked.timestamp == Self.instant("2024-03-01T21:30:10+00:00"))
        #expect(abs(linked.tremorBandPower - 0.042) < 0.0001)
        #expect(abs(linked.breathingBandPower - 0.013) < 0.0001)
        #expect(abs(linked.fidgetBandPower - 0.087) < 0.0001)
        #expect(abs(linked.activityLevel - 0.31) < 0.0001)
        #expect(linked.sensorSessionID == UUID(uuidString: serverSessionID))
        #expect(linked.syncedToServer)

        let orphan = try #require(spectrograms.last)
        #expect(orphan.sensorSessionID == nil)
    }

    // MARK: - Derived breathing rates

    @Test("derived breathing rates import all fields with session re-link and nil-fallback")
    func derivedBreathingRatesImport() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let serverSessionID = "ABABABAB-CDCD-EFEF-ABAB-CDCDCDCDCDCD"
        let (_, sessionMap) = SyncService.importSensorSessions(
            [["id": serverSessionID, "source": "polar_h10",
              "start_time": "2024-03-01T21:30:00+00:00"]],
            shift: 0, into: context
        )

        let rateID = "EEEEEEEE-FFFF-AAAA-BBBB-CCCCCCCCCCCC"
        let rows: [[String: Any]] = [
            ["id": rateID,
             "session_id": serverSessionID,
             "timestamp": "2024-03-01T21:31:00+00:00",
             "breaths_per_minute": 14.2, "confidence": 0.85, "source": "accelerometer"],
            ["id": "FFFFFFFF-AAAA-BBBB-CCCC-DDDDDDDDDDDD",
             "session_id": "C0C0C0C0-D0D0-E0E0-F0F0-A0A0A0A0A0A0",
             "timestamp": "2024-03-01T21:32:00+00:00",
             "breaths_per_minute": 15.0, "confidence": 0.6, "source": "healthkit_sleep"],
        ]

        let n = SyncService.importDerivedBreathingRates(rows, shift: 0, sessionMap: sessionMap, into: context)
        #expect(n == 2)

        let rates = try context.fetch(
            FetchDescriptor<DerivedBreathingRate>(sortBy: [SortDescriptor(\.timestamp)])
        )
        let linked = try #require(rates.first)
        #expect(linked.id == UUID(uuidString: rateID))
        #expect(linked.timestamp == Self.instant("2024-03-01T21:31:00+00:00"))
        #expect(abs(linked.breathsPerMinute - 14.2) < 0.001)
        #expect(abs(linked.confidence - 0.85) < 0.001)
        #expect(linked.source == "accelerometer")
        #expect(linked.sensorSessionID == UUID(uuidString: serverSessionID))
        #expect(linked.syncedToServer)

        let orphan = try #require(rates.last)
        #expect(orphan.sensorSessionID == nil)
    }

    // MARK: - Barometric readings

    @Test("barometric readings import all fields with exact timestamps")
    func barometricReadingsImport() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let rows: [[String: Any]] = [
            ["timestamp": "2024-03-01T08:00:00+00:00",
             "pressure_kpa": 101.325, "relative_altitude_m": 0.0],
            ["timestamp": "2024-03-01T08:15:00+00:00",
             "pressure_kpa": 100.9, "relative_altitude_m": -3.5],
            // Malformed row (missing pressure) is skipped, not crashed on.
            ["timestamp": "2024-03-01T08:30:00+00:00", "relative_altitude_m": 1.0],
        ]

        let n = SyncService.importBarometricReadings(rows, shift: 0, into: context)
        #expect(n == 2)

        let readings = try context.fetch(
            FetchDescriptor<BarometricReading>(sortBy: [SortDescriptor(\.timestamp)])
        )
        #expect(readings.count == 2)
        let first = try #require(readings.first)
        #expect(first.timestamp == Self.instant("2024-03-01T08:00:00+00:00"),
                "production restore preserves timestamps exactly (shift 0)")
        #expect(abs(first.pressureKPa - 101.325) < 0.0001)
        #expect(abs(first.relativeAltitudeM - 0.0) < 0.0001)
        let second = try #require(readings.last)
        #expect(abs(second.relativeAltitudeM - (-3.5)) < 0.0001)
    }

    // MARK: - Production no-shift behavior

    @Test("shift 0 preserves an entity timestamp bit-for-bit across importers")
    func zeroShiftPreservesTimestamps() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Server emits fractional seconds when the stored value has them.
        let ts = "2024-03-01T08:00:00.500+00:00"
        _ = SyncService.importHRVReadings(
            [["id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "timestamp": ts,
              "rmssd": 38.5, "sdnn": 52.1, "pnn50": 12.4]],
            shift: 0, sessionMap: [:], into: context
        )
        let reading = try #require(try context.fetch(FetchDescriptor<HRVReading>()).first)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try #require(fractional.date(from: ts))
        #expect(reading.timestamp == expected,
                "no demo date-shift leaks into a production restore")
    }

    // MARK: - Idempotency

    @Test("running the raw-sensor importers twice leaves row counts stable")
    func importersAreIdempotent() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let hrvRows: [[String: Any]] = [
            ["id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
             "timestamp": "2024-03-01T21:31:00+00:00",
             "rmssd": 38.5, "sdnn": 52.1, "pnn50": 12.4],
        ]
        let accelRows: [[String: Any]] = [
            ["id": "CCCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA",
             "timestamp": "2024-03-01T21:30:10+00:00",
             "tremor_band_power": 0.042, "breathing_band_power": 0.013,
             "fidget_band_power": 0.087, "activity_level": 0.31],
        ]
        let breathingRows: [[String: Any]] = [
            ["id": "EEEEEEEE-FFFF-AAAA-BBBB-CCCCCCCCCCCC",
             "timestamp": "2024-03-01T21:31:00+00:00",
             "breaths_per_minute": 14.2, "confidence": 0.85, "source": "accelerometer"],
        ]
        let barometricRows: [[String: Any]] = [
            ["timestamp": "2024-03-01T08:00:00+00:00",
             "pressure_kpa": 101.325, "relative_altitude_m": 0.0],
        ]

        for _ in 0..<2 {
            _ = SyncService.importHRVReadings(hrvRows, shift: 0, sessionMap: [:], into: context)
            _ = SyncService.importAccelSpectrograms(accelRows, shift: 0, sessionMap: [:], into: context)
            _ = SyncService.importDerivedBreathingRates(breathingRows, shift: 0, sessionMap: [:], into: context)
            _ = SyncService.importBarometricReadings(barometricRows, shift: 0, into: context)
            try context.save()
        }

        // HRV / accel / breathing dedupe via #Unique on the preserved server
        // id; barometric dedupes by timestamp (the server-side PK).
        #expect(try context.fetchCount(FetchDescriptor<HRVReading>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<AccelSpectrogram>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<DerivedBreathingRate>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<BarometricReading>()) == 1)
    }

    // MARK: - Pharmacy call logs

    @Test("pharmacy call logs import all fields, re-link by name, and dedupe on (timestamp, pharmacy_name)")
    func pharmacyCallLogsImport() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Restored pharmacy the first log should re-link to (imported by the
        // pharmacies branch, which runs before this importer).
        context.insert(Pharmacy(
            name: "Test Pharmacy #12345", address: "100 Example Blvd, Anytown, ST 00000",
            phoneNumber: "555-0100"
        ))
        try context.save()

        let rows: [[String: Any]] = [
            ["timestamp": "2024-03-01T10:00:00+00:00", "pharmacy_name": "Test Pharmacy #12345",
             "direction": "completed", "notes": "Refill ready", "duration_seconds": 95],
            // Pharmacy row no longer exists — the denormalized name carries.
            ["timestamp": "2024-03-02T09:30:00+00:00", "pharmacy_name": "Closed Test Pharmacy",
             "direction": "attempted", "notes": "", "duration_seconds": NSNull()],
            // Malformed row (no pharmacy_name) is skipped, not crashed on.
            ["timestamp": "2024-03-03T09:30:00+00:00"],
        ]

        let n = SyncService.importPharmacyCallLogs(rows, shift: 0, into: context)
        #expect(n == 2)
        try context.save()

        let logs = try context.fetch(
            FetchDescriptor<PharmacyCallLog>(sortBy: [SortDescriptor(\.timestamp)])
        )
        #expect(logs.count == 2)
        let linked = try #require(logs.first)
        #expect(linked.timestamp == Self.instant("2024-03-01T10:00:00+00:00"),
                "production restore preserves timestamps exactly (shift 0)")
        #expect(linked.direction == "completed")
        #expect(linked.pharmacyName == "Test Pharmacy #12345")
        #expect(linked.notes == "Refill ready")
        #expect(linked.durationSeconds == 95)
        #expect(linked.pharmacy?.name == "Test Pharmacy #12345", "re-linked by name")

        let orphan = try #require(logs.last)
        #expect(orphan.pharmacy == nil, "unknown pharmacy re-links to nil, not garbage")
        #expect(orphan.durationSeconds == nil, "null duration stays nil")

        // Idempotency: re-import dedupes on the server upsert key
        // (timestamp, pharmacy_name).
        let again = SyncService.importPharmacyCallLogs(rows, shift: 0, into: context)
        #expect(again == 0)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<PharmacyCallLog>()) == 2)
    }

    @Test("same timestamp at two different pharmacies is NOT deduped — the key is the pair")
    func pharmacyCallLogDedupeKeyIsPair() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rows: [[String: Any]] = [
            ["timestamp": "2024-03-01T10:00:00+00:00", "pharmacy_name": "Test Pharmacy #12345",
             "direction": "attempted", "notes": ""],
            ["timestamp": "2024-03-01T10:00:00+00:00", "pharmacy_name": "Other Test Pharmacy",
             "direction": "attempted", "notes": ""],
        ]
        let n = SyncService.importPharmacyCallLogs(rows, shift: 0, into: context)
        #expect(n == 2, "matching timestamps alone must not collapse distinct pharmacies' logs")
    }

    // MARK: - Empty-store guard

    @Test("guard passes on a fresh store and on name-deduped tables only")
    func guardPassesOnFreshStore() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        #expect(SyncService.restoreGuardTablesAreEmpty(context))

        // Name-deduped tables don't block a restore: their importers merge.
        context.insert(MedicationDefinition(
            name: "Clonazepam 1mg Tablets", defaultDoseMg: 1, category: "benzo", isActive: true
        ))
        context.insert(Pharmacy(
            name: "Test Pharmacy #12345", address: "100 Example Blvd, Anytown, ST 00000",
            phoneNumber: "555-0100"
        ))
        try context.save()
        #expect(SyncService.restoreGuardTablesAreEmpty(context),
                "deduped tables must not block restore on a configured fresh install")
    }

    @Test("guard rejects when a store holds ONLY raw sensor rows")
    func guardRejectsSensorOnlyStore() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        // Pre-fix, the guard only counted entries/snapshots/sessions — a
        // store holding only raw sensor rows was treated as empty and a
        // second restore would duplicate + (in demo mode) re-shift rows.
        context.insert(AccelSpectrogram(
            timestamp: Self.localDate(2024, 3, 1, 10, 0),
            tremorBandPower: 0.04, breathingBandPower: 0.01,
            fidgetBandPower: 0.08, activityLevel: 0.3
        ))
        try context.save()
        #expect(!SyncService.restoreGuardTablesAreEmpty(context))
    }

    @Test("guard rejects each counted table independently — all 13 guarded tables")
    func guardCountsEveryMajorTable() throws {
        // One container per table: the guard must trip on ANY of them alone.
        func rejects(_ insert: (ModelContext) -> Void) throws -> Bool {
            let container = try TestHelpers.makeFullContainer()
            let context = ModelContext(container)
            insert(context)
            try context.save()
            return !SyncService.restoreGuardTablesAreEmpty(context)
        }

        let when = Self.localDate(2024, 3, 1, 10, 0)

        #expect(try rejects { ctx in
            ctx.insert(AnxietyEntry(timestamp: when, severity: 5, notes: "guard-trip", tags: []))
        })
        #expect(try rejects { ctx in
            ctx.insert(HealthSnapshot(date: when))
        })
        #expect(try rejects { ctx in
            ctx.insert(SensorSession(startTime: when, batteryAtStart: 90))
        })
        #expect(try rejects { ctx in
            ctx.insert(HRVReading(
                timestamp: when,
                rmssd: 38, sdnn: 52, pnn50: 12, lfPower: 0, hfPower: 0, lfHfRatio: 0
            ))
        })
        #expect(try rejects { ctx in
            ctx.insert(BarometricReading(
                timestamp: when, pressureKPa: 101.3, relativeAltitudeM: 0
            ))
        })
        #expect(try rejects { ctx in
            ctx.insert(AccelSpectrogram(
                timestamp: when, tremorBandPower: 0.04, breathingBandPower: 0.01,
                fidgetBandPower: 0.08, activityLevel: 0.3
            ))
        })
        #expect(try rejects { ctx in
            ctx.insert(DerivedBreathingRate(
                timestamp: when, breathsPerMinute: 14, confidence: 0.8, source: "accelerometer"
            ))
        })
        #expect(try rejects { ctx in
            ctx.insert(MedicationDose(
                timestamp: when, medicationName: "Clonazepam 1mg Tablets", doseMg: 1,
                notes: nil, isPRN: true, medication: nil
            ))
        })
        #expect(try rejects { ctx in
            ctx.insert(CPAPSession(
                date: when, ahi: 3.5, totalUsageMinutes: 420, leakRate95th: nil,
                pressureMin: 6, pressureMax: 12, pressureMean: 9,
                obstructiveEvents: 0, centralEvents: 0, hypopneaEvents: 0,
                importSource: "oscar"
            ))
        })
        #expect(try rejects { ctx in
            ctx.insert(SleepStageEvent(
                startTime: when, endTime: when.addingTimeInterval(1800),
                stage: "asleepDeep", sourceBundleID: "com.example.test",
                sourceName: "Test Apple Watch"
            ))
        })
        #expect(try rejects { ctx in
            ctx.insert(Song(title: "Test Song", artist: "Test Artist"))
        })
        #expect(try rejects { ctx in
            ctx.insert(SongOccurrence(timestamp: when, source: "manual"))
        })
        // A call log implies real prior use of the device — exactly the
        // "not actually fresh" signal the guard exists to detect.
        #expect(try rejects { ctx in
            ctx.insert(PharmacyCallLog(timestamp: when, pharmacyName: "Test Pharmacy #12345"))
        })
    }

    // MARK: - Post-restore re-aggregation

    @Test("re-aggregation fills sensor-derived fields per day without touching HealthKit-derived fields")
    func reaggregationFillsSensorDerivedFields() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Day 1 (2024-03-01): restored snapshot with HealthKit-derived values,
        // plus two spectrograms and two breathing rates.
        let day1 = Calendar.current.startOfDay(for: Self.localDate(2024, 3, 1))
        let snapshot1 = HealthSnapshot(date: day1)
        snapshot1.restingHR = 55.0
        snapshot1.hrvAvg = 45.0
        snapshot1.steps = 8200
        snapshot1.syncedToServer = true
        context.insert(snapshot1)

        context.insert(AccelSpectrogram(
            timestamp: Self.localDate(2024, 3, 1, 9, 0),
            tremorBandPower: 0.04, breathingBandPower: 0.01,
            fidgetBandPower: 0.08, activityLevel: 0.3
        ))
        // 23:30 same LOCAL day — must bucket into day 1, not day 2.
        context.insert(AccelSpectrogram(
            timestamp: Self.localDate(2024, 3, 1, 23, 30),
            tremorBandPower: 0.06, breathingBandPower: 0.02,
            fidgetBandPower: 0.10, activityLevel: 0.5
        ))
        context.insert(DerivedBreathingRate(
            timestamp: Self.localDate(2024, 3, 1, 9, 0),
            breathsPerMinute: 14.0, confidence: 0.9, source: "accelerometer"
        ))
        context.insert(DerivedBreathingRate(
            timestamp: Self.localDate(2024, 3, 1, 23, 30),
            breathsPerMinute: 16.0, confidence: 0.8, source: "accelerometer"
        ))

        // Day 2 (2024-03-02): sensor rows but NO snapshot — one is created.
        context.insert(AccelSpectrogram(
            timestamp: Self.localDate(2024, 3, 2, 0, 30),
            tremorBandPower: 0.02, breathingBandPower: 0.01,
            fidgetBandPower: 0.04, activityLevel: 0.2
        ))
        try context.save()

        let days = try SyncService.reaggregateSensorDerivedSnapshots(in: context)
        #expect(days == 2)
        try context.save()

        let snapshots = try context.fetch(
            FetchDescriptor<HealthSnapshot>(sortBy: [SortDescriptor(\.date)])
        )
        #expect(snapshots.count == 2, "day 2 snapshot created for its sensor rows")

        let restored = try #require(snapshots.first)
        let tremor1 = try #require(restored.tremorBandPowerAvg)
        #expect(abs(tremor1 - 0.05) < 0.0001, "mean of 0.04 and 0.06")
        let fidget1 = try #require(restored.fidgetIndexAvg)
        #expect(abs(fidget1 - 0.09) < 0.0001, "mean of 0.08 and 0.10")
        let breathing1 = try #require(restored.breathingRateAvg)
        #expect(abs(breathing1 - 15.0) < 0.0001, "mean of 14 and 16")
        // HealthKit-derived fields restored from the server are untouched —
        // re-running full aggregation against an empty HealthKit store would
        // have blanked these.
        #expect(restored.restingHR == 55.0)
        #expect(restored.hrvAvg == 45.0)
        #expect(restored.steps == 8200)
        #expect(restored.syncedToServer, "sensor-derived fields aren't synced; no re-upload churn")

        let created = try #require(snapshots.last)
        #expect(created.date == Calendar.current.startOfDay(for: Self.localDate(2024, 3, 2)))
        let tremor2 = try #require(created.tremorBandPowerAvg)
        #expect(abs(tremor2 - 0.02) < 0.0001)
        #expect(created.breathingRateAvg == nil, "no breathing rows on day 2 → stays nil")
        #expect(created.restingHR == nil, "created snapshot carries ONLY sensor-derived fields")
    }

    @Test("re-aggregation is a no-op on a store with no sensor rows")
    func reaggregationNoSensorRowsIsNoOp() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let snapshot = HealthSnapshot(date: Self.localDate(2024, 3, 1))
        snapshot.restingHR = 55.0
        context.insert(snapshot)
        try context.save()

        let days = try SyncService.reaggregateSensorDerivedSnapshots(in: context)
        #expect(days == 0)
        let unchanged = try #require(try context.fetch(FetchDescriptor<HealthSnapshot>()).first)
        #expect(unchanged.restingHR == 55.0)
        #expect(unchanged.tremorBandPowerAvg == nil)
    }

    // MARK: - RestoreMigrationGate

    /// Isolated UserDefaults per test so gate state can't leak between tests
    /// or into the app's real `.standard` domain.
    private static func isolatedDefaults(_ suite: String) throws -> (UserDefaults, () -> Void) {
        let name = "test.restoreGate.\(suite)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test("shouldDeferSetup defers only while the decision is unresolved AND the store is fresh")
    func gatePureDecisionCore() {
        #expect(RestoreMigrationGate.shouldDeferSetup(storeIsEmpty: true, decisionResolved: false))
        #expect(!RestoreMigrationGate.shouldDeferSetup(storeIsEmpty: true, decisionResolved: true))
        #expect(!RestoreMigrationGate.shouldDeferSetup(storeIsEmpty: false, decisionResolved: false))
        #expect(!RestoreMigrationGate.shouldDeferSetup(storeIsEmpty: false, decisionResolved: true))
    }

    @Test("evaluateAtLaunch defers on a fresh store and leaves the decision PENDING")
    func gateDefersOnFreshStore() throws {
        let (defaults, cleanup) = try Self.isolatedDefaults("freshUnresolved")
        defer { cleanup() }
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        #expect(RestoreMigrationGate.evaluateAtLaunch(context: context, defaults: defaults),
                "fresh store + unresolved decision must defer setup")
        #expect(!RestoreMigrationGate.isResolved(defaults: defaults),
                "deferring must NOT resolve — an abandoned decision re-prompts next launch")
        // The evaluation itself must not write to the store (it would trip
        // the very guard it protects).
        #expect(SyncService.restoreGuardTablesAreEmpty(context))
    }

    @Test("evaluateAtLaunch does not defer once the decision is resolved")
    func gateResolvedDecisionNeverDefers() throws {
        let (defaults, cleanup) = try Self.isolatedDefaults("resolved")
        defer { cleanup() }
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        RestoreMigrationGate.resolve(defaults: defaults)
        #expect(!RestoreMigrationGate.evaluateAtLaunch(context: context, defaults: defaults),
                "a resolved decision (Start Fresh or completed restore) never defers again")
    }

    @Test("evaluateAtLaunch on a non-empty store never defers and auto-resolves")
    func gateNonEmptyStoreAutoResolves() throws {
        let (defaults, cleanup) = try Self.isolatedDefaults("existingInstall")
        defer { cleanup() }
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        context.insert(AnxietyEntry(
            timestamp: Self.localDate(2024, 3, 1, 10, 0), severity: 4, notes: "existing", tags: []
        ))
        try context.save()

        #expect(!RestoreMigrationGate.evaluateAtLaunch(context: context, defaults: defaults),
                "existing installs must never see the prompt or a deferred setup")
        #expect(RestoreMigrationGate.isResolved(defaults: defaults),
                "non-empty store resolves permanently so later launches skip the store probe")
    }
}

/// Full `restoreFromServer()` orchestration tests. `.serialized` because
/// `SyncService`'s configuration and `lastSyncDate` persist through
/// `UserDefaults.standard` (same reason `SyncServiceTests` is serialized).
@Suite(.serialized)
@MainActor
struct RestoreFromServerOrchestrationTests {

    private static let syncKeys = ["syncServerURL", "syncApiKey", "syncAutoEnabled", "lastSyncDate"]

    /// Save current UserDefaults values and return a restore closure.
    private func saveSyncDefaults() -> (() -> Void) {
        let saved = Self.syncKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        return {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    private static func gateDefaults(_ suite: String) throws -> (UserDefaults, () -> Void) {
        let name = "test.restoreOrchestration.\(suite)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test("successful restore advances lastSyncDate to the PRE-fetch bound, resolves the gate, and counts pharmacyCallLogs")
    func restoreSetsCursorToPreFetchBound() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.set("http://sync.example.com", forKey: "syncServerURL")
        UserDefaults.standard.set("test-api-key", forKey: "syncApiKey")
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")
        let (gateDefaults, cleanup) = try Self.gateDefaults("success")
        defer { cleanup() }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let payload: [String: Any] = [
            "anxietyEntries": [
                ["timestamp": "2024-03-01T10:00:00+00:00", "severity": 4,
                 "notes": "restored", "tags": []],
            ],
            "pharmacyCallLogs": [
                ["timestamp": "2024-03-01T10:05:00+00:00",
                 "pharmacy_name": "Test Pharmacy #12345",
                 "direction": "completed", "notes": "", "duration_seconds": 60],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        // Fixed clock captured BEFORE the (mock) download: the cursor must
        // land exactly here, never on a post-I/O `.now` — the documented
        // incremental-sync race (CLAUDE.md; mirrors sync()'s cursorUpperBound).
        let fixedNow = Date(timeIntervalSince1970: 1_711_300_000)

        let service = SyncService()
        let report = try await service.restoreFromServer(
            modelContext: context,
            now: { fixedNow },
            performRequest: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
                // The restore now makes a SECOND request: quantity samples are
                // excluded from the bulk payload (~79 MB in the real dataset)
                // and paged down separately. Route on path so the mock models
                // the real two-endpoint flow.
                if url.path.hasSuffix("/quantityHealthSamples") {
                    let page: [String: Any] = [
                        "quantityHealthSamples": [
                            ["id": "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
                             "timestamp": "2024-03-01T10:00:00+00:00",
                             "metric_type": "HKQuantityTypeIdentifierOxygenSaturation",
                             "value": 0.95, "unit_string": "%",
                             "source_bundle_id": "com.emay.SleepO2",
                             "source_name": "EMAY SleepO2"],
                        ],
                        "total": 1,
                    ]
                    return (try JSONSerialization.data(withJSONObject: page), response)
                }
                return (body, response)
            },
            defaults: gateDefaults
        )

        #expect(report.contains("quantityHealthSamples: 1"),
                "paged quantity samples are restored as part of the normal flow")
        #expect(try context.fetchCount(FetchDescriptor<QuantityHealthSample>()) == 1)

        #expect(service.lastSyncDate == fixedNow,
                "first post-restore sync must be incremental from the pre-fetch bound")
        #expect(RestoreMigrationGate.isResolved(defaults: gateDefaults),
                "a completed restore resolves the migration decision")
        #expect(report.contains("anxietyEntries: 1"))
        #expect(report.contains("pharmacyCallLogs: 1"), "call logs are counted in the report")
        #expect(try context.fetchCount(FetchDescriptor<PharmacyCallLog>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<AnxietyEntry>()) == 1)
    }

    @Test("failed restore leaves the cursor and the migration gate untouched")
    func failedRestoreLeavesCursorAndGateUntouched() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.set("http://sync.example.com", forKey: "syncServerURL")
        UserDefaults.standard.set("test-api-key", forKey: "syncApiKey")
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")
        let (gateDefaults, cleanup) = try Self.gateDefaults("failure")
        defer { cleanup() }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let service = SyncService()
        await #expect(throws: (any Error).self) {
            _ = try await service.restoreFromServer(
                modelContext: context,
                now: { Date(timeIntervalSince1970: 1_711_300_000) },
                performRequest: { request in
                    let url = try #require(request.url)
                    let response = try #require(HTTPURLResponse(
                        url: url, statusCode: 500, httpVersion: nil, headerFields: nil
                    ))
                    return (Data(), response)
                },
                defaults: gateDefaults
            )
        }
        #expect(service.lastSyncDate == nil,
                "cursor only advances after the restore fully succeeds")
        #expect(!RestoreMigrationGate.isResolved(defaults: gateDefaults),
                "a failed restore keeps the decision pending so the next launch re-prompts")
    }

    // MARK: - Quantity health samples (paged restore)
    //
    // This table synced UP but had no way back DOWN — absent from the server's
    // ENTITY_QUERIES and never referenced by RestoreFromServer. A fresh install
    // therefore silently lost every EMAY oximetry sample. Unlike Apple/Polar/
    // Dexcom rows those are app-only (the app never writes to HealthKit), so
    // nothing could re-derive them. These tests pin the path shut.

    private static func sampleRow(
        id: String, ts: String = "2024-03-01T10:00:00+00:00", source: String = "com.emay.SleepO2"
    ) -> [String: Any] {
        [
            "id": id,
            "timestamp": ts,
            "metric_type": "HKQuantityTypeIdentifierOxygenSaturation",
            "value": 0.95,
            "unit_string": "%",
            "source_bundle_id": source,
            "source_name": "EMAY SleepO2",
        ]
    }

    @Test("restored sample keeps the server's id — else HealthKit backfill duplicates every row")
    func quantitySamplePreservesServerID() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let id = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

        let n = SyncService.importQuantityHealthSamples(
            [Self.sampleRow(id: id)], shift: 0, into: context
        )

        #expect(n == 1)
        let row = try #require(try context.fetch(FetchDescriptor<QuantityHealthSample>()).first)
        // HealthDataCoordinator mirrors HealthKit keyed on `sample.hkUUID`, doing
        // update-or-insert on that id. Minting a fresh UUID here would make the
        // first post-restore backfill re-insert every HealthKit-sourced sample as
        // a duplicate instead of matching the restored row.
        #expect(row.id == UUID(uuidString: id))
    }

    @Test("restored sample is marked synced — else the next sync re-uploads the whole history")
    func quantitySampleIsMarkedSynced() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        _ = SyncService.importQuantityHealthSamples(
            [Self.sampleRow(id: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")], shift: 0, into: context
        )

        let row = try #require(try context.fetch(FetchDescriptor<QuantityHealthSample>()).first)
        // Bulk types export on `syncedToServer == false` (not by the date cursor),
        // and the model defaults it to false. Leaving the default would make the
        // first sync after a restore re-POST every restored row.
        #expect(row.syncedToServer, "rows that came FROM the server must not be queued to go back")
    }

    @Test("field mapping is correct and malformed rows are skipped")
    func quantitySampleFieldMappingAndSkips() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let rows: [[String: Any]] = [
            Self.sampleRow(id: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"),
            ["id": "not-a-uuid", "timestamp": "2024-03-01T10:00:00+00:00"],
            ["timestamp": "2024-03-01T10:00:00+00:00"],
        ]
        let n = SyncService.importQuantityHealthSamples(rows, shift: 0, into: context)

        #expect(n == 1, "malformed rows are skipped, not imported as junk")
        let row = try #require(try context.fetch(FetchDescriptor<QuantityHealthSample>()).first)
        #expect(row.metricType == "HKQuantityTypeIdentifierOxygenSaturation")
        #expect(abs(row.value - 0.95) < 0.0001)
        #expect(row.unitString == "%")
        #expect(row.sourceBundleID == "com.emay.SleepO2")
        let expected = try #require(ISO8601DateFormatter().date(from: "2024-03-01T10:00:00Z"))
        #expect(row.timestamp == expected)
    }

    @Test("paging walks every page, advancing by rows RECEIVED not rows inserted")
    func quantitySamplePagingWalksAllPages() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Two full pages then a short one. Offsets must advance by the received
        // count; paging off the inserted count would re-request forever.
        let pageSize = SyncService.quantitySamplePageSize
        let total = pageSize * 2 + 3
        var requestedOffsets: [Int] = []

        let imported = try await SyncService.restorePagedQuantitySamples(
            serverURL: "http://sync.example.com",
            apiKey: "test-api-key",
            shift: 0,
            modelContext: context,
            performRequest: { request in
                let url = try #require(request.url)
                let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let offset = Int(comps.queryItems?.first { $0.name == "offset" }?.value ?? "0") ?? 0
                requestedOffsets.append(offset)

                let count = min(pageSize, max(0, total - offset))
                let rows = (0..<count).map { i -> [String: Any] in
                    let hex = String(format: "%012X", offset + i)
                    return Self.sampleRow(id: "0A1B2C3D-4E5F-4A6B-8C7D-\(hex)")
                }
                let page: [String: Any] = ["quantityHealthSamples": rows, "total": total]
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
                return (try JSONSerialization.data(withJSONObject: page), response)
            }
        )

        #expect(imported == total)
        #expect(requestedOffsets == [0, pageSize, pageSize * 2])
        #expect(try context.fetchCount(FetchDescriptor<QuantityHealthSample>()) == total)
    }

    @Test("a store holding only quantity samples is NOT considered empty")
    func quantitySamplesCountTowardTheRestoreGuard() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        #expect(SyncService.restoreGuardTablesAreEmpty(context), "baseline: empty store")

        _ = SyncService.importQuantityHealthSamples(
            [Self.sampleRow(id: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")], shift: 0, into: context
        )
        try context.save()

        // Samples are paged, so an interrupted restore can leave several pages of
        // them behind and nothing else. If the guard ignored this table, that
        // half-restored store would still look "empty" and a retry would re-page a
        // quarter-million rows on top of the ones already there.
        #expect(!SyncService.restoreGuardTablesAreEmpty(context),
                "a partially-restored store must block a second restore")
    }

    @Test("a server predating the endpoint (404) doesn't fail the whole restore")
    func quantitySamplePagingTolerates404() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let imported = try await SyncService.restorePagedQuantitySamples(
            serverURL: "http://sync.example.com",
            apiKey: "test-api-key",
            shift: 0,
            modelContext: context,
            performRequest: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 404, httpVersion: nil, headerFields: nil
                ))
                return (Data(), response)
            }
        )

        #expect(imported == 0, "an old server yields zero samples rather than a hard failure")
    }
}
