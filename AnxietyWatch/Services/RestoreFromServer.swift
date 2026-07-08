#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftData

/// Single source of truth for the `-autoRestoreFromServer` launch argument —
/// referenced by AnxietyWatchApp, SnapshotAggregator, and HRVSessionCardView
/// so the literal can't drift between call sites.
enum RestoreDemoMode {
    static let launchArgument = "-autoRestoreFromServer"
    /// Evaluated once — launch arguments can't change mid-process.
    static let isActive = ProcessInfo.processInfo.arguments.contains(launchArgument)
}

enum RestoreError: Error, LocalizedError {
    case invalidJSON
    case storeNotEmpty

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Server response was not valid JSON"
        case .storeNotEmpty:
            return "Local store already contains data — restore is only for a fresh simulator. "
                + "Erase the simulator (Device → Erase All Content and Settings) and retry."
        }
    }
}

extension SyncService {
    @MainActor
    func restoreFromServer(modelContext: ModelContext) async throws -> String {
        guard isConfigured else { throw SyncError.notConfigured }
        // One-shot guard: the importers below do not dedupe most entity
        // types, so a second run would silently duplicate journal entries,
        // doses, sessions, and readings. Refuse unless the store is empty.
        let entryCount = (try? modelContext.fetchCount(FetchDescriptor<AnxietyEntry>())) ?? 0
        let snapshotCount = (try? modelContext.fetchCount(FetchDescriptor<HealthSnapshot>())) ?? 0
        let sessionCount = (try? modelContext.fetchCount(FetchDescriptor<SensorSession>())) ?? 0
        guard entryCount == 0, snapshotCount == 0, sessionCount == 0 else {
            throw RestoreError.storeNotEmpty
        }
        guard var components = URLComponents(string: serverURL) else { throw SyncError.invalidURL }
        components.path = "/api/data"
        guard let url = components.url else { throw SyncError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.noConnection }
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.serverError(http.statusCode, String(data: data, encoding: .utf8))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RestoreError.invalidJSON
        }

        // Shift all imported dates forward so the most-recent row aligns with
        // today. This makes a fresh sim look "current" with respect to the
        // dropoff in real-world logging activity, instead of every Dashboard
        // card reading "13 nights ago". Known tradeoff: the shift is a fixed
        // absolute-seconds offset, so rows on the far side of a DST
        // transition land ±1h off wall-clock — acceptable for demo data.
        let shift = Self.computeDateShift(json: json)

        var report: [String: Int] = ["shiftDays": Int(shift / 86_400)]

        if let rows = json["medicationDefinitions"] as? [[String: Any]] {
            report["medicationDefinitions"] = Self.importMedDefinitions(rows, into: modelContext)
        }
        if let rows = json["medicationDoses"] as? [[String: Any]] {
            report["medicationDoses"] = Self.importMedDoses(rows, shift: shift, into: modelContext)
        }
        if let rows = json["anxietyEntries"] as? [[String: Any]] {
            report["anxietyEntries"] = Self.importAnxietyEntries(rows, shift: shift, into: modelContext)
        }
        if let rows = json["healthSnapshots"] as? [[String: Any]] {
            report["healthSnapshots"] = Self.importHealthSnapshots(rows, shift: shift, into: modelContext)
        }
        if let rows = json["cpapSessions"] as? [[String: Any]] {
            report["cpapSessions"] = Self.importCPAPSessions(rows, shift: shift, into: modelContext)
        }
        if let rows = json["pharmacies"] as? [[String: Any]] {
            report["pharmacies"] = Self.importPharmacies(rows, into: modelContext)
        }
        if let rows = json["prescriptions"] as? [[String: Any]] {
            report["prescriptions"] = (try? PrescriptionImporter.importRecords(rows, into: modelContext)) ?? 0
        }

        var sessionIdMap: [String: UUID] = [:]
        if let rows = json["sensorSessions"] as? [[String: Any]] {
            let (n, map) = Self.importSensorSessions(rows, shift: shift, into: modelContext)
            report["sensorSessions"] = n
            sessionIdMap = map
        }
        if let rows = json["hrvReadings"] as? [[String: Any]] {
            report["hrvReadings"] = Self.importHRVReadings(rows, shift: shift, sessionMap: sessionIdMap, into: modelContext)
        }
        var songServerIDMap: [Int: Song] = [:]
        if let rows = json["songs"] as? [[String: Any]] {
            let (n, map) = Self.importSongs(rows, into: modelContext)
            report["songs"] = n
            songServerIDMap = map
        }
        if let rows = json["songOccurrences"] as? [[String: Any]] {
            report["songOccurrences"] = Self.importSongOccurrences(rows, shift: shift, songMap: songServerIDMap, into: modelContext)
        }
        if let rows = json["sleepStageEvents"] as? [[String: Any]] {
            // Sleep events lag snapshots in prod (auto-sync vs. manual import).
            // Use a per-entity shift so the most recent sleep night lands on
            // today regardless of the gap — otherwise the LastNight card
            // can't find events for the latest snapshot.
            let sleepShift = Self.computeMaxAlignedShift(rows: rows, dateKey: "start_time")
            report["sleepStageEvents"] = Self.importSleepStageEvents(rows, shift: sleepShift, into: modelContext)
        }

        try modelContext.save()

        return report
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
    }

    // MARK: - Per-entity importers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        if let d = iso.date(from: s) { return d }
        let fallback = ISO8601DateFormatter()
        if let d = fallback.date(from: s) { return d }
        // Bare dates ("2026-05-11") come from Postgres DATE columns
        // (health_snapshots.date, cpap_sessions.date) and represent LOCAL
        // calendar days. Parse in the local zone: parsing as UTC midnight
        // rolls back to the previous calendar day for any UTC-negative
        // user once the model layer applies startOfDay, desynchronizing
        // DATE-typed entities from TIMESTAMP-typed ones by a full day.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = .current
        return df.date(from: s)
    }

    private static func importMedDefinitions(_ rows: [[String: Any]], into ctx: ModelContext) -> Int {
        var n = 0
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty else { continue }
            let descriptor = FetchDescriptor<MedicationDefinition>(
                predicate: #Predicate { $0.name == name }
            )
            if (try? ctx.fetch(descriptor).first) != nil { continue }
            let def = MedicationDefinition(
                name: name,
                defaultDoseMg: (row["default_dose_mg"] as? Double) ?? 0,
                category: (row["category"] as? String) ?? "",
                isActive: (row["is_active"] as? Bool) ?? true
            )
            ctx.insert(def)
            n += 1
        }
        return n
    }

    /// Per-entity helper: shifts the entity's most recent row to today.
    private static func computeMaxAlignedShift(rows: [[String: Any]], dateKey: String) -> TimeInterval {
        var maxDate: Date?
        for row in rows {
            if let d = parseDate(row[dateKey]) {
                if maxDate == nil || d > maxDate! { maxDate = d }
            }
        }
        guard let maxDate else { return 0 }
        let today = Calendar.current.startOfDay(for: .now)
        let anchor = Calendar.current.startOfDay(for: maxDate)
        return today.timeIntervalSince(anchor)
    }

    private static func computeDateShift(json: [String: Any]) -> TimeInterval {
        var maxDate: Date?
        let candidateKeys: [(String, String)] = [
            ("anxietyEntries", "timestamp"),
            ("medicationDoses", "timestamp"),
            ("healthSnapshots", "date"),
            ("cpapSessions", "date")
        ]
        for (entity, field) in candidateKeys {
            guard let rows = json[entity] as? [[String: Any]] else { continue }
            for row in rows {
                if let d = parseDate(row[field]) {
                    if maxDate == nil || d > maxDate! { maxDate = d }
                }
            }
        }
        guard let maxDate else { return 0 }
        let today = Calendar.current.startOfDay(for: .now)
        let anchor = Calendar.current.startOfDay(for: maxDate)
        return today.timeIntervalSince(anchor)
    }

    private static func importMedDoses(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> Int {
        var n = 0
        let allDefs = (try? ctx.fetch(FetchDescriptor<MedicationDefinition>())) ?? []
        let defsByName = Dictionary(uniqueKeysWithValues: allDefs.map { ($0.name, $0) })

        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let name = row["medication_name"] as? String,
                  let mg = row["dose_mg"] as? Double else { continue }
            let dose = MedicationDose(
                timestamp: ts.addingTimeInterval(shift),
                medicationName: name,
                doseMg: mg,
                notes: row["notes"] as? String,
                isPRN: true,
                medication: defsByName[name]
            )
            ctx.insert(dose)
            n += 1
        }
        return n
    }

    private static func importAnxietyEntries(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> Int {
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let severity = row["severity"] as? Int else { continue }
            let tags = (row["tags"] as? [String]) ?? []
            let entry = AnxietyEntry(
                timestamp: ts.addingTimeInterval(shift),
                severity: severity,
                notes: (row["notes"] as? String) ?? "",
                tags: tags
            )
            ctx.insert(entry)
            n += 1
        }
        return n
    }

    /// Per-field medians across non-null values. Used to fill any null
    /// fields on individual snapshots so the demo Dashboard / Trends views
    /// don't show "—" for the most recent day when real recording was sparse.
    private static func computeMedians(rows: [[String: Any]]) -> [String: Double] {
        let fields = [
            "hrv_avg", "hrv_min", "resting_hr", "sleep_duration_min",
            "sleep_deep_min", "sleep_rem_min", "sleep_core_min", "sleep_awake_min",
            "skin_temp_deviation", "respiratory_rate", "spo2_avg",
            "spo2_nadir_overnight", "steps", "active_calories",
            "exercise_minutes", "environmental_sound_avg"
        ]
        var medians: [String: Double] = [:]
        for field in fields {
            var values: [Double] = []
            for row in rows {
                if let d = row[field] as? Double { values.append(d) }
                else if let i = row[field] as? Int { values.append(Double(i)) }
            }
            guard !values.isEmpty else { continue }
            values.sort()
            medians[field] = values[values.count / 2]
        }
        return medians
    }

    private static func importHealthSnapshots(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> Int {
        let medians = computeMedians(rows: rows)
        func dbl(_ row: [String: Any], _ k: String) -> Double? {
            if let v = row[k] as? Double { return v }
            if let v = row[k] as? Int { return Double(v) }
            return medians[k]
        }
        func intf(_ row: [String: Any], _ k: String) -> Int? {
            if let v = row[k] as? Int { return v }
            if let v = row[k] as? Double { return Int(v) }
            if let m = medians[k] { return Int(m) }
            return nil
        }
        var n = 0
        for row in rows {
            guard let date = parseDate(row["date"]) else { continue }
            let snap = HealthSnapshot(date: date.addingTimeInterval(shift))
            snap.hrvAvg = dbl(row, "hrv_avg")
            snap.hrvMin = dbl(row, "hrv_min")
            snap.restingHR = dbl(row, "resting_hr")
            snap.sleepDurationMin = intf(row, "sleep_duration_min")
            snap.sleepDeepMin = intf(row, "sleep_deep_min")
            snap.sleepREMMin = intf(row, "sleep_rem_min")
            snap.sleepCoreMin = intf(row, "sleep_core_min")
            snap.sleepAwakeMin = intf(row, "sleep_awake_min")
            snap.skinTempDeviation = dbl(row, "skin_temp_deviation")
            snap.skinTempWrist = row["skin_temp_wrist"] as? Double
            snap.respiratoryRate = dbl(row, "respiratory_rate")
            snap.spo2Avg = dbl(row, "spo2_avg")
            snap.spo2NadirOvernight = dbl(row, "spo2_nadir_overnight")
            snap.spo2NadirOpportunistic = row["spo2_nadir_opportunistic"] as? Double
            snap.spo2TimeBelow90Min = intf(row, "spo2_time_below_90_min")
            snap.spo2DesatsCount = intf(row, "spo2_desats_count")
            snap.steps = intf(row, "steps")
            snap.activeCalories = dbl(row, "active_calories")
            snap.exerciseMinutes = intf(row, "exercise_minutes")
            snap.environmentalSoundAvg = dbl(row, "environmental_sound_avg")
            snap.bpSystolic = row["bp_systolic"] as? Double
            snap.bpDiastolic = row["bp_diastolic"] as? Double
            snap.bloodGlucoseAvg = row["blood_glucose_avg"] as? Double
            snap.glucoseStdDev = row["glucose_std_dev"] as? Double
            snap.glucoseCV = row["glucose_cv"] as? Double
            snap.glucoseMin = row["glucose_min"] as? Double
            snap.glucoseMax = row["glucose_max"] as? Double
            snap.cpapAHI = row["cpap_ahi"] as? Double
            snap.cpapUsageMinutes = row["cpap_usage_minutes"] as? Int
            snap.barometricPressureAvgKPa = row["barometric_pressure_avg_kpa"] as? Double
            snap.barometricPressureChangeKPa = row["barometric_pressure_change_kpa"] as? Double
            if let dq = row["data_quality"] {
                if let dqString = dq as? String {
                    snap.dataQuality = dqString
                } else if let dqDict = dq as? [String: Any],
                          let dqData = try? JSONSerialization.data(withJSONObject: dqDict) {
                    snap.dataQuality = String(data: dqData, encoding: .utf8)
                }
            }
            snap.syncedToServer = true
            ctx.insert(snap)
            n += 1
        }
        return n
    }

    private static func importCPAPSessions(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> Int {
        var n = 0
        for row in rows {
            guard let date = parseDate(row["date"]),
                  let ahi = row["ahi"] as? Double,
                  let usage = row["total_usage_minutes"] as? Int else { continue }
            let session = CPAPSession(
                date: date.addingTimeInterval(shift),
                ahi: ahi,
                totalUsageMinutes: usage,
                leakRate95th: row["leak_rate_95th"] as? Double,
                pressureMin: (row["pressure_min"] as? Double) ?? 0,
                pressureMax: (row["pressure_max"] as? Double) ?? 0,
                pressureMean: (row["pressure_mean"] as? Double) ?? 0,
                obstructiveEvents: (row["obstructive_events"] as? Int) ?? 0,
                centralEvents: (row["central_events"] as? Int) ?? 0,
                hypopneaEvents: (row["hypopnea_events"] as? Int) ?? 0,
                importSource: (row["import_source"] as? String) ?? "oscar"
            )
            ctx.insert(session)
            n += 1
        }
        return n
    }

    /// Returns (imported count, map of original server UUID string -> new local SensorSession UUID).
    /// HRVReading rows reference sensor_sessions.id; the map lets us re-link them after import.
    private static func importSensorSessions(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> (Int, [String: UUID]) {
        var n = 0
        var map: [String: UUID] = [:]
        for row in rows {
            guard let serverIDString = row["id"] as? String,
                  let startStr = row["start_time"] as? String,
                  let startTime = parseDate(startStr) else { continue }
            let session = SensorSession(
                startTime: startTime.addingTimeInterval(shift),
                batteryAtStart: (row["battery_at_start"] as? Int) ?? 100
            )
            // Preserve the server's UUID so a restored session keeps its
            // identity (and so hrv_readings.session_id rows re-link 1:1).
            if let serverUUID = UUID(uuidString: serverIDString) {
                session.id = serverUUID
            }
            if let endStr = row["end_time"] as? String, let endTime = parseDate(endStr) {
                session.endTime = endTime.addingTimeInterval(shift)
            }
            session.source = row["source"] as? String
            if let summary = row["summary_json"] {
                if let str = summary as? String {
                    session.summaryJSON = str
                } else if let dict = summary as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: dict) {
                    session.summaryJSON = String(data: data, encoding: .utf8)
                }
            }
            session.syncedToServer = true
            ctx.insert(session)
            map[serverIDString] = session.id
            n += 1
        }
        return (n, map)
    }

    private static func importHRVReadings(_ rows: [[String: Any]], shift: TimeInterval, sessionMap: [String: UUID], into ctx: ModelContext) -> Int {
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let rmssd = row["rmssd"] as? Double,
                  let sdnn = row["sdnn"] as? Double,
                  let pnn50 = row["pnn50"] as? Double else { continue }
            let serverSessionID = row["session_id"] as? String
            let mappedSessionID = serverSessionID.flatMap { sessionMap[$0] }
            // Preserve the server UUID — HRVReading declares #Unique on id,
            // so passing it through keeps the documented idempotency
            // invariant instead of minting a fresh UUID per import.
            let serverID = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let reading = HRVReading(
                id: serverID,
                timestamp: ts.addingTimeInterval(shift),
                rmssd: rmssd,
                sdnn: sdnn,
                pnn50: pnn50,
                lfPower: (row["lf_power"] as? Double) ?? 0,
                hfPower: (row["hf_power"] as? Double) ?? 0,
                lfHfRatio: (row["lf_hf_ratio"] as? Double) ?? 0,
                sensorSessionID: mappedSessionID,
                source: row["source"] as? String
            )
            reading.syncedToServer = true
            ctx.insert(reading)
            n += 1
        }
        return n
    }

    /// Returns (count, map of server songs.id -> local Song instance).
    private static func importSongs(_ rows: [[String: Any]], into ctx: ModelContext) -> (Int, [Int: Song]) {
        var n = 0
        var map: [Int: Song] = [:]
        for row in rows {
            guard let serverID = row["id"] as? Int,
                  let title = row["title"] as? String,
                  let artist = row["artist"] as? String else { continue }
            let song = Song(
                title: title,
                artist: artist,
                album: row["album"] as? String,
                geniusId: row["genius_id"] as? Int,
                albumArtURL: row["album_art_url"] as? String,
                geniusURL: row["genius_url"] as? String
            )
            song.serverId = serverID
            song.lyrics = row["lyrics"] as? String
            song.lyricsSource = row["lyrics_source"] as? String
            ctx.insert(song)
            map[serverID] = song
            n += 1
        }
        return (n, map)
    }

    private static func importSongOccurrences(_ rows: [[String: Any]], shift: TimeInterval, songMap: [Int: Song], into ctx: ModelContext) -> Int {
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let songServerID = row["song_id"] as? Int else { continue }
            let occurrence = SongOccurrence(
                timestamp: ts.addingTimeInterval(shift),
                source: row["source"] as? String
            )
            occurrence.notes = row["notes"] as? String
            occurrence.song = songMap[songServerID]
            ctx.insert(occurrence)
            n += 1
        }
        return n
    }

    private static func importSleepStageEvents(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> Int {
        var n = 0
        for row in rows {
            guard let startStr = row["start_time"] as? String,
                  let endStr = row["end_time"] as? String,
                  let startTime = parseDate(startStr),
                  let endTime = parseDate(endStr),
                  let stage = row["stage"] as? String,
                  let bundleID = row["source_bundle_id"] as? String else { continue }
            // Preserve the server id — SleepStageEvent.id is documented as
            // "the HealthKit sample UUID, making sync end-to-end idempotent";
            // minting a fresh UUID would break that invariant for restored rows.
            let serverID = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let event = SleepStageEvent(
                id: serverID,
                startTime: startTime.addingTimeInterval(shift),
                endTime: endTime.addingTimeInterval(shift),
                stage: stage,
                sourceBundleID: bundleID,
                sourceName: (row["source_name"] as? String) ?? "",
                deviceModel: row["device_model"] as? String,
                syncedToServer: true
            )
            ctx.insert(event)
            n += 1
        }
        return n
    }

    private static func importPharmacies(_ rows: [[String: Any]], into ctx: ModelContext) -> Int {
        var n = 0
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty else { continue }
            let descriptor = FetchDescriptor<Pharmacy>(
                predicate: #Predicate { $0.name == name }
            )
            if (try? ctx.fetch(descriptor).first) != nil { continue }
            let pharmacy = Pharmacy(
                name: name,
                address: (row["address"] as? String) ?? "",
                phoneNumber: (row["phone_number"] as? String) ?? (row["phone"] as? String) ?? ""
            )
            ctx.insert(pharmacy)
            n += 1
        }
        return n
    }
}
#endif
