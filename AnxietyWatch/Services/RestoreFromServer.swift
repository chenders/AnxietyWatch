import Foundation
import SwiftData

/// Single source of truth for the `-autoRestoreFromServer` launch argument —
/// referenced by AnxietyWatchApp, SnapshotAggregator, and HRVSessionCardView
/// so the literal can't drift between call sites. The launch-argument flow
/// (and its date-shifted demo data) is simulator-debug-only; the type itself
/// compiles everywhere so gated call sites don't need their own literal.
enum RestoreDemoMode {
    static let launchArgument = "-autoRestoreFromServer"
    /// Evaluated once — launch arguments can't change mid-process.
    static let isActive = ProcessInfo.processInfo.arguments.contains(launchArgument)
}

/// Single source of truth for the `-seedDemoData` launch argument — seeds
/// synthetic, obviously-fictional data for README/marketing screenshots (see
/// `DemoSeeder`, DEBUG+simulator only). Kept alongside `RestoreDemoMode` so
/// `SnapshotAggregator`'s aggregation-skip guard can reference the literal
/// without a DEBUG-only symbol. Harmless in production (the arg is never set).
enum SeedDemoMode {
    static let launchArgument = "-seedDemoData"
    static let isActive = ProcessInfo.processInfo.arguments.contains(launchArgument)
}

/// First-launch migration gate: decides whether the app should defer
/// HealthKit setup (`HealthDataCoordinator.setupIfNeeded()`) and offer the
/// user a "Restore from Server vs Start Fresh" choice before any local
/// writes can trip the restore empty-store guard.
///
/// Why this exists: on a genuinely fresh install (the bundle-ID-rename
/// migration case), `setupIfNeeded()` would otherwise insert a HealthSnapshot
/// (backfill runs whenever `hasBackfilledSnapshots_v3` is unset) and start
/// barometer persistence (BarometricReading rows) within seconds of first
/// launch — long before a human can enter the server URL and tap Restore —
/// so `restoreGuardTablesAreEmpty` would ALWAYS refuse the restore this flow
/// exists to serve. The debug demo flow was protected by
/// `RestoreDemoMode.isActive` inside `aggregateDay` (DEBUG+simulator only);
/// this gate is that protection, productionized as an explicit decision.
enum RestoreMigrationGate {
    /// Set once the restore-vs-fresh decision is final: immediately on
    /// "Start Fresh", on the first successful `restoreFromServer()`, or
    /// automatically when the store is already non-empty at launch
    /// (existing users, who must never see the prompt or a deferred setup).
    static let decisionResolvedKey = "restoreDecisionResolved_v1"

    /// Pure decision core (extracted for testability): defer setup only
    /// while the decision is unresolved AND the store still looks fresh.
    static func shouldDeferSetup(storeIsEmpty: Bool, decisionResolved: Bool) -> Bool {
        !decisionResolved && storeIsEmpty
    }

    /// Launch-time evaluation. Returns true when the app should defer
    /// `setupIfNeeded()` and present the decision UI. A non-fresh store
    /// resolves the flag permanently as a side effect, so existing installs
    /// (including upgrades that predate the gate) never defer and never
    /// prompt. Reads the SwiftData store but never writes to it — the
    /// deferral check must not itself trip the guard it protects.
    @MainActor
    static func evaluateAtLaunch(context: ModelContext, defaults: UserDefaults = .standard) -> Bool {
        let resolved = defaults.bool(forKey: decisionResolvedKey)
        let storeIsEmpty = SyncService.restoreGuardTablesAreEmpty(context)
        guard shouldDeferSetup(storeIsEmpty: storeIsEmpty, decisionResolved: resolved) else {
            if !resolved {
                defaults.set(true, forKey: decisionResolvedKey)
            }
            return false
        }
        return true
    }

    static func resolve(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: decisionResolvedKey)
    }

    static func isResolved(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: decisionResolvedKey)
    }
}

extension Notification.Name {
    /// Posted after `restoreFromServer()` fully succeeds (rows saved, sync
    /// cursor advanced, migration gate resolved). `AnxietyWatchApp` listens
    /// so it can kick off the launch setup the `RestoreMigrationGate`
    /// deferred — restore first, backfill layered on top.
    static let serverRestoreCompleted = Notification.Name("serverRestoreCompleted")
}

enum RestoreError: Error, LocalizedError {
    case invalidJSON
    case storeNotEmpty

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Server response was not valid JSON"
        case .storeNotEmpty:
            return "Local store already contains data — restore only runs into an empty "
                + "store so it can't duplicate rows. On a fresh install, restore before "
                + "logging or importing anything."
        }
    }
}

extension SyncService {
    /// Pulls the server's full dataset (`GET /api/data`) and rebuilds the
    /// local SwiftData store from it. This is the production data-migration
    /// path for a fresh install (e.g. after a bundle-ID change wipes the
    /// container): the empty-store guard plus the #Unique-id merge semantics
    /// of the raw-sensor importers make the operation idempotent.
    ///
    /// - Parameter demoDateShift: Simulator-debug-only. When true (and the
    ///   build is DEBUG + simulator), all restored timestamps are shifted
    ///   forward so the most recent row aligns with today — purely a demo
    ///   convenience so a fresh simulator looks "current". Real migrations
    ///   MUST keep truthful timestamps: shifting medical data would corrupt
    ///   every day-keyed aggregate, baseline, and correlation downstream, and
    ///   a later second restore would re-shift rows by a different offset.
    ///   Release/device builds always restore with shift = 0 regardless of
    ///   this flag.
    /// - Parameter now: clock for the post-restore sync-cursor upper bound.
    ///   Injectable so tests can assert the cursor lands on the captured
    ///   bound. Defaults to `Date.now`.
    /// - Parameter performRequest: network transport for the /api/data GET.
    ///   Injectable so tests can run the full restore orchestration without
    ///   a live URLSession (mirrors `sync()`). Defaults to
    ///   `URLSession.shared.data(for:)`.
    /// - Parameter defaults: UserDefaults for the `RestoreMigrationGate`
    ///   resolution on success. Injectable for test isolation.
    @MainActor
    func restoreFromServer(
        modelContext: ModelContext,
        demoDateShift: Bool = false,
        now: @MainActor () -> Date = { Date.now },
        performRequest: (@MainActor (URLRequest) async throws -> (Data, URLResponse))? = nil,
        defaults: UserDefaults = .standard
    ) async throws -> String {
        guard isConfigured else { throw SyncError.notConfigured }
        guard Self.restoreGuardTablesAreEmpty(modelContext) else {
            throw RestoreError.storeNotEmpty
        }
        guard var components = URLComponents(string: serverURL) else { throw SyncError.invalidURL }
        components.path = "/api/data"
        guard let url = components.url else { throw SyncError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 180

        // Pin the sync cursor's upper bound BEFORE the download starts, per
        // the documented incremental-sync cursor rule (see CLAUDE.md and
        // `sync()`'s cursorUpperBound): records the user creates DURING the
        // round trip get timestamps greater than this bound, so the next
        // incremental sync still picks them up. Setting `.now` after the
        // trip would skip them forever. The cursor is assigned only after
        // the restore fully succeeds (see below).
        let restoreCursorUpperBound = now()

        let (data, response): (Data, URLResponse)
        if let performRequest {
            (data, response) = try await performRequest(request)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw SyncError.noConnection }
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.serverError(http.statusCode, String(data: data, encoding: .utf8))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RestoreError.invalidJSON
        }

        // Demo-only date shift: align the most-recent row with today so a
        // fresh sim looks "current" instead of every Dashboard card reading
        // "13 nights ago". Known tradeoff: the shift is a fixed
        // absolute-seconds offset, so rows on the far side of a DST
        // transition land ±1h off wall-clock — acceptable for demo data,
        // NEVER acceptable for a real migration. Production restores are
        // hard-wired to shift = 0 (truthful timestamps), which also keeps
        // restore idempotent — a blocked-then-retried restore on a later
        // day must not re-shift rows by a different offset.
        #if DEBUG && targetEnvironment(simulator)
        let demoShiftActive = demoDateShift
        #else
        let demoShiftActive = false
        #endif
        let shift = demoShiftActive ? Self.computeDateShift(json: json) : 0

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
        if let rows = json["barometricReadings"] as? [[String: Any]] {
            report["barometricReadings"] = Self.importBarometricReadings(rows, shift: shift, into: modelContext)
        }
        if let rows = json["pharmacies"] as? [[String: Any]] {
            report["pharmacies"] = Self.importPharmacies(rows, into: modelContext)
        }
        if let rows = json["prescriptions"] as? [[String: Any]] {
            report["prescriptions"] = (try? PrescriptionImporter.importRecords(rows, into: modelContext)) ?? 0
        }
        // After pharmacies so the `pharmacy` relationship can re-link by name.
        if let rows = json["pharmacyCallLogs"] as? [[String: Any]] {
            report["pharmacyCallLogs"] = Self.importPharmacyCallLogs(rows, shift: shift, into: modelContext)
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
        if let rows = json["accelSpectrograms"] as? [[String: Any]] {
            report["accelSpectrograms"] = Self.importAccelSpectrograms(
                rows, shift: shift, sessionMap: sessionIdMap, into: modelContext
            )
        }
        if let rows = json["derivedBreathingRates"] as? [[String: Any]] {
            report["derivedBreathingRates"] = Self.importDerivedBreathingRates(
                rows, shift: shift, sessionMap: sessionIdMap, into: modelContext
            )
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
            // Demo mode only: sleep events lag snapshots in prod (auto-sync
            // vs. manual import), so use a per-entity shift to land the most
            // recent sleep night on today — otherwise the LastNight card
            // can't find events for the latest snapshot. Production restores
            // keep truthful timestamps (shift 0), like every other entity.
            let sleepShift = demoShiftActive
                ? Self.computeMaxAlignedShift(rows: rows, dateKey: "start_time")
                : 0
            report["sleepStageEvents"] = Self.importSleepStageEvents(rows, shift: sleepShift, into: modelContext)
        }

        try modelContext.save()

        // QuantityHealthSample is deliberately NOT in the bulk /api/data
        // payload — it is ~250k rows / ~79 MB of JSON, which would blow up
        // both the response and the parsed [[String: Any]] held in memory.
        // It is paged down separately instead.
        //
        // This table used to sync UP but have no way back DOWN, so a fresh
        // install silently lost every EMAY oximetry sample. Those are app-only
        // (the app never writes to HealthKit), so unlike Apple/Polar/Dexcom
        // rows, nothing else can re-derive them — they were simply gone.
        report["quantityHealthSamples"] = try await Self.restorePagedQuantitySamples(
            serverURL: serverURL,
            apiKey: apiKey,
            shift: shift,
            modelContext: modelContext,
            performRequest: performRequest
        )

        // Post-restore re-aggregation: restored AccelSpectrogram /
        // DerivedBreathingRate rows never feed HealthSnapshot's
        // sensor-derived aggregates on their own — SnapshotAggregator runs
        // for today (and backfill gap-fill is capped and may run before the
        // restore), so historical days would show restored raw rows but nil
        // tremor/breathing/fidget averages forever. Re-run just the
        // sensor-derived block per affected day. Deliberately NOT a full
        // aggregateDay: HealthKit is typically empty right after a fresh
        // install, and a full re-aggregation would blank restored
        // HealthKit-derived fields with nils.
        report["sensorAggregatedDays"] = try Self.reaggregateSensorDerivedSnapshots(in: modelContext)
        try modelContext.save()

        // Everything imported and saved — finalize:
        // 1. Advance the sync cursor to the pre-download bound so the first
        //    sync after a restore is incremental. Without this, since == nil
        //    would take DataExporter's date-range path (which bypasses the
        //    per-row dirty flags) and re-POST the entire just-restored
        //    history back at the server.
        // 2. Resolve the restore-vs-fresh migration gate so the deferred
        //    HealthKit setup (backfill, observers, barometer) can begin.
        lastSyncDate = restoreCursorUpperBound
        RestoreMigrationGate.resolve(defaults: defaults)
        NotificationCenter.default.post(name: .serverRestoreCompleted, object: nil)

        return report
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
    }

    // MARK: - Empty-store guard

    /// One-shot guard: several importers (entries, doses, snapshots, CPAP,
    /// sensor sessions, songs) do not dedupe, so a restore into a non-empty
    /// store would silently duplicate rows. The proxy set must cover EVERY
    /// major table the restore writes — a store holding ONLY raw sensor rows
    /// (e.g. from a prior partial restore) is NOT empty, which is also what
    /// makes a second restore a hard no-op instead of a duplicate-and-reshift
    /// hazard. Name-deduped tables (medication definitions, pharmacies,
    /// prescriptions) are deliberately excluded: a fresh install may hold
    /// user-entered rows there, and their importers merge safely.
    /// PharmacyCallLog IS counted even though its importer dedupes: a call
    /// log implies real prior use of the device, exactly the "not actually
    /// fresh" signal this guard exists to detect (same reasoning as
    /// BarometricReading, whose importer also dedupes).
    /// `internal` so RestoreFromServerTests can exercise the guard directly.
    static func restoreGuardTablesAreEmpty(_ ctx: ModelContext) -> Bool {
        // A fetch error counts as NON-empty (fail closed): proceeding on an
        // unreadable store risks the duplication this guard exists to stop.
        func isEmpty<T: PersistentModel>(_ type: T.Type) -> Bool {
            ((try? ctx.fetchCount(FetchDescriptor<T>())) ?? Int.max) == 0
        }
        return isEmpty(AnxietyEntry.self)
            && isEmpty(HealthSnapshot.self)
            && isEmpty(SensorSession.self)
            && isEmpty(HRVReading.self)
            && isEmpty(BarometricReading.self)
            && isEmpty(AccelSpectrogram.self)
            && isEmpty(DerivedBreathingRate.self)
            && isEmpty(MedicationDose.self)
            && isEmpty(CPAPSession.self)
            && isEmpty(SleepStageEvent.self)
            && isEmpty(Song.self)
            && isEmpty(SongOccurrence.self)
            && isEmpty(PharmacyCallLog.self)
    }

    // MARK: - Post-restore re-aggregation

    /// Recompute `HealthSnapshot`'s sensor-derived aggregates
    /// (tremorBandPowerAvg / fidgetIndexAvg / breathingRateAvg) for every
    /// calendar day that holds AccelSpectrogram or DerivedBreathingRate rows,
    /// creating the day's snapshot when none exists. Runs after a restore,
    /// where the guard guarantees every such row was just imported. Touches
    /// ONLY the three sensor-derived fields (via
    /// `SnapshotAggregator.applySensorDerivedMetrics`) — restored
    /// HealthKit-derived fields are left exactly as the server sent them.
    /// Deliberately does NOT flip `syncedToServer` on the snapshots it
    /// touches: the three sensor-derived averages have no columns in the
    /// server schema (see `health_snapshots` in server/schema.sql) and are
    /// never synced, so recomputing them cannot make a snapshot dirty —
    /// marking it dirty would only cause a pointless full-row re-upload.
    /// Returns the number of days recomputed. `internal` for test access.
    @MainActor
    static func reaggregateSensorDerivedSnapshots(in ctx: ModelContext) throws -> Int {
        let calendar = Calendar.current
        var days = Set<Date>()
        for spectrogram in try ctx.fetch(FetchDescriptor<AccelSpectrogram>()) {
            days.insert(calendar.startOfDay(for: spectrogram.timestamp))
        }
        for rate in try ctx.fetch(FetchDescriptor<DerivedBreathingRate>()) {
            days.insert(calendar.startOfDay(for: rate.timestamp))
        }
        // Set iteration order is arbitrary — sort for deterministic writes.
        for day in days.sorted() {
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let existing = try ctx.fetch(
                FetchDescriptor<HealthSnapshot>(predicate: #Predicate { $0.date == day })
            )
            // Synthesizing a snapshot for a day the restore didn't bring one
            // is safe only because GET /api/data is UNPAGINATED: the response
            // carries the server's complete health_snapshots set, so a day
            // missing locally right after import is guaranteed missing
            // server-side too. If the endpoint ever paginates or windows its
            // export, this must re-check the server before creating rows —
            // otherwise a synthesized sensor-only snapshot would shadow the
            // server's real one (unique-date constraint) on a later restore.
            let snapshot = existing.first ?? HealthSnapshot(date: day)
            if existing.isEmpty {
                ctx.insert(snapshot)
            }
            try SnapshotAggregator.applySensorDerivedMetrics(
                to: snapshot, dayStart: day, dayEnd: end, context: ctx
            )
        }
        return days.count
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
            // SpO₂ source basis (F-092). Text columns — no median fill.
            snap.spo2AggregateSource = row["spo2_aggregate_source"] as? String
            snap.spo2BurdenSource = row["spo2_burden_source"] as? String
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

    /// `internal` (not private) so RestoreFromServerTests can verify a
    /// null-AHI (EDF-only) row still imports rather than being skipped (F-094).
    static func importCPAPSessions(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> Int {
        var n = 0
        for row in rows {
            guard let date = parseDate(row["date"]),
                  let usage = row["total_usage_minutes"] as? Int else { continue }
            // AHI is NULL for EDF-only nights (server stores null rather than a
            // fabricated 0, F-068). Import the row regardless — its leak/usage/
            // pressure are still valuable — carrying ahi through as nil rather
            // than skipping the whole session (the F-094 data-loss bug).
            let ahi = row["ahi"] as? Double
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
                importSource: (row["import_source"] as? String) ?? "oscar",
                // By-session fields (migration 0010): NULL means "source
                // didn't report" — carry through as nil, never coerce to 0.
                rdiEvents: row["rdi_events"] as? Double,
                reraEvents: row["rera_events"] as? Int,
                spo2Avg: row["spo2_avg"] as? Double,
                spo2Min: row["spo2_min"] as? Double,
                pulseAvg: row["pulse_avg"] as? Double,
                pressure95th: row["pressure_95th"] as? Double,
                leakAvg: row["leak_avg"] as? Double,
                leakMax: row["leak_max"] as? Double
            )
            ctx.insert(session)
            n += 1
        }
        return n
    }

    // MARK: - Quantity health samples (paged)

    /// Rows per page when restoring `QuantityHealthSample`. The server clamps
    /// to its own maximum; this is sized so a ~250k-row history restores in a
    /// few dozen round trips while each page stays a couple of MB.
    static let quantitySamplePageSize = 5000

    /// Pull `QuantityHealthSample` down page-by-page and insert it.
    ///
    /// Paged rather than bulk because this is by far the largest table (~250k
    /// rows / ~79 MB of JSON on a real device); inlining it in `/api/data`
    /// would make the response — and the parsed dictionary the app holds in
    /// memory — large enough to get the restore jetsammed. Each page is saved
    /// before the next is fetched so peak memory stays bounded.
    ///
    /// Tolerates a server that predates the endpoint (404) by returning what it
    /// has, so an app update can't hard-fail a restore against an older server.
    static func restorePagedQuantitySamples(
        serverURL: String,
        apiKey: String,
        shift: TimeInterval,
        modelContext: ModelContext,
        performRequest: (@MainActor (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> Int {
        var imported = 0
        var offset = 0
        var total: Int?

        while true {
            guard var components = URLComponents(string: serverURL) else { throw SyncError.invalidURL }
            components.path = "/api/data/quantityHealthSamples"
            components.queryItems = [
                URLQueryItem(name: "limit", value: String(quantitySamplePageSize)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            guard let url = components.url else { throw SyncError.invalidURL }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 180

            let (data, response): (Data, URLResponse)
            if let performRequest {
                (data, response) = try await performRequest(request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw SyncError.noConnection }
            // Older server without this entity — don't fail the whole restore.
            if http.statusCode == 404 { return imported }
            guard (200...299).contains(http.statusCode) else {
                throw SyncError.serverError(http.statusCode, String(data: data, encoding: .utf8))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["quantityHealthSamples"] as? [[String: Any]] else {
                throw RestoreError.invalidJSON
            }
            if total == nil { total = json["total"] as? Int }

            imported += Self.importQuantityHealthSamples(rows, shift: shift, into: modelContext)
            // Save per page: a quarter-million unsaved inserts in one context is
            // exactly the peak-memory shape that gets the app killed.
            try modelContext.save()

            // Advance by rows RECEIVED, not rows inserted — dedupe drops some
            // rows, and paging off the inserted count would re-request them
            // forever.
            offset += rows.count
            if rows.count < quantitySamplePageSize { break }
            if let total, offset >= total { break }
        }
        return imported
    }

    /// Insert restored quantity samples.
    ///
    /// Two non-obvious invariants, both load-bearing:
    /// - **The server's `id` is preserved.** `HealthDataCoordinator` mirrors
    ///   HealthKit using `sample.hkUUID` as the row id and does update-or-insert
    ///   on it. Minting fresh UUIDs here would make the first post-restore
    ///   HealthKit backfill re-insert every Apple/Polar/Dexcom sample as a
    ///   duplicate instead of matching the restored row.
    /// - **`syncedToServer` is `true`.** These rows came FROM the server, and
    ///   bulk types are exported on `syncedToServer == false` (not by the date
    ///   cursor), so the default `false` would make the next sync re-upload the
    ///   entire restored history.
    static func importQuantityHealthSamples(
        _ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext
    ) -> Int {
        var n = 0
        for row in rows {
            guard let idString = row["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let ts = parseDate(row["timestamp"]),
                  let metricType = row["metric_type"] as? String,
                  let value = row["value"] as? Double,
                  let unitString = row["unit_string"] as? String,
                  let sourceBundleID = row["source_bundle_id"] as? String else { continue }
            let groupID = (row["group_id"] as? String).flatMap(UUID.init(uuidString:))
            ctx.insert(QuantityHealthSample(
                id: id,
                timestamp: ts.addingTimeInterval(shift),
                metricType: metricType,
                value: value,
                unitString: unitString,
                sourceBundleID: sourceBundleID,
                sourceName: row["source_name"] as? String ?? "",
                deviceModel: row["device_model"] as? String,
                groupID: groupID,
                syncedToServer: true
            ))
            n += 1
        }
        return n
    }

    // MARK: - Barometric readings

    /// Barometric readings are the one restored table with NO other source of
    /// truth — they come from this app's own `CMAltimeter` capture and are not
    /// re-derivable from HealthKit, CPAP, or anything else. Losing them in a
    /// migration is permanent, which is why the restore path must carry them.
    /// The server PK is `timestamp` (see `barometric_readings` in schema.sql)
    /// and `BarometricReading` has no #Unique column, so dedupe by shifted
    /// timestamp to keep the importer idempotent like its #Unique-id siblings.
    /// `internal` (not private) for RestoreFromServerTests.
    static func importBarometricReadings(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> Int {
        var seenTimestamps = Set(
            ((try? ctx.fetch(FetchDescriptor<BarometricReading>())) ?? []).map(\.timestamp)
        )
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let pressure = row["pressure_kpa"] as? Double,
                  let altitude = row["relative_altitude_m"] as? Double else { continue }
            let shifted = ts.addingTimeInterval(shift)
            guard seenTimestamps.insert(shifted).inserted else { continue }
            ctx.insert(BarometricReading(
                timestamp: shifted,
                pressureKPa: pressure,
                relativeAltitudeM: altitude
            ))
            n += 1
        }
        return n
    }

    /// Returns (imported count, map of original server UUID string -> new local SensorSession UUID).
    /// HRVReading rows reference sensor_sessions.id; the map lets us re-link them after import.
    /// `internal` (not private) for RestoreFromServerTests.
    static func importSensorSessions(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> (Int, [String: UUID]) {
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

    /// `internal` (not private) for RestoreFromServerTests.
    static func importHRVReadings(_ rows: [[String: Any]], shift: TimeInterval, sessionMap: [String: UUID], into ctx: ModelContext) -> Int {
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

    /// `internal` (not private) for RestoreFromServerTests.
    static func importAccelSpectrograms(
        _ rows: [[String: Any]], shift: TimeInterval, sessionMap: [String: UUID], into ctx: ModelContext
    ) -> Int {
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let tremor = row["tremor_band_power"] as? Double,
                  let breathing = row["breathing_band_power"] as? Double,
                  let fidget = row["fidget_band_power"] as? Double,
                  let activity = row["activity_level"] as? Double else { continue }
            // session_id is nullable server-side; Watch-local session IDs
            // that never synced as sensor_sessions rows won't be in the map
            // and re-link to nil — matching importHRVReadings.
            let serverSessionID = row["session_id"] as? String
            let mappedSessionID = serverSessionID.flatMap { sessionMap[$0] }
            // Preserve the server UUID — AccelSpectrogram declares #Unique
            // on id, keeping the documented idempotency invariant.
            let serverID = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let spectrogram = AccelSpectrogram(
                id: serverID,
                timestamp: ts.addingTimeInterval(shift),
                tremorBandPower: tremor,
                breathingBandPower: breathing,
                fidgetBandPower: fidget,
                activityLevel: activity,
                sensorSessionID: mappedSessionID
            )
            spectrogram.syncedToServer = true
            ctx.insert(spectrogram)
            n += 1
        }
        return n
    }

    /// `internal` (not private) for RestoreFromServerTests.
    static func importDerivedBreathingRates(
        _ rows: [[String: Any]], shift: TimeInterval, sessionMap: [String: UUID], into ctx: ModelContext
    ) -> Int {
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let bpm = row["breaths_per_minute"] as? Double,
                  let confidence = row["confidence"] as? Double,
                  let source = row["source"] as? String else { continue }
            let serverSessionID = row["session_id"] as? String
            let mappedSessionID = serverSessionID.flatMap { sessionMap[$0] }
            // Preserve the server UUID — DerivedBreathingRate declares
            // #Unique on id, keeping the documented idempotency invariant.
            let serverID = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let rate = DerivedBreathingRate(
                id: serverID,
                timestamp: ts.addingTimeInterval(shift),
                breathsPerMinute: bpm,
                confidence: confidence,
                source: source,
                sensorSessionID: mappedSessionID
            )
            rate.syncedToServer = true
            ctx.insert(rate)
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

    /// The server's upsert key is `(timestamp, pharmacy_name)` — the PK of
    /// `pharmacy_call_logs` in server/schema.sql — and `PharmacyCallLog` has
    /// no #Unique column, so dedupe on that same pair (with the shifted
    /// timestamp) to keep the importer idempotent like its siblings. Must run
    /// AFTER `importPharmacies` so the `pharmacy` relationship can re-link by
    /// name; a log whose pharmacy no longer exists re-links to nil — the
    /// model denormalizes `pharmacyName` precisely so logs survive pharmacy
    /// deletion. `internal` (not private) for RestoreFromServerTests.
    static func importPharmacyCallLogs(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) -> Int {
        // Sorted fetch: Pharmacy has no #Unique on name, so two same-named
        // rows are possible; an unsorted fetch would make the "first wins"
        // collapse below nondeterministic (CLAUDE.md deterministic-ordering
        // pitfall). Sorting by id makes the tie-break stable across runs.
        let pharmacies = (try? ctx.fetch(FetchDescriptor<Pharmacy>(
            sortBy: [SortDescriptor(\.id)]
        ))) ?? []
        let pharmaciesByName = Dictionary(pharmacies.map { ($0.name, $0) }) { first, _ in first }
        var seen: [String: Set<Date>] = [:]
        for log in (try? ctx.fetch(FetchDescriptor<PharmacyCallLog>())) ?? [] {
            seen[log.pharmacyName, default: []].insert(log.timestamp)
        }
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let name = row["pharmacy_name"] as? String, !name.isEmpty else { continue }
            let shifted = ts.addingTimeInterval(shift)
            guard seen[name, default: []].insert(shifted).inserted else { continue }
            ctx.insert(PharmacyCallLog(
                timestamp: shifted,
                direction: (row["direction"] as? String) ?? "attempted",
                pharmacyName: name,
                notes: (row["notes"] as? String) ?? "",
                durationSeconds: row["duration_seconds"] as? Int,
                pharmacy: pharmaciesByName[name]
            ))
            n += 1
        }
        return n
    }
}
