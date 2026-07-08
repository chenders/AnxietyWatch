# AnxietyWatch Codebase Atlas

Reference for humans and agents working on this codebase, anchored by symbol names so every claim can be verified with a grep or a jump-to-definition. Synthesized from a 16-cluster survey of the repository (iOS app, watchOS targets, Flask sync server, and tooling/CI perimeter) plus targeted gap-fill passes (recording pill, `MetricSalience`, `NotificationDelegate`); written as Phase 1 of the Fable 5 re-evaluation. The "Oddity index" and "Known-issue seeds" sections at the end seed Phase 2 investigations — the observations there are deliberately neutral, not verified defects.

## Table of contents

1. [How the data flows](#how-the-data-flows)
   - [Flow A: HealthKit → SnapshotAggregator → HealthSnapshot → Dashboard](#flow-a-healthkit--snapshotaggregator--healthsnapshot--dashboard)
   - [Flow B: Sensor session (Polar/EMAY/CPAP) → aggregation → Trends charts](#flow-b-sensor-session-polaremaycpap--aggregation--trends-charts)
   - [Flow C: App → SyncService → server → admin/analysis → RestoreFromServer](#flow-c-app--syncservice--server--adminanalysis--restorefromserver)
2. [Clusters](#clusters)
   - [HealthKit ingestion & daily aggregation](#healthkit-ingestion--daily-aggregation)
   - [Polar H10 HRV pipeline](#polar-h10-hrv-pipeline)
   - [CPAP & EMAY CSV import + SpO2 arbitration](#cpap--emay-csv-import--spo2-arbitration)
   - [Sync & restore](#sync--restore)
   - [Medications, pharmacy & prescriptions](#medications-pharmacy--prescriptions)
   - [Dashboard](#dashboard)
   - [In-app recording status pill](#in-app-recording-status-pill)
   - [Trends & charts](#trends--charts)
   - [Journal, labs, reports & songs](#journal-labs-reports--songs)
   - [Watch app, complications & Live Activities](#watch-app-complications--live-activities)
   - [Models layer (SwiftData schema)](#models-layer-swiftdata-schema)
   - [Server core & admin UI](#server-core--admin-ui)
   - [Server third-party sync clients & job dispatcher](#server-third-party-sync-clients--job-dispatcher)
   - [Server crypto, schema & auth](#server-crypto-schema--auth)
   - [Server analysis engine](#server-analysis-engine)
   - [Tooling & CI](#tooling--ci)
3. [Invariants registry](#invariants-registry)
4. [Oddity index](#oddity-index)
5. [Known-issue seeds](#known-issue-seeds)

---

## How the data flows

### Flow A: HealthKit → SnapshotAggregator → HealthSnapshot → Dashboard

Every physiological metric the Dashboard shows starts in HealthKit and passes through exactly one gate: the `HealthKitManager` actor (`Services/HealthKitManager.swift`), the only type permitted to touch HK APIs (project rule; `HealthKitDataSource` is the test seam, mocked by `MockHealthKitDataSource`). On launch, `HealthDataCoordinator.setupIfNeeded()` runs the ingestion sequence: `pruneOldSamples` → `startBarometerPersistence` → `backfillIfNeeded` (one-time, gated by UserDefaults key `hasBackfilledSnapshots_v3`) → `fillGaps` (every launch, ≤90 days) → `startObserving` → `mirrorHealthKitSamples` → `importClinicalRecordsIfNeeded`.

`mirrorHealthKitSamples()` copies `SampleCaptureRegistry.quantityMetrics` plus sleep into per-sample SwiftData mirrors — `QuantityHealthSample` and `SleepStageEvent`, both keyed by `HKSample.uuid` for idempotent upserts — using date anchors under `sampleAnchor.<rawIdentifier>` with a 48 h rolling lookback; the anchor advances to the pre-captured `now` only after `context.save()` succeeds. A parallel path (`bufferSamples`/`flushSampleBuffer` fed by `startAnchoredQueries`) fills the ephemeral 7-day `HealthSample` cache that powers dashboard sparklines.

`SnapshotAggregator.aggregateDay(_:)` then materializes one `HealthSnapshot` per calendar day (`#Unique` on `date`, normalized to `Calendar.current.startOfDay`): ~25 concurrent `async let` HK reads, sleep and overnight metrics over a **noon-to-noon** window (activity metrics midnight-to-midnight), SpO2 sufficiency gates (`minSamplesForOvernightStats` = 30 AND ≥300 s monitored), glucose gates (≥4 samples, ≥1 h spread), plus stitched-in SwiftData rows written by other subsystems (`CPAPSession`, `AccelSpectrogram`, `DerivedBreathingRate`, `BarometricReading`, EMAY `QuantityHealthSample`s). Source precedence is applied last: `applyOvernightSpO2Precedence` lets dedicated-oximeter samples (per `DeviceProvenance.overnightPulseOximeters`) exclusively determine overnight SpO2 aggregates while always writing `spo2NadirOpportunistic` for the Apple Watch contrast; `applyDailyHeartMetricsPrecedence` does the same for chest-strap HRV/RHR. `SnapshotFingerprint` gates `syncedToServer = false` + `pendingSyncVersion &+= 1` so unchanged re-aggregations don't re-upload.

The Dashboard consumes the result: `DashboardView` holds six `@Query`s (four bounded to a 30-day `startOfDay` cutoff captured in `init()`), feeds them to `DashboardViewModel` (`@MainActor @Observable`), which delegates the math to pure services — `BaselineCalculator` (MAD-trimmed 30-day baselines, ≥14 points), `SmartSummaryComposer` (z-score top-3 summary), `SleepEfficiencyCalculator` + `LastNightHeadline` (last-night hero verdict), `AlertsDeduper`, `SparklineData`, `PrescriptionSupplyCalculator` (supply alerts). On appear, `.task` closes the loop: `SnapshotAggregator.aggregateDay(.now)`, `SyncService.shared.sync(...)` auto-sync, and `PhoneConnectivityManager.shared.sendStatsToWatch(...)`.

### Flow B: Sensor session (Polar/EMAY/CPAP) → aggregation → Trends charts

**Polar H10.** `PolarHRMService` (`@MainActor @Observable`) owns the full CoreBluetooth lifecycle (restore identifier `com.anxietywatch.polar-h10`, 10-min reconnect grace via `scheduleReconnect`, launch recovery via `recoverInFlightSessionIfNeeded`). BLE 0x2A37 frames flow `PolarHRMParser.parse` → `RRTimestampBackprojection.project` (off-main) → `RRIntervalBuffer` (60 s trailing actor) + `RRArchiveWriter` (10-byte big-endian records at `Application Support/rr_archives/<sessionID>.rr`). Every minute, `HRVSessionRecorder.tick` flushes the buffer, filters RR to [250, 2000] ms, runs `HRVCalculator` (time domain ≥2 RR; frequency domain ≥30 RR, 4 Hz resample → `SpectralAnalyzer.computePSD`) and writes one `HRVReading` carrying `sensorSessionID` + `source == PolarHRMService.sourceLabel` (`"polar_h10"`). Finalize writes `summaryJSON` onto the `SensorSession` row. Three artifacts per session: `SensorSession`, `HRVReading` rows, and the `.rr` archive (UUID-linked).

**CPAP/EMAY.** `CSVImportRouter.importContent` sniffs the header and dispatches to `CPAPImporter` (simple/OSCAR formats → day-keyed `CPAPSession` upserts, AirSense clock-reset detection via `earliestPlausibleDate`) or `EMAYImporter` (1 Hz oximeter rows → `QuantityHealthSample` with `(timestamp, metricType)` dedup scoped to `sourceBundleID == "com.emay.SleepO2"`). CPAP imports trigger a snapshot backfill loop over the imported date range; both device families reach the charts *through* `HealthSnapshot` fields written by `SnapshotAggregator` (Flow A's precedence step).

**Aggregation for Trends.** `TrendsView` owns all `@Query`s and a `TrendWindow`-based paging window (day-aligned; `pageOffset == 0` end-inclusive, past pages end-exclusive). The Polar pipeline runs in-body: `LFHFAggregator.coalesce(sessions:gapTolerance: 45*60)` merges fragmented sessions into `CoalescedNight`s (id = first member UUID), the `overnightThresholdSeconds = 3*3600` gate filters to real nights, and `nightlyAggregates(from:coalescedNights:)` produces MAD-outlier-trimmed HF/SDNN/RMSSD means (`outlierTrimmedMean`, `robustUpperBound`; zero `lfPower`/`hfPower` is the no-data sentinel). Nights are bucketed by authoritative `SensorSession.startTime`, never first-reading timestamp. The ~9 `ChartCard`-wrapped charts (`HRVTrendChart`, `HeartRateTrendChart`, `HFPowerTrendChart`, `RMSSDTrendChart`, `SleepRespiratoryTrendChart`, `GlucoseTrendDatum`-fed glucose, steps, sleep, barometric) draw from pure datum-builder enums with `ChartPalette` tokens; every chart's `chartXScale` uses a +12 h-padded `dateRange` while non-visual consumers get the unpadded sibling (`HFPowerTrendChart.baselineAnchor`). Drill-down: tapping a night pushes `PolarSessionHRDetailView`, which replays the `.rr` archive via `RRArchiveAggregator.perMinuteHR(rrFiles:window:)` and overlays HK sleep-stage bands.

### Flow C: App → SyncService → server → admin/analysis → RestoreFromServer

`SyncService.sync(modelContext:)` is a `@MainActor` drain loop pushing SwiftData to the personal Flask server: it captures `cursorUpperBound = Date.now` **before** building the payload, assembles `buildPayload(...)` — the `DataExporter.exportJSON` bundle (small-volume tables, windowed by `lastSyncDate`) plus capped dirty-flag arrays (`quantitySamples`, `sleepStageEvents`, `sensorSessions`, `hrvReadings`, `healthSnapshots`, 1000-row `sampleBatchLimit`) tagged `syncSchemaVersion` (currently 4) — POSTs to `/api/sync`, then advances `lastSyncDate = cursorUpperBound` **only** on iterations that exported the small-volume tables (`!iterationIsBulkOnly`). Post-200: `extractUploadedSyncedIDs` re-parses the payload (never re-queries) so `markSamplesSynced`/`flagSnapshotsSynced` flip exactly what went on the wire (snapshots guarded by `pendingSyncVersion`); `uploadPendingRRArchives` POSTs zlib-compressed `.rr` blobs to `/api/sensor_sessions/<id>/rr_archive` (cursor `rrArchiveUploadedAt`); correlations, the song catalog (`SongService.fetchCatalog`), and prescriptions (`fetchPrescriptions` → `PrescriptionImporter`) are pulled back.

Server-side, `create_app` (`server/server.py`) handles `POST /api/sync` behind `require_api_key` (SHA-256-hashed Bearer tokens): ~16 `_upsert_*` helpers run in one transaction with schema-versioned COALESCE-vs-EXCLUDED clauses (v≥2 overnight stats, v≥3 `data_quality`), keyed on natural keys (`health_snapshots(date)`, `anxiety_entries(timestamp)`, …) or the iOS UUIDs. After commit, `correlations.compute_correlations` (Pearson over paired snapshot/anxiety days, `MINIMUM_PAIRED_DAYS = 12`) recomputes inline when stale and rides back in the response. Independent server-resident pullers (`resmed_sync.py`, `walgreens_sync.py`, `caprx_sync.py`) enrich `cpap_sessions`/`prescriptions` with source-discriminator upserts (`manual`/`sd_card` rows never overwritten). The admin blueprint (`server/admin.py`) provides API-key management, Fernet-encrypted scraper credentials (`crypto.encrypt_value`, PBKDF2 from `SECRET_KEY`), and launches Claude analyses: `analysis.start_analysis` → `job_dispatcher.create_analysis_jobs` (health_analysis → optional 4 conflict-research jobs → conflict_synthesis DAG) → `dispatch_analysis` polling ThreadPoolExecutor.

The return leg is `SyncService.restoreFromServer(modelContext:)` (`Services/RestoreFromServer.swift`, `#if DEBUG && targetEnvironment(simulator)`, gated by `RestoreDemoMode.isActive` / `-autoRestoreFromServer`): GET `/api/data`, refuse unless the store is empty (`RestoreError.storeNotEmpty`), shift all dates so the newest row lands today (`computeDateShift`, plus a separate per-entity `computeMaxAlignedShift` for sleep events), median-fill null snapshot fields, remap `sensor_sessions.id → HRVReading.sensorSessionID` and `songs.id → SongOccurrence.song`, and mark bulk rows `syncedToServer = true`.

---

## Clusters

### HealthKit ingestion & daily aggregation

**Purpose:** Pulls physiological data out of HealthKit and materializes it into SwiftData in two shapes — per-sample mirrors (`QuantityHealthSample`, `SleepStageEvent`, short-lived `HealthSample`) and one-row-per-day aggregates (`HealthSnapshot`). Handles first-launch backfill, per-launch gap fill, observer/anchored-query updates, BG refresh, and barometric capture. Everything downstream reads these SwiftData tables, never HealthKit directly.

**Key symbols:**
- `HealthKitManager` (actor) — sole HK touchpoint; conforms to `HealthKitDataSource` (test seam, `MockHealthKitDataSource`). Statistics (`averageQuantity`/`minimumQuantity`/`cumulativeQuantity`/`mostRecentQuantity`), raw samples (`quantitySamples`/`quantitySamplesWithSource`, `.strictStartDate` + end-clipped), `sleepStageEvents`, `querySleepAnalysis` (via `SleepIntervalMerger`), `averageBloodPressure` (HKCorrelation), `queryHeartbeatSeries`, `oldestSampleDate` (backfill horizon, HRV-based), `startObserving` (sleep-only HKObserverQuery), `startAnchoredQueries` (per `SampleTypeConfig.anchoredTypes`, anchors archived under `HKAnchor_<type>`). `isNoDataError` maps HK codes 5/11 to nil/empty.
- `HealthDataCoordinator` (`@Observable`) — orchestrator; `setupIfNeeded()` sequence above. `backfillIfNeeded()` gated by `hasBackfilledSnapshots_v3`; `gapDates(lastSnapshotDate:today:maxDays:)` pure, gap fill capped at 90 days; `mirrorHealthKitSamples()` (date-anchored mirror, `sampleAnchor.<id>` anchors, 48 h lookback = `SampleCaptureRegistry.mirrorLookbackInterval`, UUID-keyed upsert, field-change detection); `fetchInChunks` respects `SQLiteLimits.predicateBatchSize` (999); `bufferSamples`/`flushSampleBuffer` (2 s throttle, 500-cap) → `HealthSample`; `registerBackgroundTask`/`handleBackgroundRefresh` (BGAppRefreshTask `com.groundeffectsoftware.AnxietyWatch.refresh`). Exposes `isBackfilling`/`backfillProgress` for `BackfillOverlay`.
- `SnapshotAggregator.aggregateDay(_:)` — the per-day builder (Flow A); `applyOvernightSpO2Precedence`, `applyDailyHeartMetricsPrecedence` (chest-strap tier includes `fi.polar.polarflow` and `polar_h10`), `computeDataQuality` (`Reliability` tiers, `.sortedKeys` JSON), `SnapshotFingerprint` dirty gate.
- `BaselineCalculator` (enum) — pure rolling baselines over `[HealthSnapshot]`; `baseline(from:)` MAD trim (2.5 × 1.4826), N−1 variance, ≥14 values (`minimumSampleCount`); bounds = mean ± `Constants.deviationThreshold` × SD; per-metric wrappers (`hrvBaseline`, `spo2NadirBaseline`, `t90Baseline`, …).
- `BarometerService` (`@Observable` singleton) — CMAltimeter wrapper; pure `shouldCapture` (≥0.05 kPa delta OR ≥900 s) → `BarometricReading`.
- `SleepEfficiencyCalculator.compute(from:)` — pure efficiency/WASO from `SleepStageEvent`s; `inBedMinutes = max(inBedFromEvents, asleepMinutes)` pins efficiency ≤100%; `isBedTimeEstimated` flags the fallback ("~" UI contract); `gapTolerance: 0` (merger's 5-min default would hide real WASO).
- Support: `SampleCaptureRegistry`, `SampleTypeConfig.anchoredTypes`, `DeviceProvenance` (+ `partition(samples:metricType:)`, `Reliability`), `SleepIntervalMerger` (`mergedMinutes`, `coalesce`), `Statistics` (`timeBelowThresholdMinutes`, `countDesatEvents`, `collapseOverlaps`).

**Data flow:** In — HK samples/statistics, CMAltimeter, plus rows other subsystems wrote (`CPAPSession`, `AccelSpectrogram`/`DerivedBreathingRate`, `BarometricReading`, EMAY `QuantityHealthSample`). Out — `HealthSnapshot` (Dashboard, Trends, `BaselineCalculator`, `ReportGenerator`, `SyncService`), `QuantityHealthSample` + `SleepStageEvent` (precedence/quality logic + sync), `HealthSample` (7-day sparkline cache), `BarometricReading`. `aggregateDay` is invoked from `AnxietyWatchApp`, `DashboardViewModel`, `SettingsView.rebuildAllSnapshots` (own coordinator instance), `CPAPListView`, `TrendsView`; `RestoreDemoMode.isActive` short-circuits it in DEBUG+simulator.

**Invariants:**
- All HK access via `HealthKitManager` / `HealthKitDataSource`.
- Snapshot day identity: `HealthSnapshot.date == startOfDay` local time, exact `==` fetch.
- Overnight window = noon-previous-day → noon (sleep, skin temp, RR, SpO2); activity = midnight → midnight.
- `.strictStartDate` + end-clipping so a sample belongs to exactly one window; `averageQuantity` deliberately does NOT use it (glucose avg derived locally from `quantitySamples` to share boundary semantics with min/max/CV).
- Units: HK SpO2 fraction ×100 at assignment; HRV ms; glucose mg/dL; pressure kPa; temps °C.
- Mirror upsert identity = `HKSample.uuid` (unique, replay-idempotent); EMAY CSV rows use app UUIDs and never collide.
- Mirror cursor: capture `now` pre-query, advance only after save; failure bails without advancing; 48 h lookback catches retroactive HK corrections; changed-field guard prevents re-dirtying.
- `syncedToServer` flips false only on real field/fingerprint change (anti-re-upload-storm).
- Compound `#Predicate` avoidance: date-only predicates + in-memory `metricType` filtering (iOS 26).
- Source precedence layered on top of HK-direct values: empty preferred tier ⇒ HK values stand.
- Baselines ≥14 points, day-aligned windows; SpO2-nadir/T90 baselines anchor-date-bounded, others not.
- Sleep minutes merge overlapping intervals per stage before summing; `inBed` excluded from `totalMinutes`; `asleepUnspecified` counts as core.

Oddities: index #1–14.

### Polar H10 HRV pipeline

**Purpose:** BLE capture → RR archive → per-minute HRV → nightly aggregates (Flow B). Survives BLE drops (10-min grace, interruption tracking) and app termination (CB state restoration + session recovery).

**Key symbols:**
- `PolarHRMService` (`@MainActor @Observable`, ~1070 lines) — `CBCentralManager` owner; pairing persisted (`polarH10.peripheralUUID`/`.peripheralName`); `sourceLabel = "polar_h10"` canonical discriminator. `startSession()`/`stopSession()` (status → `.idle` *before* finalize so the sheet dismisses instantly); `tearDownResources()` (idempotent, closes open `SensorInterruption`s, returns (recorder, archive) for `finalizeOffline`); `scheduleReconnect` (backoff `[1,2,4,8,30,60×11]` s, capped by `reconnectGraceTotalSeconds` 600 s; `recordInterruption`/`closeInterruption` bracket gaps, at most one open); `recoverInFlightSessionIfNeeded()` (finalizes all but newest open session; stale >24 h or peripheral-less → `finalizeOrphan`, which passes empty `hrValues` so `hrMean == 0` gates it out of the HR trend chart); rehydration replays prior `HRVReading`s + the `.rr` archive.
- `PolarHRMState` — separate `@Observable` view state (status incl. `bluetoothOff/Unauthorized/Unsupported`, `currentHR`, `lastMinuteRMSSD`, `sessionElapsed`). `PolarBluetoothStateMapping.resolve(_:)` — pure CBManagerState mapping shared by three entry points.
- `PolarHRMParser.parse(_:)` — BT SIG 0x2A37 decode; RR 1/1024 s → ms. `RRTimestampBackprojection.project` — distributes packet RRs backward from arrival, off-main. `RRIntervalBuffer` (actor) — 60 s trailing window; `flush(at:)` evicts old **and future-timestamped** samples, non-destructive.
- `HRVSessionRecorder` (`@MainActor`) — per-minute `tick(at:)`: flush → artifact filter [250, 2000] ms → `HRVCalculator` off-main via `Task.detached` → re-validate session after **each** await → one `HRVReading`; accumulates `rmssdValues`/`hrValues`/`totalRRCount`/`skippedMinutes` for `finalize(at:)` → `buildSummaryJSON`; recovery init; `rehydratedHRValues` O(N+M) two-pointer.
- `HRVCalculator` — `timeDomain` (≥2 RR), `frequencyDomain` (≥30 RR, 4 Hz linear resample, detrend, LF 0.04–0.15 Hz / HF 0.15–0.40 Hz, ratio 0 when hf ≤ 0). `SpectralAnalyzer.computePSD` — vDSP FFT, Hann window, one-sided 2/N² normalization.
- `RRArchiveWriter` — 10-byte records (uint64 epoch-ms, uint16 rrMs), 64 KB buffered; `init(url:append:true)` recovery; `recordCount(url:)`/`read(url:)` (`.truncatedArchive` on misalignment).
- `LFHFAggregator` — `coalesce` (45-min gap tolerance → `CoalescedNight`, id = first member UUID, `wearTimeSeconds` excludes gaps), `overnightThresholdSeconds = 3*3600` (single source of truth), `nightlyAggregates`, `nightlyHRFromSummaries`, `outlierTrimmedMean` (MAD ×5×1.4826, floor 3× median), `robustUpperBound` (p95 ×1.15), `hfBaseline` (30-day, ≥3 nights, `startOfDay` cutoff), `belowBaselineThreshold = -0.15`, `hasFrequencyData` (both powers > 0).
- `RRArchiveAggregator.perMinuteHR(rrFiles:window:)` — archive replay → per-minute BPM (half-open buckets, BPM pre-clip [30, 220] → nil gap, deterministic UUIDs from bucket timestamps).
- Adjacent: `AccelerometerProcessor` (watch tremor/breathing/fidget bands, shares `SpectralAnalyzer`), `LiveActivityCoordinator` + `LiveActivityUpdateThrottle` + `HRVRecordingActivityAttributes` (see watch cluster).

**Data flow:** In — BLE notifications → parse → backproject → main-actor hop → buffer + archive in parallel. Per minute — `PolarHRMService.scheduleTicks` (Task.sleep loop, not Timer, so UI scrolling can't stall it) → `tick` → `HRVReading`. Out — `SensorSession` (`summaryJSON`: rmssdMean/min/max, hrMean, rrCount, durationSec, gapFraction, interruptionCount, skippedMinutes) + `HRVReading` rows (both `syncedToServer`-flagged) + `.rr` archive (UUID is the only shared state between writer, `SyncService.uploadPendingRRArchives`, and chart replayer). Consumers: `TrendsView` (coalesce → overnight filter → aggregates), `DashboardViewModel` (device chips), `LiveActivityCoordinator`.

**Invariants:**
- RR units ms everywhere post-parser; [250, 2000] ms filter repeated at every consumption point (tick, rehydration, `RRArchiveAggregator`).
- `source == "polar_h10"` discriminates on `SensorSession` and `HRVReading`; legacy/Watch rows nil; typed constant outside `#Predicate`.
- `lfPower == 0 || hfPower == 0` = "window too sparse", never a measurement; `hrMean == 0` in summaryJSON = "unknown".
- Nightly aggregation anchors to `SensorSession.startTime` / `CoalescedNight.startTime`, never earliest reading (readings lag ≤60 s — matters near midnight).
- At most one open `SensorInterruption` per session; at most one recoverable open session per source.
- Archive byte count multiple of 10; `recordCount` returns 0 for misaligned files.
- Deterministic ordering: nightly series sort `(night, id.uuidString)`; stable chart datum IDs.
- `tick` re-checks `session.endTime == nil` (explicit unwrap) after every await; recorder commits to `self` only after `start()` succeeds.
- CB delegate callbacks `nonisolated`, hop to `@MainActor`, verify `peripheral?.identifier` to drop stale callbacks.
- `beginRecording` gated on `didUpdateNotificationStateFor` — no `SensorSession` for a failed subscription.

Oddities: index #15–25.

### CPAP & EMAY CSV import + SpO2 arbitration

**Purpose:** External-CSV ingest for ResMed AirSense summaries (→ `CPAPSession`) and EMAY SleepO2 1 Hz oximeter exports (→ `QuantityHealthSample`), via a format-sniffing router with two entry points; plus the source-fidelity arbitration layer (`DeviceProvenance` + `SnapshotAggregator.applyOvernightSpO2Precedence`) deciding which source wins when a dedicated oximeter/chest strap and Apple Watch overlap.

**Key symbols:**
- `CSVImportRouter.importContent(_:into:)` — sniffs first non-empty header (BOM-stripped, lowercased), dispatches, reads the file exactly once, wraps errors/results into `CSVImportRouter.Result` (`kind: .cpap | .emay`); `nonisolated`, runs in `Task.detached`. `isEMAYFormat` requires `date,time,spo2` prefix AND `pr(bpm)` so other brands hit `.unrecognizedFormat`.
- `CPAPImporter` — `importContent` auto-detects simple (10-col) vs OSCAR (37+ col) via `isSimpleFormat`/`isOSCARFormat`; upserts by day; `prefetchSessions(in:)` dictionary keyed by start-of-day date, duplicates resolved (highest usage, lowest AHI) to match `SnapshotAggregator`; `earliestPlausibleDate` (Jan 1 2015 fixed Gregorian) + `clockResetWarning(count:)` flag the AirSense ~2009-epoch clock-reset symptom (flagged, not blocked).
- `EMAYImporter` — two-pass (parse + collect window, then window-scoped dedup prefetch + insert); each row fans out to ≤2 `QuantityHealthSample`s (SpO2 fraction 0–1 unit `"%"`; pulse `"count/min"`); `sourceBundleID = "com.emay.SleepO2"` (CSV-only tag, distinct from `"com.emay.oximeter"` which the EMAY iOS app writes to HK); `ParseOutcome.sensorGap` counts probe-off rows separately (all-gaps file = zero-insert success, not `.noData`).
- `ImportSkipTracker` — skip diagnostics, caps warnings at 5 + "… and N more". `CSVImportPresentation.swift` — `Result.summarySentence`/`.alertMessage`, `MultiFileImportAlert.compose(results:errors:)`; all alert text lives here.
- `DeviceProvenance` — `overnightPulseOximeters`, `csvOnlySpO2Bundles` (both EMAY CSV case variants), `chestStrapHRMonitors`, `appleEcosystemSources`, `medicalGradeBPCuffs`; `highFidelitySources(for:)`, `partition(samples:metricType:)`. `Reliability` — per-metric daily tiers.
- `SnapshotAggregator.applyOvernightSpO2Precedence(on:overnightStart:overnightEnd:)` — unions SwiftData rows with a conditional live-HK fetch (skipped only when a *non*-CSV-only row proves mirror coverage), partitions by provenance, preferred tier exclusively determines avg/nadir/T90/desats; always sets `spo2NadirOpportunistic`.
- `AnxietyWatchApp.handleIncomingFile(_:)`/`processImportBatch(_:)`/`runImports(urls:in:)` — share-sheet entry: debounce-coalesced batches, fresh `ModelContext` per file, unioned CPAP date ranges → one snapshot backfill. `CPAPListView.handleImport` — single-file `.fileImporter` entry.
- `QuantityHealthSample` — `#Index([\.sourceBundleID, \.timestamp])`; HK rows use `HKSample.uuid` as `id`; CSV rows use app UUIDs + `(sourceBundleID, timestamp, metricType)` dedup. `CPAPSession` — `#Unique([\.date])`, start-of-day-normalized in `init`; `importSource` raw string behind a `source` enum.

**Data flow:** In — security-scoped CSV URLs from either entry point → router → importers → SwiftData. Out — `Result` → alert text; CPAP `dateRange` → `backfillSnapshots` → `SnapshotAggregator.aggregateDay` per day (CPAP-only). Sideways — the SpO2 precedence path (Flow A) lands on `HealthSnapshot.spo2Avg/spo2NadirOvernight/spo2NadirOpportunistic/spo2TimeBelow90Min/spo2DesatsCount`. Tests: `CPAPImporterTests`, `EMAYImporterTests`, `CSVImportRouterTests`, `MultiFileImportAlertTests`, `DeviceProvenanceTests`.

**Invariants:**
- Read-once dispatch: router reads content once; importers' own `importCSV(from:)` file entries exist but the router path never re-reads.
- CPAP uniqueness = one session per calendar day (`init` normalization + prefetch upsert + `#Unique`); re-import overwrites in place (`updateSession`), never duplicates.
- EMAY idempotency: `(timestamp, metricType)` scoped to the CSV bundle, window-prefetched; deliberately does NOT dedupe against the EMAY app's HK writes — double-count by design (documented in precedence step 3).
- Units: SpO2 fraction 0–1, ×100 at snapshot write; AHI events/hour; usage whole minutes; OSCAR `Total Time` truncates seconds; EMAY zeros → nil, never stored.
- Dates: CPAP `yyyy-MM-dd` en_US_POSIX device-local midnight; EMAY `M/d/yyyy h:mm:ss a` with `TimeZone.current`; `earliestPlausibleDate` fixed-Gregorian by design.
- CSV-only bundle gate: a `csvOnlySpO2Bundles` row means "user imported a CSV", not "mirror covered this window" — the load-bearing May 12 fresh-install fix (Watch off-finger artifact shown as oximeter nadir).
- Precedence: preferred samples exclusively determine aggregates; opportunistic nadir always recorded; no preferred coverage ⇒ HK-direct values untouched.
- Error taxonomy: nothing parseable → `.noData`; all-deduped / all-sensor-gaps → zero-insert success.
- Whole import stack `nonisolated` + `Task.detached` + fresh `ModelContext` per file; `Result` types `Sendable`.

Oddities: index #26–35.

### Sync & restore

**Purpose:** Push-only mirror of SwiftData to the personal Flask+Postgres server ("app is source of truth; server is a mirror"), pull-back of server-authored datasets (correlations, songs, prescriptions), a DEBUG/simulator-only restore path, and the Watch relay (`PhoneConnectivityManager`).

**Key symbols:**
- `SyncService` — `@Observable` singleton; config (`serverURL`, `apiKey`, `autoSyncEnabled`, `lastSyncDate`) as stored `var`s mirrored to UserDefaults via `didSet` (stored, not computed, so `@Observable` tracks them).
- `SyncService.sync(modelContext:)` — drain loop (Flow C); loops while any bulk type hit `sampleBatchLimit` (1000), hard-capped at `maxRoundTrips` (deliberate constant reuse of `sampleBatchLimit`); iteration 1 carries small-volume tables via `DataExporter.exportJSON`, iterations 2+ are `bulkOnly` and do NOT advance `lastSyncDate`.
- `buildPayload(from:demographics:upperBound:bulkOnly:)` — DataExporter bundle + capped dirty-flag arrays + `syncSchemaVersion` (4) + `syncType` full/incremental + demographics.
- `extractUploadedSyncedIDs(from:)` / `UploadedSyncedIDs` — re-parses the just-built payload so flagging marks exactly what went on the wire; `healthSnapshotDates` + index-aligned `healthSnapshotVersions`; `hitBulkLimit(_:)` continue signal.
- `applyPostUploadResponse(...)` — `markSamplesSynced`, RR uploads, correlation upsert (`upsertCorrelations`, delete-if-absent only when server returned non-empty), song-catalog pull; a flag failure (`PostUploadOutcome.flaggingSucceeded == false`) breaks the drain loop to avoid perpetual re-upload.
- `markSamplesSynced`/`flagSyncedInChunks` — batched flips (`SQLiteLimits.predicateBatchSize`), generic over `SyncableSample` (`QuantityHealthSample`, `SleepStageEvent`, `SensorSession`, `HRVReading`). `flagSnapshotsSynced` — by `date` (server PK), range-bounded two-`Date`-clause predicate + in-memory `!syncedToServer` filter; skips rows whose `pendingSyncVersion` advanced mid-flight.
- `uploadPendingRRArchives`/`postRRArchive` — zlib POST per session; `rrArchiveUploadedAt` nil = retry. `fullSync` — clears `lastSyncDate` after all guards pass. `fetchPrescriptions` → `PrescriptionImporter.importRecords`.
- `SongService` — stateless enum client sharing `SyncService.shared` config; `fetchCatalog(into:)` (upsert `serverId` then `geniusId`), `search(query:)`, `addByGeniusId`.
- `RestoreDemoMode` (`Services/RestoreFromServer.swift`, `#if DEBUG && targetEnvironment(simulator)`) — single source of `-autoRestoreFromServer`; referenced by `AnxietyWatchApp`, `SnapshotAggregator`, `HRVSessionCardView`. `SyncService.restoreFromServer(modelContext:)` — see Flow C; `parseDate(_:)` three-tier (fractional ISO → plain ISO → bare `yyyy-MM-dd` in **local** timezone, since Postgres DATE columns are local calendar days).
- `PhoneConnectivityManager` — iPhone `WCSessionDelegate`; `handleIncoming` inserts Watch `AnxietyEntry`s (hops to `@MainActor`); `session(_:didReceive file:)` decodes `SensorTransferPayload`; `sendStatsToWatch`/`updateCheckInContext` push applicationContext.

**Data flow:** Out — SwiftData → export + dirty-flag fetches → `POST /api/sync` (Bearer); RR archives separate binary POST. In — correlations → `PhysiologicalCorrelation`; song catalog; prescriptions; `/api/data` (restore) → 13 entity importers. Triggers — `DashboardViewModel.autoSync`, `SyncSettingsView` manual, `AnxietyWatchApp` `.task` (auto-restore + `SyncService.backfillMedicationLinks` every launch). Watch — `WatchConnectivityManager` → `PhoneConnectivityManager` → SwiftData; stats back via applicationContext.

**Invariants:**
- Cursor: `cursorUpperBound = Date.now` captured **before** payload build; assigned only on `!iterationIsBulkOnly` iterations; never `= .now` after I/O (regression tests `SyncServiceTests.payloadUpperBoundCapsExportRange`, `payloadBulkOnlyOmitsSmallVolumeTables`; Semgrep ERROR rule).
- Two disjoint progress mechanisms: bulk types via `syncedToServer == false` predicates; small-volume via the `lastSyncDate`/`upperBound` window.
- Flag exactly what was uploaded: IDs from re-parsing the payload, never a re-query.
- Snapshot identity is `date`, compared as absolute `Date` equality with NO `startOfDay` re-normalization (timezone-travel-safe). Two ISO formatters coexist deliberately: fractional `isoFormatter` for samples, whole-second `snapshotDateFormatter` for snapshot dates (matches `DataExporter.isoFormatter`).
- Snapshot race guard: `_pendingSyncVersion` (client-internal, server ignores) captured at fetch; mismatch leaves the row dirty; `-1`/absent = no check (full-sync path).
- `source` non-null on the server (schema 0005): nil → sentinel `"unknown"`. Wire key for HRV session FK is `sessionId`, not `sensorSessionID`.
- `syncSchemaVersion` governs server conflict semantics (v3+: missing `dataQuality` = intentional clear); bumps documented inline in `buildPayload`.
- Restore preserves server UUIDs for `SensorSession`, `HRVReading`, `SleepStageEvent`; restored rows inserted `syncedToServer = true`.
- `flagSnapshotsSynced` keeps its compound `#Predicate` to two `Date` clauses (primitive-only); `Set<Date>.contains` in `#Predicate` avoided (silent zero-row matches on some iOS 17/18 builds).

Oddities: index #36–45.

### Medications, pharmacy & prescriptions

**Purpose:** Medication life-cycle: definitions, dose logging (optional anxiety-rating prompt + 30-min follow-up notification), prescriptions (manual / OCR scan / server import), supply estimation and run-out alerts, pharmacies (MapKit search, CallKit call logging). Feeds `AnxietyEntry` records that contextualize the physiological data.

**Key symbols:**
- Models: `MedicationDefinition` (`promptAnxietyOnLog: Bool?` nil→false), `MedicationDose` (`medicationName` denormalized; `isPRN: Bool?` nil→**true**), `Prescription` (`rxNumber` upsert key; PBM fields `daysSupply`, `patientPay`, `planPay`, `ndcCode`, `lastFillDate`, `walgreensRxId`, `importSource`; denormalized `medicationName`/`pharmacyName`), `Pharmacy`/`PharmacyCallLog` (string `direction` + `Direction` enum via `callDirection`). All parent relationships `.nullify`.
- `PrescriptionSupplyCalculator` (stateless enum) — `effectiveRunOutDate(for:)` precedence: PBM `daysSupply` > stored `estimatedRunOutDate` > quantity ÷ `dailyDoseCount`; `supplyStatus(for:now:)` (`.good` >14d / `.warning` 7–14d / `.low` <7d / `.expired` / `.unknown`, `startOfDay` both ends); `alertPrescriptions(from:now:)` — shared Dashboard/MedicationsHub filter: latest fill per medication name, staleness cutoff (`alertStalenessLimitDays` = 2× supply, floor 60 d), skips inactive meds; `inferDailyDoseCount(for:doses:windowDays:)`.
- `PrescriptionImporter` (stateless enum) — `importRecord(_:into:)` upserts by `rxNumber`; `update(...)` fills only-empty fields but always overwrites `daysSupply`/`patientPay`/`planPay`; `findOrCreateMedication(name:doseMg:in:)` exact predicate then full-table case-insensitive fallback (SwiftData predicates can't lowercase), reactivating inactive matches. Server `importSource` defaults `"caprx"`.
- `PrescriptionLabelScanner` (stateless enum) — Vision OCR (`.accurate`) + pure `parse(lines:)` regex parser (Rx#, qty, refills, dose, date); `detectPharmacyName` (chain list + uppercase-ratio heuristic); `detectMedicationName` (longest unclaimed line).
- `PharmacySearchService.search(query:region:)` — `MKLocalSearch` `.pharmacy` POIs → `PharmacySearchResult`.
- `PharmacyCallService` (`@Observable` singleton) — `initiateCall(to:modelContext:)` opens `tel:`, logs "attempted", upgrades via `CXCallObserverDelegate` to "connected"/"completed" (+duration); 30 s timeout; `logManualCall` writes "incoming"/"outgoing".
- `DoseFollowUpManager` (stateless enum, `Utilities/`) — 30-min follow-ups; pending list JSON in UserDefaults (`pendingDoseFollowUps`); `pendingFollowUpIfDue`/`cleanupStale` (2 h) called from `AnxietyWatchApp.checkPendingFollowUp()` on scene-active.
- `NotificationDelegate` (`App/NotificationDelegate.swift`, ~30 lines) — the app's `UNUserNotificationCenterDelegate` and the middle hop of the follow-up loop: `DoseFollowUpManager` schedules → **NotificationDelegate surfaces/relays** → `AnxietyWatchApp.checkPendingFollowUp()` presents. Two load-bearing behaviors: `willPresent` returns `[.banner, .sound]` unconditionally for every notification (without a delegate, iOS silently suppresses foreground local notifications — dose follow-ups and random check-ins would appear to "do nothing" for a foregrounded user; `.list` omitted, so foreground-presented notifications don't persist in Notification Center); `didReceive` posts `.didTapLocalNotification` (declared in an extension at the bottom of this file) with `object: nil` — no discrimination on identifier, category, or action. Held as a stored property on `AnxietyWatchApp` (required — `UNUserNotificationCenter.delegate` is weak) and assigned in the `@MainActor init()` before launch finishes, alongside BGTask registration. Upstream producers: `DoseFollowUpManager.scheduleFollowUp` (`"dose-followup-<uuid>"`) and `RandomCheckInManager` (category `"RANDOM_CHECKIN"`).
- Views: `MedicationsHubView` (tab root), `DoseAnxietyPromptView` (creates `AnxietyEntry(triggerDose:isFollowUp:)`), `AddPrescriptionView` (prefill init + inline med creation + scanner sheet), `PrescriptionListView` ("Fetch from Server" via `SyncService.shared.fetchPrescriptions`), `PrescriptionScannerView`, `PharmacyListView`/`PharmacyDetailView`/`PharmacySearchView`/`AddPharmacyView`.

**Data flow:** In — server (`fetchPrescriptions`, launch-time `SyncService.backfillMedicationLinks`), OCR (scan → reviewed `ScannedPrescriptionData` → prefill, mcg→mg ÷1000, mL → doseMg 0), MapKit. Out — `MedicationDose` + optional `AnxietyEntry`; `UNUserNotificationCenter`; supply alerts to both surfaces; outbound sync via `SyncService.sync()`. Notification-tap hop — `.didTapLocalNotification` has exactly one consumer: `AnxietyWatchApp.body`'s `.onReceive` → `checkPendingFollowUp()`, which re-derives what to show from `DoseFollowUpManager.pendingFollowUpIfDue()` + SwiftData fetches (it does NOT trust the notification itself) before setting `followUpDose`/`followUpMedication` to drive the `DoseAnxietyPromptView` sheet. The same check also runs on `scenePhase == .active` and a 60 s foreground timer, so the tap hop is an acceleration path, not the sole trigger — a broken delegate degrades to "sheet appears late" for background taps but to "notification never visible" for foreground users.

**Invariants:**
- `Prescription.rxNumber` de-facto unique key (importer upserts; `AddPrescriptionView.canSave` requires non-empty); nothing enforces uniqueness for manual entries.
- Run-out precedence fixed as documented; importer computes the same chain when the server omits `estimated_run_out_date`.
- All day-remaining math `startOfDay`-wrapped on both ends.
- Alerts consider only the latest fill per `medicationName` (`latestPrescriptionPerMedication`), keyed by `lastFillDate ?? dateFilled` everywhere.
- Denormalized names are the survival copies on parent deletion; `medication-name-drift-warn.py` hook watches drift.
- Migration nils: `isPRN` nil→true, `promptAnxietyOnLog` nil→false, `AnxietyEntry.isFollowUp` nilable.
- `DoseFollowUpManager`: one pending per doseID; identifier `"dose-followup-<uuid>"`; >2 h stale purged; completion detected in-memory in `checkPendingFollowUp` (deliberately not a compound `#Predicate`).
- `PharmacyCallService`: at most one in-flight call (`pendingCallLogId`); lifecycle vocabulary "attempted"→"connected"→"completed" (observed) vs "incoming"/"outgoing" (manual).
- Importer accepts both fractional and plain ISO8601 (`isoFormatterFractional`/`isoFormatterPlain`, Python `isoformat()` compat).
- `NotificationDelegate` must be assigned before notifications can arrive (assignment in `AnxietyWatchApp.init()`, pre-launch-finish) and the instance must stay strongly referenced for the app's lifetime.
- The tap signal is deliberately content-free: all state needed to present the follow-up sheet lives in `DoseFollowUpManager`'s UserDefaults-persisted pending list, so `checkPendingFollowUp()` is idempotent and safe from any of its three triggers (tap, scene-active, timer).
- `willPresent` returning non-empty options is the sole reason foreground notifications render at all; any future per-category muting must happen there.

Oddities: index #46–58, #203–207.

### Dashboard

**Purpose:** The landing screen — 12 fixed zones (alerts strip, smart summary, Polar quick-start, last anxiety, "Last Night" hero, vitals hero + grid, activity row, collapsible environment, last medication, Care/labs). Bounded `@Query`s in the root view feed a computational view model; derived state comes from pure, tested services.

**Key symbols:**
- `DashboardView` — root; six `@Query`s, four 30-day-bounded with the cutoff captured in `init()` (`#Predicate` can't reference `Date.now`); `.task` → compute from cached data, then `loadSamples`, `refreshSnapshot` (SnapshotAggregator), `autoSync` (SyncService).
- `DashboardViewModel` (`@MainActor @Observable`) — owns no data; `loadSamples(from:)` fetches `HealthSample`s manually (7-day window, `fetchLimit` 5000) instead of `@Query` to avoid re-render per anchored insert; `computeBaselines(from:)` fills six `BaselineCalculator.BaselineResult`s; `smartSummary(...)` packs `SmartSummaryComposer.Input`; `efficiencyBaselinePct(sleepBaselineMean:)` placeholder (duration mean / 480 × 100, clamp 100, fallback 88); `baselineDelta`/`baselineColor` chips (suppressed <5%); `nightFreshnessLabel(for:)` (snapshot date = *morning* the noon-to-noon window ended, so day-diff N reads "(N+1) nights ago"); `deviceChipSource(for:)` maps `EMAYImporter.sourceBundleID`/`PolarHRMService.sourceLabel`/Apple substrings.
- `SmartSummaryComposer.compose(input:)` — deterministic; z-score candidates (HRV, RHR, sleep efficiency with fixed σ≈10 pp, AHI), keep |z| > 1.0, sort by |z| downward-tie-break, top 3; `.summary`/`.quiet`.
- `SleepEfficiencyCalculator` / `LastNightHeadline.compose(...)` — verdict from breach count (efficiency <85%, AHI ≥5, SpO2 nadir <92%): 0 "Solid night" / 1 "OK" / 2+ "Rough night"; "~" prefix when estimated.
- `AlertsDeduper.collapse(alerts:)` + `DashboardAlert` — strongest |z| per category with `relatedCount`; canonical order `[.supply, .autonomic, .sleep, .environment]`; supply passes through unranked (V1: at most one).
- `AlertsSectionView.buildAlerts()` — generation rules (supply, 3-day HRV below baseline, last-night sleep, RR above, 3-night AHI, barometric); child View so alert logic doesn't invalidate the root.
- `HRVSessionCardView` — Polar quick-start; single-clause `#Predicate` (`$0.source == polarSource`), `fetchLimit` 5, `endTime != nil` in-memory; full BT state machine; simulator demo via `RestoreDemoMode.isActive`.
- `LastNightCard`, `AlertsStrip`, `LiveMetricCard` + `MetricVisualization`, `SparklineData`/`SparklineView` (midnight→now, split at >120-min gaps), `CollapsibleSection` (`@AppStorage("dashboard.section.<id>.expanded")`), `GlucoseDetailView`+`GlucoseDetailViewModel`, `AnxietyPredictor.predict(correlations:todaySnapshot:baselineSnapshots:)` (logistic score, ≥7 baseline values per signal).

**Data flow:** In — nine SwiftData models via `@Query`/manual fetch; live BLE via `PolarHRMService.state`; barometer via `BarometerService.shared.currentPressureKPa`. Side effects — `aggregateDay(.now)`, auto-sync, `sendStatsToWatch`. Delegation — `BaselineCalculator`, `PrescriptionSupplyCalculator`, `TrendCalculator.direction`, `LabTestRegistry.isTracked`. Navigation — `CPAPDetailView`, `LabResultsView` (`.equatable()`).

**Invariants:**
- All unbounded-table `@Query`s date-bounded (30 d, `startOfDay` cutoff); `HealthSample`s bypass `@Query` entirely.
- `#Predicate`s single-clause; secondary filters in-memory.
- Snapshot "today" = date equality with `startOfDay(now)` (`todaySnapshot(from:)`).
- Estimated values visually marked: `isBedTimeEstimated` ⇒ "~" in `LastNightHeadline` and `LastNightCard`.
- Efficiency ≤100% (inBed floored); WASO excludes latency and post-final-wake awake time.
- Thresholds are z-scores against 30-day personal baselines, never population norms.
- Alert collapse order is a hardcoded array, never Set/Dictionary iteration order.
- SpO2/walking-steadiness fractions ×100 for display; pressure kPa; sleep minutes.
- Interactive cards use `.accessibilityElement(children: .ignore)` + composed label.
- Every pure service has tests: `SmartSummaryComposerTests`, `SleepEfficiencyCalculatorTests`, `LastNightHeadlineTests`, `AlertsDeduperTests`, `SparklineDataTests`, `DashboardViewModelTests`, `DashboardPerfTests`, `AnxietyPredictorTests`.

**Orphaned satellite: `MetricSalience`** (`Services/MetricSalience.swift` + `MetricSalienceTests`) — pure `nonisolated enum` of static surface-vs-demote verdicts for eight secondary metrics, spec'd as Task 4 of the dashboard-trim plan (`docs/superpowers/plans/2026-05-16-dashboard-trim.md`, design in `docs/superpowers/specs/2026-05-16-dashboard-trim-design.md`) and shipped in PR #147 with the contract "the view layer asks for a verdict; it does not know the rule". Rules: `vo2MaxVerdict` (surface if no/zero baseline or latest < 90% of 90-day baseline — "insufficient data is itself notable"), `walkingHRVerdict` (recent avg > baseline mean + 1 SD), `walkingSteadinessVerdict` (transition into the Low/Very-Low band at Apple's 0.6 threshold), `afibBurdenVerdict` (any nonzero burden or positive week delta), `barometricVerdict` (|24 h delta| > 0.5 kPa), `audioExposureVerdict` (7-day TWA > 80 dBA or 24 h max > 85 dBA), `bloodPressureVerdict` (latest stale > 7 days, or all last-3 outside 90–130/60–80), `glucoseVerdict` (> 180 or fasting > 100, mg/dL implied). **Status: orphaned** — no production code calls any function; the plan's `DashboardViewModel.salience(for:)` never landed, and the shipped dashboard places metrics in `EnvironmentDisclosureSectionView` statically. Invariants (should it ever be wired): all functions pure and synchronous (no HealthKit/SwiftData/`Date.now`/actor hops; callers pre-compute baselines, SDs, deltas, `ageDays`); `Verdict` is `surface|demote`, `Equatable & Sendable` — the spec's optional `reason` was dropped; thresholds are inline spec literals with no shared constants file (nothing else duplicates them, precisely because nothing else uses them).

Oddities: index #59–70, #197–202.

### In-app recording status pill

**Purpose:** While a Polar H10 session is connecting or recording, a floating, draggable "Recording · M:SS · NN BPM" pill is overlaid on ContentView's TabView so the session stays visible from every tab; tapping the pill (or the Dashboard HRV card, or Settings' Polar section) reopens the root-level `HRVSessionLiveView` sheet via a shared `RecordingPresentationCoordinator`. The pill is the *in-app* sibling of the Lock Screen / Dynamic Island Live Activity (watch cluster): same underlying `PolarHRMState`, but the pill formats its own text via `RecordingFormatters`/`RecordingPillContent` while the Live Activity uses `Text(timerInterval:)` for system-driven ticking. The subsystem is a deliberate, heavily-commented case study of pitfall #24 (`@Observable` reads at App/WindowGroup scope): all per-second observation is fenced inside the pill's own body.

**Key symbols:**
- `RecordingPresentationCoordinator` (`@MainActor @Observable`, one property: `showingLiveView: Bool`) — shared sheet-presentation state, created as `@State` in `AnxietyWatchApp` and `.environment`-injected so any subtree can flip the flag and ContentView's root `.sheet(isPresented:)` reacts. Deliberately separate from `PolarHRMService` so the model layer doesn't own UI state: the service says "is a session running", the coordinator says "is the user looking at it". **Reset contract** (documented in the type's doc comment): the coordinator does NOT clear `showingLiveView` when a session ends — SwiftUI resets the binding on dismissal, and if the session dies externally while the sheet is open, the sheet intentionally stays mounted showing the idle/error state. Contributors are explicitly warned not to patch `PolarHRMService.stopSession()` to set it false (would race user-driven dismissal).
- `RecordingStatusPill` (`Views/Common/`, ~240 lines) — the overlay view; reads `polarService.state` and the coordinator via `@Environment`. Rendered *unconditionally* by ContentView (`.overlay(alignment: .topLeading)`) so the visibility decision (`RecordingPillContent.from(state:) == nil` → hidden) lives inside the pill's body, scoping the ~1 Hz HR/elapsed invalidations to this leaf view only (same fix pattern as the PR #135 `BackfillOverlay` extraction). Overlay rather than `.safeAreaInset(edge: .bottom)` because iOS 18+'s liquid-glass `Tab {}` bar doesn't contribute a bottom safe-area inset. Internals: `resolvedAnchor(saved:container:safeArea:)` (per-render anchor pick: saved position re-clamped against the *current* container — rotation, iPad multitasking — else `defaultPosition`, top-center at `safeArea.top + 8`); drag via `.highPriorityGesture(DragGesture(minimumDistance: 3))` so drags beat the Button's tap, `dragOffset` applied live via `.offset`, clamped only `onEnded` via `PillPositionStore.clamp` then persisted; measurement dance — natural size tunneled up through file-private `PillSizePreferenceKey`; until `pillSize != .zero` the pill is `.opacity(0)` **and** `.allowsHitTesting(false)` (an invisible Button still takes taps) to avoid a one-frame jump-left from centering with width 0; `debugAccessibilityIdentifier` (`#if DEBUG`) consumed by `DebugScreenCapture` to hide the pill during full-screen captures.
- `RecordingPillContent` (`Utilities/`, pure `Equatable` struct) — `from(state: PolarHRMState) -> RecordingPillContent?` maps status → pill text: `.recording` → "Recording" + optional `"\(hr) BPM"` + formatted elapsed, `isLive: true` (red dot); `.connecting` → "Connecting", no HR/elapsed, `isLive: false` (orange dot); all other statuses (`.idle/.scanning/.bluetoothOff/.bluetoothUnauthorized/.bluetoothUnsupported/.error`) → nil (pill hidden). Extracted so visibility/formatting branches are testable without a view (`RecordingPillContentTests`).
- `PillPositionStore` (`Utilities/`) — UserDefaults persistence (key `recordingStatusPill.position.v1`, JSON-encoded private `StoredPoint`) via `load()`/`save(_:)`, plus pure static `clamp(position:screen:pillSize:safeArea:)`: pulls a top-leading-corner position inside screen − safeArea − pillSize; degenerate cases (pill bigger than the safe rect) pin to the safe-area top-leading via `max(min, …)`; `safeArea` defaults to zero insets. Covered by `PillPositionStoreTests` (inside/edge/degenerate/safe-area/round-trip, isolated `UserDefaults` suite).
- `RecordingFormatters.formatElapsed(_:)` (`Utilities/`, enum namespace) — `M:SS` under an hour, `H:MM:SS` after; negative input clamped to 0 (device clock adjusted backwards mid-session would otherwise show "−0:03"). Covered by `RecordingFormattersTests`. Doc note: the Live Activity widget does *not* call these — it uses `Text(timerInterval:)`.

**Data flow:** State in — BLE session lifecycle → `PolarHRMService` mutates `PolarHRMState` (`status`, `currentHR`, `sessionElapsed`, ~1 Hz while recording) → `RecordingStatusPill.body` calls `RecordingPillContent.from(state:)` each render. Presentation flag — `AnxietyWatchApp` (`@State recordingPresentation`) → `.environment` → writers: pill tap, `HRVSessionCardView` (two call sites), `PolarSettingsView` (three call sites) → reader: `ContentView` (`@Bindable`, `.sheet(isPresented: $presentation.showingLiveView) { HRVSessionLiveView(service: polarService) }`). Position — drag end → `PillPositionStore.clamp` → `@State persistedPosition` + `store.save`; next launch `store.load()` in `.onAppear` (nil until first-ever drag → default top-center). Boundaries — `DebugScreenCapture` finds the pill by `debugAccessibilityIdentifier`; `#Preview` blocks in `DashboardView`/`SettingsView` inject throwaway coordinators. Nothing outside the iOS app target touches this subsystem; the Live Activity path (`LiveActivityCoordinator`, `HRVRecordingActivityAttributes+PolarHRMState`) is parallel, not layered on it.

**Invariants:**
- Per-second `PolarHRMState` observation stays inside `RecordingStatusPill.body` (or deeper). `ContentView` holds `polarService` *only* to forward into the sheet and must not read `.state` in its body; `AnxietyWatchApp` must not read either object in WindowGroup-scope modifiers (pitfall #24 — the backfill-overlay regression is the precedent).
- `ContentView` renders `RecordingStatusPill()` unconditionally; visibility is decided solely by `RecordingPillContent.from(state:)` returning nil. An outer `if recording` gate at ContentView level would re-hoist observation.
- `showingLiveView` is set `true` by entry points and reset `false` only by sheet dismissal (user or SwiftUI). No code path may clear it on session end — the coordinator's reset contract.
- `PillPositionStore.clamp` treats the position as the pill's **top-leading corner** (matching `.offset` from the ZStack's `.topLeading` alignment); saved positions are re-clamped against the live container size on every render, never trusted raw.
- The pill is interactive only when measured: `.opacity` and `.allowsHitTesting` gated together on `pillSize != .zero`; the outer overlay's `.allowsHitTesting(content != nil)` guarantees zero hit-test interference with tabs when idle.
- New `PolarHRMState.status` cases must be classified in `RecordingPillContent.from(state:)`'s switch (exhaustive, no `default`) — the compiler enforces the pill-visible-vs-hidden decision.

Oddities: index #187–196.

### Trends & charts

**Purpose:** The Trends tab — ~9 `ChartCard`-wrapped Swift Charts over a pageable `TrendWindow`, plus Polar-night and correlation drill-downs. `TrendsView` owns all queries; per-chart files are presentation over pure datum builders.

**Key symbols:**
- `TrendsView` — all `@Query`s, `TimeRange`/`pageOffset`/`SourceFilter` state, window filtering, Polar coalescing pipeline in-body; swipe paging; `.navigationDestination(item: $tappedNight)` → `PolarSessionHRDetailView`; `.task` runs `refreshSnapshot()` (`aggregateDay(.now)`).
- `TrendWindow.init(now:periodDays:pageOffset:)` — pure date math (`TrendWindowTests`); current page end = now, start = `startOfDay(now − periodDays)`; past pages day-snapped, end-exclusive.
- `ChartPalette` (Utilities/) — semantic series tokens (`hkHeartRate` red, `polarHeartRate` blue, `polarRMSSD` purple, `polarHFPower` teal, `sleepDeep/REM/Core`, `oximeterSpO2`/`appleWatchSpO2`, `baselineRule`, `outOfRangeFill`, …); Semgrep-enforced on Views/Trends; severity colors (`Color.severity(_:)` in `SeverityColor.swift`) a deliberately separate namespace. Distinctness tested by `ChartPaletteTests`.
- Datum builders — `HRVTrendDatum`, `HeartRateTrendDatum`, `HFPowerTrendDatum`, `RMSSDTrendDatum`, `GlucoseTrendDatum`, each with `from(...)`/`hasAnyData(...)` and a matching `*Tests.swift`.
- Charts: `HRVTrendChart` (HK SDNN + Polar overnight SDNN as separate `series:`), `HeartRateTrendChart` (`handleTap(at:proxy:geo:)` maps taps to nearest `CoalescedNightRef` ±0.4 day), `HFPowerTrendChart` (info → `LFHFExplainerSheet`, the prose-quality benchmark; unpadded `baselineAnchor`), `SleepRespiratoryTrendChart` (AHI/dual-source SpO2 nadir/T90/usage; `ClinicalSeverity.ahiSeverity/t90Severity`), correlation views (`CorrelationInsightsView`/`CorrelationCardView`/`CorrelationChartView`, `signalValue(from:)` maps "hrv_avg" etc. to snapshot fields), `LFHFSessionsListView`.
- Detail: `PolarSessionHRDetailView` (per-minute HR via `RRArchiveAggregator`, HK sleep bands ±30 min pad, anxiety rules; `Equatable` on `night` + `.equatable()`); `LFHFSessionDetailView` (single-clause `$0.sensorSessionID == sessionID`, in-memory source filter; outliers pre-clipped via `robustUpperBound`, no `chartYScale`+`.nan`). `CoalescedNightRef` — Hashable/Codable navigation transport so the destination never re-coalesces.

**Invariants:**
- Padded vs unpadded: `chartXScale(domain: dateRange)` carries +12 h; baseline cutoffs/window membership use the unpadded sibling.
- `TrendsView.inWindow`: current period end-inclusive, past periods end-exclusive at midnight; nights bucketed by coalesced-night `startTime`.
- HK and Polar series always separate `series:` with distinct palette tokens and symbols (Polar = diamond, symbolSize 40).
- Datum builders drop nil-valued points pre-render; `hasAnyData` treats anxiety entries/baselines as context, not data.
- Any `@Query`-holding navigation destination: `Equatable` on identity props + `.equatable()`.
- `HRVReading` predicates single-clause; the literal `"polar_h10"` is required *inside* `#Predicate`; typed constant elsewhere.
- No `chartYScale(domain:)` where `.nan` sentinels are plotted (`AnxietySeverityChart`'s `1...10` domain fine — no NaNs).
- Expensive derivations hoisted to `let`s at top of `body`.
- Units in axis names: HRV/RMSSD ms, HF/LF ms², glucose mg/dL, pressure kPa, SpO2 %, T90 minutes.

Oddities: index #71–80.

### Journal, labs, reports & songs

**Purpose:** The subjective/clinical half: anxiety journal (design principle #5, "the journal is the anchor"), LOINC-whitelisted FHIR lab imports, the export surface (principle #2, export-first), and the song/earworm catalog. All converge on `AnxietyEntry`.

**Key symbols:**
- Journal: `AnxietyEntry` (severity 1–10, tags, `triggerDose`, `isFollowUp: Bool?`, `source: String?` — nil/"user", `"dose_followup"`, `"random_checkin"`); `JournalListView` (segmented journal/`SongCatalogView` toggle; `JournalEntryRow` + `SeverityBadge`); `AddJournalEntryView` (Express Mode one-tap save; `frequentTags` over 50 recent entries; defines `FlowLayout`); `JournalEntryDetailView` (`@Bindable`, song edits staged in `@State selectedSong`, committed via `SongLinkHelper.applySongChange`); `RandomCheckInPromptView` (fired by `RandomCheckInManager`, `source: "random_checkin"`, calls `completeCheckIn()`).
- Songs: `Song` (dual identities `serverId: Int?`/`geniusId: Int?`; `updatedAt` deliberately a recent-activity timestamp bumped on every occurrence change; cascade-deletes `occurrences` — the schema's only cascade); `SongOccurrence` (`source` ∈ "journal"/"checkin"/"standalone" — different vocabulary from `AnxietyEntry.source`); `SongLinkHelper.applySongChange(to:selectedSong:in:)` (the only sanctioned entry↔song link mutator) + `occurrenceSource(for:)`; `SongService` (reuses `SyncService.shared` config; `search`, `addByGeniusId`, `fetchCatalog(into:)` — called from `SyncService.sync()`; `upsertLocal(from:in:)` by `geniusId`); `SongSearchSheet` (`.catalog`/`.picker` modes, 400 ms debounce); `SongCatalogView`/`SongDetailView`/`SongRow`. Songs are **bidirectionally** synced (`_upsert_songs`/`_upsert_song_occurrences` server-side), unlike most push-only tables.
- Labs: `LabTestRegistry` (~12 LOINC-keyed `TestDefinition`s with rationale; `isTracked(_:)` gates the import); `FHIRLabResultParser.parse(fhirJSON:)` (minimal FHIR R4 Observation decode: tracked LOINC + numeric `valueQuantity` + parseable `effectiveDateTime`; first reference range + interpretation); `ClinicalRecordImporter.importLabResults()` (mirrors the `HealthKitDataSource` pattern; dedupe by `healthKitSampleUUID` via `propertiesToFetch`-narrowed fetch; invoked from `HealthDataCoordinator`; HK query in `HealthKitManager.queryClinicalLabResults(since:)`); `ClinicalLabResult` (`#Unique` on `healthKitSampleUUID`); `LabResultsView` (grouped by `TestCategory`, latest per LOINC, `Equatable` returning `true` — documented iOS-26 workaround); `LabTestHistoryView` (line+points over a `RectangleMark` reference band).
- Export/report: `DataExporter.exportJSON(from:start:end:omitHealthSnapshots:)`/`exportCSV` — `ExportBundle` DTOs over all 12 entity types; `omitHealthSnapshots: true` is the sync optimization (`SyncService.buildPayload` overwrites the snapshots key). The DTO shapes are effectively the sync wire format — changing a DTO changes what the server receives; doc comments here encode load-bearing sync semantics. `ReportGenerator.generatePDF(...)` — UIGraphicsPDFRenderer clinical report, `PDFCursor` pagination, `ClinicalSeverity` severity words, `BaselineCalculator.hrvBaseline`. `ExportView` — date-range + JSON/CSV/PDF, `FileManager.temporaryDirectory` + `ShareSheet`.

**Invariants:**
- `AnxietyEntry.source` vocabulary as above; bell icon for `"random_checkin"` in `JournalEntryRow`.
- Tags lowercased + trimmed on add (`addTag()`), deduped per entry.
- Severity color/label always via `Color.severity(_:)`/`Color.severityLabel(_:)`.
- Catalog upsert match order: `serverId` first, then `geniusId` (back-fills `serverId`), else insert; lyrics updates also update `lyricsSource`; resurfacing mutations must bump `Song.updatedAt`.
- Reference-range precedence everywhere (views + PDF): lab-provided range wins, registry `normalRange` fallback.
- Only registry-tracked LOINC codes persist; untracked/non-numeric silently skipped; import always `since: nil` (idempotency = UUID dedupe).
- Export timestamps ISO8601 UTC (`.withInternetDateTime`, no fractional seconds); range filtering inclusive both ends, time-series tables only; `escapeCsv` doubles quotes, flattens newlines; adherence groups sorted by key.

Oddities: index #81–93.

### Watch app, complications & Live Activities

**Purpose:** Three extension targets: the watchOS app (`AnxietyWatch Watch App/` — one-tap logging, stats glance, invisible background sensor capture), the **watchOS** widget extension (`AnxietyWatchWidgets/`), and the **iOS** Live Activities extension (`AnxietyWatchLiveActivities/`, coordinator in the main target).

**Key symbols:**
- Watch `AnxietyWatchApp` — watch-local `ModelContainer` with `[SensorSession, HRVReading, AccelSpectrogram, DerivedBreathingRate]`; `.task` → `startSensorCapture()` → `SensorCaptureSession` + forever loop: every 60 s `flushPending(to:)` + `WatchConnectivityManager.transferSensorData(modelContainer:)`.
- `QuickLogView` — 2×5 severity grid → `sendAnxietyEntry(severity:source:)` (tags `"random_checkin"` if `pendingRandomCheckIn`); `CurrentStatsView` — read-only stats.
- `WatchConnectivityManager` (watch, `@Observable` singleton) — `sendAnxietyEntry` via `sendMessage` with `transferUserInfo` fallback (unreachable AND error handler); `transferSensorData` (most recent 500 per model → `SensorTransferPayload` JSON temp file → `transferFile`, metadata `type == "sensorData"`); `applyIncomingData(_:)` → `pushToWidget()` (app-group UserDefaults + `WidgetCenter.reloadAllTimelines()`).
- `SharedData` — app group `group.com.groundeffectsoftware.AnxietyWatch.watch`; two intentionally-divergent copies (widget copy omits `pendingRandomCheckIn`).
- `SensorCaptureSession` (actor) — invisible `HKWorkoutSession(.mindAndBody)` + `HKLiveWorkoutBuilder` + chained `WKExtendedRuntimeSession`; 200 Hz `CMBatchedSensorManager.accelerometerUpdates()`, 10 s/2000-sample windows → `AccelerometerProcessor.processWindow` (`AccelSpectrogram`) + `estimateBreathingRate` (`DerivedBreathingRate`); creates a `SensorSession` at start, finalizes in `stop(modelContainer:)`. `SensorSessionDelegate` — `nonisolated` trampoline; expiring extended sessions chain fresh ones. `RawAccelerometerBuffer` — file-based raw-accel rolling buffer (10-min chunks, Int16 g×4096, 48 h retention).
- `SensorTransferPayload` (`AnxietyWatch/Models/`, shared) — Codable DTOs (`SpectrogramDTO`, `BreathingRateDTO`, `HRVDTO`) carrying model `id`s + `sensorSessionID`.
- `PhoneConnectivityManager` (iOS) — see sync cluster; `handleIncoming` also calls `RandomCheckInManager.completeCheckIn()` for `"random_checkin"`.
- Complication: `AnxietyWatchWidgets`/`StatsTimelineProvider`/`StatsEntry` — app-group UserDefaults, single entry, `.after(+15 min)` + event-driven reloads.
- Live Activity: `HRVRecordingActivityAttributes` (static `sessionStartedAt` drives `Text(timerInterval:)`; `ContentState`: `currentHRBPM: Int?`, `statusText`, `isLive`; its doc comment is the canonical pbxproj `membershipExceptions` explanation); `ContentState.from(state:)` maps `PolarHRMState.status` (mirrors `RecordingPillContent.from(state:)`); `LiveActivityCoordinator` (`withObservationTracking` re-arm; pure `decide(currentlyHosted:nextContent:)`; `hasHostedActivity` treats `.pending` as hosted; `isUnexpectedEnd(status:)` gates the "Recording stopped" banner; `staleAfter = 60 s`); `LiveActivityUpdateThrottle.shouldPush(...)` (10 s gap, bypassed for status-class transitions); `HRVRecordingLiveActivity` (Lock Screen + Dynamic Island; solid `activityBackgroundTint`, elapsed timer only when `isLive`).

**Invariants:**
- Cross-device dedup by model `id` uniqueness (`#Unique<T>([\.id])` on the three sensor models) — the "recent 500 every 60 s" re-send relies on phone-side upsert, not exactly-once transfer.
- Watch and phone maintain separate SwiftData stores; DTO `id`s are the only identity bridge.
- WatchConnectivity dict timestamps are `timeIntervalSince1970` doubles; sensor DTOs use Codable `Date`.
- App-group name + key strings duplicated in three places (two `SharedData` enums + `PhoneConnectivityManager.sendStatsToWatch` literals) — keep aligned.
- Live Activity updates only via the throttle (10 s gap ≈ 360/h budget for overnight sessions); `staleAfter` stays generously above the gap.
- Attributes immutable after `Activity.request`; anything mutable lives in `ContentState`.
- End semantics: unexpected → final "Disconnected" + banner, 3 s, `.default` dismissal; user-initiated → `.immediate`; `endRunning` nils bookkeeping synchronously (documented two-pills edge case).
- Severity color/label duplicated per target (file-sharing constraint, per `QuickLogView.severityColor` comment).
- Accel processing assumes exactly 200 Hz / 2000-sample windows; `RawAccelerometerBuffer` fixed little-endian header (UInt32 count, Double refDate, Float rate).

Oddities: index #94–104.

### Models layer (SwiftData schema)

**Purpose:** 20 `@Model` classes in `AnxietyWatch/Models/`, four families: journaling/meds (`AnxietyEntry`, `MedicationDefinition`, `MedicationDose`, `Prescription`, `Pharmacy`, `PharmacyCallLog`), HK aggregates/mirrors (`HealthSnapshot`, `HealthSample`, `QuantityHealthSample`, `SleepStageEvent`, `ClinicalLabResult`), sensor time series (`SensorSession`, `HRVReading`, `AccelSpectrogram`, `DerivedBreathingRate`), auxiliary (`CPAPSession`, `BarometricReading`, `PhysiologicalCorrelation`, `Song`, `SongOccurrence`). HealthKit remains the source of truth; these are caches/mirrors for trending and sync.

**Key schema facts:**
- `HealthSnapshot` — `#Unique` on `date` (startOfDay-normalized in `init`); ~50 optional metric columns; `syncedToServer` **defaults `true`** (lightweight migration treats pre-existing rows as clean) while `init` sets it `false`; `pendingSyncVersion` closes the mark-clean-during-in-flight-aggregation race.
- `QuantityHealthSample` — `@Attribute(.unique)` on `id`; `#Index` on `(sourceBundleID, timestamp)` (~36k rows per EMAY night); `groupID` links BP correlation pairs. `SleepStageEvent` — `id` = HK sample UUID; `stage` raw HK name string. `HealthSample` — `#Unique` on `(type, timestamp, source)`, `source` optional.
- `SensorSession` — `interruptions: [SensorInterruption]` inline Codable array; `source` optional (nil = pre-source-tracking/Watch); `summaryJSON` schema-flexible; `rrArchiveUploadedAt` independent of `syncedToServer`. `HRVReading` — loose FK `sensorSessionID: UUID?` (no `@Relationship`). `AccelSpectrogram`/`DerivedBreathingRate` — `#Unique` on client `id` (retransfer-idempotent), loose FK.
- `CPAPSession` — `#Unique` on `date`; `importSource` raw string, `source` computed falls back to `.csv` on unknown. `ClinicalLabResult` — `#Unique` on `healthKitSampleUUID`. `PhysiologicalCorrelation` — `#Unique` on `signalName`. `Song.serverId: Int?` maps to the server integer PK; `Song.occurrences` is the only cascade delete.
- `SyncService.SyncableSample` — `{ var syncedToServer: Bool }` conformed by `QuantityHealthSample`, `SleepStageEvent`, `SensorSession`, `HRVReading`; `HealthSnapshot` handled separately by date + `pendingSyncVersion`.
- Containers: iOS registers all 20 (`AnxietyWatchApp.sharedModelContainer`); watch registers only the 4 sensor models; `SensorTransferPayload` (plain Codable, `nonisolated`) bridges them.

**Invariants:**
- Day-keyed tables (`HealthSnapshot`, `CPAPSession`) normalize `date` in `init`, local timezone, one row/day.
- Two sync mechanisms coexist: per-row `syncedToServer` dirty flags vs the `lastSyncDate` cursor; snapshots add `pendingSyncVersion` compare-and-clear.
- Idempotency keys differ by origin: HK rows reuse `HKSample.uuid`; watch/Polar rows use unique-constrained client UUIDs; EMAY CSV rows use importer-side `(sourceBundleID, timestamp, metricType)` dedup.
- `source` discriminators nilable by history — predicates must handle nil (CLAUDE.md nil-discriminator rule); `PolarHRMService.sourceLabel` is the typed constant.
- Nil-backfill boolean semantics vary: `isFollowUp` nil→false, `promptAnxietyOnLog` nil→false, `isPRN` nil→**true**.
- Denormalized names must track `MedicationDefinition.name` (hook-watched).
- Loose UUID FKs (not relationships) tie sensor series to sessions — deliberate for cross-device transfer; queries stay single-clause.
- Units in docstrings: HRV ms, pressure kPa, sleep minutes, glucose mg/dL, SpO2 %, leak L/min, temps °C; SpO2 nadirs source-partitioned (`spo2NadirOvernight` vs `spo2NadirOpportunistic`).

Oddities: index #105–112.

### Server core & admin UI

**Purpose:** Flask app (`server/server.py` `create_app` factory; routes as closures) receiving every synced table (`POST /api/sync`), storing via idempotent upserts, serving it back (`GET /api/data`, `/api/status`, song endpoints); admin blueprint (`server/admin.py`) with dashboard, key management, scraper credentials, profiles, conflict tracking, AI analysis, data browser. Single-user: no user/tenant column anywhere.

**Key symbols:**
- `create_app(test_config)` — requires `SECRET_KEY` unless `TESTING`; runs Alembic `upgrade head` via `init_db()` at startup (failure logged, not fatal); exposes `app.get_db` (per-request `g.db`, autocommit off) to the admin blueprint; `SESSION_COOKIE_SAMESITE = "Strict"`.
- `require_api_key` — SHA-256 of Bearer token → `api_keys.key_hash`, `is_active` check, bumps `last_used_at`/`request_count` (committed pre-handler), stashes `g.api_key_id`.
- `sync()` — ~16 `_upsert_*` helpers in one transaction + `sync_log` row; then non-fatal inline correlation recompute in the response.
- `_upsert_health_snapshots` + `_overnight_stats_update_clause`/`_data_quality_update_clause` — schema-versioned EXCLUDED-vs-COALESCE (Swift `encodeIfPresent` makes intentional-nil indistinguishable from old-client-missing); v≥2 for `_OVERNIGHT_STATS_COLUMNS`, v≥3 for `data_quality` JSONB.
- `_upsert_quantity_health_samples`/`_upsert_sleep_stage_events` — `psycopg2.extras.execute_values` batching; UUID-keyed; replays update identity columns (HK retroactive corrections); `group_id` COALESCE-preserved.
- `_upsert_sensor_sessions`/`_upsert_hrv_readings` — sessions before readings (FK); `end_time`/`battery_at_start`/`summary_json` COALESCE-preserved (partial-row lifecycle); `_coerce_summary_json` tolerates string or dict.
- `upload_rr_archive()` — UUID-validated, 404-before-payload, `MAX_RR_ARCHIVE_BYTES` (5 MB) via Content-Length AND bounded chunked stream read.
- `ENTITY_QUERIES` + `_query_entity` — allowlisted table config for `GET /api/data[/entity]?since=` and `/api/status` counts; `_serialize_row` ISO-formats dates, nulls `memoryview` (binary never leaks into JSON).
- Song endpoints — Genius proxy; `_upsert_songs` last-write-wins guarded `WHERE EXCLUDED.updated_at >= songs.updated_at` + `GREATEST(...)`; manual songs dedupe on partial unique index `lower(btrim(title)), lower(btrim(artist))`.
- Admin: `require_admin`/`login` (`hmac.compare_digest` vs `ADMIN_PASSWORD`; fails if env empty); `create_key` (`secrets.token_urlsafe(32)`, hash + 8-char prefix, raw shown once via `session["new_key"]`); `resmed_settings`/`walgreens_settings`/`caprx_settings` (Fernet-encrypted credentials; "sync now": ResMed `subprocess.run` 60 s, Walgreens `xvfb-run` 180 s, CapRx in-process `caprx_sync.run_sync(conn=db)`); `patient_profile*`/`psychiatrist_profile*` (Claude API: refinement/summary `claude-sonnet-4-20250514`, research `claude-opus-4-7` + `web_search_20250305`, parsed by `json_helpers.parse_llm_json`); `analysis`/`analysis_run`/`analysis_detail`; `BROWSABLE_TABLES` + `admin.data` (read-only browser, limit ≤500).

**Invariants:**
- Every sync write is an idempotent upsert on natural keys: `anxiety_entries(timestamp)`, `medication_doses(timestamp, medication_name)`, `cpap_sessions(date)`, `health_snapshots(date)`, `barometric_readings(timestamp)`, `pharmacies(name)`, `medication_definitions(name)`, `prescriptions(rx_number)`, `pharmacy_call_logs(timestamp, pharmacy_name)`, `song_occurrences(song_id, timestamp, source)`; UUID PKs for the four bulk tables.
- `/api/sync` is one transaction — any failure rolls back everything, 500, client cursor must not advance (pairs with the iOS cursor invariant).
- Ordering: `sensor_sessions` before `hrv_readings`; songs before `song_occurrences` (unresolvable occurrences silently skipped).
- COALESCE-preserve protects server-enriched data: `cpap_sessions.leak_rate_95th` (EDF path), `group_id`, session lifecycle columns, song lyrics/album/art; `_upsert_demographics` never overwrites non-NULL `patient_profile` fields.
- `rr_archive` binary only via its endpoint, never `/api/sync`, never serialized out.
- Hash-only API auth; admin auth a boolean session flag; `/health` the only unauthenticated route.
- Dynamic-SQL f-strings only over hardcoded allowlists — user input never reaches an identifier position.
- Timestamps stored as sent (timestamptz); correlations pair on `a.timestamp::date` (UTC day); `settings.timezone` (default US/Pacific) consumed by analysis prompts, not here.

Oddities: index #113–129.

### Server third-party sync clients & job dispatcher

**Purpose:** Server-resident pullers — ResMed myAir (Okta PKCE + GraphQL → `cpap_sessions`), Walgreens (headed Playwright intercepting the site's own APIs → `prescriptions`), Capital Rx (requests-only SAML/Kratos SSO → `prescriptions`) — each a `*_client.py` + `*_sync.py` pair with encrypted credentials, source-discriminator upserts, a shared exit-code contract, in-container cron, and admin "sync now". Plus `job_dispatcher.py`, a DB-backed DAG executor for Claude analysis jobs.

**Key symbols:**
- `MyAirClient` (`resmed_client.py`) — Okta authn → authorize → token exchange, then GraphQL `getPatientWrapper`; `fetch_sessions(days:)` → normalized dicts; `MyAirAuthError`/`MyAirAPIError`; needs `GRAPHQL_API_KEY`. `resmed_sync.main()` — `--check-schedule` gates on `resmed_sync_time` vs current UTC hour (`should_run_now`); lookback 7 days if `resmed_last_sync` else 365. `upsert_sessions()` — keyed on `date`; `sd_card` rows never overwritten (pre-SELECT skip + `ON CONFLICT ... WHERE import_source='resmed_cloud'` belt-and-suspenders).
- `WalgreensClient` — Playwright **headed** Chrome (`headless=False`; Akamai detects headless — servers use `xvfb-run`); `_authenticate()` char-by-char typing; `_handle_2fa()` security-question flow; data via intercepting `POST /rx-settings/printrx/load` (`_try_fetch`) + `_fetch_all_fill_histories()` UI-clicking to trigger `/rx-status/fillhistory` (XSRF is HttpOnly); `save_session()` persists `storage_state`. `normalize_prescription()` (`_parse_dose` mg/mcg/ml, `_parse_walgreens_date`). `walgreens_sync.upsert_prescriptions()` — keyed `rx_number`, `WHERE import_source='walgreens'` (manual never overwritten).
- `CapRxClient` — pure-requests SSO chain (`_follow_saml_chain`/`_post_saml_form` → `/sso/resolve` → 15-min access token); `fetch_all_claims()` paginates; `_session_with_timeout()` monkeypatches a default timeout. `normalize_claim()` — synthesizes `rx_number = "CRX-{claim.id}"` (no pharmacy Rx numbers exposed), skips reversed/rejected/denied/voided. `caprx_sync.run_sync(conn=None, ...)` — in-process reusable; computes `estimated_run_out_date = date_filled + days_supply`; `WHERE import_source='caprx'`.
- `job_dispatcher.create_analysis_jobs()` — 1 `health_analysis` (no deps); if an active `conflicts` row exists, +4 research jobs (`patient_validity`, `psychiatrist_validity`, `patient_criticism`, `psychiatrist_criticism`) + 1 `conflict_synthesis` depending on all 4; `depends_on` int-array column. `dispatch_analysis(analysis_id, database_url)` — 2 s poll over `find_ready_jobs()`; `mark_running()` atomic claim (`UPDATE ... WHERE status='pending'`); 2-worker `ThreadPoolExecutor`; `_execute_single_job()` per-job connection, `store_request_payload` **before** the API call, `mark_completed`/`mark_failed` + recursive `cascade_failures()`; loop commits per iteration (VACUUM); `finalize_analysis()` copies the health result to the parent `analyses` row.

**Invariants:**
- Source-discriminator upserts everywhere: `sd_card` beats `resmed_cloud`; `manual` beats `walgreens`/`caprx`; enforced by `ON CONFLICT ... WHERE import_source = '<this source>'` (rowcount 0 when filtered).
- Uniqueness: `cpap_sessions.date`; `prescriptions.rx_number` — Walgreens uses the real Rx number (per prescription), CapRx `CRX-<claim_id>` (per **claim/fill**) — different granularity in the same table.
- Exit-code contract for all three CLIs: 0 success / 1 auth / 2 API-network / 3 credentials-config.
- Schedule gating = UTC-hour equality; cron provides the hourly trigger.
- Never log credential values — presence/length metadata only.
- Job DAG: run only when all `depends_on` completed; failure cascades recursively to pending dependents; `mark_running` conditional UPDATE is the concurrency guard; loop terminates when nothing ready and nothing running.
- Anthropic request payloads persisted pre-call (auditable on crash); raw responses + token counts stored.

Oddities: index #130–142.

### Server crypto, schema & auth

**Purpose:** Security and persistence backbone: `crypto.py` (Fernet for portal credentials in `settings`), `schema.sql` + `server/alembic/` (~25 tables mirroring SwiftData), and two auth planes (hashed Bearer keys for `/api/*`; `ADMIN_PASSWORD` + signed-cookie sessions for `/admin`).

**Key symbols:**
- `crypto._fernet_key(secret)` — PBKDF2-HMAC-SHA256, 100k iterations, **static salt** `b"anxietywatch-settings"`, re-derived per call. `encrypt_value`/`decrypt_value` — the only public functions; `secret` is always the `SECRET_KEY` env var (same value Flask signs cookies with). Tests: `test_crypto.py`.
- `create_app.init_db()` — programmatic `alembic upgrade head`; requires explicit `DATABASE_URL` (so alembic.ini's localhost default can't reach production); also `flask init-db`.
- `admin.require_admin`/`login` — signed-cookie session (`session["admin"]`), no server-side store, no expiry, no rate limiting; `create_key`/`revoke_key` (soft revoke `is_active = FALSE`).
- `alembic/env.py.get_url()` — `DATABASE_URL` > alembic.ini `sqlalchemy.url` (localhost:5439 dev default) > RuntimeError.
- `alembic/versions/0001_baseline_schema.py` — executes `schema.sql` verbatim (fresh DBs; existing DBs `alembic stamp 0001`); its `downgrade()` must enumerate every schema.sql table, including later-migration-owned ones. Migrations `0002`–`0006`: data fixes (SpO2 scale, skin-temp split, sleep cap), overnight stat columns, bulk sample tables + `data_quality`, Polar tables, `spo2_nadir_opportunistic`. `migrations/fix_2026_04_17_health_data_formatting.py` — deprecated standalone, preserved as 0002, dry-run mode.

**Invariants:**
- `SECRET_KEY` is triple-duty (cookie signing, Fernet KDF, session validity); rotating it invalidates admin sessions AND orphans every encrypted settings value — no re-encryption path exists.
- Static KDF salt ⇒ key fully determined by `SECRET_KEY`; ciphertexts still differ per call (Fernet random IV; asserted in `test_encrypted_output_is_different_each_time`).
- Raw API keys never persisted — SHA-256 hash + 8-char prefix; unsalted SHA-256 acceptable for 256-bit random tokens.
- Single-user: no `users` table, no `user_id` FKs (documented in migrations 0004/0005); natural keys dominate.
- UUID PKs on the four bulk tables equal the iOS-side IDs; `ON CONFLICT (id) DO UPDATE` is the replay contract.
- All timestamps `TIMESTAMPTZ`; day tables `DATE`; `hrv_readings.session_id → sensor_sessions.id` is the only CASCADE FK — sessions must be upserted first.
- schema.sql header says "REFERENCE ONLY" but it is *executed* by 0001, so it must equal head state; later migrations must be idempotent against a fresh DB (0003/0006 `ADD COLUMN IF NOT EXISTS`, 0005 `if_not_exists=True`).
- Nullable `lf_power`/`hf_power`/`lf_hf_ratio` encode the <30-RR data contract.
- Migration 0002's fixes are threshold-heuristic and idempotent (SpO2 rows match only while `<= 1.0`; skin-temp only while `ABS(...) > 5.0`).
- `test_alembic.py` refuses any DB whose name lacks "test" (it drops the public schema).

Oddities: index #143–155.

### Server analysis engine

**Purpose:** The intelligence layer: `analysis.py` gathers synced data for a range, builds an engineered Claude prompt, stores structured insights; `job_dispatcher.py` runs it as a DAG; `correlations.py` (deterministic Pearson), `conflict_analysis.py` (adversarial patient-vs-psychiatrist research), `edf_parser.py` (ResMed EDF leak extraction), `genius.py` (lyrics acquisition), `json_helpers.py` (robust LLM-JSON parsing). Entry points: `admin.py` and `server.py`.

**Key symbols:**
- `analysis.MODEL_CHOICES`/`MODEL`/`MODEL_PRICING` — single source of allowed model IDs + pricing. `gather_analysis_data(cur, date_from, date_to)` — 8 sources (anxiety_entries, health_snapshots, medication_doses, cpap_sessions, barometric_readings with >500-row uniform-stride downsampling, correlations, song_occurrences, song_summary). `flag_outliers(data)` — `PHYSIOLOGICAL_LIMITS` hard bounds + sleep-stage-total-vs-duration consistency; warnings injected as "do NOT use" prompt instructions. `compute_effective_dates`. `build_prompt(...)` — patient context, `RELIABILITY_AND_ABSENCE_INSTRUCTIONS`, dose-tracking caveat, CPAP always-worn rule, timezone line, therapy schedule, JSON schema, confidence calibration, lyric budget (`MAX_LYRICS_CHARS_PER_SONG` 3000 / `MAX_LYRICS_CHARS_TOTAL` 60000, most-salient-first). `_format_per_day_data_quality` + `_device_display_name` (mirror of Swift `DeviceProvenance.displayName(for:)` — keep in sync). `start_analysis` (pending row → jobs → daemon thread), `run_analysis` (sync, test-only, `_complete_analysis`), `parse_response`, `sweep_stale_analyses` (`STALE_ANALYSIS_MINUTES` 15, 60 s `_sweep_lock` throttle).
- `conflict_analysis.SYSTEM_PROMPTS` (5: validity/criticism × 2 parties + synthesis); `build_job_prompt` (shared `_build_context_block`; research jobs get `web_search_20250305`, synthesis gets the 4 JSONs, no tools); `parse_job_result` (degrades to a valid shape on parse failure).
- `json_helpers.parse_llm_json` — fence extraction (incl. unclosed from truncation), `json.loads` fast path, `json_repair` slow path, `_clean_citation_artifacts`.
- `correlations.compute_correlations(cur)` — per-signal SQL joining `health_snapshots` to daily `AVG(anxiety_entries.severity)` on `a.timestamp::date = h.date`; `MINIMUM_PAIRED_DAYS` 12; `scipy.stats.pearsonr`; mean-severity contrast >1 SD vs within. `store_correlations`/`get_correlations` (upsert on `signal_name`, global all-time, ordered `ABS(correlation) DESC`); `correlations_are_stale`.
- `edf_parser.parse_edf_file(path)` — pyedflib, first "leak" signal, 95th percentile, header date/duration; `upsert_cpap_leak(conn, sessions)` — fills `leak_rate_95th` only where NULL; new row (`import_source='edf'`) only if no row for that date.
- `genius.search_songs`/`fetch_song_metadata` (REST, `GENIUS_API_TOKEN`); `scrape_lyrics(url)` (BeautifulSoup on `div[data-lyrics-container="true"]`); `fetch_lyrics_musixmatch` fallback (30% preview, disclaimer stripped).

**Invariants:**
- Timestamp queries half-open `[ts_start, ts_end)` in UTC; date tables inclusive; the prompt asserts timestamps are in `settings.timezone` (default US/Pacific).
- `analyses.status` lifecycle pending → running → completed|failed; every failure path lands in `_mark_analysis_failed` or the sweeper.
- Job claiming race-safe only via `mark_running`'s conditional UPDATE; dispatcher commits between polls for VACUUM.
- A job is ready only when all `depends_on` completed; failure cascades recursively.
- Conflict context appears in the health prompt only when `include_conflict` — never promises a conflict analysis that won't run.
- Prompt rendering deterministic: source counts sort `(-count, bundle_id)`; `_safe_int` shields non-numeric JSONB.
- `DEVICE_DISPLAY_NAMES` must stay in sync with Swift `DeviceProvenance.displayName(for:)`.
- Correlations global all-time, one row/signal, recomputed only when stale; constant arrays skipped (pearsonr NaN guard).
- `upsert_cpap_leak` never overwrites non-NULL leak; CSV rows win over EDF except the leak column they lack.
- `song_occurrences.anxiety_entry_id` is a TIMESTAMPTZ (joins `ae.timestamp`), not an integer FK.
- Lyric inclusion is budget-checked before appending — the cap can't overshoot.

Oddities: index #156–167.

### Tooling & CI

**Purpose:** The automated quality/safety perimeter: seven Claude Code hooks, five review sub-agents, project Semgrep rules, five GitHub Actions workflows, and the five-file instruction set whose synchronization is itself an invariant. Design driver is empirical: recurring Copilot-review categories (`docs/plans/claude-code-setup-improvements.md`) and real incidents (PII history rewrites, iOS-26 render hangs, the sync-cursor race) each became a hook, agent rule, or Semgrep rule.

**Key symbols:**
- Hooks (`.claude/hooks/`, wired in `.claude/settings.json`; self-filtering, fail-open except the PII gate): `swiftlint-edited.py::run_swiftlint()` (PostToolUse, `--strict`, exit 2 feeds violations back); `flake8-edited.py` (server mirror); `voiceover-consistency-edited.py` (four regex a11y checks: `find_int_truncation_with_percent_f`, `find_button_inside_navigation_link`, `find_combine_with_interactive_children`, `find_slash_in_accessibility_label`; production dirs only); `medication-name-drift-warn.py::discover_canonical_names()` (advisory; exists because prod DB has `clonazePAM` vs `Clonazepam 1mg Tablets` drift); `block-pii-in-fixtures.py::find_findings()` (PreToolUse, **blocking**; scans tool_input under test paths for non-fictional phones/Rx numbers/device names/addresses/doctor names/store numbers); `pre-pr-reviewer-reminder.py` (non-blocking `git push` reminder); `post-tool-call.py` (personal provenance hook, `settings.local.json` only).
- Agents (`.claude/agents/*.md`, `model: sonnet`, Task-dispatched): `swift-pre-pr-reviewer` (~30-rule generalist, calibrated against PR #132 — 16 rounds, 39 comments, 94% catch rate; tiers [Will Block]/[Should Address]/[Nit]; mandatory pre-push per CLAUDE.md); `swiftui-render-pitfall-detector` (the four iOS-26 crash patterns); `chart-ux-auditor` (token map + empty states + optional XcodeBuildMCP screenshots vs `docs/screenshots/trends-baselines/`); `medical-data-accuracy-reviewer` (units/timezone/discriminators/OCR ≥0.7/baseline math/CPAP clock-reset; false positives cheap, false negatives clinical risk); `process-walkthrough` (file → Mermaid + lay prose; bar is `LFHFExplainerSheet.swift`; only agent with Write).
- Slash commands: `query-prod.md` (`ssh megadude "docker exec anxietywatch-db psql …"`, refuses destructive SQL); `respond-to-copilot.md` (both GitHub comment endpoints; PRRT thread IDs; count captured before re-request); `sync-instruction-files.md` (classify + mirror across the five files, user approval per diff).
- Semgrep (`.semgrep/swift-pitfalls.yml`, all `languages: [generic]`): `anxietywatch-hardcoded-source-label` (WARN), `anxietywatch-overnight-threshold-magic-number` (WARN), `anxietywatch-date-arithmetic-no-calendar` (WARN), `anxietywatch-chart-color-literal` (WARN, Views/Trends), `anxietywatch-sync-cursor-now` (**ERROR**, merge-blocking, SyncService.swift only). The `chartYScale`+`.nan` pitfall is deliberately absent (regex FP rate) — the render-pitfall agent owns it.
- CI/CD: `ios-ci.yml` (self-hosted macOS; `scripts/check-deployment-targets.sh` — xcconfig is sole deployment-target source; `scripts/generate-version.sh`; swiftlint `--strict`; `semgrep --error`; `xcodebuild test` with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`; watchOS build); `ci.yml` (flake8 + pytest vs postgres:16, reusable `workflow_call`); `deploy.yml` (ci → GHCR `ghcr.io/chenders/anxietywatch-server` → self-hosted `anxietywatch` runner, `/opt/anxietywatch`, `docker inspect` health poll); `release.yml` (`v*` tags); `verify-schema.yml` (manual alembic/`\d` prod checks).
- Config: `.claude/settings.json` (committed allowlist; deny `.env*`, `**/Secrets.swift`, `rm -rf`; env `DEFAULT_SIMULATOR: iPhone 17 Pro`); `.claude/settings.local.json` (personal); `.swiftlint.yml` (only `AnxietyWatch/` + `AnxietyWatchTests/` — **Watch App and Widgets excluded**; line_length 150/200); `.xcodebuildmcp/config.yaml` (gitignored session defaults); `.github/dependabot.yml`.

**Invariants:**
- Every rule lives at multiple layers with consistent wording, different framing (CLAUDE.md author-facing ↔ Copilot reviewer-facing ↔ Semgrep/hook machine-enforced); a rule in one file but not its counterparts is by definition a bug; `/sync-instruction-files` is the repair tool.
- Hooks fail-open (exit 0 on malformed input/missing tools); only `block-pii-in-fixtures.py` fail-closed.
- Zero-warning policy triple-enforced: `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, swiftlint `--strict`, flake8.
- Semgrep WARNING = PR annotation, ERROR = merge block; only the sync-cursor rule is ERROR.
- Canonical constants have exactly one tooling-known home: source labels `PolarHRMService.sourceLabel`, overnight threshold `LFHFAggregator`, chart colors `ChartPalette`, medication names `MedicationDefinition.swift`.
- Prod DB access read-only via `docker exec` (never compose CLI), container `anxietywatch-db`, compose project `anxietywatch`; calendar-day queries wrap timestamps in `AT TIME ZONE 'America/Los_Angeles'`.
- Deployment targets live only in `Config/*.xcconfig`; CI fails if they reappear in the pbxproj.

Oddities: index #168–180.

---

## Invariants registry

CLAUDE.md's 26 "Common pitfalls" mapped to the symbol that embodies each, the machine enforcement (if any), and test coverage. Roughly a third are enforced only by review sub-agents.

| # | Pitfall (CLAUDE.md) | Embodied by (symbol) | Static/hook enforcement | Test coverage |
|---|---|---|---|---|
| 1 | Source-label / constant drift | `PolarHRMService.sourceLabel` | Semgrep `anxietywatch-hardcoded-source-label` (WARNING; excludes Models/, PolarHRMService, DeviceProvenance; allows `#Predicate` bodies) | `SourceFilterTests`, `SnapshotAggregatorSourcePrecedenceTests` (behavioral, not drift-detection) |
| 2 | `@Query` scope (source + date bound) | `LFHFSessionsListView` @Query | UNENFORCED statically — review-agent only | UNTESTED directly |
| 3 | Nil-discriminator back-compat | `TrendsView` self-reported filter (`$0.source == nil \|\| …`) | UNENFORCED statically | `SourceFilterTests` "Entries with nil source are self-reported" |
| 4 | VoiceOver rounding/format consistency | call sites throughout Views | Hook `voiceover-consistency-edited.py` | UNTESTED |
| 5 | Button inside NavigationLink label | — | Hook `voiceover-consistency-edited.py` | UNTESTED |
| 6 | State-machine completeness | `PolarHRMService.recoverInFlightSessionIfNeeded`, `finalizeOrphan` | UNENFORCED statically | `PolarHRMServiceOrphanTests`, `PolarBluetoothStateMappingTests` |
| 7 | Empty-state gates (`hasAnyData`) | `hasAnyData` in the five trend charts + `TrendsView` | UNENFORCED statically | `HFPowerTrendChartTests` (others partial) |
| 8 | Fallback-state UX honesty | `LastNightHeadline`; `HRVSessionCardView` | UNENFORCED statically | `LastNightHeadlineTests` ("~" prefix test) |
| 9 | Deterministic ordering | `LFHFAggregator.coalesce` explicit sort by `startTime` | UNENFORCED statically | `LFHFAggregatorCoalesceTests` |
| 10 | Doc-comment drift | — | UNENFORCED — review-agent only | UNTESTED |
| 11 | SwiftLint line-length 150/200 | `.swiftlint.yml` | SwiftLint CI (`--strict`) + hook `swiftlint-edited.py` | n/a |
| 12 | Magic-number duplication (`3*3600`) | `LFHFAggregator.overnightThresholdSeconds` | Semgrep `anxietywatch-overnight-threshold-magic-number` (also `10800`) | `ConstantsTests` |
| 13 | Float-equality in tests | epsilon pattern `abs(result - expected) < 0.0001` | UNENFORCED (convention; no shared helper in `TestHelpers.swift`) | pattern used e.g. `LFHFAggregatorTests` |
| 14 | Day-alignment of date math | `TrendWindow` (`calendar.startOfDay`) | Semgrep `anxietywatch-date-arithmetic-no-calendar` | `TrendWindowTests`, `TrendsDateFilteringTests` |
| 15 | Padded vs unpadded date range | `TrendsView.paddedChartEnd` vs `HFPowerTrendChart.baselineAnchor` | UNENFORCED statically | `HFPowerTrendChartTests` (anchor path) |
| 16 | Anchor to `SensorSession.startTime` | `LFHFAggregator.coalesce` | UNENFORCED statically | `LFHFAggregatorCoalesceTests` (incl. "Fragmented May-13 case") |
| 17 | Per-render recomputation | — | UNENFORCED — `swiftui-render-pitfall-detector` | `DashboardPerfTests` (partial) |
| 18 | Extract view-embedded computation | `LastNightHeadline`, `TrendWindow`, `BarometerService.shouldCapture` | UNENFORCED — convention | the extraction *is* the coverage |
| 19 | `.combine` w/ interactive children | — | Hook `voiceover-consistency-edited.py` | UNTESTED |
| 20 | Filter granularity vs aggregation unit | `HFPowerTrendChart.windowMeans` | UNENFORCED statically | `LFHFAggregatorCoalesceTests` (cross-member grouping) |
| 21 | Compound `#Predicate` w/ captured locals (0x8BADF00D) | `LFHFSessionDetailView` single-clause pattern | UNENFORCED — agent only | UNTESTED |
| 22 | `@Query` NavigationLink destination needs `Equatable` + `.equatable()` | `LFHFSessionDetailView`, `PolarSessionHRDetailView`; call sites `LFHFSessionsListView:76`, `TrendsView:316`, `CareSectionRowView:12`; doctrine in `LabResultsView` header | UNENFORCED — agent only | UNTESTED |
| 23 | `chartYScale(domain:)` + `.nan` | pre-clipping at data layer | Deliberately NOT a Semgrep rule (FP rationale in `swift-pitfalls.yml`); agent-owned | `HFPowerTrendChartTests` (adjacent) |
| 24 | `@Observable` reads at App/WindowGroup scope | `BackfillOverlay` child struct (`AnxietyWatchApp.swift:114/366`) | UNENFORCED — agent only | UNTESTED |
| 25 | Sync cursor advanced to `.now` after I/O | `SyncService.sync()` `cursorUpperBound` pre-capture; `buildPayload(upperBound:)` | Semgrep `anxietywatch-sync-cursor-now` (**ERROR**, path-scoped) | `SyncServiceTests` "buildPayload upperBound caps the small-volume export range" |
| 26 | Conditional-skip breaking prior invariants (`bulkOnly`) | `if !iterationIsBulkOnly { lastSyncDate = cursorUpperBound }` | Same Semgrep rule, indirectly | `SyncServiceTests` bulkOnly pair |

**Cross-cutting invariants:** canonical source strings `polar_h10`/`healthkit`/`apple_watch`/`emay` (literals only in `#Predicate` bodies, Models/, `PolarHRMService.swift`, `DeviceProvenance.swift`); cursor captured pre-payload, advanced only with the export that carried the rows (UserDefaults key `"lastSyncDate"`); every Trends series color from `ChartPalette` (`ChartPaletteTests` verifies distinctness); day boundaries via `startOfDay`, bucketing by `SensorSession.startTime`, +12 h chart padding never leaks into non-visual math; coalesced-night wear = sum of member durations, never span.

**Cross-check against the other cluster surveys** (live tensions with the registry, all also listed in the Oddity index):
- Pitfall #2: the dashboard, meds, journal, and trends surveys independently found unbounded `@Query`s — `MedicationsHubView.recentDoses`/`prescriptions`, `PrescriptionListView`, `ExportView` (six tables), `CorrelationInsightsView`/`CorrelationChartView` — confirming the "review-only" enforcement gap is being exercised.
- Pitfall #9: `PrescriptionSupplyCalculator.latestPrescriptionPerMedication` returns dictionary-order output consumed unsorted by `ForEach` — a live counterexample.
- Pitfall #17: `GlucoseTrendChart.datums` (re-parses `dataQuality` JSON per access ×5) and the double `SleepEfficiencyCalculator`/`LastNightHeadline` run in `DashboardView.lastNightSection` are live instances.
- Pitfall #22: `CorrelationInsightsView`/`CorrelationChartView` are `@Query`-holding closure destinations *without* the Equatable treatment.
- ChartPalette invariant: token drift exists inside the enforced zone — `HRVTrendChart` colors Polar SDNN with `ChartPalette.polarRMSSD`; `ChartPalette.glucose` is literally `Color.purple` (same as `polarRMSSD`) despite its "magenta family" doc; `PolarSessionHRDetailView.sleepStageBands` hardcodes stage colors.
- Pitfall #1: `TrendsView.filterBySource` hardcodes entry-source literals outside `#Predicate`.

---

## Oddity index

Every oddity observed across the 16 cluster surveys and the gap-fill passes (#187–207), in one table. These are neutral observations — some are deliberate design, some are latent bugs, some are dead code; Phase 2 triages them. Numbering is stable; cluster sections above reference their ranges.

| # | Cluster | Symbol anchor | Observation |
|---|---|---|---|
| 1 | healthkit-ingestion | `HealthDataCoordinator.mirrorHealthKitSamples` | Per-metric fetch failure `return`s from `mirrorQuantityMetric` but earlier metrics' inserts still commit and later metrics' `pendingAnchors` still advance — per-metric independence worth confirming as intentional |
| 2 | healthkit-ingestion | `HealthKitManager.oldestSampleDate` | Backfill horizon anchored to oldest HRV sample only; older steps/HR history never backfilled |
| 3 | healthkit-ingestion | `loadAnchor`/`saveAnchor` | Two parallel anchor systems share the same method-name pair: HKQueryAnchor blobs (`HKAnchor_`, `UserDefaults.standard`) vs Date anchors (`sampleAnchor.`, injected defaults) |
| 4 | healthkit-ingestion | `HealthDataCoordinator.backfillIfNeeded` | Uses `UserDefaults.standard` while mirror anchors use injected `defaults` — inconsistent injection; tests can't isolate backfill state |
| 5 | healthkit-ingestion | `SnapshotAggregator.aggregateDay` | Cross-instance racing explicitly unserialized (`isMirroring` per-instance; `SettingsView.rebuildAllSnapshots` spins its own coordinator); recovery relies on unique-constraint + retry |
| 6 | healthkit-ingestion | `applyDailyHeartMetricsPrecedence` | Uses full calendar-day window for HRV/RHR; overnight Polar sessions crossing midnight split samples across two snapshots |
| 7 | healthkit-ingestion | `Reliability.spo2Overnight` | Classifies from mirror rows only, but precedence can compute values partly from live-HK samples not yet mirrored — `dataQuality` can understate on a fresh install |
| 8 | healthkit-ingestion | `SnapshotAggregator` ~line 239 | `steps`/exercise/vo2/daylight are never nil-ed out on re-aggregation when HK returns nil (most fields explicitly clear); stale values can persist |
| 9 | healthkit-ingestion | `nocturnalHRDip` | Mixes all HR sources (direct `averageQuantity`, no precedence); Polar daytime sessions can skew the day-HR denominator |
| 10 | healthkit-ingestion | `SampleCaptureRegistry` / `HealthKitManager.allReadTypes` | `bodyTemperature`/`bodyMass` mirrored and surfaced in `computeDataQuality` but never read in `aggregateDay` and absent from the authorization list — silently empty on real devices |
| 11 | healthkit-ingestion | `SampleTypeConfig.anchoredTypes` vs `SampleCaptureRegistry.quantityMetrics` | Two similar metric lists with different consumers and different membership (anchored: vo2Max/walkingHR/steadiness/audio; registry: bodyTemp/bodyMass/wristTemp/BP) |
| 12 | healthkit-ingestion | `BarometerService.captureIfSignificant` | Thresholds only latch when `onSignificantChange` is non-nil — ordering-sensitive on wiring (harmless today; `setupIfNeeded` wires first) |
| 13 | healthkit-ingestion | `HealthDataCoordinator.fillGaps` | 90-day cap with no follow-up: an app untouched >91 days permanently loses snapshot days beyond the cap |
| 14 | healthkit-ingestion | `SleepEfficiencyCalculator` / `SnapshotAggregator` | Uncommitted local modifications on branch `tooling/claude-code-recommendations`; survey describes the working tree |
| 15 | polar-hrv | `RRArchiveWriter.init(url:append:true)` | Misaligned existing file is truncated to zero bytes (whole prior night's raw RR lost), not just the partial trailing record |
| 16 | polar-hrv | `RRIntervalBuffer.flush(at:)` | Future-timestamped samples permanently dropped; off-main `Date()` at packet arrival vs main-actor tick `Date()` allows a small eviction race |
| 17 | polar-hrv | `SensorSession.batteryAtStart` | Populated from **iPhone** battery (`UIDevice` via `currentBatteryPercent`), not strap battery; name/docstring don't say which device |
| 18 | polar-hrv | `PolarHRMState.lastMinuteRMSSD` | On a skipped minute, the previous minute's value keeps displaying as current with no staleness indication |
| 19 | polar-hrv | `LFHFAggregator.nightlyAggregates` | Asymmetric no-data behavior: nightly overload silently omits zero-reading nights; per-session overload emits a `validWindowCount: 0` sentinel |
| 20 | polar-hrv | `LFHFAggregator.nightlyHRFromSummaries` | Weights `hrMean` by full `endTime - startTime` (gaps included) while `CoalescedNight.wearTimeSeconds` excludes gaps — two duration conventions in one aggregation |
| 21 | polar-hrv | `SpectralAnalyzer.computePSD` | Hann window applied **after** zero-padding, so the taper over the real signal is asymmetric (conventional practice windows first) |
| 22 | polar-hrv | `SensorInterruption.reason` | Docstring lists `"userWorkout"/"lowPowerMode"/"charging"` but the Polar path writes `"ble_disconnect"`/`"state_restoration_disconnected"` — uncoordinated free strings |
| 23 | polar-hrv | `PolarHRMService` / `LiveActivityCoordinator` | Logger subsystems differ within the cluster (`"AnxietyWatch"` vs `"com.groundeffectsoftware.AnxietyWatch"`) |
| 24 | polar-hrv | `RRArchiveAggregator` | Comments reference "PPG dropout/noise" but the H10 is ECG — comment drift from an Apple Watch context |
| 25 | polar-hrv | `PolarHRMService.finalizeOrphan` | Deliberately passes empty `hrValues` so `hrMean == 0` gates the session out of the HR chart — sentinel semantics documented only at the call site |
| 26 | cpap-emay | `CPAPImporter.importOSCAR` | Maps OSCAR *median* pressure into both `pressureMin` and `pressureMean`, 99.5th percentile into `pressureMax` — `pressureMin` is not a minimum for OSCAR rows; no field-level comment |
| 27 | cpap-emay | `CPAPImporter.updateSession` | Unconditionally overwrites `importSource` on upsert — a `caprx`/`manual` session silently becomes `csv`/`oscar` on re-import |
| 28 | cpap-emay | `CPAPSession.source` | `ImportSource` enum lacks an `edf` case though the docstring lists `"edf"`; an edf row reads back as `.csv` |
| 29 | cpap-emay | `EMAYImporter.parseRow` + `DedupKey` | Wall-clock parsing with `TimeZone.current`: fall-back DST maps the repeated 1–2 AM hour onto identical `Date`s, so the second hour's samples are dropped by dedup |
| 30 | cpap-emay | `AnxietyWatchApp.runImports` / `CPAPListView.handleImport` | EMAY imports never trigger a snapshot backfill (`backfillSnapshots` gated on `kind == .cpap`); an EMAY night doesn't update `HealthSnapshot` SpO2 until `aggregateDay` runs from another path |
| 31 | cpap-emay | `EMAYImporter.parseRow`/`importLines` | A both-zeros (dropout) row inserts nothing but counts as "parsed" and extends the dedup window and reported `dateRange` |
| 32 | cpap-emay | `CPAPImporter.importSimple`, `EMAYImporter.importLines` | Both split on bare `","` with no quoted-field handling; future quoted-comma formats would mis-column silently |
| 33 | cpap-emay | `AnxietyWatchApp.runImports` + `CPAPImporter.prefetchSessions` | Fresh `ModelContext` per file: two same-batch files upserting the same CPAP date each prefetch from their own context; `#Unique([\.date])` is the only cross-context guard |
| 34 | cpap-emay | `EMAYImporter.sourceBundleID` | Deliberate non-dedup against `com.emay.oximeter` HK writes means running CSV + companion-app paths double-counts the same night (documented, by design) |
| 35 | cpap-emay | `SnapshotAggregator.swift` | Uncommitted local modifications to the SpO2 precedence path on the current branch (same caveat as #14) |
| 36 | sync-restore | `SyncService.fetchPrescriptions` / `SongService.search` | URL path handling inconsistent: `sync()` preserves a configured base path; `fetchPrescriptions`/`postRRArchive`/`restoreFromServer`/all `SongService` calls overwrite `components.path` unconditionally |
| 37 | sync-restore | `PhoneConnectivityManager.updateCheckInContext` | Seeds outgoing context from `receivedApplicationContext` (the watch→phone direction) rather than the last-sent outgoing context — mixes directional dictionaries |
| 38 | sync-restore | `PhoneConnectivityManager.session(_:didReceive:)` | File-receive path builds a `ModelContext` and saves on the nonisolated delegate thread while `handleIncoming` hops to `@MainActor` — two isolation conventions in one file |
| 39 | sync-restore | `SyncService.restoreFromServer` | Post-restore, `lastSyncDate` stays nil while only bulk types are flagged synced — a configured sync would full-export date-shifted demo copies of small-volume entities back to the server (DEBUG/sim only) |
| 40 | sync-restore | `importMedDoses` | Hardcodes `isPRN: true` for every restored dose regardless of server data |
| 41 | sync-restore | `computeMaxAlignedShift` | Sleep events get their own alignment shift but `sensorSessions`/`hrvReadings` use the global shift — restored HRV cards can misalign with snapshots (see Known-issue seeds) |
| 42 | sync-restore | `SyncService.upsertCorrelations` | Parses `computed_at` with a no-fractional-seconds `ISO8601DateFormatter` and silently falls back to `.now` on failure — fractional server timestamps always read as "just computed" |
| 43 | sync-restore | `SongService.fetchCatalog` | Update path never refreshes `geniusURL` (`CatalogSong` doesn't decode `genius_url`); `hasLyrics` decoded but unused |
| 44 | sync-restore | `PhoneConnectivityManager.sendStatsToWatch` | Replaces the whole applicationContext with only currently-non-nil metrics — a previously-sent value disappears when the next push has it nil |
| 45 | sync-restore | `SyncService.maxRoundTrips` | Deliberate constant reuse of `sampleBatchLimit` as the drain-loop cap — coincidental coupling of batch size and round-trip limit |
| 46 | medications | `PrescriptionSupplyCalculator.latestPrescriptionPerMedication` | Returns `Array(latest.values)` (dictionary order); `alertPrescriptions` callers `ForEach` without sorting — deterministic-ordering rule candidate |
| 47 | medications | `MedicationsHubView.recentDoses` / `PrescriptionListView` | Unbounded `@Query`s over whole tables then `prefix(10)`/in-memory filter; per-row `supplyStatus` recomputed across multiple `body` accesses |
| 48 | medications | `PharmacyDetailView.prescriptionsSection` | `NavigationLink(value: rx)` for `Prescription` with no `navigationDestination(for: Prescription.self)` anywhere in the repo — links may be inert |
| 49 | medications | `PharmacyCallService.handleCallChanged` | Any `CXCall` state change is attributed to the pending pharmacy log (no number matching) — an unrelated call in the 30 s window could upgrade the log |
| 50 | medications | `PharmacyCallService.initiateCall` | A second call while one is pending silently overwrites `pendingCallLogId`, orphaning the earlier log as "attempted"; single-call assumption implicit |
| 51 | medications | `PrescriptionImporter.update` | Fills `refillsRemaining` only when local is 0 and incoming > 0 — server-side refill decreases never propagate |
| 52 | medications | `Prescription.importSource` | Docstring says `"manual"`/`"walgreens"` but the importer defaults to `"caprx"` — vocabulary drift |
| 53 | medications | `AddPrescriptionView` scanner prefill | `Double(dose.filter { isNumber or "." })` concatenates digits across compound strings ("10mg/5mL" → "105"); mL doses set `doseMg = 0` |
| 54 | medications | `AddPrescriptionView.addNewSentinel` | Magic UUID (`…-000000000001`) as the "Add New…" picker tag |
| 55 | medications | `AnxietyWatchApp` (`reactivateMedsKey`) | One-time fixup re-activates ALL inactive `MedicationDefinition`s, overriding deliberate pre-migration deactivations; flag + code linger post-migration |
| 56 | medications | `PrescriptionLabelScanner.parse` | Dose regex includes `tablet\|cap\|capsule` as units, so "Take 1 tablet" directions can claim the `dose` field first (order-dependent on OCR lines) |
| 57 | medications | `MedicationsHubView.logDose` | Non-prompt path inserts a dose without `modelContext.save()` and schedules no follow-up (only `promptAnxietyOnLog` meds get the loop) — asymmetry undocumented |
| 58 | medications | `Prescription.rxNumber` | No uniqueness enforcement for manual entries despite being the importer's upsert key |
| 59 | dashboard | `DashboardView.body` → `vm.smartSummary` | Passes the full 30-day `recentSleepEvents` into `SleepEfficiencyCalculator.compute` — a single-night calculator; the summary's efficiency figure spans the whole event stream |
| 60 | dashboard | `DashboardView.lastNightSection` | Pairs `recentSnapshots.first(where:)` with `recentCPAP.first` without checking same-night — an older CPAP session can merge into a newer snapshot's card |
| 61 | dashboard | `LastNightCard` / `lastNightSection` | `SleepEfficiencyCalculator.compute` + `LastNightHeadline.compose` run twice per render in the linked branch (a11y label + card body) |
| 62 | dashboard | `DashboardViewModel.smartSummary` | Falls back to `snapshots.first?.hrvAvg ?? 0` when today's snapshot is missing — a genuine 0 with a valid baseline yields an extreme z-score phrased as today's change |
| 63 | dashboard | `DashboardView.body` (`activeAlerts`) | Composer's alert count covers only supply (`lowSupplyCount`), not `AlertsSectionView.buildAlerts()` output — quiet state can coexist with visible baseline alerts |
| 64 | dashboard | `SmartSummaryComposer.compose` | AHI candidate pre-filtered at \|z\| > 1.0 inside its own branch (duplicating `notable`); sleep-efficiency candidate appended unconditionally (even at 0% from empty events) whenever a baseline exists |
| 65 | dashboard | `AnxietyPredictor.predict` | No production call sites — only `AnxietyPredictorTests` (possibly orphaned by the PR #147 dashboard trim) |
| 66 | dashboard | `DashboardView.init()` `recentCutoff` | 30-day cutoff captured at view-struct creation; a very long-lived scene slides the window stale (documented in-file) |
| 67 | dashboard | `VitalsGridSectionView.walkHRTile` | `baselineDelta(value:baseline: nil,...)` — deliberately-nil baseline, permanent no-op chip kept as placeholder (per comment) |
| 68 | dashboard | `AlertsSectionView` sleep alert | Says "Last night's sleep" but reads `snapshots.first?.sleepDurationMin` — the newest snapshot may be older than last night if aggregation lagged |
| 69 | dashboard | `VitalsGridSectionView`/`VitalsHeroSectionView` | Dashboard tile series colors are raw literals (`.red`, `.mint`, `.indigo`…) — ChartPalette/Semgrep scope is only `Views/Trends/` |
| 70 | dashboard | `DashboardViewModel.deviceChipSource` | Apple sources matched by substring (`"apple.health"`/`"com.apple"`) — no single constant covers the variants |
| 71 | trends-charts | `LFHFSessionsListView` | Appears unreachable from production code — the LF/HF trend card that linked to it was removed from `TrendsView` |
| 72 | trends-charts | `HRVTrendChart` | Colors Polar **SDNN** with `ChartPalette.polarRMSSD` — token name drifted from usage; legend just says "Purple: Polar" |
| 73 | trends-charts | `ChartPalette.glucose` | Literally `Color.purple`, identical to `polarRMSSD`, though its doc claims "Magenta family — distinct from HRV purples" |
| 74 | trends-charts | `PolarSessionHRDetailView.sleepStageBands` | Hardcodes stage colors (`.indigo/.purple/.blue/.orange`) instead of `ChartPalette.sleepDeep/REM/Core`; its REM (purple) disagrees with `SleepTrendChart` REM (cyan) |
| 75 | trends-charts | `CorrelationInsightsView` / `CorrelationChartView` | Closure-based `@Query`-holding destinations without `Equatable` + `.equatable()`; their `AnxietyEntry`/`HealthSnapshot` queries are also unbounded |
| 76 | trends-charts | `GlucoseTrendChart.datums` | Computed property accessed by `datums`/`rollingMean`/`meanCV`/`subtitle`/`body` — each access re-runs `GlucoseTrendDatum.from` including per-snapshot `JSONSerialization` of `dataQuality` |
| 77 | trends-charts | `TrendsView.filterBySource` | Hardcodes entry-source literals (`"user"`, `"dose_followup"`, `"random_checkin"`) outside `#Predicate` |
| 78 | trends-charts | `TrendWindow` | Current-period width is periodDays *plus* today's elapsed hours — "7 Days" spans up to ~8 calendar days; past pages are exact |
| 79 | trends-charts | `TrendsView.body` | Full Polar pipeline (coalesce + `nightlyAggregates` over the entire source-filtered `HRVReading` table) runs on the main thread per body evaluation — watch as the table grows |
| 80 | trends-charts | `LFHFAggregator` doc comment | Doc comment is one of only two remaining references to `LFHFSessionsListView` (see #71) — doc/reachability drift |
| 81 | journal-labs | `DataExporter.AnxietyEntryDTO` | Omits `source`, `isFollowUp`, `triggerDose`; `SongDTO` CSV omits `geniusURL` — exports lossy relative to models; sync consumers can't distinguish check-in entries |
| 82 | journal-labs | `AddJournalEntryView.save()` | Never calls `modelContext.save()` while `RandomCheckInPromptView.logEntry` does `try? modelContext.save()` — inconsistent persistence discipline |
| 83 | journal-labs | `AddJournalEntryView.save()` (express mode) | Saves with the `timestamp` `@State` captured at sheet-open, not tap time — a long-idle sheet logs a stale timestamp |
| 84 | journal-labs | `SongDetailView.toolbar` | Edit→Done sets `lyricsSource = "manual"` whenever lyrics are non-nil, even for a title-only edit — clobbers genius/server provenance |
| 85 | journal-labs | `SongLinkHelper.occurrenceSource(for:)` | `SongOccurrence.source` documents `"standalone"` but no code path in the cluster creates it |
| 86 | journal-labs | `FHIRLabResultParser.parseDate` | Date-only strings parse to local midnight (no explicit timeZone) — displayed day can shift with device timezone; `effectivePeriod` FHIR records dropped entirely |
| 87 | journal-labs | `ExportView.filteredCounts`/`generatePDF()` | `endDate` starts as `Date.now` with `.date`-only pickers — the end bound carries sheet-open time-of-day; later same-day entries fall outside the inclusive range |
| 88 | journal-labs | `ExportView` | Six unbounded `@Query`s filtered in-memory; "Data Summary" counts recompute per render (tolerated: export is whole-table by nature) |
| 89 | journal-labs | `LabResultsView.statusColor` (+2) | In-range/low/high status color logic triplicated across `LabResultsView`, `LabTestHistoryView`, `LabResultMetricCard` — drift risk |
| 90 | journal-labs | `LabTestHistoryView.chartView` | Reference band uses registry population norms while point colors use lab-provided ranges — a point can render red inside the green band; band spans only first→last result dates |
| 91 | journal-labs | `SongCatalogView.sortedSongs` | Delete offsets and rendering both derive from a locally re-sorted computed property over an already-sorted `@Query` — correct today, fragile pairing |
| 92 | journal-labs | `LabTestHistoryView` marks | Raw `.green`/`.orange`/`.red` on chart marks — outside the Semgrep rule's `Views/Trends/` scope; semantic status colors, intent vs `ChartPalette` unconfirmed |
| 93 | journal-labs | `SongOccurrence.source` vs `AnxietyEntry.source` | Overlapping concepts, different vocabularies ("journal"/"checkin"/"standalone" vs "user"/"dose_followup"/"random_checkin") |
| 94 | watch-widgets | `RawAccelerometerBuffer` | No callers anywhere — `writeChunk`/`pruneOldChunks` never invoked; the 48 h raw-accel retention pipeline is scaffolding or a dropped feature |
| 95 | watch-widgets | `SensorCaptureSession.handleNewHealthData` | Stub; the watch never creates `HRVReading` rows, so the `HRVDTO` leg of `SensorTransferPayload`/`transferSensorData` is dead on the watch→phone path |
| 96 | watch-widgets | `SensorTransferPayload` | No `SensorSession` DTO — watch-side session rows never reach the phone; transferred readings carry dangling `sensorSessionID`s in the phone store |
| 97 | watch-widgets | `SensorCaptureSession.stop(modelContainer:)` | No caller in the watch app — capture is never stopped, so watch `SensorSession.endTime`/`batteryAtEnd` presumably never populate |
| 98 | watch-widgets | `QuickLogView.severityColor` vs `CurrentStatsView`/`RectangularView` | Severity color buckets disagree within the cluster (1–2 green/3–4 yellow/… vs 1–3 green/4–6 yellow/…); QuickLogView's comment claims parity with `SeverityColor.swift` |
| 99 | watch-widgets | `WatchConnectivityManager.transferSensorData` | Doc comment says "call periodically (e.g., every 5 minutes)" but `startSensorCapture` calls it every 60 s — doc drift |
| 100 | watch-widgets | watch SwiftData store | Nothing prunes `AccelSpectrogram`/`DerivedBreathingRate` after transfer (re-sends recent 500, never deletes) — unbounded growth during long-term capture |
| 101 | watch-widgets | `WatchConnectivityManager.sendAnxietyEntry` | `transferUserInfo` fallback inside the `sendMessage` error handler could double-deliver; `AnxietyEntry` has no `#Unique` on the phone, so a duplicate persists |
| 102 | watch-widgets | `RectangularView` | Widget hardcodes series-like colors (`.blue` HRV, `.red` RHR) — outside ChartPalette scope but visually parallel to the token rule |
| 103 | watch-widgets | `PhoneConnectivityManager.updateCheckInContext` | Seeds from `receivedApplicationContext`; stats keys could drop from the merged context when the watch has never sent one (same root as #37) |
| 104 | watch-widgets | `SharedData` (×2) + `sendStatsToWatch` | App-group name + key strings duplicated verbatim in three places |
| 105 | models-layer | `CPAPSession.source` | Missing `edf` enum case vs docstring (same as #28; schema-level view) |
| 106 | models-layer | `HRVReading.syncedToServer` | Defaults `false` (pre-migration rows all re-upload) while `HealthSnapshot.syncedToServer` deliberately defaults `true` — asymmetry undocumented (possibly fine: HRV re-upload is id-idempotent) |
| 107 | models-layer | `SensorTransferPayload.HRVDTO` | Carries no `source`/`syncedToServer` — watch-originated readings land with `source == nil`; future watch tagging needs a DTO change |
| 108 | models-layer | `QuantityHealthSample.id` | Mixed uniqueness idioms: `#Unique` macro (newer sensor models) vs `@Attribute(.unique)` (mirror tables) |
| 109 | models-layer | `AnxietyEntry.id` | `AnxietyEntry`, `MedicationDose`, `BarometricReading`, pharmacy/prescription tables have no uniqueness constraint on `id`; dedup relies entirely on the cursor mechanism |
| 110 | models-layer | `HealthSample` `#Unique` | Includes optional `source` as a constraint component — behavior for two rows with same `(type, timestamp)` and both `source == nil` unconfirmed |
| 111 | models-layer | `SongOccurrence.source` | Vocabulary overlap with `AnxietyEntry.source` (same as #93; schema-level view) |
| 112 | models-layer | `Services/RestoreFromServer.swift` | Untracked new file in the working tree at survey time — interacts with every idempotency key above (now surveyed in sync-restore) |
| 113 | server-core | `_upsert_song_occurrences` | Returns `len(occurrences)` including `continue`-skipped rows — `sync_log.record_counts` can over-report |
| 114 | server-core | `sync()` correlation recompute | `compute_correlations` (scipy) runs synchronously inside the `/api/sync` request post-commit; lengthens every sync that finds correlations stale (also in `GET /api/correlations`) |
| 115 | server-core | `correlations_are_stale` | Compares `MAX(timestamp) > MAX(computed_at)` — a backfilled/past-dated entry synced after computation doesn't mark correlations stale |
| 116 | server-core | `_overnight_stats_update_clause` etc. | Schema-version boundaries scattered (v≥2, v≥3 hand-rolled in server.py, no central registry); a v4 field needs a third clause function |
| 117 | server-core | `admin.data` | `int(request.args.get("limit", 50))` unguarded — non-numeric `?limit=` → ValueError → 500 |
| 118 | server-core | `admin.resmed_settings` | Allows GET (and non-sync POST) without `SECRET_KEY` while walgreens/caprx settings redirect immediately — inconsistent guard placement |
| 119 | server-core | `settings` credential fields | CapRx encrypts the email (`caprx_username`) but `resmed_email` and `walgreens_username` are plaintext — inconsistent treatment |
| 120 | server-core | `crypto._fernet_key` | Static salt ⇒ deterministic key from `SECRET_KEY`; rotating `SECRET_KEY` silently orphans all encrypted settings |
| 121 | server-core | `admin.login` | No rate limiting or lockout (timing-safe compare only) |
| 122 | server-core | `resmed_settings` sync-now | Spawns `resmed_sync.py` with a relative path — depends on the Gunicorn worker cwd being `server/` |
| 123 | server-core | `sync_time` validation | Only the hour is validated (`HH` 0–23); `21:99` passes |
| 124 | server-core | `song_occurrences.anxiety_entry_id` | Holds an anxiety-entry *timestamp* (insert + `admin_song_detail` join confirm) — `_id` name misleading |
| 125 | server-core | `_upsert_songs` | Guarded last-write-wins silently drops stale replays but still counts them in the returned total |
| 126 | server-core | `api_songs_create` | External HTTP (Genius metadata + lyrics scrape + Musixmatch) inside the request while holding the open DB transaction |
| 127 | server-core | `GET /api/data` | No `since` streams every table in full (all bulk rows) in one JSON response — no pagination anywhere on the read API |
| 128 | server-core | `psychiatrist_profile_research` | Pins `claude-opus-4-7` while other admin calls use `claude-sonnet-4-20250514`; both string literals in admin.py, separate from `analysis.MODEL_CHOICES` |
| 129 | server-core | `require_api_key` | Commits the usage-stat update on the shared `g.db` before the handler runs — any pre-auth work by future code would be committed early |
| 130 | server-sync-clients | `Dockerfile` cron files | COPYs `resmed-cron` and `caprx-cron` but **not** `walgreens-cron` (file exists in repo) — the scheduled Walgreens sync appears never installed; only admin "sync now" runs it |
| 131 | server-sync-clients | `resmed_sync.log_sync()` | Sets `resmed_last_sync` unconditionally (even on error) while walgreens/caprx gate on success; presence shrinks lookback 365→7 days, so an error streak can leave a gap larger than the window |
| 132 | server-sync-clients | `WalgreensClient._try_fetch` | Accepts `start_date`/`end_date` but never uses them — the range computed in `walgreens_sync.main()` has no effect |
| 133 | server-sync-clients | `walgreens_sync.upsert_prescriptions` | `normalize_prescription()` emits price/insurance/address/phone/expiry/written-date fields that the upsert never inserts — expensive per-Rx UI-click enrichment dropped at the DB boundary |
| 134 | server-sync-clients | `settings` credentials | Credential-at-rest asymmetry (same as #119; client-side view) |
| 135 | server-sync-clients | `MyAirClient.fetch_sessions` | Naive local `datetime.now()` for the date range while sync scripts use UTC — mixed timezone conventions in one pipeline |
| 136 | server-sync-clients | `resmed_client._normalize_record` | Hardcodes `mean_pressure: None` and the cloud upsert refreshes `pressure_mean = EXCLUDED.pressure_mean` — every cloud re-sync re-nulls `pressure_mean` on `resmed_cloud` rows |
| 137 | server-sync-clients | `CapRxClient` | Stores `refresh_token` and documents the refresh exchange, but no refresh logic exists — a 401 mid-pagination raises `CapRxAuthError` |
| 138 | server-sync-clients | `log_sync` implementations | resmed/walgreens build `record_counts` JSONB via f-string interpolation; caprx uses `json.dumps` and interpolates exception text into `status` — the f-string variants couldn't have handled that |
| 139 | server-sync-clients | `job_dispatcher.cascade_failures` / `find_ready_jobs` | Recursive per-dependent commits; all jobs loaded each 2 s poll — fine at 6 jobs, watch if the DAG grows |
| 140 | server-sync-clients | `walgreens_client._fetch_all_fill_histories` | Re-registers `page.on("response", ...)` per reload without removing prior listeners — stacked duplicate handlers (idempotent writes, currently harmless) |
| 141 | server-sync-clients | `server/test_walgreens_login.py` | Stray manual harness outside `tests/` at the package root |
| 142 | server-sync-clients | `prescriptions` granularity | Walgreens rows are per-prescription (real Rx number); CapRx rows are per-claim (`CRX-<id>`) — two granularities in one table (documented invariant, listed here as a modeling oddity) |
| 143 | server-crypto | `admin.create_key` | Raw API key transits to the browser inside a signed-but-not-encrypted session cookie until `keys()` pops it (single-admin HTTPS mitigates) |
| 144 | server-crypto | `create_app()` | Sets `SESSION_COOKIE_SAMESITE = "Strict"` but not `SESSION_COOKIE_SECURE` — cookies would ride plain HTTP on a misconfigured TLS termination |
| 145 | server-crypto | `init_db()` startup block | Swallows all exceptions, logging only the exception *type name* — a failed boot migration is nearly silent; app serves a possibly stale schema |
| 146 | server-crypto | `admin.resmed_settings` vs siblings | `SECRET_KEY` guard placement divergence (same as #118) |
| 147 | server-crypto | `require_api_key` | Early commit on `g.db` (same as #129) |
| 148 | server-crypto | admin "sync now" | Portal-scraping subprocesses run synchronously in the request thread with `env={**os.environ}` and 60–180 s timeouts — a Gunicorn worker is pinned |
| 149 | server-crypto | `admin.dashboard()` | `SELECT COUNT(*) FROM {table}` via f-string over a hardcoded list — the only non-parameterized construction in auth-adjacent code |
| 150 | server-crypto | `crypto._fernet_key` | 100k-iteration PBKDF2 re-run on every encrypt/decrypt, no memoization — hot-spot shape if per-record encryption ever appears |
| 151 | server-crypto | `0001_baseline_schema.downgrade()` | Carries drops for tables introduced by 0005; the baseline downgrade grows with every schema.sql table — easy to forget at migration N+1 |
| 152 | server-crypto | `alembic.ini` | Ships a real-looking default DSN; `env.py` and `init_db()` both defend against it reaching production — three code paths must keep agreeing |
| 153 | server-crypto | `crypto.encrypt_value` call sites | No key-rotation/re-encryption tooling despite `SECRET_KEY` being the single decryption point for four credential sets + the Walgreens session blob |
| 154 | server-crypto | `admin.login` | No expiry, no rate limiting (same as #121; auth-plane view) |
| 155 | server-crypto | `schema.sql` header | Says "REFERENCE ONLY" while being the executed 0001 baseline — the dual role is the source of the idempotent-migration requirement |
| 156 | server-analysis | `analysis.gather_analysis_data` | Day boundaries built in UTC while `build_prompt` tells Claude timestamps are US/Pacific — a Pacific-evening entry on `date_to` falls outside the range; same theme in `correlations.compute_correlations` day-bucketing |
| 157 | server-analysis | `analysis._complete_analysis` | Calls the API with module-level `MODEL`, ignoring the `model` stored on the analyses row; only the job-dispatcher path honors per-run choice (sync path test-only today) |
| 158 | server-analysis | `analysis._execute_analysis` | No callers anywhere — leftover from the pre-job-dispatcher architecture |
| 159 | server-analysis | `analysis.parse_response` vs `json_helpers.parse_llm_json` | Two fence-stripping implementations; the health-analysis path gets the weaker hand-rolled one |
| 160 | server-analysis | `edf_parser.upsert_cpap_leak` | Inserts `ahi = 0.0` as an unknown-AHI sentinel — downstream (correlations `cpap_ahi`, prompts) can't distinguish "perfect night" from "unknown" |
| 161 | server-analysis | `analysis.MODEL_CHOICES` | Identical hardcoded pricing for all three Opus models; a model deprecation silently breaks new analyses until edited |
| 162 | server-analysis | `song_occurrences.anxiety_entry_id` | TIMESTAMPTZ named like an int FK; an anxiety-entry timestamp edit silently orphans the link (same as #124; analysis-side view) |
| 163 | server-analysis | `correlations` rows | All-time global, no date window; a 2-week analysis prompt receives whole-history correlations without that caveat |
| 164 | server-analysis | `job_dispatcher.cascade_failures` | Recurses only into `pending` dependents; a `running` dependent whose dependency fails is left to finish — implicit invariant (deps complete before dependents start) |
| 165 | server-analysis | `genius.scrape_lyrics` | Depends on Genius page markup (`data-lyrics-container`) — fragile; page-scraping is ToS-gray relative to the API metadata calls |
| 166 | server-analysis | `sweep_stale_analyses` | Times out from `created_at`, not `started_at` — a queued-then-slow analysis is marked failed at minute 15 while the dispatcher may still write a completion afterward |
| 167 | server-analysis | `flag_outliers` sleep consistency check | The prompt-side "do NOT use" guard for physiologically impossible sleep values exists server-side only — the iOS charts have no equivalent gate (see Known-issue seeds) |
| 168 | tooling-ci | CLAUDE.md Commands section | Claims "no shared schemes are checked in" but three shared schemes are tracked at `AnxietyWatch.xcodeproj/xcshareddata/xcschemes/` — stale doc |
| 169 | tooling-ci | `pre-pr-reviewer-reminder.py` | Prints to stderr with exit 0; PreToolUse stderr at exit 0 may never be surfaced to the model (exit 2 is the feedback channel) — whether the reminder is seen is unconfirmed |
| 170 | tooling-ci | `post-tool-call.py::http_request` | Calls `connection.request(...)` without `getresponse()`; `excepthook` exits 1 on any failure — a down provenance server fails every Write/Edit PostToolUse locally |
| 171 | tooling-ci | `.semgrep/swift-pitfalls.yml` | In generic mode `pattern-not-regex` filters on the *matched range* (the string literal), so the `#Predicate` exclusion in `anxietywatch-hardcoded-source-label` (and the `//.*lastSyncDate` comment exemption in `anxietywatch-sync-cursor-now`) may not fire as the comments imply |
| 172 | tooling-ci | `voiceover-consistency-edited.py::find_slash_in_accessibility_label` | Outer `re.search(re.escape(label)…)` is always true (label extracted from the same content) — nested skip logic is the only effective condition |
| 173 | tooling-ci | `medication-name-drift-warn.py::discover_canonical_names` | Scrapes *any* capitalized quoted string ≥4 chars from `MedicationDefinition.swift` — could silently whitelist non-medication strings |
| 174 | tooling-ci | `settings.json` vs `ios-ci.yml` | `DEFAULT_SIMULATOR: iPhone 17 Pro` vs CI fallback "iPhone 16 Pro" — two defaults for the same concept |
| 175 | tooling-ci | `.claude/settings.json` matchers | Hooks target a `MultiEdit` tool name; if the harness no longer emits it, the matcher is dead weight |
| 176 | tooling-ci | `.claude/hooks/__pycache__/` | Compiled `.pyc` (cpython-314) for four hooks with no importer found in the repo — untracked clutter |
| 177 | tooling-ci | `.claude/worktrees/fix+song-lyrics-cap/` | Full stale worktree checkout shadowing real paths in grep results; may confuse path-scoped tooling |
| 178 | tooling-ci | `swift-pre-pr-reviewer.md` | Mentions a planned `/pre-pr-review` slash command "as a follow-up" that still doesn't exist — Task-dispatch only |
| 179 | tooling-ci | `block-pii-in-fixtures.py::extract_content` | Inspects only the incoming edit's `new_string`/`content` — pre-existing PII or Bash-heredoc/`sed` introductions are out of reach |
| 180 | tooling-ci | `.swiftlint.yml` | Watch App and Widgets targets are excluded from lint entirely |
| 181 | invariants-registry | `LFHFSessionsListView` @Query | Source-filtered but not date-bounded — the exact pattern pitfall #2 forbids (may be intentional: per-session table is small); compounds with #71 (view may be unreachable) |
| 182 | invariants-registry | `AnxietyWatchTests/Helpers/TestHelpers.swift` | No shared float-epsilon `#expect` helper; each test hand-rolls `abs(x - y) < 0.0001` — inconsistent tolerances invited |
| 183 | invariants-registry | `anxietywatch-sync-cursor-now` paths.include | ERROR rule path-scoped to `SyncService.swift` only — any future sync-like cursor elsewhere escapes it; the new `RestoreFromServer.swift` sits outside the scope |
| 184 | invariants-registry | `anxietywatch-overnight-threshold-magic-number` | `languages: [generic]` regex patterns behave literal-ish — `3*3600` or `60 * 60 * 3` variants would not match |
| 185 | invariants-registry | CLAUDE.md regression-test names | Cites `payloadUpperBoundCapsExportRange`/`payloadBulkOnlyOmitsSmallVolumeTables` (function names) while the `@Test` display strings differ — sync check needed next doc touch |
| 186 | invariants-registry | `.claude/hooks/post-tool-call.py` | Absent from CLAUDE.md's hook inventory and wired only in gitignored `settings.local.json` — a personal hook living in a committed directory |
| 187 | recording-pill | `RecordingStatusPill` re-clamp comment | Justifies re-clamping with "iCloud-synced UserDefaults could surface a position from a larger device", but `PillPositionStore` uses plain `UserDefaults.standard`, which does not sync via iCloud (that would be `NSUbiquitousKeyValueStore`) — re-clamp still right for rotation/multitasking, but the rationale is comment drift |
| 188 | recording-pill | `RecordingPillContent` doc comment | Says "(and, in the future, the Live Activity widget)" while the Live Activity already ships via `HRVRecordingActivityAttributes+PolarHRMState` and deliberately does *not* use this helper (per `RecordingFormatters`' own doc) — stale future tense pointing the wrong way |
| 189 | recording-pill | `RecordingStatusPill` elapsed text | Ticks only when the service externally updates `PolarHRMState.sessionElapsed`; unlike the Live Activity's self-ticking `Text(timerInterval:)`, a stall in the service's update loop freezes the in-app elapsed display with no staleness cue |
| 190 | recording-pill | `RecordingStatusPill` drag | `dragOffset` applied unclamped during the drag (`onChanged` stores raw translation); clamping happens only `onEnded` — mid-drag the pill can visually leave the safe rect and snap back on release |
| 191 | recording-pill | `RecordingStatusPill` a11y | Hint says "Drag to move the pill" but there is no `.accessibilityAction` alternative to the `DragGesture` — VoiceOver users cannot reposition the pill, notable given the project's a11y hook coverage |
| 192 | recording-pill | `DragGesture(minimumDistance: 3)` | Hair-trigger: a tap with ≥3 pt of finger movement becomes a no-op drag instead of opening the sheet (trade-off documented in-file, but an easy "tap sometimes doesn't work" report) |
| 193 | recording-pill | `PillPositionStore.load()` | Swallows decode failures with `try?` — corrupt/legacy data silently reverts to the default anchor with no cleanup of the stale key |
| 194 | recording-pill | `PillSizePreferenceKey.defaultValue` | `static var` (not `let`) — harmless today but a Swift 6 strict-concurrency warning candidate |
| 195 | recording-pill | pill measurement gate | When recording ends, the preference reverts `pillSize` to `.zero`, so every new session re-runs the invisible measurement frame — intended, but the opacity gate is on the hot path of every session start, not just first launch |
| 196 | recording-pill | `HRVSessionCardView` vs `PolarSettingsView` | Both flip the same `showingLiveView` flag, but only `PolarSettingsView` gates the flip on current status (`if case .connecting/.recording`); the Dashboard card sets it `true` unconditionally — consistent-looking entry points with subtly different guard conventions |
| 197 | dashboard | `MetricSalience` | Orphaned but tested — spec'd (dashboard-trim design), shipped in PR #147, no production caller (the plan's `DashboardViewModel.salience(for:)` never landed); the exact analogue of the `AnxietyPredictor` orphan (#65); a Dashboard contributor could re-derive these rules from the spec without knowing they're already codified and tested |
| 198 | dashboard | `MetricSalience.Verdict` | The design spec's `Verdict` included an optional `reason` string for the demoted-section header; the implementation dropped it — any future wiring needing demote reasons must re-widen the API |
| 199 | dashboard | `MetricSalienceTests` | Test coverage is partial: walking steadiness, audio exposure, blood pressure, and glucose verdicts are untested, despite the file existing solely to be testable |
| 200 | dashboard | `MetricSalience.bloodPressureVerdict` | Asymmetric guard: the "3 readings" gate checks `last3Systolic.count >= 3` only; `zip` silently truncates to the shorter array, so 3 systolic + 2 diastolic values can yield `.surface` from 2 pairs; callers must pass already-limited last-3 arrays — nothing enforces ordering/length beyond parameter names |
| 201 | dashboard | `MetricSalience.glucoseVerdict` | Thresholds 180/100 imply mg/dL but no unit appears in the signature or doc comment — a unit-mismatch hazard of exactly the kind `medical-data-accuracy-reviewer` targets, should this ever gain a HealthKit-fed caller (HKQuantity glucose can be mmol/L) |
| 202 | dashboard | `MetricSalience` inputs | Walking steadiness, AFib burden, and audio exposure verdicts assume inputs (Apple steadiness ratio, AFib burden %, dBA TWA) from HealthKit types not clearly aggregated anywhere yet — the rules may be ahead of the data pipeline, which could be *why* wiring stalled |
| 203 | medications | `NotificationDelegate.userNotificationCenter(_:didReceive:)` | The tap handler routes only to `checkPendingFollowUp()` — tapping a `RANDOM_CHECKIN` banner while the app is already foregrounded never calls `checkPendingRandomCheckIn()` (no scene-phase transition fires); a foreground check-in banner tap is a silent no-op until the next scene transition (the minute-timer also only checks follow-ups) |
| 204 | medications | `didReceive` action handling | Does not distinguish `UNNotificationDismissActionIdentifier` from the default tap action; currently harmless (no category registers `customDismissAction`), but a future category that does would make dismissals fire the follow-up check |
| 205 | medications | `NotificationDelegate` doc comment | Says taps arrive "from lock screen, banner, or Watch" — taps on Watch-mirrored notifications launch the watch app, not the iOS delegate; the "Watch" claim is at best indirect |
| 206 | medications | `willPresent` options | `[.banner, .sound]` plays sound even when the user is actively in the app; omitting `.list` means a foreground-presented follow-up the user ignores leaves no trace in Notification Center to return to |
| 207 | medications | `.didTapLocalNotification` | Generic name and nil object leave no room for a second notification-driven feature to discriminate taps without widening this file — fine today with one consumer, a refactor point the moment a second tap-consumer appears |

---

## Known-issue seeds

Pre-identified items carried into Phase 2 alongside the oddity index:

1. **Sleep lane shows physiologically impossible values.** The Trends sleep lane has rendered impossible sleep values; queued for a separate investigation against the raw `health.psv` data. Note the asymmetry captured in oddity #167: the server prompt path guards against this (`analysis.flag_outliers` checks `PHYSIOLOGICAL_LIMITS` and sleep-stage-total-vs-duration consistency and injects "do NOT use" instructions), but no equivalent gate exists on the iOS chart path (`SleepTrendChart` / `SnapshotAggregator` sleep-stage fields). Suspects worth cross-referencing: `SleepIntervalMerger` overlap collapsing, multi-source stage merging in `SnapshotAggregator.aggregateDay`, and migration 0002's "sleep cap" data fix (which implies the bad values have reached the server before).

2. **Estimated sleep efficiency vs verdict (deferred from PR #152).** `SleepEfficiencyCalculator.compute` pins efficiency at ≤100% and sets `isBedTimeEstimated` when the inBed denominator falls back to the asleep span; `LastNightHeadline.compose` counts efficiency <85% as a breach toward the Solid/OK/Rough verdict and prefixes "~" when estimated. The open question deferred from PR #152: should an *estimated* efficiency participate in the breach count at all (a pinned ~100% can mask a real efficiency breach, and an artifactual low estimate can manufacture one), or should the verdict treat estimated efficiency as absent? Related live observations: oddities #59 (30-day event stream fed into the single-night calculator via `smartSummary`) and #61 (double computation per render).

3. **RestoreFromServer per-entity sleep shift only aligns the newest night (documented tradeoff).** `SyncService.restoreFromServer` applies a global `computeDateShift` (most-recent row → today) to most entities but a separate `computeMaxAlignedShift` to sleep events so the newest night lines up with the newest snapshot. Sessions and HRV readings (`sensorSessions`/`hrvReadings`) still use the global shift, so if Polar sessions lag the snapshot max date the way sleep events do, restored HRV cards can misalign with their snapshots (oddity #41). The single-shift-per-entity approach also means only the *newest* night is guaranteed aligned; older nights retain whatever relative skew existed on the server. DEBUG/simulator-only surface, but it shapes every demo dataset.
