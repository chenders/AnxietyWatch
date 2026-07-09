# Fable 5 Re-Evaluation — Findings Register

The living register for Phases 2 (static audit), 6 (sensor reliability), and 7 (runtime). Each finding is one row. Only adversarially-verified findings are marked **confirmed** (≥2 of 3 verify lenses agreed); everything else is **plausible** — which here includes findings whose verification lenses were cut off by the session-limit interruption (see the [Phase 2 implementation notes](02-deep-audit.md#implementation-notes-post-merge)), not only genuinely-uncertain ones.

## Format

| Field | Meaning |
|-------|---------|
| ID | `F-NNN` stable identifier |
| Subsystem | code area (e.g. `polar-hrv`, `sync`, `server-auth`) |
| Severity | P0 (data corruption / crash / security) → P3 (cosmetic / nit) |
| Confidence | `confirmed` (≥2 of 3 verify lenses agree) / `plausible` |
| Effort | S / M / L |
| Tag | `bug` / `accuracy` / `efficiency` / `render` / `silent-failure` / `security` / `test-gap` / `reliability` / `runtime` |
| Disposition | `open` / `approved` / `deferred` / `rejected` / `fixed (#PR)` |

**Severity note:** the headline **Sev** below is the *verified* severity — the median of the 3 verification lenses' severity votes for confirmed findings (per the master-plan synthesis rule), which is often one tier below the finder's initial rating. Each finding's **finder severity** and the raw lens votes are recorded in the Detailed findings section so a value can be re-elevated at triage. In particular the render/data-loss crash pitfalls (Pitfall #2 NavigationLink family, the RR-archive wipe) were rated P0 by the finders and voted P1 by the severity lenses; a maintainer may reasonably restore P0.

## Register

Severity-ranked; confirmed before plausible within a tier. Full failure scenarios are in [Detailed findings](#detailed-findings) below — this table is the scan view. Disposition is `open` for every entry pending the maintainer's triage pass. In the table, the **Conf** column abbreviates the confidence values defined above: `conf` = `confirmed`, `plaus` = `plausible`.

| ID | Sev | Conf | Eff | Tag | Subsystem | Summary | Anchor |
|----|-----|------|-----|-----|-----------|---------|--------|
| F-001 | P0 | conf | S | render | lab-results-nav | LabResultsView's own body pushes LabTestHistoryView via a closure-form NavigationLink whose destination owns an unbounded @Query, with neither Equatable conformance nor `.equatable()` at the call site — the exact pitfall LabResultsView itself was hardened against one hop up, missed one hop down. | `AnxietyWatch/Views/LabResults/LabResultsView.swift:LabResultsView.body` |
| F-002 | P0 | conf | S | render | trends-correlation-nav | CorrelationInsightsView pushes CorrelationChartView via a closure-form NavigationLink; the destination holds two @Query properties but has no Equatable conformance and no .equatable() at the call site. | `AnxietyWatch/Views/Trends/CorrelationInsightsView.swift:31` |
| F-003 | P0 | conf | S | render | trends-correlation-nav | TrendsView pushes CorrelationInsightsView via a closure-form NavigationLink; the destination holds three @Query properties but has no Equatable conformance and no .equatable() at the call site. | `AnxietyWatch/Views/Trends/TrendsView.swift:269` |
| F-004 | P0 | conf | S | render | journal-nav | JournalListView pushes JournalEntryDetailView via a closure-form NavigationLink; the destination holds an unbounded @Query and has neither Equatable conformance nor .equatable() at the call site, matching the exact structural shape of the documented polar-session-hr-detail crash pattern. | `AnxietyWatch/Views/Journal/JournalListView.swift:JournalEntryRow-NavigationLink` |
| F-005 | P0 | conf | S | render | settings-navigation | Settings' closure-based NavigationLink to CPAPListView (which owns three @Query properties) has no Equatable conformance and no .equatable() at the call site, while the same screen drives a per-day rebuildProgress @State mutation loop that repeatedly re-executes the parent body. | `AnxietyWatch/Views/Settings/SettingsView.swift:SettingsView.body` |
| F-089 | P0 | conf | S | render | reports-nav | ExportView (five unbounded @Query properties) is pushed from SettingsView via a closure-form NavigationLink with neither Equatable conformance nor .equatable() at the call site — same family as F-001–F-005; found during the Batch A implementation review, missed by the Phase 2 audit. | `AnxietyWatch/Views/Reports/ExportView.swift:ExportView` |
| F-006 | P1 | plaus | S | silent-failure | cpap-emay | EMAY CSV imports never trigger a snapshot backfill in either import entry point, so imported oximeter data for a past night can silently never reach HealthSnapshot on a normal daily-use install. | `AnxietyWatch/App/AnxietyWatchApp.swift:processImportBatch` |
| F-007 | P1 | plaus | S | accuracy | cpap-oscar-import | OSCAR Summary CSV import writes the median pressure into both pressureMin and pressureMean, so an OSCAR-imported session's 'Min' pressure is never actually a minimum — it's the median, mislabeled. | `AnxietyWatch/Services/CPAPImporter.swift:importOSCAR` |
| F-008 | P1 | plaus | M | accuracy | fhir-labs | FHIRLabResultParser stores the lab's raw reported unit and value with no conversion or compatibility check against the registry's fixed-unit reference range, so cross-institution unit variance (mg/dL vs mmol/L, ng/dL vs pmol/L, mcg/dL vs nmol/L) silently produces wrong HIGH/LOW flags on screen and in the clinician PDF. | `AnxietyWatch/Services/FHIRLabResultParser.swift:parse(observation:)` |
| F-009 | P1 | plaus | S | bug | prescription-sync | PrescriptionImporter.update() refreshes daysSupply/patientPay/planPay on every re-sync of an existing rxNumber but never updates dateFilled or lastFillDate, so supply run-out math combines a stale fill date with a fresh supply duration after any refill. | `AnxietyWatch/Services/PrescriptionImporter.swift:update(_:from:directions:refills:context:)` |
| F-010 | P1 | plaus | S | accuracy | dashboard-summary | smartSummary substitutes 0 for missing HRV/RHR values, producing extreme false 'below baseline' headlines whenever today's snapshot lacks the metric. | `AnxietyWatch/Views/Dashboard/DashboardViewModel.swift:smartSummary` |
| F-011 | P1 | plaus | S | accuracy | dashboard-summary | The Smart Summary feeds the full 30-day SleepStageEvent stream into SleepEfficiencyCalculator, which is documented and written as a single-night calculator, so the displayed 'Sleep efficiency was X%' is a month-long aggregate (or a fabricated 0% when no events exist). | `AnxietyWatch/Views/Dashboard/DashboardView.swift:body` |
| F-012 | P1 | plaus | M | test-gap | sync | The cursor-advance invariants in SyncService.sync() (advance to the pre-captured cursorUpperBound, and only on non-bulkOnly iterations) have no test that fails if they break — all SyncServiceTests coverage stops at buildPayload, and sync() itself is untestable because it hardcodes URLSession.shared. | `AnxietyWatch/Services/SyncService.swift:sync()` |
| F-013 | P2 | conf | S | accuracy | sync-sensor-session | SensorSession rows synced mid-recording are flagged syncedToServer, and finalize()/finalizeOrphan() never re-dirty the flag, so the session's endTime, summaryJSON, and interruption data permanently never reach the server. | `AnxietyWatch/Services/HRVSessionRecorder.swift:finalize` |
| F-014 | P2 | conf | S | accuracy | sync-rr-archive | uploadPendingRRArchives uploads the RR archive of sessions that are still recording (no endTime guard) and stamps rrArchiveUploadedAt, so the server permanently keeps a truncated archive missing everything recorded after the mid-session sync. | `AnxietyWatch/Services/SyncService.swift:uploadPendingRRArchives` |
| F-090 | P2 | plaus | M | accuracy | sync-rr-archive | finalizeOffline flushes the RR archive via a detached background Task while recorder.finalize sets endTime synchronously, so uploadPendingRRArchives (gated only on endTime != nil) can read a not-yet-fully-flushed archive, upload it, and permanently stamp rrArchiveUploadedAt on a truncated file. | `AnxietyWatch/Services/PolarHRMService.swift:finalizeOffline` |
| F-091 | P2 | plaus | S | accuracy | server-correlations | correlations.py joins anxiety entries to health snapshots via a::timestamp::date cast in the DB session timezone (UTC), so a 9 PM Pacific entry joins to the NEXT day's snapshot — same UTC/Pacific day-bucketing family as F-029, one layer down in the correlation engine. | `server/correlations.py:36` |
| F-092 | P2 | plaus | M | accuracy | spo2-provenance | applyOvernightSpO2Precedence can pair avg/nadir from a sparse preferred-oximeter subset with T90/desats kept from the broader HK-direct set (post-F-023), and no rendered surface (LastNightCard, CPAPDetailView, clinician PDF) discloses the mixed provenance. | `AnxietyWatch/Services/SnapshotAggregator.swift:applyOvernightSpO2Precedence` |
| F-093 | P2 | plaus | M | accuracy | polar-hrv-freqdomain | The frequency-domain path still receives the spliced artifact-filtered RR array: resampleRRIntervals builds its tachogram from cumulative sums over the filtered array, fabricating a gap-spanning interval at each excised artifact — the same splicing defect F-026 fixed for RMSSD/pNN50, live for LF/HF/ratio. | `AnxietyWatch/Services/HRVSessionRecorder.swift:tick` |
| F-094 | P3 | conf | S | bug | restore-from-server | RestoreFromServer.importCPAPSessions guards `row["ahi"] as? Double`, so the JSON null AHI that EDF-only sessions now carry (post-F-068) fails the cast and the whole session row is silently skipped on restore — leak data never reaches a new device. | `AnxietyWatch/Services/RestoreFromServer.swift:importCPAPSessions` |
| F-095 | P3 | plaus | M | accuracy | reports-pdf | ExportView pre-filters snapshots to the selected report range before handing them to ReportGenerator, so the HRV "30-day baseline" is computed from only the range (mislabeled, or omitted) for report ranges shorter than 30 days. | `AnxietyWatch/Views/Reports/ExportView.swift:generatePDF` |
| F-096 | P3 | plaus | S | efficiency | watch-connectivity | The phone-side receive of watch sensor data constructs HRVReading with syncedToServer=false via the #Unique upsert, so any WCSession redelivery of an unchanged row (e.g. after a watch relaunch mid-transfer) re-dirties it and triggers a server re-upload. | `AnxietyWatch/Services/PhoneConnectivityManager.swift:session(_:didReceive:)` |
| F-015 | P2 | conf | S | silent-failure | sync-rr-archive | A failed RR-archive POST is never retried: the retry scan is keyed to uploadedIDs.sensorSessions (sessions in the current payload), but markSamplesSynced flips those sessions' syncedToServer=true in the same call, so they never appear in any future payload and rrArchiveUploadedAt==nil is never re-examined. | `AnxietyWatch/Services/SyncService.swift:applyPostUploadResponse` |
| F-016 | P1 | conf | S | bug | sync-actor-isolation | SongService.fetchCatalog(into:) and SyncService.fetchPrescriptions(modelContext:) are nonisolated async functions that fetch/insert/save on the caller's MainActor-bound ModelContext from the global concurrent executor — the exact undefined-behavior hazard the sync() doc comment was written to prevent, and it runs on every sync. | `AnxietyWatch/Services/SongService.swift:fetchCatalog` |
| F-017 | P2 | conf | S | bug | watch-connectivity | PhoneConnectivityManager.updateCheckInContext builds the outgoing applicationContext from WCSession.receivedApplicationContext (the context received FROM the Watch — always empty, since the Watch never calls updateApplicationContext) instead of .applicationContext (the last-sent context), so every check-in state change wipes the stats keys from the Watch's app context. | `AnxietyWatch/Services/PhoneConnectivityManager.swift:updateCheckInContext` |
| F-018 | P2 | conf | M | efficiency | watch-connectivity | WatchConnectivityManager.transferSensorData has no sent-tracking despite its 'Fetch un-synced' comments: every 60 seconds it re-encodes and re-transferFiles the most recent 500 rows of all three sensor tables forever, and the phone-side #Unique upsert resets HRVReading.syncedToServer=false on each redelivery, causing perpetual re-uploads of the same rows to the sync server. | `AnxietyWatch Watch App/WatchConnectivityManager.swift:transferSensorData` |
| F-019 | P2 | conf | S | silent-failure | server-jobs | _execute_single_job's exception handler calls mark_failed on the same connection without rollback, so any psycopg2 error inside the job body leaves the job stuck 'running' and the dispatch loop polling forever. | `server/job_dispatcher.py:_execute_single_job` |
| F-020 | P2 | conf | M | efficiency | trends-query | TrendsView's HRVReading @Query is source-filtered but has no date bound, so the entire per-minute HRV table is materialized on the main thread and fully re-aggregated (coalesce + nightlyAggregates with per-night MAD trims) on every body evaluation. | `AnxietyWatch/Views/Trends/TrendsView.swift:allHRVReadings` |
| F-021 | P2 | conf | M | efficiency | lfhf-sessions-list | LFHFSessionsListView loads the entire per-minute HRVReading table (source-filtered, no date bound) and recomputes per-session outlier-trimmed means over the full history on every body evaluation, just to render one HF/LF-HF number per list row. | `AnxietyWatch/Views/Trends/LFHFSessionsListView.swift:allReadings` |
| F-022 | P2 | conf | M | efficiency | trends-charts | TrendsView fetches the full date-unbounded per-minute Polar HRVReading table and re-runs the whole LFHF pipeline (coalesce, night filtering, member-ID set build, nightlyAggregates grouping, nightlyHRFromSummaries) inside body on the main thread on every re-render, not just when Polar data changes. | `AnxietyWatch/Views/Trends/TrendsView.swift:body` |
| F-023 | P2 | conf | S | accuracy | spo2-precedence | When a dedicated overnight oximeter contributes even a handful of samples, applyOvernightSpO2Precedence recomputes T90/desat count from that sparse preferred-only subset and nils the fields on failing its own sufficiency gate — discarding the already-sufficient HK-direct T90/desat values computed earlier in the same aggregateDay pass. | `AnxietyWatch/Services/SnapshotAggregator.swift:applyOvernightSpO2Precedence` |
| F-024 | P2 | conf | S | accuracy | last-night-verdict | LastNightHeadline.compose computes the efficiency-breach flag from the raw (possibly pinned-to-100%) efficiency value without regard to `efficiencyEstimated`, so a night with missing/incomplete inBed data — precisely the case the pin exists to flag as unreliable — can never register an efficiency breach and can present as 'Solid night'. | `AnxietyWatch/Services/LastNightHeadline.swift:compose` |
| F-025 | P1 | conf | M | silent-failure | polar-rr-archive | A misaligned (partially-written) .rr archive file is silently wiped to empty on next open instead of having only its corrupt trailing bytes discarded, permanently destroying every prior RR interval recorded for that session. | `AnxietyWatch/Services/RRArchiveWriter.swift:init(url:append:)` |
| F-026 | P2 | conf | M | accuracy | polar-hrv-timedomain | RMSSD and pNN50 are computed as successive differences over the artifact-filtered RR array, so removing an interior out-of-range RR interval silently splices together two non-adjacent heartbeats and injects a spurious, squared successive difference in exactly the window the filter was meant to protect. | `AnxietyWatch/Services/HRVCalculator.swift:timeDomain(rrIntervals:)` |
| F-027 | P2 | conf | M | bug | hr-hrv-precedence | applyDailyHeartMetricsPrecedence can never actually apply Polar H10 BLE-session precedence because it only reads QuantityHealthSample, and the app's own Polar BLE pipeline never writes to that table. | `AnxietyWatch/Services/SnapshotAggregator.swift:applyDailyHeartMetricsPrecedence` |
| F-028 | P2 | conf | M | efficiency | cpap-clock-reset | A single AirSense clock-reset row (dated pre-2015) is still folded into the CSV's min/max dateRange, so the resulting snapshot-backfill loop iterates one aggregateDay call per day across the entire multi-year gap instead of skipping the flagged date. | `AnxietyWatch/Services/CPAPImporter.swift:importSimple` |
| F-029 | P2 | conf | S | accuracy | server-analysis | gather_analysis_data builds timestamp-range filters as UTC day boundaries while the prompt tells Claude all timestamps are US/Pacific, so evening-of-final-day entries are silently dropped from analysis and day-bucketed inconsistently against the date-column tables. | `server/analysis.py:gather_analysis_data` |
| F-030 | P2 | conf | S | render | glucose-detail-predicate | GlucoseDetailView's @Query init builds a compound `#Predicate` (`&&`) capturing both a String local and a Date local — the exact shape already fixed elsewhere in this sweep (HRVSessionCardView) — currently dormant because no production call site instantiates GlucoseDetailView yet. | `AnxietyWatch/Views/Dashboard/GlucoseDetailView.swift:GlucoseDetailView.init(anxietyEntries:sleepIntervals:)` |
| F-031 | P2 | conf | S | efficiency | trends-barometric-query | TrendsView's @Query on BarometricReading fetches the entire table with no date or source bound, then filters to the visible window purely in-memory, with no offsetting full-history use. | `AnxietyWatch/Views/Trends/TrendsView.swift:allBarometric` |
| F-032 | P2 | conf | S | render | medications-nav | MedicationsHubView pushes to PrescriptionListView and PharmacyListView via closure-based NavigationLinks whose destinations declare @Query but conform to neither Equatable nor .equatable(), so SwiftUI cannot dedupe the destination across parent re-renders. | `AnxietyWatch/Views/Medications/MedicationsHubView.swift:navigationSection` |
| F-033 | P2 | conf | S | security | admin-session | Admin session cookie lacks the Secure flag and the app is published directly as plain HTTP on all interfaces, so the admin password, session cookie, newly-created raw API keys (which round-trip through the signed-but-not-encrypted session cookie via session["new_key"]), and Bearer sync tokens all transit the network in cleartext. | `server/server.py:create_app` |
| F-034 | P2 | conf | S | security | admin-auth | POST /admin/login has no rate limiting, lockout, or failure delay, allowing unthrottled online brute force of the single ADMIN_PASSWORD that gates all PHI and the credential-encryption UI. | `server/admin.py:login` |
| F-035 | P2 | conf | S | security | server-deploy | Both compose files publish the PostgreSQL container on all interfaces ("5439:5432" defaults to 0.0.0.0), contradicting the documented 127.0.0.1 binding in CLAUDE.md and exposing the entire health database to the network with only POSTGRES_PASSWORD protecting it. | `server/docker-compose.prod.yml:anxietywatch-db.ports` |
| F-036 | P2 | conf | S | accuracy | dashboard-lastnight | The Dashboard 'Last Night' card pairs the newest sleep snapshot with `recentCPAP.first` without any date match, so a stale CPAP session's AHI is presented as last night's value in the headline, the CPAP row, and the baseline delta. | `AnxietyWatch/Views/Dashboard/DashboardView.swift:lastNightSection` |
| F-037 | P2 | conf | S | silent-failure | watch-quicklog-ingest | Phone-side ingestion of watch quick-log anxiety entries uses `try? context.save()` with no logging and no failure handling, while the watch has already played a success haptic and holds no local copy — a save failure permanently and silently loses the journal entry and still marks a check-in complete. | `AnxietyWatch/Services/PhoneConnectivityManager.swift:handleIncoming` |
| F-038 | P2 | conf | M | silent-failure | sync-api | /api/sync silently drops song occurrences it cannot link to a song, yet counts them as upserted and returns 200, so the iOS client advances its sync cursor and the records are lost permanently. | `server/server.py:_upsert_song_occurrences` |
| F-039 | P2 | conf | S | bug | resmed-sync | resmed_sync.log_sync advances the resmed_last_sync cursor unconditionally on every outcome (auth_error, api_error, decrypt_error, no_credentials), which permanently forfeits the 365-day first-run backfill if the first attempt fails. | `server/resmed_sync.py:log_sync` |
| F-040 | P2 | plaus | S | accuracy | cpap-import-provenance | CPAPImporter.updateSession unconditionally overwrites importSource on every re-import, silently discarding a manually-entered or server-restored session's true provenance (e.g. "manual", "resmed_cloud", "edf") and replacing it with "csv"/"oscar". | `AnxietyWatch/Services/CPAPImporter.swift:updateSession` |
| F-041 | P2 | plaus | M | accuracy | emay-import | EMAYImporter parses timestamps as device-local wall-clock time with no DST-fallback disambiguation, so the repeated hour on a fall-back DST transition collapses onto identical Date values and dedup silently drops one hour of real oximeter samples. | `AnxietyWatch/Services/EMAYImporter.swift:importLines` |
| F-042 | P2 | plaus | S | silent-failure | prescription-ocr | PrescriptionLabelScanner discards VNRecognizedText.confidence entirely, so a low-confidence OCR misread of a dose/Rx-number digit is displayed in the 'Detected Fields' review screen with identical visual weight to a high-confidence read, with no threshold gate or warning. | `AnxietyWatch/Services/PrescriptionLabelScanner.swift:recognizeText(in:)` |
| F-043 | P2 | plaus | M | accuracy | reports-pdf | The clinical PDF's HRV section computes its '30-day baseline' and 'Current status' anchored to .now regardless of the report's date range, printing 'Current status: Within normal range' when the range ends more than 3 days ago and no recent data exists. | `AnxietyWatch/Services/ReportGenerator.swift:generatePDF` |
| F-044 | P2 | plaus | S | bug | export | ExportView's endDate is seeded with Date.now's time-of-day behind a .date-only picker, so all exports (JSON/CSV/PDF) and the Data Summary counts silently exclude same-day records logged after the sheet was opened. | `AnxietyWatch/Views/Reports/ExportView.swift:filteredCounts` |
| F-045 | P2 | plaus | S | accuracy | snapshot-aggregation | Reliability classifiers for HR/HRV/RHR treat any non-Apple-dominant sample window as 'low' reliability, so nights dominated by the highest-fidelity sources (EMAY oximeter pulse rate, Polar chest strap) are stored in dataQuality as the lowest tier. | `AnxietyWatch/Utilities/DeviceProvenance.swift:Reliability.heartRate` |
| F-046 | P2 | plaus | M | accuracy | snapshot-aggregation | applyDailyHeartMetricsPrecedence buckets chest-strap HRV/HR samples by calendar day [startOfDay, +1d) while the same snapshot's sleep/SpO2 fields use a noon-to-noon window, so an overnight chest-strap session crossing midnight has its samples split across two snapshots and each day's hrvAvg mixes fragments of two different nights. | `AnxietyWatch/Services/SnapshotAggregator.swift:applyDailyHeartMetricsPrecedence` |
| F-047 | P2 | plaus | M | silent-failure | labs-fhir | FHIRLabResultParser requires effectiveDateTime and silently drops Observations that carry effectivePeriod (a legal FHIR R4 effective[x] variant), so labs from EHRs that emit Period are never imported. | `AnxietyWatch/Services/FHIRLabResultParser.swift:parse` |
| F-048 | P2 | plaus | S | test-gap | trends-source-filter | SourceFilterTests re-implements the self-reported/check-in predicate inline in every test instead of calling the production TrendsView.filterBySource (which is private), so the nil-discriminator back-compat invariant (atlas registry row 3) is unprotected despite the registry crediting SourceFilterTests for it. | `AnxietyWatch/Views/Trends/TrendsView.swift:filterBySource` |
| F-049 | P2 | plaus | S | test-gap | chart-palette | ChartPaletteTests' distinctness suite omits the one token pair that actually collides — glucose vs polarRMSSD are both literally Color.purple — so the atlas cross-cutting invariant 'ChartPaletteTests verifies distinctness' is only partially enforced and the live collision goes unflagged. | `AnxietyWatch/Utilities/ChartPalette.swift:glucose` |
| F-050 | P2 | plaus | S | test-gap | trends-empty-state | SleepRespiratoryTrendChart is the only one of the five trend charts whose hasAnyData empty-state gate is untested — and unlike the four siblings it is an inline let in body rather than an extracted static helper, so it cannot be tested without refactoring (atlas registry row 7). | `AnxietyWatch/Views/Trends/SleepRespiratoryTrendChart.swift:body` |
| F-051 | P3 | conf | S | bug | server-jobs | dispatch_analysis has a TOCTOU race between find_ready_jobs and no_running_jobs that can exit the loop while dependent jobs are still pending, silently skipping the entire conflict-analysis DAG. | `server/job_dispatcher.py:dispatch_analysis` |
| F-052 | P3 | conf | M | silent-failure | server-jobs | Process restart (deploy, OOM, gunicorn worker recycle) orphans analysis_jobs rows in 'running'/'pending' forever — sweep_stale_analyses only recovers the parent analyses table, and there is no job resume or re-dispatch mechanism. | `server/analysis.py:sweep_stale_analyses` |
| F-053 | P3 | conf | S | bug | server-jobs | sweep_stale_analyses times out from created_at rather than started_at or last progress, falsely failing a legitimately-running conflict DAG at minute 15, after which finalize_analysis flips it back to 'completed' without clearing the stale error_message. | `server/analysis.py:sweep_stale_analyses` |
| F-054 | P3 | conf | S | silent-failure | walgreens-sync | walgreens_sync reads walgreens_last_sync but uses it only as a boolean, applying a fixed 90-day lookback from today regardless of how long ago the last successful sync actually was. | `server/walgreens_sync.py:main` |
| F-055 | P3 | conf | S | efficiency | snapshot-aggregator | SnapshotAggregator.aggregateDay fetches the identical full-day QuantityHealthSample window twice back-to-back — once in applyDailyHeartMetricsPrecedence and again in computeDataQuality — materializing every sample row in the day two times per aggregation run. | `AnxietyWatch/Services/SnapshotAggregator.swift:computeDataQuality` |
| F-056 | P3 | conf | M | efficiency | export | DataExporter.buildBundle fetches every table in full (including the unbounded BarometricReading table) and applies the caller's start/end range in memory, and it runs synchronously on the main thread from ExportView's button actions. | `AnxietyWatch/Services/DataExporter.swift:buildBundle` |
| F-057 | P3 | conf | S | efficiency | correlation-chart | CorrelationChartView evaluates the grouping-heavy `pairedData` computed property twice per body (empty-check and Chart data), rebuilding a Dictionary(grouping:) over all AnxietyEntry rows and compactMapping all HealthSnapshot rows each time, on top of two unbounded @Querys. | `AnxietyWatch/Views/Trends/CorrelationChartView.swift:pairedData` |
| F-058 | P3 | conf | S | efficiency | server-export | The /api/data export runs SELECT * on sensor_sessions, detoasting every rr_archive BYTEA (~80-120KB gzip per overnight session) out of Postgres into Python only for _serialize_row to immediately null it. | `server/server.py:_query_entity` |
| F-059 | P3 | conf | M | efficiency | server-export | GET /api/data with no `since` materializes every row of the unbounded per-sample tables (hrv_readings at ~480 rows/night, sleep_stage_events, barometric_readings, plus all songs with full lyrics) via fetchall() into a single un-paginated JSON response. | `server/server.py:get_all_data` |
| F-060 | P3 | conf | S | efficiency | sync-upserts | _upsert_barometric_readings is the only unbounded time-series upsert still using a per-row cur.execute loop, while its siblings (quantity samples, sleep events, sensor sessions, hrv readings) were deliberately converted to execute_values to avoid one round trip per row. | `server/server.py:_upsert_barometric_readings` |
| F-061 | P3 | conf | M | efficiency | correlations | compute_correlations runs the identical health_snapshots-to-anxiety_entries join eight times per recompute (7 signals + get_paired_day_count), inside the /api/sync request path, with a `a.timestamp::date = h.date` cast that defeats the anxiety_entries timestamp PK index (no expression index exists). | `server/correlations.py:compute_correlations` |
| F-062 | P3 | conf | S | efficiency | journal | AddJournalEntryView and JournalEntryDetailView each declare a full-table unbounded @Query on AnxietyEntry whose only consumer is a prefix(50) frequent-tags counter, duplicating the same fetch-everything-take-50 pattern in two sibling views. | `AnxietyWatch/Views/Journal/AddJournalEntryView.swift:recentEntries` |
| F-063 | P3 | conf | S | efficiency | trends-charts | CorrelationInsightsView retains two full-table @Querys (AnxietyEntry, HealthSnapshot) that are read only by the empty-state progress meter, so once correlations exist the view fetches and observes both entire tables for nothing. | `AnxietyWatch/Views/Trends/CorrelationInsightsView.swift:pairedDayCount` |
| F-064 | P3 | conf | S | render | trends-charts | GlucoseTrendChart re-runs GlucoseTrendDatum.from — including JSONSerialization of each snapshot's dataQuality blob — six-plus times per render because `datums` is an uncached computed property fanned out to subtitle, meanCV, rollingMean, isEmpty, ForEach, and cvData. | `AnxietyWatch/Views/Trends/GlucoseTrendChart.swift:datums` |
| F-065 | P3 | conf | S | render | medications | PrescriptionListView evaluates the activePrescriptions and expiredPrescriptions computed properties three times each per body, re-running PrescriptionSupplyCalculator.supplyStatus (calendar/day math) over the whole prescriptions table on every access. | `AnxietyWatch/Views/Prescriptions/PrescriptionListView.swift:activePrescriptions` |
| F-066 | P3 | conf | M | accuracy | baseline-calculator | BaselineCalculator.BaselineResult exposes only mean/SD/bounds — no sample count or trim ratio — so a baseline that barely cleared the 14-point minimum (some of which may have been MAD-trimmed) is indistinguishable from one built on 30 well-distributed, untrimmed points. | `AnxietyWatch/Services/BaselineCalculator.swift:BaselineResult` |
| F-067 | P3 | conf | S | accuracy | polar-session-recovery | A session's displayed `rrCount` mixes two incompatible counting bases — artifact-filtered for the live-recorded portion, raw/unfiltered for any pre-recovery or orphaned portion — inflating the beat count shown on the Dashboard session card for any session that survives an app restart mid-recording. | `AnxietyWatch/Services/PolarHRMService.swift:recoverInFlightSessionIfNeeded()` |
| F-068 | P3 | conf | M | accuracy | cpap-edf | upsert_cpap_leak inserts ahi = 0.0 as an "unknown AHI" sentinel for EDF-only dates, making an unknown-AHI night indistinguishable from a real zero-event (perfect) night in every downstream AHI consumer. | `server/edf_parser.py:upsert_cpap_leak` |
| F-069 | P3 | conf | S | accuracy | server-analysis | correlations_are_stale keys freshness off MAX(timestamp)/MAX(date), so a backfilled or past-dated entry (older than the newest existing row) never marks correlations stale and the analysis prompt keeps serving correlations that ignore the newly added history. | `server/correlations.py:correlations_are_stale` |
| F-070 | P3 | conf | S | efficiency | lab-results-query-scope | LabTestHistoryView's @Query fetches the entire ClinicalLabResult table with no predicate, then filters to a single loincCode in-memory via a computed property re-evaluated on every access. | `AnxietyWatch/Views/LabResults/LabTestHistoryView.swift:results` |
| F-071 | P3 | conf | S | efficiency | dashboard-query-scope | DashboardView's `recentSnapshots` @Query has no predicate at all, fetching the entire ever-growing HealthSnapshot table on every render, unlike its four sibling queries in the same init() that are deliberately 30-day-bounded. | `AnxietyWatch/Views/Dashboard/DashboardView.swift:recentSnapshots` |
| F-072 | P3 | conf | S | efficiency | medications-query | MedicationsHubView and PrescriptionListView each declare an unbounded @Query over an entire growing table (MedicationDose, Prescription) with no date or fetchLimit bound, then truncate/filter the full result set in memory on every body evaluation. | `AnxietyWatch/Views/Medications/MedicationsHubView.swift:recentDoses` |
| F-073 | P3 | conf | S | render | settings-navigation | HealthRecordsSettingsView's closure-based NavigationLink to LabResultsView (which declares @Query) omits the `.equatable()` call-site modifier that the equivalent CareSectionRowView call site applies, so LabResultsView's Equatable conformance is dormant here. | `AnxietyWatch/Views/Settings/HealthRecordsSettingsView.swift:HealthRecordsSettingsView.body` |
| F-074 | P3 | conf | S | efficiency | cpap-query | CPAPListView holds two unbounded @Query properties (all HealthSnapshot rows, all AnxietyEntry rows) with no date bound, purely to let CPAPDetailView look up a single day's snapshot/entries per session. | `AnxietyWatch/Views/CPAP/CPAPListView.swift:CPAPListView` |
| F-075 | P3 | conf | M | security | crypto | crypto.py derives the Fernet key from SECRET_KEY with a hardcoded public salt and no key versioning, so rotating SECRET_KEY (the normal response to a suspected leak, and also Flask's cookie-signing key) silently orphans every encrypted portal credential with no re-encryption path. | `server/crypto.py:_fernet_key` |
| F-076 | P3 | conf | S | security | resmed-sync | The Okta one-time sessionToken is sent as a URL query parameter, and connection-failure exceptions that embed the full URL (including the token) are wrapped verbatim into MyAirAuthError, logged at ERROR, and flashed into the admin UI. | `server/resmed_client.py:MyAirClient._authenticate` |
| F-077 | P3 | conf | S | security | walgreens-sync | On Walgreens login failure the client dumps 3000 chars of arbitrary page text into ERROR logs and saves an unencrypted screenshot of the login page (username field filled with the real account email) to /tmp, where it persists indefinitely. | `server/walgreens_client.py:WalgreensClient._authenticate` |
| F-078 | P3 | conf | S | security | caprx-sync | CapRx sync persists raw exception text into the settings table and sync_log (unlike ResMed/Walgreens which store fixed status strings), so SSO-chain exception messages containing a resolve_id — directly exchangeable for access+refresh tokens with no further auth — can be stored in the DB and rendered on the admin page. | `server/caprx_sync.py:run_sync` |
| F-079 | P3 | conf | S | security | server-songs | The Musixmatch API key is passed as a URL query parameter and log.exception on any RequestException prints a traceback whose exception message includes the full request URL — API key included — into server logs. | `server/genius.py:fetch_lyrics_musixmatch` |
| F-080 | P3 | conf | S | security | server-credentials | ResMed email and Walgreens username are stored plaintext in the settings table while the CapRx email is Fernet-encrypted — the same credential-identifier class gets inconsistent at-rest protection (confirms atlas oddity #119 in the current code). | `server/admin.py:resmed_settings` |
| F-081 | P3 | conf | M | silent-failure | clinical-labs-import | ClinicalRecordImporter drops FHIR records that fail to parse with a bare `continue` — no skip counter, no log, and no user surface — and the hourly background import is the only ingestion path, so dropped lab results are permanently invisible. | `AnxietyWatch/Services/ClinicalRecordImporter.swift:importLabResults` |
| F-082 | P3 | conf | S | silent-failure | health-records-auth | The 'Connect Health Records' button swallows authorization errors with an empty catch, giving the user zero feedback when the request fails — the button appears to do nothing. | `AnxietyWatch/Views/Settings/HealthRecordsSettingsView.swift:body` |
| F-083 | P3 | conf | S | silent-failure | server-core | The startup auto-migration block swallows all exceptions and logs only the exception type name at WARNING level, so a failed Alembic migration boots the app against a stale schema with no traceback anywhere. | `server/server.py:create_app` |
| F-084 | P3 | plaus | M | efficiency | journal | JournalListView loads the complete journal history through an unbounded @Query with no pagination or fetch limit, the only cap on a primary history list fed multiple entries per day by random check-ins and dose follow-ups. | `AnxietyWatch/Views/Journal/JournalListView.swift:entries` |
| F-085 | P3 | plaus | S | accuracy | trends-baselines | HRV, AHI, and barometric trend charts compute their baseline rules anchored to .now even when the user pages into past windows, unlike HFPowerTrendChart which deliberately anchors to the window end; the sibling BaselineCalculator functions also lack the upper-bound filter that spo2Nadir/t90 added, so they cannot be safely re-anchored without that fix. | `AnxietyWatch/Views/Trends/HRVTrendChart.swift:baseline` |
| F-086 | P3 | plaus | S | silent-failure | dose-followup-state | DoseFollowUpManager.loadPending decodes its UserDefaults blob with `(try? ...) ?? []`, so any decode failure (e.g. a Codable schema change on app update) silently discards all pending dose follow-ups, and the next savePending permanently overwrites the old blob with the empty list. | `AnxietyWatch/Utilities/DoseFollowUpManager.swift:loadPending` |
| F-087 | P3 | plaus | S | test-gap | trends-tests | TrendsDateFilteringTests derives both its fixtures and its cutoff from independent unpinned `.now` reads, so a midnight boundary crossing mid-test breaks the fixed-count assertion. | `AnxietyWatchTests/TrendsDateFilteringTests.swift:swiftDataFilterCorrectCount` |
| F-088 | P3 | plaus | S | test-gap | server-tests | test_server.py mutates process-global os.environ['ADMIN_PASSWORD'] and os.environ['SECRET_KEY'] by direct assignment with no teardown, leaking credential env state into every subsequent test in the session. | `server/tests/test_server.py:test_admin_login` |

## Triage decisions (accepted 2026-07-08)

**The maintainer reviewed and accepted all recommendations on 2026-07-08**, so the Action column below is now the final triage: every entry's **Disposition** in [Detailed findings](#detailed-findings) has been set to `approved` (84) or `deferred (Phase 8 backlog)` (4), and the 7 severity re-elevations have been applied to the register in place (IDs are stable, so F-016 and F-025 now read slightly above their table neighbours' severity). This closes the Phase 2 triage gate.

**Recommended split:** 84 approve, 4 defer (backlog), 0 reject. Of the approves, 22 are `plausible` (verification lenses were cut off by the session-limit interruption) — confirm the mechanism cheaply as the first step of the fix.

**Suggested severity re-elevations** (the 3-lens median demoted these; the finder ratings match the crash/data-loss reality): F-001 → P0, F-002 → P0, F-003 → P0, F-004 → P0, F-005 → P0, F-016 → P1, F-025 → P1. Bump these first.

| ID | Rec Sev | Action | Verify first? | Batch | Rationale |
|----|---------|--------|---------------|-------|-----------|
| F-001 | P1 → **P0** | approve | — | A | Documented iOS-26 NavigationLink+@Query crash family; LabResults hardened one hop up, missed here. |
| F-002 | P1 → **P0** | approve | — | A | Same crash family — CorrelationChartView destination holds @Query, no Equatable/.equatable(). |
| F-003 | P1 → **P0** | approve | — | A | Same crash family — CorrelationInsightsView destination holds 3 @Query. |
| F-004 | P1 → **P0** | approve | — | A | Same crash family — JournalEntryDetailView destination holds @Query. |
| F-005 | P1 → **P0** | approve | — | A | Same crash family — CPAPListView destination + a rebuildProgress mutation loop that re-runs the parent body. |
| F-006 | P1 | approve | yes | G | Both import entry points gate backfill on .cpap; EMAY nights silently never reach HealthSnapshot. |
| F-007 | P1 | approve | yes | F | 'Min' pressure shows the median for every OSCAR night — clinically misleading, one-line fix. |
| F-008 | P1 | approve | yes | F | Cross-institution unit variance (mmol/L vs mg/dL) flips HIGH/LOW on the clinician PDF; needs a unit map. |
| F-009 | P1 | approve | yes | F | Refill re-sync never updates dateFilled/lastFillDate → false 'refill needed' then suppressed alerts. |
| F-010 | P1 | approve | yes | F | Missing HRV/RHR collapses to 0 → false 'Resting HR down ~60 bpm' headline. |
| F-011 | P1 | approve | yes | F | 30-day sleep events fed to a single-night calculator → month aggregate (or 0%) shown as last night. |
| F-012 | P1 | approve | yes | B | Regression coverage for the documented cursor-advance race; extract sync() seam so it is testable. |
| F-013 | P2 | approve | — | B | Mid-recording sync flags the session synced; finalize never re-dirties → endTime/summary never reach server. |
| F-014 | P2 | approve | — | B | RR archive uploaded while still recording, then cursor-stamped → server keeps a truncated night. |
| F-015 | P2 | approve | — | B | Failed RR POST never retried because the session is already flagged synced. |
| F-016 | P2 → **P1** | approve | — | B | nonisolated async fetch/insert/save on the MainActor ModelContext — SwiftData race (crash/corruption); Swift 6 precursor. |
| F-017 | P2 | approve | — | K | Reads receivedApplicationContext (always empty) → check-ins wipe the Watch's cached stats. |
| F-018 | P2 | approve | — | K | No sent-tracking → re-transfers 500 rows/60s and the #Unique upsert re-dirties them, perpetual re-upload. |
| F-019 | P2 | approve | — | D | mark_failed on an aborted txn without rollback → job stuck 'running', dispatcher spins forever. |
| F-020 | P2 | approve | — | H | Unbounded per-minute HRV @Query fully re-aggregated on the main thread every body. |
| F-021 | P2 | approve | — | H | Whole HRVReading table recomputed per row of the LFHF sessions list. |
| F-022 | P2 | approve | — | H | Full LFHF pipeline re-run in body on every re-render, not just when Polar data changes. |
| F-023 | P2 | approve | — | F | Sparse oximeter samples nil out the already-sufficient HK-direct T90/desat → understated hypoxic burden in PDF. |
| F-024 | P2 | approve | — | F | Estimated (pinned-100%) efficiency can never breach → 'Solid night' on unreliable data (the deferred-from-#152 question). |
| F-025 | P2 → **P1** | approve | — | G | Misaligned .rr file wiped to empty on next open → permanent loss of the night's per-beat archive. |
| F-026 | P2 | approve | — | F | Successive-diff RMSSD/pNN50 over the filtered array splices non-adjacent beats → inflated HRV in the filtered window. |
| F-027 | P2 | approve | — | F | Polar precedence reads a table the BLE pipeline never writes → noisier Watch HRV always wins; contradicts intent. |
| F-028 | P2 | approve | — | G | One clock-reset row widens the backfill range to ~2 decades → thousands of aggregateDay calls hang import. |
| F-029 | P2 | approve | — | F | UTC day-boundary filter vs Pacific prompt drops evening-of-final-day entries from analysis. |
| F-030 | P2 | approve | — | A | Same compound-#Predicate crash shape as the fixed HRVSessionCardView; dormant (no call site yet) but fix while cheap. |
| F-031 | P2 | approve | — | H | Whole BarometricReading table loaded and window-filtered in body every render. |
| F-032 | P2 | approve | — | A | Same NavigationLink+@Query family (Prescription/Pharmacy list destinations). |
| F-033 | P2 | approve | — | E | Cookie missing Secure + plain-HTTP on all interfaces; single-user home box, but cheap hardening. |
| F-034 | P2 | approve | — | E | No login throttle/lockout on the single ADMIN_PASSWORD gating all PHI. |
| F-035 | P2 | approve | — | E | DB published on 0.0.0.0, contradicting the documented 127.0.0.1 binding. |
| F-036 | P2 | approve | — | F | 'Last Night' pairs newest snapshot with recentCPAP.first with no date match → stale AHI shown as last night. |
| F-037 | P2 | approve | — | K | Watch plays a success haptic but the phone-side save is try? with no failure surface. |
| F-038 | P2 | approve | — | C | /api/sync drops unlinkable song occurrences yet returns 200 → client advances cursor and loses them. |
| F-039 | P2 | approve | — | C | log_sync advances the cursor on every outcome (incl. errors) → permanent CPAP gap; found by 4 dimensions. |
| F-040 | P2 | approve | yes | G | Re-import clobbers manual/resmed_cloud/edf provenance with 'csv'/'oscar'. |
| F-041 | P2 | approve | yes | G | DST fall-back hour collapses to identical Dates; dedup drops ~1h of oximetry silently. |
| F-042 | P2 | approve | yes | K | OCR confidence discarded → a misread dose shown with the same weight as high-confidence fields. |
| F-043 | P2 | approve | yes | K | PDF HRV baseline/status anchored to .now regardless of report range → 'Within normal range' on stale past ranges. |
| F-044 | P2 | approve | yes | K | endDate carries time-of-day behind a date-only picker → same-day late entries silently excluded from exports. |
| F-045 | P2 | approve | yes | F | Reliability classifier labels the densest dual-source nights 'low', contradicting the precedence logic. |
| F-046 | P2 | approve | yes | F | Chest-strap HR/HRV day-bucketed [startOfDay,+1d) while sleep uses noon-to-noon → overnight session split across two days. |
| F-047 | P2 | approve | yes | G | Requires effectiveDateTime, silently dropping the valid FHIR effectivePeriod variant. |
| F-048 | P2 | approve | yes | J | Tests reimplement filterBySource instead of exercising production; nil-source branch untested. |
| F-049 | P2 | approve | yes | J | Surfaces a REAL palette collision — glucose and polarRMSSD are both Color.purple; fix the token too, then add the test. |
| F-050 | P2 | approve | yes | J | Only trend chart whose empty-state gate is untested. |
| F-051 | P3 | approve | — | D | TOCTOU between find_ready_jobs and no_running_jobs can strand the whole conflict DAG as 'pending'. |
| F-052 | P3 | defer | — | — (backlog) | Real, but the fix is a job resume/re-dispatch mechanism (M); park in the Phase 8 backlog. |
| F-053 | P3 | approve | — | D | Timeout measured from created_at falsely fails a legitimately-running DAG at minute 15. |
| F-054 | P3 | approve | — | C | Fixed 90-day lookup regardless of last success → permanent hole after any >90d outage. |
| F-055 | P3 | approve | — | H | aggregateDay fetches the same full-day QuantityHealthSample window twice; dedupe. |
| F-056 | P3 | approve | — | H | buildBundle fetches every table in full and filters in memory, synchronously; bound + move off main. |
| F-057 | P3 | approve | — | H | pairedData (Dictionary(grouping:)) rebuilt twice per body. |
| F-058 | P3 | approve | — | I | /api/data SELECT * detoasts every rr_archive BYTEA it never serializes. |
| F-059 | P3 | approve | — | I | GET /api/data with no `since` materializes every per-sample row. |
| F-060 | P3 | approve | — | I | Only unbounded time-series upsert still using a per-row execute loop; batch it like its siblings. |
| F-061 | P3 | approve | — | I | compute_correlations runs the same join 8x per recompute inside the sync request path. |
| F-062 | P3 | approve | — | H | Two views hold full-table AnxietyEntry @Query just for a prefix(50) tag counter. |
| F-063 | P3 | approve | — | H | Two full-table @Query retained only for the empty-state meter, live after correlations exist. |
| F-064 | P3 | approve | — | H | GlucoseTrendDatum.from (incl. JSONSerialization) recomputed 6+x per render; cache. |
| F-065 | P3 | approve | — | H | active/expired computed props (supplyStatus) evaluated 3x each per body. |
| F-066 | P3 | defer | — | — (backlog) | Enhancement (expose baseline sample count / confidence band), not a defect; backlog. |
| F-067 | P3 | approve | — | F | Recovered-session rrCount mixes filtered + unfiltered bases → inflated beat count on the card. |
| F-068 | P3 | approve | — | C | EDF-only dates insert ahi=0.0 — an unknown night reads as a perfect one; use NULL. |
| F-069 | P3 | approve | — | C | Staleness keyed on MAX watermark misses backfills/edits → stale correlations served. |
| F-070 | P3 | approve | — | H | Whole ClinicalLabResult table fetched, filtered to one loincCode in an uncached property. |
| F-071 | P3 | approve | — | H | recentSnapshots @Query has no predicate at all, unlike its four bounded siblings. |
| F-072 | P3 | approve | — | H | Unbounded MedicationDose/Prescription @Query rendering only the first 10 rows. |
| F-073 | P3 | approve | — | A | Missing .equatable() on the LabResultsView link — same family as F-001. |
| F-074 | P3 | approve | — | H | Two unbounded @Query just to hand one day's snapshot to the detail view. |
| F-075 | P3 | defer | — | — (backlog) | Only bites on SECRET_KEY rotation; key-versioning is a larger design change. Backlog. |
| F-076 | P3 | approve | — | E | Okta one-time token in a URL query param, echoed into wrapped exception text/logs. |
| F-077 | P3 | approve | — | E | Login failure dumps 3000 chars of page text + an unencrypted screenshot with the username filled. |
| F-078 | P3 | approve | — | E | CapRx persists raw exception text (SSO-chain messages may carry identifiers) into settings/sync_log. |
| F-079 | P3 | approve | — | E | Musixmatch key in a URL query param; log.exception traceback includes the full URL. |
| F-080 | P3 | approve | — | E | ResMed/Walgreens identifiers stored plaintext while CapRx is encrypted — make consistent. |
| F-081 | P3 | approve | — | K | Hourly FHIR import drops unparseable records with a bare continue — no count, no log, no surface. |
| F-082 | P3 | approve | — | K | 'Connect Health Records' swallows auth errors with an empty catch — button appears dead. |
| F-083 | P3 | approve | — | K | Startup auto-migration swallows all exceptions → boots against a stale schema silently. |
| F-084 | P3 | approve | yes | H | Primary journal history list has no pagination/fetch limit. |
| F-085 | P3 | defer | — | — (backlog) | Documented tradeoff; needs the baseline upper-bound-filter fix first and is low value. Backlog. |
| F-086 | P3 | approve | yes | K | (try? decode) ?? [] silently discards all pending dose follow-ups on a Codable schema change. |
| F-087 | P3 | approve | yes | J | Same Phase-0 time-bomb pattern (fixtures + unpinned now); pin the clock. |
| F-088 | P3 | approve | yes | J | Tests mutate os.environ ADMIN_PASSWORD/SECRET_KEY with no teardown — leaks into later tests. |

### Proposed fix batches (Phase 3 sequencing)

Each batch is one or a few PRs; every confirmed-bug fix ships with a regression test per the ground rules. Suggested order is highest data/UX impact first.

**1. Batch B — Sync integrity — data reaches the server correctly** (5): F-012, F-013, F-014, F-015, F-016 — _F-012/F-015 split to Batch B-2 during execution, joined there by F-090 (found during Batch B review)_  
**2. Batch A — SwiftUI render crash pitfalls (NavigationLink + @Query family)** (8): F-001, F-002, F-003, F-004, F-005, F-030, F-032, F-073 — _plus F-089, found during implementation review and fixed in the same PR (#157)_  
**3. Batch F — Medical-accuracy: display & clinician-report correctness** (14): F-007, F-008, F-009, F-010, F-011, F-023, F-024, F-026, F-027, F-029, F-036, F-045, F-046, F-067  
**4. Batch G — Import robustness & data-loss** (6): F-006, F-025, F-028, F-040, F-041, F-047  
**5. Batch C — Server ingest & sync-client correctness** (5): F-038, F-039, F-054, F-068, F-069 — _plus F-091 (correlations.py UTC day-bucketing, found during Batch F's F-029 fix)_  
**6. Batch E — Server security & credential-log hygiene** (8): F-033, F-034, F-035, F-076, F-077, F-078, F-079, F-080  
**7. Batch D — Server job-dispatcher robustness** (3): F-019, F-051, F-053  
**8. Batch K — Silent-failure / UX honesty** (10): F-017, F-018, F-037, F-042, F-043, F-044, F-081, F-082, F-083, F-086  
**9. Batch H — iOS @Query efficiency bounds & per-render caching** (16): F-020, F-021, F-022, F-031, F-055, F-056, F-057, F-062, F-063, F-064, F-065, F-070, F-071, F-072, F-074, F-084  
**10. Batch I — Server efficiency** (4): F-058, F-059, F-060, F-061  
**11. Batch J — Test-discipline & coverage** (5): F-048, F-049, F-050, F-087, F-088  

**Deferred to Phase 8 backlog** (4): F-052 (Real, but the fix is a job resume/re-dispatch mechanism (M)), F-066 (Enhancement (expose baseline sample count / confidence band), not a defect), F-075 (Only bites on SECRET_KEY rotation), F-085 (Documented tradeoff).



## Detailed findings

### F-001 · P0 · confirmed · render · lab-results-nav · _severity re-elevated at triage_

**Anchor:** `AnxietyWatch/Views/LabResults/LabResultsView.swift:LabResultsView.body`  

**Summary:** LabResultsView's own body pushes LabTestHistoryView via a closure-form NavigationLink whose destination owns an unbounded @Query, with neither Equatable conformance nor `.equatable()` at the call site — the exact pitfall LabResultsView itself was hardened against one hop up, missed one hop down.  

**Failure scenario:** From the Dashboard's Care row (CareSectionRowView -> LabResultsView().equatable()), the user opens Lab Results and taps any lab-test row inside a category Section. SwiftUI pushes `NavigationLink { LabTestHistoryView(loincCode: result.loincCode, definition: def) } label: { labResultRow(...) }`. `LabTestHistoryView` declares `@Query private var allResults: [ClinicalLabResult]` and conforms to no Equatable protocol, and the call site never applies `.equatable()`. Any ClinicalLabResult mutation elsewhere in the app (e.g. a background FHIR import completing while the Lab Results list is on screen) re-evaluates LabResultsView.body, SwiftUI cannot dedupe the 'new' destination struct, and the NavigationStack push restarts — on iOS 26 this is the documented path to the ~30 Hz render loop and CA::Layer::layout_is_active use-after-free crash (the exact Pitfall #2 signature, PolarSessionHRDetail Phase 4 precedent).  

**Verification:** finder P0, 3/3 verify lenses confirmed, lens votes [P2, P2, P2, P1, P1, P1].  

**Merged from 2 finder reports** (same root defect); related anchors: `AnxietyWatch/Views/LabResults/LabResultsView.swift:labResultRow-NavigationLink`.  

**Disposition:** fixed (#157)

### F-002 · P0 · confirmed · render · trends-correlation-nav · _severity re-elevated at triage_

**Anchor:** `AnxietyWatch/Views/Trends/CorrelationInsightsView.swift:31`  

**Summary:** CorrelationInsightsView pushes CorrelationChartView via a closure-form NavigationLink; the destination holds two @Query properties but has no Equatable conformance and no .equatable() at the call site.  

**Failure scenario:** User taps a correlation card, pushing CorrelationChartView(correlation: corr). While that screen is on-screen, any write to HealthSnapshot or AnxietyEntry (SnapshotAggregator.aggregateDay running from another tab's .task, an HRV/CPAP import, or SyncService.restoreFromServer) causes CorrelationInsightsView's own @Query(sort: \PhysiologicalCorrelation.computedAt)/entries/snapshots to update, re-executing its body and reconstructing NavigationLink { CorrelationChartView(correlation: corr) } for every row. Because CorrelationChartView isn't Equatable and isn't wrapped in .equatable(), SwiftUI can't tell the reconstructed destination is 'the same' as the currently-pushed one, so it treats it as new — restarting the push transition and, per the documented iOS 26 defect, cascading into the CA::Layer::layout_is_active use-after-free / scene-update watchdog kill. Notably, the sibling drill-downs in this same directory (PolarSessionHRDetailView, LFHFSessionDetailView) were explicitly hardened with this exact Equatable+.equatable() pattern, but CorrelationChartView was missed.  

**Verification:** finder P0, 3/3 verify lenses confirmed, lens votes [P1, P1, P1].  

**Disposition:** fixed (#157)

### F-003 · P0 · confirmed · render · trends-correlation-nav · _severity re-elevated at triage_

**Anchor:** `AnxietyWatch/Views/Trends/TrendsView.swift:269`  

**Summary:** TrendsView pushes CorrelationInsightsView via a closure-form NavigationLink; the destination holds three @Query properties but has no Equatable conformance and no .equatable() at the call site.  

**Failure scenario:** User taps the 'Correlation Insights' card at the bottom of Trends, pushing CorrelationInsightsView(). TrendsView's body depends on six volatile @Query sets (allSnapshots, allEntries, allCPAPSessions, allBarometric, allHRVReadings, allSensorSessions) that mutate frequently in the background (SnapshotAggregator writes on every launch/tab-appear, HRVSessionRecorder ticking every minute during an active Polar session, CPAP/EMAY imports, sync restore). Any such mutation re-executes TrendsView.body and reconstructs NavigationLink { CorrelationInsightsView() }. Since CorrelationInsightsView (which itself holds @Query correlations/entries/snapshots) isn't Equatable and isn't `.equatable()`-wrapped at this call site, SwiftUI can't dedupe the reconstructed destination against the pushed one, causing repeated push-transition restarts and the same iOS 26 layout/use-after-free failure mode documented for the Polar session detail view.  

**Verification:** finder P0, 3/3 verify lenses confirmed, lens votes [P1, P1, P1].  

**Disposition:** fixed (#157)

### F-004 · P0 · confirmed · render · journal-nav · _severity re-elevated at triage_

**Anchor:** `AnxietyWatch/Views/Journal/JournalListView.swift:JournalEntryRow-NavigationLink`  

**Summary:** JournalListView pushes JournalEntryDetailView via a closure-form NavigationLink; the destination holds an unbounded @Query and has neither Equatable conformance nor .equatable() at the call site, matching the exact structural shape of the documented polar-session-hr-detail crash pattern.  

**Failure scenario:** User taps a journal entry to open JournalEntryDetailView, taps Edit, and types in the Notes TextEditor bound to $entry.notes. Each keystroke mutates the @Bindable AnxietyEntry (also mutated directly by the severity grid and tag-chip buttons in edit mode), invalidating JournalListView's own `@Query entries` over the same AnxietyEntry table and causing JournalListView.body — including the NavigationLink closure that constructs `JournalEntryDetailView(entry: entry)` — to re-evaluate. Because JournalEntryDetailView additionally declares its own `@Query private var recentEntries: [AnxietyEntry]` and is neither Equatable nor wrapped with `.equatable()`, SwiftUI cannot recognize the freshly-constructed destination struct as identical to the currently-pushed one, so it restarts the NavigationStack push animation on every keystroke/tag-edit. On iOS 26 this is the documented path to a ~30 Hz render loop culminating in the `CA::Layer::layout_is_active` use-after-free that has previously crashed the app, and unlike the Polar/LFHF case (which needed live BLE data to retrigger), this one reproduces on the ordinary 'edit a journal entry' workflow.  

**Verification:** finder P0, 3/3 verify lenses confirmed, lens votes [P1, P1, P1].  

**Disposition:** fixed (#157)

### F-005 · P0 · confirmed · render · settings-navigation · _severity re-elevated at triage_

**Anchor:** `AnxietyWatch/Views/Settings/SettingsView.swift:SettingsView.body`  

**Summary:** Settings' closure-based NavigationLink to CPAPListView (which owns three @Query properties) has no Equatable conformance and no .equatable() at the call site, while the same screen drives a per-day rebuildProgress @State mutation loop that repeatedly re-executes the parent body.  

**Failure scenario:** User taps 'Rebuild All History…' in Settings, then (while the rebuild is still running) taps into the CPAP row to view CPAPListView. rebuildAllSnapshots() sets `rebuildProgress = offset + 1` once per day of HealthKit history inside a tight loop, re-executing SettingsView.body on every increment (potentially hundreds of times for a multi-year history). Each re-execution re-evaluates the NavigationLink { CPAPListView() } closure; since CPAPListView is neither Equatable nor wrapped in .equatable(), SwiftUI's default reflection-based diff (which cannot see into @Query's internal observation state) treats each reconstruction as a distinct destination, restarting the already-pushed CPAPListView's transition on every rebuildProgress tick — exactly the closure-NavigationLink+@Query+no-Equatable shape documented in CLAUDE.md as the root cause of the iOS 26 CA::Layer::layout_is_active use-after-free (the same crash class as the polar-session-hr-detail Phase 4 incident).  

**Verification:** finder P0, 3/3 verify lenses confirmed, lens votes [P1, P1, P1].  

**Disposition:** fixed (#157)

### F-006 · P1 · plausible · silent-failure · cpap-emay

**Anchor:** `AnxietyWatch/App/AnxietyWatchApp.swift:processImportBatch`  

**Summary:** EMAY CSV imports never trigger a snapshot backfill in either import entry point, so imported oximeter data for a past night can silently never reach HealthSnapshot on a normal daily-use install.  

**Failure scenario:** A daily user (the app aggregates a HealthSnapshot for every day it's opened) later imports an EMAY SleepO2 CSV for a night from two weeks ago. CSVImportRouter.importContent correctly parses it and returns `Result(kind: .emay, ..., dateRange: <that night>)`. Both `AnxietyWatchApp.processImportBatch` (`if result.kind == .cpap, let range = result.dateRange`) and `CPAPListView.handleImport` (`if routerResult.kind == .cpap, let dateRange = ...`) gate the backfill call on `kind == .cpap`, so no `aggregateDay` runs for that date. Because a HealthSnapshot row already exists for that day (normal daily usage), HealthDataCoordinator.fillGaps() — which only fills genuinely missing days between the last existing snapshot and today — will never touch it either. The import alert reports N inserted samples (apparent success), but HealthSnapshot.spo2Avg/spo2NadirOvernight/spo2TimeBelow90Min/spo2DesatsCount for that night remain whatever was previously computed (typically nil or Apple-Watch-only) until the user manually runs Settings' 'Rebuild All History'. Trends and the PDF report for that night silently omit the oximeter data despite the import having succeeded.  

**Verification:** finder P1, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#160)

### F-007 · P1 · plausible · accuracy · cpap-oscar-import

**Anchor:** `AnxietyWatch/Services/CPAPImporter.swift:importOSCAR`  

**Summary:** OSCAR Summary CSV import writes the median pressure into both pressureMin and pressureMean, so an OSCAR-imported session's 'Min' pressure is never actually a minimum — it's the median, mislabeled.  

**Failure scenario:** User imports an OSCAR Summary export (37+ column format). parseOSCARRow reads column 22 ('Median Pressure') into `medianPressure` and column 36 ('99.5% Pressure') into `pressure995`; no minimum-pressure column is read at all. importOSCAR then constructs/updates the session with `pressureMin: parsed.medianPressure, pressureMax: parsed.pressure995, pressureMean: parsed.medianPressure`. CPAPDetailView renders these three fields verbatim as 'Min' / 'Mean' / 'Max' LabeledContent rows, so the patient/clinician sees a 'Min' pressure value that is numerically identical to 'Mean' for every OSCAR-imported night, hiding the actual pressure floor the auto-titrating machine used (clinically relevant for assessing titration range/leak).  

**Verification:** finder P1, 1/1 verify lenses confirmed, lens votes [P2].  

**Disposition:** fixed (#159)

### F-008 · P1 · plausible · accuracy · fhir-labs

**Anchor:** `AnxietyWatch/Services/FHIRLabResultParser.swift:parse(observation:)`  

**Summary:** FHIRLabResultParser stores the lab's raw reported unit and value with no conversion or compatibility check against the registry's fixed-unit reference range, so cross-institution unit variance (mg/dL vs mmol/L, ng/dL vs pmol/L, mcg/dL vs nmol/L) silently produces wrong HIGH/LOW flags on screen and in the clinician PDF.  

**Failure scenario:** A HealthKit clinical-record Observation for Fasting Glucose (LOINC 2345-7) from a lab that reports valueQuantity in mmol/L (a normal ~5.5 mmol/L) arrives with no `referenceRange` array (common when a lab omits it). `FHIRLabResultParser.parse` stores `value: 5.5, unit: "mmol/L"` verbatim (no unit check against `LabTestRegistry.definition(for:).unit == "mg/dL"`). `LabResultsView.statusColor`/`LabTestHistoryView.statusColor` and `ReportGenerator`'s PDF lab section fall back to `def?.normalRangeLow/High` (70-100, assumed mg/dL) since the FHIR record had no reference range, so 5.5 < 70 triggers orange 'LOW' status on screen and a literal '▼ LOW' annotation next to the raw '5.5 mmol/L' value in the clinician-facing PDF report — a clinically normal result rendered as critically low.  

**Verification:** finder P1, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#159)

### F-009 · P1 · plausible · bug · prescription-sync

**Anchor:** `AnxietyWatch/Services/PrescriptionImporter.swift:update(_:from:directions:refills:context:)`  

**Summary:** PrescriptionImporter.update() refreshes daysSupply/patientPay/planPay on every re-sync of an existing rxNumber but never updates dateFilled or lastFillDate, so supply run-out math combines a stale fill date with a fresh supply duration after any refill.  

**Failure scenario:** A Walgreens-synced Prescription with rxNumber 'RX1' is first imported with dateFilled=Jan 1 and daysSupply=30. Two months later the medication is refilled; the server resends the same rx_number with an updated days_supply for the new fill, but PrescriptionImporter.importRecord finds the existing row by rxNumber and calls update(), which sets `rx.daysSupply = ds` but never touches `rx.dateFilled` or `rx.lastFillDate` (neither field is assigned anywhere in `update`). PrescriptionSupplyCalculator.effectiveRunOutDate computes `dateFilled(Jan 1) + daysSupply(30 days) = Jan 31`, so `supplyStatus` reports `.expired` for a medication actually refilled in March with weeks of supply left, surfacing a false 'refill needed' alert on Dashboard/MedicationsHub; conversely `alertPrescriptions`'s staleness cutoff (`lastFillDate ?? dateFilled`, also frozen at Jan 1) can eventually exclude the prescription from alerts entirely, silently suppressing future genuine low-supply warnings for that medication.  

**Verification:** finder P1, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#159)

### F-010 · P1 · plausible · accuracy · dashboard-summary

**Anchor:** `AnxietyWatch/Views/Dashboard/DashboardViewModel.swift:smartSummary`  

**Summary:** smartSummary substitutes 0 for missing HRV/RHR values, producing extreme false 'below baseline' headlines whenever today's snapshot lacks the metric.  

**Failure scenario:** Morning app open before Apple Watch writes today's resting HR: todaySnapshot exists but restingHR is nil, so rhrValue collapses to 0 via the '?? 0' chain; with a valid 30-day baseline the z-score is ~-10σ and SmartSummaryComposer emits 'Resting HR down ~60 bpm' (same for HRV: 'HRV 100% below your baseline') as the top what-changed-today headline, despite no data existing.  

**Verification:** finder P1, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#159)

### F-011 · P1 · plausible · accuracy · dashboard-summary

**Anchor:** `AnxietyWatch/Views/Dashboard/DashboardView.swift:body`  

**Summary:** The Smart Summary feeds the full 30-day SleepStageEvent stream into SleepEfficiencyCalculator, which is documented and written as a single-night calculator, so the displayed 'Sleep efficiency was X%' is a month-long aggregate (or a fabricated 0% when no events exist).  

**Failure scenario:** DashboardView passes recentSleepEvents (30-day @Query) to vm.smartSummary → SleepEfficiencyCalculator.compute sums asleep/inBed minutes across ~30 nights and clamps WASO between the month's first and last asleep intervals; the composer then compares this diluted figure to a per-night baseline and, because efficiencyBaseline falls back to 88 (always > 0), the candidate is appended unconditionally — with zero events efficiencyPct is 0 and the card reads 'Sleep efficiency was 0% (typical 88%)'.  

**Verification:** finder P1, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#159)

### F-012 · P1 · plausible · test-gap · sync

**Anchor:** `AnxietyWatch/Services/SyncService.swift:sync()`  

**Summary:** The cursor-advance invariants in SyncService.sync() (advance to the pre-captured cursorUpperBound, and only on non-bulkOnly iterations) have no test that fails if they break — all SyncServiceTests coverage stops at buildPayload, and sync() itself is untestable because it hardcodes URLSession.shared.  

**Failure scenario:** A refactor moves `lastSyncDate = cursorUpperBound` outside the `if !iterationIsBulkOnly` guard (or reorders it after applyPostUploadResponse with a fresh timestamp that isn't literally `.now`): both payloadBulkOnlyAndCursorAdvanceContract and payloadUpperBoundCapsExportRange still pass (they only assert JSON payload contents from buildPayload), the Semgrep rule anxietywatch-sync-cursor-now doesn't fire (it matches `lastSyncDate = .now`, not `= cursorUpperBound`), and the incremental-sync race the atlas registry rows 25/26 document as twice-fixed silently returns — small-volume records (anxiety entries, med doses) created during a drain loop are never uploaded to the server.  

**Verification:** finder P1, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#173)

### F-013 · P2 · confirmed · accuracy · sync-sensor-session

**Anchor:** `AnxietyWatch/Services/HRVSessionRecorder.swift:finalize`  

**Summary:** SensorSession rows synced mid-recording are flagged syncedToServer, and finalize()/finalizeOrphan() never re-dirty the flag, so the session's endTime, summaryJSON, and interruption data permanently never reach the server.  

**Failure scenario:** Overnight Polar recording; user opens the app in the morning while still recording; Dashboard auto-sync runs, fetchUnsyncedSensorSessions picks up the open session (endTime nil), uploads it, and markSamplesSynced flips syncedToServer=true. User then stops the session: HRVSessionRecorder.finalize writes endTime + summaryJSON and saves, but the flag stays true, so no future payload ever includes the row — the server mirror permanently shows that session with endTime NULL and no summary (rmssdMean/hrMean/gapFraction all absent), skewing any server-side analysis of session duration or quality.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#158)

### F-014 · P2 · confirmed · accuracy · sync-rr-archive

**Anchor:** `AnxietyWatch/Services/SyncService.swift:uploadPendingRRArchives`  

**Summary:** uploadPendingRRArchives uploads the RR archive of sessions that are still recording (no endTime guard) and stamps rrArchiveUploadedAt, so the server permanently keeps a truncated archive missing everything recorded after the mid-session sync.  

**Failure scenario:** Same trigger as above: auto-sync runs while a Polar session is recording; the open session lands in uploadedIDs.sensorSessions; uploadPendingRRArchives finds rrArchiveUploadedAt == nil and the on-disk .rr file (partial, still being appended), compresses and POSTs it, then sets `session.rrArchiveUploadedAt = .now`. All RR intervals recorded after that instant never reach the server — the skip check `where session.rrArchiveUploadedAt == nil` excludes the session on every future sync, so server-side RR-based analysis operates on a silently truncated night.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P1, P2, P2].  

**Disposition:** fixed (#158)

### F-015 · P2 · confirmed · silent-failure · sync-rr-archive

**Anchor:** `AnxietyWatch/Services/SyncService.swift:applyPostUploadResponse`  

**Summary:** A failed RR-archive POST is never retried: the retry scan is keyed to uploadedIDs.sensorSessions (sessions in the current payload), but markSamplesSynced flips those sessions' syncedToServer=true in the same call, so they never appear in any future payload and rrArchiveUploadedAt==nil is never re-examined.  

**Failure scenario:** Session row syncs successfully; the follow-up rr_archive POST fails once (server restart, timeout, Wi-Fi drop). rrArchiveUploadedAt stays nil as designed, but on the next sync fetchUnsyncedSensorSessions excludes the (now-flagged) session, so uploadPendingRRArchives never receives its ID again — the archive silently never reaches the server, contradicting the SensorSession doc comment 'the next sync run retries any session where this is nil'. Recoverable only because the local .rr file persists, but no code path will ever resend it.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#173)

### F-016 · P1 · confirmed · bug · sync-actor-isolation · _severity re-elevated at triage_

**Anchor:** `AnxietyWatch/Services/SongService.swift:fetchCatalog`  

**Summary:** SongService.fetchCatalog(into:) and SyncService.fetchPrescriptions(modelContext:) are nonisolated async functions that fetch/insert/save on the caller's MainActor-bound ModelContext from the global concurrent executor — the exact undefined-behavior hazard the sync() doc comment was written to prevent, and it runs on every sync.  

**Failure scenario:** Every successful sync ends with `await SongService.fetchCatalog(into: modelContext)` from @MainActor applyPostUploadResponse; per SE-0338 the nonisolated async body (including `context.fetch`, `context.insert(song)`, `try context.save()`) executes on a background executor against the same mainContext that @Query views and other MainActor code use concurrently. A catalog save landing while the main thread is mid-fetch (e.g., Dashboard re-render or an HRV tick) is a data race on a non-thread-safe SwiftData context — intermittent crash or store corruption. PrescriptionListView's 'Fetch from Server' has the identical shape via fetchPrescriptions → PrescriptionImporter.importRecords. SWIFT_VERSION = 5.0 means the compiler never flags it.  

**Verification:** finder P1, 2/3 verify lenses confirmed, lens votes [P1, P3, P2].  

**Disposition:** fixed (#158)

### F-017 · P2 · confirmed · bug · watch-connectivity

**Anchor:** `AnxietyWatch/Services/PhoneConnectivityManager.swift:updateCheckInContext`  

**Summary:** PhoneConnectivityManager.updateCheckInContext builds the outgoing applicationContext from WCSession.receivedApplicationContext (the context received FROM the Watch — always empty, since the Watch never calls updateApplicationContext) instead of .applicationContext (the last-sent context), so every check-in state change wipes the stats keys from the Watch's app context.  

**Failure scenario:** RandomCheckInManager schedules or completes a check-in → updateCheckInContext(pending:) sends a context containing only pendingRandomCheckIn. The Watch's in-memory stats survive (applyIncomingData uses if-let), but on the next Watch app cold launch loadContext() reads the received context, finds no lastAnxiety/hrvAvg/restingHR keys, and sets all three to nil — CurrentStatsView and the widget show blank/stale stats until the user next opens the iPhone Dashboard to trigger sendStatsToWatch.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P2, P2].  

**Disposition:** fixed (#164)

### F-018 · P2 · confirmed · efficiency · watch-connectivity

**Anchor:** `AnxietyWatch Watch App/WatchConnectivityManager.swift:transferSensorData`  

**Summary:** WatchConnectivityManager.transferSensorData has no sent-tracking despite its 'Fetch un-synced' comments: every 60 seconds it re-encodes and re-transferFiles the most recent 500 rows of all three sensor tables forever, and the phone-side #Unique upsert resets HRVReading.syncedToServer=false on each redelivery, causing perpetual re-uploads of the same rows to the sync server.  

**Failure scenario:** Watch sensor capture active; AnxietyWatchApp.startSensorCapture loop calls transferSensorData every 60 s. The three FetchDescriptors sort by timestamp descending with fetchLimit 500 and no transferred/synced predicate, so identical rows ship in every payload; with the iPhone unreachable overnight, WCSession's outstandingFileTransfers queue grows by ~480 redundant files. On receipt, PhoneConnectivityManager re-inserts each HRVReading via init (which hardcodes `syncedToServer = false`); the #Unique([\.id]) upsert overwrites the existing row, flipping already-synced rows dirty so SyncService re-POSTs up to 500 stale HRV readings to the server after every transfer, indefinitely.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P2, P2, P2, P2].  

**Merged from 2 finder reports** (same root defect); all at the same anchor, independently found by dimensions: concurrency-state, silent-failures.  

**Disposition:** fixed (#164)

### F-019 · P2 · confirmed · silent-failure · server-jobs

**Anchor:** `server/job_dispatcher.py:_execute_single_job`  

**Summary:** _execute_single_job's exception handler calls mark_failed on the same connection without rollback, so any psycopg2 error inside the job body leaves the job stuck 'running' and the dispatch loop polling forever.  

**Failure scenario:** A DB error inside build_job_prompt or load_dependency_results aborts the worker connection's transaction; the except block's mark_failed UPDATE then raises InFailedSqlTransaction (no conn.rollback() first), the exception escapes into an unchecked ThreadPoolExecutor future, the job row stays 'running', cascade_failures never runs, no_running_jobs never returns True, and the dispatcher thread spins on the 2-second poll indefinitely (leaked thread + connection) until process restart; the analysis is only rescued cosmetically by sweep_stale_analyses 15 minutes later.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P2, P2, P2, P2].  

**Merged from 2 finder reports** (same root defect); all at the same anchor, independently found by dimensions: concurrency-state, silent-failures.  

**Disposition:** fixed (#163)

### F-020 · P2 · confirmed · efficiency · trends-query

**Anchor:** `AnxietyWatch/Views/Trends/TrendsView.swift:allHRVReadings`  

**Summary:** TrendsView's HRVReading @Query is source-filtered but has no date bound, so the entire per-minute HRV table is materialized on the main thread and fully re-aggregated (coalesce + nightlyAggregates with per-night MAD trims) on every body evaluation.  

**Failure scenario:** After ~a year of nightly Polar wear (~480 readings/night, ~150k+ rows), every TrendsView body re-run — each swipe-page gesture, time-range/source picker change, tappedNight set/clear, or any SwiftData save that invalidates the query — re-fetches the whole table via @Query on the main thread and re-runs LFHFAggregator.coalesce + Set(flatMap) + filter over all readings + nightlyAggregates over the full history, plausibly locking the main thread for hundreds of ms to seconds per render; only the visible window plus the 30-day hfBaseline lookback (HFPowerTrendChart.baselineAnchor) is actually needed.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** approved (deferred to Batch H-3 — window-reactive TrendsView extraction)

### F-021 · P2 · confirmed · efficiency · lfhf-sessions-list

**Anchor:** `AnxietyWatch/Views/Trends/LFHFSessionsListView.swift:allReadings`  

**Summary:** LFHFSessionsListView loads the entire per-minute HRVReading table (source-filtered, no date bound) and recomputes per-session outlier-trimmed means over the full history on every body evaluation, just to render one HF/LF-HF number per list row.  

**Failure scenario:** With months of overnight sessions, opening the sessions list (or any re-render of it, e.g. a SwiftData save invalidating the query while a live recording writes readings) materializes ~100k+ HRVReading model objects on the main thread and runs LFHFAggregator.nightlyMeans (Dictionary grouping + per-session sort-based MAD trims) across all of them, producing a noticeable stall that grows without bound as history accumulates.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** approved (deferred to Batch H-3 — window-reactive TrendsView extraction)

### F-022 · P2 · confirmed · efficiency · trends-charts

**Anchor:** `AnxietyWatch/Views/Trends/TrendsView.swift:body`  

**Summary:** TrendsView fetches the full date-unbounded per-minute Polar HRVReading table and re-runs the whole LFHF pipeline (coalesce, night filtering, member-ID set build, nightlyAggregates grouping, nightlyHRFromSummaries) inside body on the main thread on every re-render, not just when Polar data changes.  

**Failure scenario:** With ~480 readings per overnight session, a year of nightly wear puts ~170k HRVReading rows behind the source-only @Query; every body evaluation (time-range picker change, source-filter change, page swipe, tappedNight set/clear, any @Query invalidation) re-coalesces and re-aggregates the entire history synchronously on the main thread, producing progressively worse tab-switch and interaction latency as the table grows.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** approved (deferred to Batch H-3 — window-reactive TrendsView extraction)

### F-023 · P2 · confirmed · accuracy · spo2-precedence

**Anchor:** `AnxietyWatch/Services/SnapshotAggregator.swift:applyOvernightSpO2Precedence`  

**Summary:** When a dedicated overnight oximeter contributes even a handful of samples, applyOvernightSpO2Precedence recomputes T90/desat count from that sparse preferred-only subset and nils the fields on failing its own sufficiency gate — discarding the already-sufficient HK-direct T90/desat values computed earlier in the same aggregateDay pass.  

**Failure scenario:** A night where an EMAY/Wellue oximeter (bundle in DeviceProvenance.overnightPulseOximeters) contributes only a few samples (e.g. connected briefly, then dropped or low battery) while Apple Watch spot-checked SpO2 all night meeting the earlier gate (>=30 samples, >=300s monitored) at lines 226-237 of aggregateDay, so snapshot.spo2TimeBelow90Min/spo2DesatsCount are already correctly populated. Because `preferred` is non-empty (even with just a few samples), the `guard !preferred.isEmpty else { return }` at step 6 does NOT early-return, so execution reaches step 8, which recomputes T90/desats from ONLY the sparse preferred set, fails its own `minSamplesForOvernightStats`/`minMonitoredDurationForOvernightStats` gate, and explicitly overwrites the fields to nil. The comment directly above the early-return guard says wiping T90/desats 'would lose legitimate Apple-Watch-derived overnight stats on watch-only nights' — but that is exactly what happens once preferred is non-empty-but-insufficient. ReportGenerator.renderOvernightSection then shows the night's SpO2 nadir (from the sparse EMAY reading) with T90/desat counts silently absent, understating hypoxic burden in the clinician-facing PDF for a night that had adequate combined-source coverage.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#159)

### F-024 · P2 · confirmed · accuracy · last-night-verdict

**Anchor:** `AnxietyWatch/Services/LastNightHeadline.swift:compose`  

**Summary:** LastNightHeadline.compose computes the efficiency-breach flag from the raw (possibly pinned-to-100%) efficiency value without regard to `efficiencyEstimated`, so a night with missing/incomplete inBed data — precisely the case the pin exists to flag as unreliable — can never register an efficiency breach and can present as 'Solid night'.  

**Failure scenario:** A night where Apple Watch/EMAY log `asleepCore`/`asleepREM` stage events but no (or only partial) `inBed` events — documented in SleepEfficiencyCalculator as a normal occurrence. `SleepEfficiencyCalculator.compute` then sets `inBedMinutes = max(inBedFromEvents, asleepMinutes)` = `asleepMinutes`, giving `efficiencyPct == 100.0` exactly and `isBedTimeEstimated == true`. `LastNightHeadline.compose` computes `effLow = efficiencyPct < 85` using that raw pinned value — always false — with no adjustment for the `efficiencyEstimated` flag that is otherwise only used to add a '~' prefix to the displayed percentage. If AHI and SpO2 nadir are both within normal range that same night (independent of the sleep-stage tagging problem), the LastNightCard headline reads 'Solid night · Sleep efficiency ~100%...' even though the '~' exists specifically because no real efficiency measurement could be made — masking a scenario where the true efficiency could have been poor. `LastNightHeadlineTests.estimatedEfficiencyMarked` only asserts the '~' substring appears in the text; it never asserts what verdict/breach-count results, so this gap is untested.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#159)

### F-025 · P1 · confirmed · silent-failure · polar-rr-archive · _severity re-elevated at triage_

**Anchor:** `AnxietyWatch/Services/RRArchiveWriter.swift:init(url:append:)`  

**Summary:** A misaligned (partially-written) .rr archive file is silently wiped to empty on next open instead of having only its corrupt trailing bytes discarded, permanently destroying every prior RR interval recorded for that session.  

**Failure scenario:** During a multi-hour overnight Polar H10 session, iOS kills the app (jetsam, force-quit, or battery pull) mid-write inside RRArchiveWriter.flushToDisk()'s `handle.write(contentsOf: pending)`, leaving the on-disk file's size not a multiple of the 10-byte record size. On next launch, PolarHRMService.recoverInFlightSessionIfNeeded() calls `RRArchiveWriter(url: archiveURL, append: true)`; since `size % recordSize != 0`, the init falls through to `FileManager.default.createFile(atPath: url.path, contents: nil)`, which overwrites the existing file with an empty one — not a truncation of just the bad trailing record as the code comment claims ('truncate so we don't append into a partial record'). Every RR interval recorded before the crash (potentially hours of per-beat data) is gone with no warning logged. Separately, `RRArchiveWriter.read(url:)` throws `.truncatedArchive` for the same misalignment and every caller (`RRArchiveAggregator.perMinuteHR`, the recovery path's `priorSamples`) does `try? ... ?? []`/`continue`, discarding the entire (otherwise-intact) aligned prefix rather than reading what's readable. The night's per-minute HR detail chart (`PolarSessionHRDetailView`) and any server-side `.rr` backup upload silently show/ship only the post-crash portion of the session, while the summary JSON and HRVReading rows (persisted separately in SwiftData) look unaffected, masking the loss.  

**Verification:** finder P0, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#160)

### F-026 · P2 · confirmed · accuracy · polar-hrv-timedomain

**Anchor:** `AnxietyWatch/Services/HRVCalculator.swift:timeDomain(rrIntervals:)`  

**Summary:** RMSSD and pNN50 are computed as successive differences over the artifact-filtered RR array, so removing an interior out-of-range RR interval silently splices together two non-adjacent heartbeats and injects a spurious, squared successive difference in exactly the window the filter was meant to protect.  

**Failure scenario:** Within one 60s tick window, a single interior RR sample is a legitimate PPG/contact artifact (e.g. 120ms, correctly excluded by the `[250,2000]` bound). `HRVSessionRecorder.tick` passes the resulting `filtered` array (with that element simply deleted, not interpolated or flagged) straight into `HRVCalculator.timeDomain`, which computes `diffs = zip(rrIntervals.dropFirst(), rrIntervals).map { $0 - $1 }` over the now-index-shifted array. The two RR values that used to straddle the removed artifact are treated as directly successive beats even though a whole beat was excised between them; RMSSD squares that spurious gap-spanning difference, so it can dominate the window's RMSSD and inflate pNN50, with no `skippedMinutes` increment or any other signal that a splice occurred. SDNN is unaffected (order-independent), but the resulting `HRVReading.rmssd`/`.pnn50` rows feed directly into `LFHFAggregator.nightlyRMSSD`'s per-night trend value and the `RMSSDTrendChart` the user sees.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#159)

### F-027 · P2 · confirmed · bug · hr-hrv-precedence

**Anchor:** `AnxietyWatch/Services/SnapshotAggregator.swift:applyDailyHeartMetricsPrecedence`  

**Summary:** applyDailyHeartMetricsPrecedence can never actually apply Polar H10 BLE-session precedence because it only reads QuantityHealthSample, and the app's own Polar BLE pipeline never writes to that table.  

**Failure scenario:** User records a Polar H10 chest-strap session overnight via the app's own BLE pipeline (PolarHRMService/HRVSessionRecorder), which writes rows only to SensorSession/HRVReading tagged source == "polar_h10" (per PolarHRMService.sourceLabel). Apple Watch also opportunistically logs its own noisier HRV/RHR samples to HealthKit the same night, which HealthDataCoordinator mirrors into QuantityHealthSample under an Apple bundle ID. During aggregateDay, applyDailyHeartMetricsPrecedence fetches only from QuantityHealthSample and partitions by DeviceProvenance.chestStrapHRMonitors (which includes "polar_h10"), but no QuantityHealthSample row ever carries sourceBundleID == "polar_h10" — only HealthDataCoordinator's HK mirror and EMAYImporter write to QuantityHealthSample, neither of which stamps that bundle ID. The partition's preferred set is always empty for this path, so the function silently falls through to the Apple-Watch-derived HK-direct value. HealthSnapshot.hrvAvg/hrvMin/restingHR — and therefore BaselineCalculator baselines, the Dashboard smart summary, and ReportGenerator's clinician-facing PDF HRV/RHR trend sections — reflect the noisier Watch value even though a higher-fidelity Polar session was recorded, contradicting the function's own documented intent (only the optional 'fi.polar.polarflow' companion-app-to-HealthKit path can ever trigger the override).  

**Verification:** finder P1, 2/2 verify lenses confirmed, lens votes [P2, P2].  

**Disposition:** fixed (#159)

### F-028 · P2 · confirmed · efficiency · cpap-clock-reset

**Anchor:** `AnxietyWatch/Services/CPAPImporter.swift:importSimple`  

**Summary:** A single AirSense clock-reset row (dated pre-2015) is still folded into the CSV's min/max dateRange, so the resulting snapshot-backfill loop iterates one aggregateDay call per day across the entire multi-year gap instead of skipping the flagged date.  

**Failure scenario:** A CPAP CSV/OSCAR export contains one row with a clock-reset artifact date (e.g. ~2009, the AirSense epoch-reset symptom this feature exists to detect) alongside otherwise-normal recent rows. importSimple/importOSCAR track `suspiciousDates` for the warning but still update `minDate`/`maxDate` unconditionally for every row, including the flagged one, so the returned dateRange spans from the bogus ~2009 date to today. CSVImportRouter.importContent forwards this dateRange verbatim as `Result.dateRange`. Both AnxietyWatchApp.processImportBatch/runImports and CPAPListView.handleImport gate a per-day `while date <= dateRange.upperBound { try await aggregator.aggregateDay(date); date = ...+1 day }` loop on this exact range, so a single bad row triggers ~6,000+ sequential aggregateDay calls (each firing ~25 concurrent HealthKit queries plus several SwiftData fetches/saves) on the main actor, effectively hanging import for a very long time and writing thousands of near-empty HealthSnapshot rows — while the user only sees the informational clock-reset warning, not any indication that import is now walking two decades of history.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P1, P2, P2].  

**Disposition:** fixed (#160)

### F-029 · P2 · confirmed · accuracy · server-analysis

**Anchor:** `server/analysis.py:gather_analysis_data`  

**Summary:** gather_analysis_data builds timestamp-range filters as UTC day boundaries while the prompt tells Claude all timestamps are US/Pacific, so evening-of-final-day entries are silently dropped from analysis and day-bucketed inconsistently against the date-column tables.  

**Failure scenario:** User (always US/Pacific per app context) requests an analysis for date_from..date_to = July 8. gather_analysis_data sets ts_end = combine(July 9, 00:00, tzinfo=utc). An anxiety entry / medication dose / song occurrence logged 9 PM Pacific on July 8 is stored as ~04:00 UTC July 9, which is >= ts_end, so it is excluded from anxiety_entries/medication_doses/song_occurrences/barometric_readings even though health_snapshots and cpap_sessions (filtered by their date column) DO include July 8; the analysis prompt then reasons over a Pacific day whose last ~7-8h of subjective/med data is missing and mis-attributed.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#159)

### F-030 · P2 · confirmed · render · glucose-detail-predicate

**Anchor:** `AnxietyWatch/Views/Dashboard/GlucoseDetailView.swift:GlucoseDetailView.init(anxietyEntries:sleepIntervals:)`  

**Summary:** GlucoseDetailView's @Query init builds a compound `#Predicate` (`&&`) capturing both a String local and a Date local — the exact shape already fixed elsewhere in this sweep (HRVSessionCardView) — currently dormant because no production call site instantiates GlucoseDetailView yet.  

**Failure scenario:** GlucoseDetailView is fully built (day-pill picker, window picker, chart, provenance footer) and already carries an `Equatable` conformance whose doc comment explicitly anticipates being used as a NavigationLink/`.equatable()` destination, but no call site exists today. The moment a future PR wires it in (e.g. a NavigationLink from the glucose tile in VitalsGridSectionView, the obvious next step given the view is otherwise complete), SwiftData will route `sample.metricType == glucoseRaw && sample.timestamp >= cutoff` through `_NSPredicateUtilities _predicateEnforceRestrictionsOnSelector:` while generating the SQL ORDER BY, hanging the main thread until the scene-update watchdog kills the app on the very first open of the glucose detail screen — reproducing the documented 0x8BADF00D crash class this same sweep found already fixed in HRVSessionCardView.swift.  

**Verification:** finder P1, 2/3 verify lenses confirmed, lens votes [P2, P3, P2].  

**Merged from 2 finder reports** (same root defect); related anchors: `AnxietyWatch/Views/Dashboard/GlucoseDetailView.swift:init`.  

**Disposition:** fixed (#173)

### F-031 · P2 · confirmed · efficiency · trends-barometric-query

**Anchor:** `AnxietyWatch/Views/Trends/TrendsView.swift:allBarometric`  

**Summary:** TrendsView's @Query on BarometricReading fetches the entire table with no date or source bound, then filters to the visible window purely in-memory, with no offsetting full-history use.  

**Failure scenario:** Over months/years of app use, BarometerService persists a new BarometricReading roughly every 15 minutes (or on a ≥0.05 kPa change) whenever the app is foregrounded or a background task runs. TrendsView's `@Query(sort: \BarometricReading.timestamp) private var allBarometric: [BarometricReading]` loads every one of those rows on every render (including on every tab switch back to Trends), then discards all but the current 7/30/90-day window via `allBarometric.filter { inWindow(...) }`. Unlike `allSnapshots` (legitimately needed in full for baseline calculations, per the file's own comments), `allBarometric`'s only consumer is the windowed `barometricReadings` value — the barometric-pressure baseline is computed from `allSnapshots`, not from raw readings — so there is no correctness reason to fetch the whole table. This is exactly the anti-pattern CLAUDE.md's own invariant calls out by name ('Any new @Query on HRVReading, BarometricReading, or another unbounded table must filter by source and bound by date. Don't fetch the whole table to filter in-memory'), and it also means SwiftUI re-evaluates/observes TrendsView on every barometric insert even when the visible window is far in the past.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P3, P2, P2, P2, P3].  

**Merged from 2 finder reports** (same root defect); all at the same anchor, independently found by dimensions: efficiency, render-pitfalls.  

**Disposition:** approved (deferred to Batch H-3 — window-reactive TrendsView extraction)

### F-032 · P2 · confirmed · render · medications-nav

**Anchor:** `AnxietyWatch/Views/Medications/MedicationsHubView.swift:navigationSection`  

**Summary:** MedicationsHubView pushes to PrescriptionListView and PharmacyListView via closure-based NavigationLinks whose destinations declare @Query but conform to neither Equatable nor .equatable(), so SwiftUI cannot dedupe the destination across parent re-renders.  

**Failure scenario:** User is viewing MedicationsHubView and taps 'Prescriptions' (or 'Pharmacies') to push into the closure-based NavigationLink destination. While the user is on/entering that pushed screen, any mutation that MedicationsHubView's own @Query properties observe (a dose logged via logDose, a background SyncService.fetchPrescriptions/autosync completing, a med activated/deactivated) re-evaluates MedicationsHubView.body, which reconstructs `NavigationLink { PrescriptionListView() }` / `NavigationLink { PharmacyListView() }` as a 'different' destination instance (no Equatable conformance and no .equatable() modifier to dedupe it). This restarts the NavigationStack push animation and, under repeated re-renders, cascades into the documented iOS 26 CA::Layer::layout_is_active use-after-free — the same class of bug that hit polar-session-hr-detail Phase 4, just triggered here via the medications hub's dose/prescription queries instead.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P2, P1, P2].  

**Disposition:** fixed (#157)

### F-033 · P2 · confirmed · security · admin-session

**Anchor:** `server/server.py:create_app`  

**Summary:** Admin session cookie lacks the Secure flag and the app is published directly as plain HTTP on all interfaces, so the admin password, session cookie, newly-created raw API keys (which round-trip through the signed-but-not-encrypted session cookie via session["new_key"]), and Bearer sync tokens all transit the network in cleartext.  

**Failure scenario:** Anyone able to capture traffic on the network path to `<server-host>:8081` (whatever host the compose stack runs on) reads the ADMIN_PASSWORD form POST, replays the admin session cookie, and reads the raw API key out of the base64 session payload during the create_key redirect — full read/write access to all synced health data.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#162)

### F-034 · P2 · confirmed · security · admin-auth

**Anchor:** `server/admin.py:login`  

**Summary:** POST /admin/login has no rate limiting, lockout, or failure delay, allowing unthrottled online brute force of the single ADMIN_PASSWORD that gates all PHI and the credential-encryption UI.  

**Failure scenario:** An attacker who can reach port 8081 scripts POSTs to /admin/login at line speed; a weak or reused ADMIN_PASSWORD falls to a dictionary run with no alerting, no delay, and nothing logged per attempt, granting the dashboard, data browser, and stored Walgreens/ResMed/CapRx credential management.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P3].  

**Disposition:** fixed (#162)

### F-035 · P2 · confirmed · security · server-deploy

**Anchor:** `server/docker-compose.prod.yml:anxietywatch-db.ports`  

**Summary:** Both compose files publish the PostgreSQL container on all interfaces ("5439:5432" defaults to 0.0.0.0), contradicting the documented 127.0.0.1 binding in CLAUDE.md and exposing the entire health database to the network with only POSTGRES_PASSWORD protecting it.  

**Failure scenario:** Any host on the LAN (or the internet, if the box is exposed — Docker's iptables port-publishing bypasses ufw-style host firewalls) connects to `<server-host>:5439` and brute-forces or replays the Postgres password to read/modify every synced medical record, bypassing the app's API-key layer entirely.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#162)

### F-036 · P2 · confirmed · accuracy · dashboard-lastnight

**Anchor:** `AnxietyWatch/Views/Dashboard/DashboardView.swift:lastNightSection`  

**Summary:** The Dashboard 'Last Night' card pairs the newest sleep snapshot with `recentCPAP.first` without any date match, so a stale CPAP session's AHI is presented as last night's value in the headline, the CPAP row, and the baseline delta.  

**Failure scenario:** Sleep/SpO2 snapshots are current via HealthKit but the CPAP SD card hasn't been imported for several days (the normal cadence for this app). lastNightSection picks last night's snapshot, then `if let cpap = recentCPAP.first` grabs a CPAP session up to 30 days old; LastNightCard shows 'Last Night ... AHI x.x' and computes '+x.x vs baseline' from the wrong night, and the breach verdict ('Rough night'/'Solid night') is scored on that stale AHI. The freshness label only reflects `snapshot.date` (`nightFreshnessLabel(for: snapshot.date)`), so nothing on screen indicates the AHI belongs to a different night — a direct violation of the project's fallback-state-honesty rule.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P2, P1, P2].  

**Merged from 2 finder reports** (same root defect); all at the same anchor, independently found by dimensions: medical-accuracy, silent-failures.  

**Disposition:** fixed (#159)

### F-037 · P2 · confirmed · silent-failure · watch-quicklog-ingest

**Anchor:** `AnxietyWatch/Services/PhoneConnectivityManager.swift:handleIncoming`  

**Summary:** Phone-side ingestion of watch quick-log anxiety entries uses `try? context.save()` with no logging and no failure handling, while the watch has already played a success haptic and holds no local copy — a save failure permanently and silently loses the journal entry and still marks a check-in complete.  

**Failure scenario:** User logs anxiety from the watch (QuickLogView plays `.success` and shows confirmation immediately; the entry exists only in the WCSession message — the watch never persists it). PhoneConnectivityManager.handleIncoming inserts into a fresh non-autosaving `ModelContext(container)` and calls `try? context.save()`; if the save throws (store busy/migration/disk), the entry vanishes with not even a log line (every other save path in the codebase at least logs), and the subsequent `RandomCheckInManager.completeCheckIn()` still runs, so a check-in is marked answered with no entry stored. The `guard ... let container = modelContainer else { return }` path is equally log-free.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#164)

### F-038 · P2 · confirmed · silent-failure · sync-api

**Anchor:** `server/server.py:_upsert_song_occurrences`  

**Summary:** /api/sync silently drops song occurrences it cannot link to a song, yet counts them as upserted and returns 200, so the iOS client advances its sync cursor and the records are lost permanently.  

**Failure scenario:** An occurrence payload arrives whose songGeniusId matches no songs row and whose songServerId is nil (e.g., a manually-added song created while offline, whose serverId the client never learned — DataExporter sends o.song?.serverId). The loop hits `continue  # Can't link occurrence without a song`, but the helper still returns len(occurrences), the sync_log records the full count, and the endpoint returns {"status": "ok"}. The iOS SyncService advances lastSyncDate past the occurrence's timestamp, so it is never re-sent; the server-side earworm history is silently incomplete and no error surfaces anywhere.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P2, P2, P2].  

**Disposition:** fixed (#161)

### F-039 · P2 · confirmed · bug · resmed-sync

**Anchor:** `server/resmed_sync.py:log_sync`  

**Summary:** resmed_sync.log_sync advances the resmed_last_sync cursor unconditionally on every outcome (auth_error, api_error, decrypt_error, no_credentials), which permanently forfeits the 365-day first-run backfill if the first attempt fails.  

**Failure scenario:** User configures ResMed credentials with a typo; the first run hits MyAirAuthError and calls log_sync(conn, "auth_error", 0), which runs set_setting(conn, "resmed_last_sync", now) with no status gate. On the next (successful) run, `days = 7 if last_sync else 365` sees a last_sync value and fetches only 7 days — up to a year of historical CPAP sessions (AHI, usage, leak) is silently never imported, and every later run also uses the 7-day window. Walgreens and CapRx both gate this on `if status == "success"`; ResMed does not.  

**Verification:** finder P1, 3/3 verify lenses confirmed, lens votes [P2, P2, P2, P2, P2, P2, P2, P2, P2, P2, P2, P2].  

**Merged from 4 finder reports** (same root defect); all at the same anchor, independently found by dimensions: concurrency-state, medical-accuracy, server-safety, silent-failures.  

**Disposition:** fixed (#161)

### F-040 · P2 · plausible · accuracy · cpap-import-provenance

**Anchor:** `AnxietyWatch/Services/CPAPImporter.swift:updateSession`  

**Summary:** CPAPImporter.updateSession unconditionally overwrites importSource on every re-import, silently discarding a manually-entered or server-restored session's true provenance (e.g. "manual", "resmed_cloud", "edf") and replacing it with "csv"/"oscar".  

**Failure scenario:** A session for a given date is created either via AddCPAPSessionView (`importSource: "manual"`) or restored from the server with `import_source` values the server itself tracks (e.g. "resmed_cloud", "edf" — see resmed_sync.py / edf_parser.py) through RestoreFromServer.swift (`importSource: (row["import_source"] as? String) ?? "oscar"`). If the user later imports a CSV/OSCAR file that happens to cover the same calendar date, CPAPImporter's prefetchSessions matches the existing session by date and updateSession runs `session.importSource = fields.importSource`, where `fields.importSource` is always the hardcoded literal "csv" or "oscar" for that call site — overwriting the prior provenance with no comparison or precedence check. CPAPListView and CPAPDetailView display `session.importSource` directly as "Source", so the user now sees a fabricated provenance label for a session that was actually manually entered or resmed_cloud/edf-derived.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#160)

### F-041 · P2 · plausible · accuracy · emay-import

**Anchor:** `AnxietyWatch/Services/EMAYImporter.swift:importLines`  

**Summary:** EMAYImporter parses timestamps as device-local wall-clock time with no DST-fallback disambiguation, so the repeated hour on a fall-back DST transition collapses onto identical Date values and dedup silently drops one hour of real oximeter samples.  

**Failure scenario:** A user runs an overnight EMAY oximeter session that spans a fall-back DST transition (the one night per year the local 1:00-2:00 AM hour occurs twice). `importLines` parses `"\(fields[0]) \(fields[1])"` with a `DateFormatter` whose `timeZone = TimeZone.current` and no ambiguous-time handling; both physical occurrences of the repeated wall-clock minute:second produce the identical `Date` value. Because `insertIfNew`'s dedup key is `(timestamp, metricType)` and `existingKeys` is updated as rows are inserted within the same import pass, the second (post-fallback, physically real and distinct) sample for any wall-clock time that also occurred pre-fallback is treated as an already-imported duplicate and silently dropped — not counted in `skippedRowCount` or `sensorGapRowCount`, so the import reports full success while roughly an hour's worth of SpO2/pulse samples from that specific night are missing from `QuantityHealthSample`, understating that night's monitored duration and potentially flipping it below `minSamplesForOvernightStats`/`minMonitoredDurationForOvernightStats` gates in SnapshotAggregator.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Merged from 2 finder reports** (same root defect); all at the same anchor, independently found by dimensions: medical-accuracy.  

**Disposition:** fixed (#160)

### F-042 · P2 · plausible · silent-failure · prescription-ocr

**Anchor:** `AnxietyWatch/Services/PrescriptionLabelScanner.swift:recognizeText(in:)`  

**Summary:** PrescriptionLabelScanner discards VNRecognizedText.confidence entirely, so a low-confidence OCR misread of a dose/Rx-number digit is displayed in the 'Detected Fields' review screen with identical visual weight to a high-confidence read, with no threshold gate or warning.  

**Failure scenario:** A blurry or glare-affected photo of a prescription label causes Vision (`.accurate` + `usesLanguageCorrection`) to misread a dose digit, e.g. reporting '7mg' for an actual '1mg' Clonazepam label, at a confidence Vision itself would rate well below 0.7. `recognizeText(in:)` only pulls `observation.topCandidates(1).first?.string` and never reads `.confidence`, so `ScannedPrescriptionData.dose` is populated identically regardless of underlying certainty. `PrescriptionScannerView.reviewForm` renders 'Dose: 7mg' next to other high-confidence fields with no distinguishing indicator, and a user trusting the OCR result over careful manual comparison to the bottle can tap 'Use These Values', carrying the misread dose into `AddPrescriptionView`'s pre-filled (but not flagged) form field and ultimately into the persisted `Prescription.doseMg`.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#164)

### F-043 · P2 · plausible · accuracy · reports-pdf

**Anchor:** `AnxietyWatch/Services/ReportGenerator.swift:generatePDF`  

**Summary:** The clinical PDF's HRV section computes its '30-day baseline' and 'Current status' anchored to .now regardless of the report's date range, printing 'Current status: Within normal range' when the range ends more than 3 days ago and no recent data exists.  

**Failure scenario:** User generates a report for a past range (e.g. 40→5 days ago): hrvBaseline(from: filteredSnapshots) uses the default anchorDate .now so only the overlap with the trailing 30 days contributes yet is labeled '30-day baseline'; isHRVBelowBaseline's recentAverage(days: 3) finds no snapshots in the last 3 days of the filtered set, returns nil → false, and the clinician-facing PDF asserts 'Current status: Within normal range' when the status is actually unknown. Fully-past ranges (>30 days ago) silently omit the baseline lines.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#164)

### F-044 · P2 · plausible · bug · export

**Anchor:** `AnxietyWatch/Views/Reports/ExportView.swift:filteredCounts`  

**Summary:** ExportView's endDate is seeded with Date.now's time-of-day behind a .date-only picker, so all exports (JSON/CSV/PDF) and the Data Summary counts silently exclude same-day records logged after the sheet was opened.  

**Failure scenario:** User opens Export at 10 AM, logs an anxiety entry at 8 PM, then exports with the default 'To: today': the filters use '$0.timestamp <= endDate' where endDate carries 10 AM, and DataExporter likewise drops 'date > e' — the evening entry is missing from the clinician report and export with no indication, even though the picker shows today as included.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#164)

### F-045 · P2 · plausible · accuracy · snapshot-aggregation

**Anchor:** `AnxietyWatch/Utilities/DeviceProvenance.swift:Reliability.heartRate`  

**Summary:** Reliability classifiers for HR/HRV/RHR treat any non-Apple-dominant sample window as 'low' reliability, so nights dominated by the highest-fidelity sources (EMAY oximeter pulse rate, Polar chest strap) are stored in dataQuality as the lowest tier.  

**Failure scenario:** An EMAY CSV import writes ~32k HKQuantityTypeIdentifierHeartRate samples under com.emay.SleepO2 for a night; Reliability.heartRate computes appleDominant = false (Apple share < 0.8) and returns .low, so the snapshot's dataQuality JSON labels the densest, dual-source HR day 'low' — contradicting DeviceProvenance.chestStrapHRMonitors/oximeter precedence that treats these same sources as preferred, and misleading any consumer of the synced dataQuality metadata.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#159)

### F-046 · P2 · plausible · accuracy · snapshot-aggregation

**Anchor:** `AnxietyWatch/Services/SnapshotAggregator.swift:applyDailyHeartMetricsPrecedence`  

**Summary:** applyDailyHeartMetricsPrecedence buckets chest-strap HRV/HR samples by calendar day [startOfDay, +1d) while the same snapshot's sleep/SpO2 fields use a noon-to-noon window, so an overnight chest-strap session crossing midnight has its samples split across two snapshots and each day's hrvAvg mixes fragments of two different nights.  

**Failure scenario:** Polar Flow (fi.polar.polarflow) mirrors an 11 PM–7 AM session into HealthKit: day D's snapshot hrvAvg is computed from that night's 11 PM–midnight fragment plus the previous night's post-midnight fragment, while day D's sleep fields describe a single noon-to-noon night — the stored 'daily HRV' disagrees in night-attribution with both the sleep fields on the same row and the Trends Polar series, which anchors whole nights to SensorSession.startTime.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#159)

### F-047 · P2 · plausible · silent-failure · labs-fhir

**Anchor:** `AnxietyWatch/Services/FHIRLabResultParser.swift:parse`  

**Summary:** FHIRLabResultParser requires effectiveDateTime and silently drops Observations that carry effectivePeriod (a legal FHIR R4 effective[x] variant), so labs from EHRs that emit Period are never imported.  

**Failure scenario:** A HealthKit clinical record whose Observation uses effectivePeriod {start, end} instead of effectiveDateTime: the guard returns nil, ClinicalRecordImporter records nothing, and the lab result is permanently absent from LabResults views and reports with no warning; additionally date-only strings parse via a DateFormatter with no fixed timeZone, so the stored instant is local midnight and the displayed day can shift if the device timezone changes.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#160)

### F-048 · P2 · plausible · test-gap · trends-source-filter

**Anchor:** `AnxietyWatch/Views/Trends/TrendsView.swift:filterBySource`  

**Summary:** SourceFilterTests re-implements the self-reported/check-in predicate inline in every test instead of calling the production TrendsView.filterBySource (which is private), so the nil-discriminator back-compat invariant (atlas registry row 3) is unprotected despite the registry crediting SourceFilterTests for it.  

**Failure scenario:** Someone edits TrendsView.filterBySource line 80 — e.g. drops the `$0.source == nil` clause during a cleanup, or renames the "dose_followup" literal — and every legacy pre-migration entry (nil source) or dose-follow-up entry silently disappears from the Self-Reported trend series; all six SourceFilterTests still pass because each one asserts against its own local copy of the predicate (`let isSelfReported = entry.source == nil || entry.source == "user" || ...`), never the production symbol.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#171)

### F-049 · P2 · plausible · test-gap · chart-palette

**Anchor:** `AnxietyWatch/Utilities/ChartPalette.swift:glucose`  

**Summary:** ChartPaletteTests' distinctness suite omits the one token pair that actually collides — glucose vs polarRMSSD are both literally Color.purple — so the atlas cross-cutting invariant 'ChartPaletteTests verifies distinctness' is only partially enforced and the live collision goes unflagged.  

**Failure scenario:** A user scrolls Trends with both the RMSSD chart (polarRMSSD series) and the Glucose chart (glucose series) visible: two unrelated medical metrics render in the identical purple, contradicting glucose's own doc comment ('Magenta family — distinct from HRV purples so a multi-metric overlay doesn't blur'); no test fails because the suite asserts hkHeartRate/polarHeartRate, healthKitHRV/polarRMSSD, LF/HF/ratio, sleep-stage, SpO2, and fill pairs — but never glucose against any HRV purple, and the tokensResolve test only checks the token exists.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#171)

### F-050 · P2 · plausible · test-gap · trends-empty-state

**Anchor:** `AnxietyWatch/Views/Trends/SleepRespiratoryTrendChart.swift:body`  

**Summary:** SleepRespiratoryTrendChart is the only one of the five trend charts whose hasAnyData empty-state gate is untested — and unlike the four siblings it is an inline let in body rather than an extracted static helper, so it cannot be tested without refactoring (atlas registry row 7).  

**Failure scenario:** A new data source is wired into the Sleep Respiratory card (e.g. an additional overnight series) but the inline gate `!sessions.isEmpty || !nadirData.isEmpty || !t90Data.isEmpty` isn't extended, or one of the three clauses is dropped in a refactor: a user whose only overnight data comes from the omitted source sees the card collapse to 'No Data' while data exists; nothing fails, because HeartRateTrendDatum.hasAnyData, RMSSDTrendDatum.hasAnyData, HRVTrendDatum.hasAnyData, and HFPowerTrendDatum.hasAnyData all have dedicated @Test coverage but SleepRespiratoryTrendChart has zero test references anywhere in AnxietyWatchTests.  

**Verification:** finder P2, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#171)

### F-051 · P3 · confirmed · bug · server-jobs

**Anchor:** `server/job_dispatcher.py:dispatch_analysis`  

**Summary:** dispatch_analysis has a TOCTOU race between find_ready_jobs and no_running_jobs that can exit the loop while dependent jobs are still pending, silently skipping the entire conflict-analysis DAG.  

**Failure scenario:** The health_analysis worker commits mark_completed in the window between the dispatcher's find_ready_jobs SELECT (which saw it 'running', so ready=[]) and the no_running_jobs SELECT (READ COMMITTED sees the fresh commit, count=0); the loop breaks, the 4 research jobs and conflict_synthesis stay 'pending' forever, and finalize_analysis marks the analysis 'completed' from the health result, so the run looks successful but the conflict analysis the user requested never executes.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3, P2, P2, P3].  

**Merged from 2 finder reports** (same root defect); all at the same anchor, independently found by dimensions: concurrency-state, silent-failures.  

**Disposition:** fixed (#163)

### F-052 · P3 · confirmed · silent-failure · server-jobs

**Anchor:** `server/analysis.py:sweep_stale_analyses`  

**Summary:** Process restart (deploy, OOM, gunicorn worker recycle) orphans analysis_jobs rows in 'running'/'pending' forever — sweep_stale_analyses only recovers the parent analyses table, and there is no job resume or re-dispatch mechanism.  

**Failure scenario:** The container is redeployed while a daemon dispatch thread has a research job marked 'running'; after restart nothing ever transitions that job — sweep_stale_analyses' UPDATE targets only the analyses table, mark_running claims are never reclaimed, and the admin conflict-analysis views show the job perpetually running with its sibling jobs perpetually pending, while the parent analysis is marked 'failed' by the sweep with a misleading timeout message.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** deferred (Phase 8 backlog)

### F-053 · P3 · confirmed · bug · server-jobs

**Anchor:** `server/analysis.py:sweep_stale_analyses`  

**Summary:** sweep_stale_analyses times out from created_at rather than started_at or last progress, falsely failing a legitimately-running conflict DAG at minute 15, after which finalize_analysis flips it back to 'completed' without clearing the stale error_message.  

**Failure scenario:** A full run (health analysis + 4 web-search research jobs on a 2-worker pool + synthesis, each up to 16384 output tokens) exceeds 15 minutes; an admin page refresh triggers the sweep and the analysis shows 'failed: Analysis timed out' while jobs continue burning API tokens; when the DAG finishes, finalize_analysis overwrites status to 'completed' but its UPDATE column list omits error_message, leaving a completed analysis carrying a timeout error string.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#163)

### F-054 · P3 · confirmed · silent-failure · walgreens-sync

**Anchor:** `server/walgreens_sync.py:main`  

**Summary:** walgreens_sync reads walgreens_last_sync but uses it only as a boolean, applying a fixed 90-day lookback from today regardless of how long ago the last successful sync actually was.  

**Failure scenario:** Walgreens auth (headed Playwright + security-question 2FA) stays broken for over 90 days — a realistic failure mode for a scraper — and when it is finally fixed, the next run fetches only today-minus-90-days onward, permanently omitting any fills dispensed in the interval between the last success and the 90-day window, with 'success' logged so nothing signals the hole in the prescriptions table.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#161)

### F-055 · P3 · confirmed · efficiency · snapshot-aggregator

**Anchor:** `AnxietyWatch/Services/SnapshotAggregator.swift:computeDataQuality`  

**Summary:** SnapshotAggregator.aggregateDay fetches the identical full-day QuantityHealthSample window twice back-to-back — once in applyDailyHeartMetricsPrecedence and again in computeDataQuality — materializing every sample row in the day two times per aggregation run.  

**Failure scenario:** On a day with minute-level Apple Watch HR (~1,440 rows), CGM (~288 rows), and the midnight-side half of a 1 Hz EMAY night (~16k rows), each aggregateDay call performs two separate `FetchDescriptor<QuantityHealthSample>(predicate: timestamp >= start && < end)` fetches of the same ~18k rows; aggregateDay runs on every app foreground and from both DashboardView's and TrendsView's `.task`, so the duplicated fetch cost is paid several times per launch when passing the first fetch's rows into computeDataQuality would eliminate it.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#167)

### F-056 · P3 · confirmed · efficiency · export

**Anchor:** `AnxietyWatch/Services/DataExporter.swift:buildBundle`  

**Summary:** DataExporter.buildBundle fetches every table in full (including the unbounded BarometricReading table) and applies the caller's start/end range in memory, and it runs synchronously on the main thread from ExportView's button actions.  

**Failure scenario:** Exporting a 1-month JSON range after a year of use still fetches the entire multi-year BarometricReading (~35k+ rows), AnxietyEntry, MedicationDose, and CPAP tables, filters them via the in-memory `inRange` closure, then pretty-prints/sorts the JSON — all inside `exportJSON()` called directly from a Button on the main actor, freezing the UI for the duration; the range belongs in the FetchDescriptor predicates and the encode belongs off-main.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P3, P3].  

**Disposition:** fixed (#167)

### F-057 · P3 · confirmed · efficiency · correlation-chart

**Anchor:** `AnxietyWatch/Views/Trends/CorrelationChartView.swift:pairedData`  

**Summary:** CorrelationChartView evaluates the grouping-heavy `pairedData` computed property twice per body (empty-check and Chart data), rebuilding a Dictionary(grouping:) over all AnxietyEntry rows and compactMapping all HealthSnapshot rows each time, on top of two unbounded @Querys.  

**Failure scenario:** Opening a correlation detail after years of journaling (thousands of entries, ~365 snapshots/year) runs `Dictionary(grouping: entries) { startOfDay }` plus the full snapshot compactMap twice on every body evaluation instead of once via a `let` at the top of body — the exact 'computed property accessed 2+ times in the same body' pattern the project's CLAUDE.md pitfalls list forbids; wasted main-thread work that scales with total history, not with what the scatter plot shows.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#165)

### F-058 · P3 · confirmed · efficiency · server-export

**Anchor:** `server/server.py:_query_entity`  

**Summary:** The /api/data export runs SELECT * on sensor_sessions, detoasting every rr_archive BYTEA (~80-120KB gzip per overnight session) out of Postgres into Python only for _serialize_row to immediately null it.  

**Failure scenario:** User taps Restore From Server (or any /api/data call): after a year of nightly Polar sessions, ~365 archives (~36MB) are read from TOAST storage, transferred to the Flask worker, and discarded by the memoryview->None branch — pure wasted DB I/O and worker memory that grows linearly with session count and inflates response latency toward RestoreFromServer's 180s client timeout.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3, P3, P3, P3].  

**Merged from 2 finder reports** (same root defect); all at the same anchor, independently found by dimensions: efficiency, server-safety.  

**Disposition:** fixed (#169)

### F-059 · P3 · confirmed · efficiency · server-export

**Anchor:** `server/server.py:get_all_data`  

**Summary:** GET /api/data with no `since` materializes every row of the unbounded per-sample tables (hrv_readings at ~480 rows/night, sleep_stage_events, barometric_readings, plus all songs with full lyrics) via fetchall() into a single un-paginated JSON response.  

**Failure scenario:** RestoreFromServer.restoreFromServer calls /api/data with no query parameters and a 180s timeout; after a year of data (~175k hrv_readings rows plus sleep events and barometric history) the gunicorn worker builds a multi-hundred-MB Python list + JSON blob in memory and the phone must decode it in one JSONSerialization call on the main actor — restore times out or OOMs, and there is no chunked/paginated fallback.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** approved (deferred to backlog — needs a paginated/streamed /api/data protocol change touching the iOS restore client; F-058 already removed the dominant per-row cost)

### F-060 · P3 · confirmed · efficiency · sync-upserts

**Anchor:** `server/server.py:_upsert_barometric_readings`  

**Summary:** _upsert_barometric_readings is the only unbounded time-series upsert still using a per-row cur.execute loop, while its siblings (quantity samples, sleep events, sensor sessions, hrv readings) were deliberately converted to execute_values to avoid one round trip per row.  

**Failure scenario:** A full sync (since == nil, e.g. Rebuild All History) ships the entire barometric history in one payload — SyncService's buildPayload routes barometric readings through DataExporter's uncapped small-volume export — so years of threshold/interval-gated readings become thousands of sequential INSERT statements inside one /api/sync transaction, multiplying sync duration ~10-50x versus the batched helpers and pushing the request toward the worker timeout.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#169)

### F-061 · P3 · confirmed · efficiency · correlations

**Anchor:** `server/correlations.py:compute_correlations`  

**Summary:** compute_correlations runs the identical health_snapshots-to-anxiety_entries join eight times per recompute (7 signals + get_paired_day_count), inside the /api/sync request path, with a `a.timestamp::date = h.date` cast that defeats the anxiety_entries timestamp PK index (no expression index exists).  

**Failure scenario:** Every /api/sync that carries a new journal entry marks correlations stale (correlations_are_stale compares MAX(timestamp) to computed_at), so the sync response is delayed by 8 sequential seq-scan hash joins over the full snapshot and entry history — cost that grows linearly with history and repeats the same JOIN + GROUP BY per signal when a single grouped query (or one materialized paired-days pass) would serve all seven SIGNALS.  

**Verification:** finder P3, 2/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#169)

### F-062 · P3 · confirmed · efficiency · journal

**Anchor:** `AnxietyWatch/Views/Journal/AddJournalEntryView.swift:recentEntries`  

**Summary:** AddJournalEntryView and JournalEntryDetailView each declare a full-table unbounded @Query on AnxietyEntry whose only consumer is a prefix(50) frequent-tags counter, duplicating the same fetch-everything-take-50 pattern in two sibling views.  

**Failure scenario:** Every time the add-entry sheet or an entry detail is opened, the entire journal history (thousands of rows with random check-ins) is fetched and observed, though only the newest 50 entries' tags are ever read; a fetchLimit-50 descriptor (the HRVSessionCardView pattern) would make the cost constant.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#165)

### F-063 · P3 · confirmed · efficiency · trends-charts

**Anchor:** `AnxietyWatch/Views/Trends/CorrelationInsightsView.swift:pairedDayCount`  

**Summary:** CorrelationInsightsView retains two full-table @Querys (AnxietyEntry, HealthSnapshot) that are read only by the empty-state progress meter, so once correlations exist the view fetches and observes both entire tables for nothing.  

**Failure scenario:** A user with computed correlations (the steady state) opens Insights: `pairedDayCount` is never evaluated because the non-empty branch renders, yet both unbounded queries still execute and re-fire the view on every journal entry or snapshot write; in the empty state the paired-day count also rebuilds two Sets over full tables per render.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#165)

### F-064 · P3 · confirmed · render · trends-charts

**Anchor:** `AnxietyWatch/Views/Trends/GlucoseTrendChart.swift:datums`  

**Summary:** GlucoseTrendChart re-runs GlucoseTrendDatum.from — including JSONSerialization of each snapshot's dataQuality blob — six-plus times per render because `datums` is an uncached computed property fanned out to subtitle, meanCV, rollingMean, isEmpty, ForEach, and cvData.  

**Failure scenario:** On a 30- or 90-day Trends window, every TrendsView body evaluation (picker change, swipe, any @Query update) parses each visible snapshot's dataQuality JSON ~6 times (body→isEmpty, ForEach, cvData; subtitle→datums×2 + meanCV→datums; rollingMean→datums), multiplying main-thread JSON work per render for output identical to a single pass cached in a let.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#165)

### F-065 · P3 · confirmed · render · medications

**Anchor:** `AnxietyWatch/Views/Prescriptions/PrescriptionListView.swift:activePrescriptions`  

**Summary:** PrescriptionListView evaluates the activePrescriptions and expiredPrescriptions computed properties three times each per body, re-running PrescriptionSupplyCalculator.supplyStatus (calendar/day math) over the whole prescriptions table on every access.  

**Failure scenario:** With CapRx per-claim rows accumulating (hundreds of Prescription records), each render performs ~6 full passes of supplyStatus over the table (lines 37, 66, 71/73, 86/88) plus per-row SupplyBadge recomputation, instead of one cached pass; list scrolling and any prescription write amplify the redundant work.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#165)

### F-066 · P3 · confirmed · accuracy · baseline-calculator

**Anchor:** `AnxietyWatch/Services/BaselineCalculator.swift:BaselineResult`  

**Summary:** BaselineCalculator.BaselineResult exposes only mean/SD/bounds — no sample count or trim ratio — so a baseline that barely cleared the 14-point minimum (some of which may have been MAD-trimmed) is indistinguishable from one built on 30 well-distributed, untrimmed points.  

**Failure scenario:** Two baselines — one from exactly 14 raw values (2 removed as MAD outliers, 12 effective) and one from 30 stable values — return the same-shaped `BaselineResult` with no field indicating sample size or how many points were trimmed. `VitalsGridSectionView.baselineDelta`/`baselineColor` and `ReportGenerator`'s '30-day baseline: %.1f ms (σ = %.1f)' line render identically in both cases, so a clinician reading the PDF, or the patient reading a red/yellow/green baseline chip, has no way to tell a low-confidence near-minimum baseline apart from a well-supported one — exactly the 'confidence band' the check calls for and the internal `baseline(from:)` helper already computes (`effective.count`) but discards before returning.  

**Verification:** finder P2, 2/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** deferred (Phase 8 backlog)

### F-067 · P3 · confirmed · accuracy · polar-session-recovery

**Anchor:** `AnxietyWatch/Services/PolarHRMService.swift:recoverInFlightSessionIfNeeded()`  

**Summary:** A session's displayed `rrCount` mixes two incompatible counting bases — artifact-filtered for the live-recorded portion, raw/unfiltered for any pre-recovery or orphaned portion — inflating the beat count shown on the Dashboard session card for any session that survives an app restart mid-recording.  

**Failure scenario:** A Polar H10 session runs long enough to hit a BLE-restoration recovery (a routine event for overnight recordings, e.g. after a background suspend/relaunch). `HRVSessionRecorder.tick` accumulates `totalRRCount += filtered.count` — i.e. only RR intervals passing the `[250,2000]` physiological filter — for every live tick. But `PolarHRMService.recoverInFlightSessionIfNeeded()` seeds the recovered recorder's prior count via `let priorRRCount = RRArchiveWriter.recordCount(url: archiveURL)`, which is simply the on-disk file's byte count divided by 10 — every raw RR record ever archived, including out-of-range artifacts that every other consumer (tick, rehydration, RRArchiveAggregator) filters out. `finalizeOrphan` does the same unfiltered `recordCount` for stranded sessions. The resulting `summaryJSON.rrCount`, displayed as e.g. '1.2k' on `HRVSessionCardView`, is therefore inflated relative to an otherwise-identical session that never recovered, even though every other per-tick statistic in the same summary (RMSSD, SDNN, LF/HF, hrMean) consistently excludes those same artifacts.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#159)

### F-068 · P3 · confirmed · accuracy · cpap-edf

**Anchor:** `server/edf_parser.py:upsert_cpap_leak`  

**Summary:** upsert_cpap_leak inserts ahi = 0.0 as an "unknown AHI" sentinel for EDF-only dates, making an unknown-AHI night indistinguishable from a real zero-event (perfect) night in every downstream AHI consumer.  

**Failure scenario:** A detail EDF file is the only source for a given date (no CSV/cloud row exists). upsert_cpap_leak inserts a new cpap_sessions row with ahi = 0.0. That date now reports AHI 0.0 to the analysis prompt and any AHI aggregation/correlation, which reads it as a clinically meaningful "zero apneas last night" rather than "AHI not measured", biasing AHI trends and Claude's sleep-quality reasoning downward toward a fabricated perfect value.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#161)

### F-069 · P3 · confirmed · accuracy · server-analysis

**Anchor:** `server/correlations.py:correlations_are_stale`  

**Summary:** correlations_are_stale keys freshness off MAX(timestamp)/MAX(date), so a backfilled or past-dated entry (older than the newest existing row) never marks correlations stale and the analysis prompt keeps serving correlations that ignore the newly added history.  

**Failure scenario:** User imports a batch of historical data (e.g. a past night's EMAY oximeter data or an older anxiety entry / CPAP session) whose timestamp/date is earlier than the current MAX. correlations_are_stale compares only MAX(anxiety_entries.timestamp) and MAX(health_snapshots.date) against last_computed; since neither max moved, it returns False, correlations are never recomputed to incorporate the backfilled data, and /api/correlations plus the analysis prompt present correlation coefficients computed from an incomplete dataset with no staleness signal.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3, P2, P3, P3].  

**Merged from 2 finder reports** (same root defect); all at the same anchor, independently found by dimensions: concurrency-state, medical-accuracy.  

**Disposition:** fixed (#161)

### F-070 · P3 · confirmed · efficiency · lab-results-query-scope

**Anchor:** `AnxietyWatch/Views/LabResults/LabTestHistoryView.swift:results`  

**Summary:** LabTestHistoryView's @Query fetches the entire ClinicalLabResult table with no predicate, then filters to a single loincCode in-memory via a computed property re-evaluated on every access.  

**Failure scenario:** As ClinicalLabResult rows accumulate across years of hospital-linked HealthKit clinical records, opening any single lab test's history screen (e.g. one panel out of dozens tracked in LabTestRegistry) loads and re-sorts the full cross-test history on every body/chart/list access via the `results` computed property (`allResults.filter { $0.loincCode == loincCode }.sorted { ... }`), instead of scoping the @Query predicate to the one code the screen actually displays.  

**Verification:** finder P2, 2/3 verify lenses confirmed, lens votes [P3, P3, P3, P3, P3, P3].  

**Merged from 2 finder reports** (same root defect); related anchors: `AnxietyWatch/Views/LabResults/LabTestHistoryView.swift:allResults`.  

**Disposition:** fixed (#165)

### F-071 · P3 · confirmed · efficiency · dashboard-query-scope

**Anchor:** `AnxietyWatch/Views/Dashboard/DashboardView.swift:recentSnapshots`  

**Summary:** DashboardView's `recentSnapshots` @Query has no predicate at all, fetching the entire ever-growing HealthSnapshot table on every render, unlike its four sibling queries in the same init() that are deliberately 30-day-bounded.  

**Failure scenario:** HealthSnapshot accumulates roughly one row per day of app use (aggregateDay runs from AnxietyWatchApp, DashboardView, CPAPListView, TrendsView, and SettingsView.rebuildAllSnapshots). Every downstream consumer of `recentSnapshots` only needs a small recent window — BaselineCalculator's six functions each independently re-filter the passed array down to the last 30 days by date, `sevenDayAverage` takes `.prefix(7)`, `todaySnapshot`/`lastSnapshotWith` scan for a single match — yet the @Query itself pulls the full multi-year table into memory and re-sorts it on every SwiftData change notification touching any HealthSnapshot row, including edits to old days made by 'Rebuild All History'. This is the same 'don't fetch the whole table to filter in-memory' rule DashboardView already applies correctly to recentEntries/recentDoses/recentCPAP/recentLabResults two lines above.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#165)

### F-072 · P3 · confirmed · efficiency · medications-query

**Anchor:** `AnxietyWatch/Views/Medications/MedicationsHubView.swift:recentDoses`  

**Summary:** MedicationsHubView and PrescriptionListView each declare an unbounded @Query over an entire growing table (MedicationDose, Prescription) with no date or fetchLimit bound, then truncate/filter the full result set in memory on every body evaluation.  

**Failure scenario:** As MedicationDose accumulates years of routine + PRN dose logs, `MedicationsHubView`'s `@Query(sort: \MedicationDose.timestamp, order: .reverse) private var recentDoses` fetches and sorts the whole table on every re-render just to show `recentDoses.prefix(10)` (and re-slices again in `deleteDoses`). Independently, `prescriptions` (the whole `Prescription` table, also unbounded) is queried by both `MedicationsHubView` and `PrescriptionListView`; `PrescriptionListView` then runs `PrescriptionSupplyCalculator.supplyStatus` over every row inside two computed properties (`activePrescriptions`, `expiredPrescriptions`) that are each evaluated 3-4 times per single `body` pass (isEmpty checks plus ForEach). Every dose logged, med toggled, or background prescription sync re-triggers the full unbounded fetch/sort/filter chain, growing the per-render main-thread cost with table size instead of bounding it — the same 'fetch whole table then filter/prefix in-memory' shape called out for HRVReading/BarometricReading @Query scope elsewhere in the codebase.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P3, P3, P3, P3, P3].  

**Merged from 2 finder reports** (same root defect); all at the same anchor, independently found by dimensions: efficiency, render-pitfalls.  

**Disposition:** fixed (#165)

### F-073 · P3 · confirmed · render · settings-navigation

**Anchor:** `AnxietyWatch/Views/Settings/HealthRecordsSettingsView.swift:HealthRecordsSettingsView.body`  

**Summary:** HealthRecordsSettingsView's closure-based NavigationLink to LabResultsView (which declares @Query) omits the `.equatable()` call-site modifier that the equivalent CareSectionRowView call site applies, so LabResultsView's Equatable conformance is dormant here.  

**Failure scenario:** LabResultsView conforms to Equatable (`static func == { true }`) specifically to opt out of SwiftUI's default per-render diffing of its `@Query` property, but merely conforming to Equatable has no effect on view diffing unless the call site wraps the destination in `.equatable()` (EquatableView). CareSectionRowView.swift correctly does `LabResultsView().equatable()`, but HealthRecordsSettingsView.swift's `NavigationLink { LabResultsView() } label: { Label("Lab Results", ...) }` does not. If HealthRecordsSettingsView's body is ever re-rendered while this destination is pushed (e.g. a future edit adds reactive state to this screen, or a parent Form re-layout), the destination will re-push/restart transition exactly like the CareSectionRowView call site would have without its fix.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#157)

### F-074 · P3 · confirmed · efficiency · cpap-query

**Anchor:** `AnxietyWatch/Views/CPAP/CPAPListView.swift:CPAPListView`  

**Summary:** CPAPListView holds two unbounded @Query properties (all HealthSnapshot rows, all AnxietyEntry rows) with no date bound, purely to let CPAPDetailView look up a single day's snapshot/entries per session.  

**Failure scenario:** Every time the CPAP tab is opened, CPAPListView fetches the *entire* HealthSnapshot and AnxietyEntry tables into memory (`@Query(sort: \HealthSnapshot.date, order: .reverse) private var snapshots` and `@Query(sort: \AnxietyEntry.timestamp, order: .reverse) private var entries`, both unfiltered), even though each CPAPDetailView only needs the single day matching that session's date. As the journal grows over years of use (multiple entries/day from manual logging, random check-ins, and dose follow-ups), this view re-derives and holds a growing, unbounded working set on every render — the same 'don't fetch the whole table to filter in-memory' anti-pattern CLAUDE.md flags for HRVReading/BarometricReading, just on AnxietyEntry/HealthSnapshot instead.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3, P3, P3, P3].  

**Merged from 2 finder reports** (same root defect); related anchors: `AnxietyWatch/Views/CPAP/CPAPListView.swift:entries`.  

**Disposition:** fixed (#165)

### F-075 · P3 · confirmed · security · crypto

**Anchor:** `server/crypto.py:_fernet_key`  

**Summary:** crypto.py derives the Fernet key from SECRET_KEY with a hardcoded public salt and no key versioning, so rotating SECRET_KEY (the normal response to a suspected leak, and also Flask's cookie-signing key) silently orphans every encrypted portal credential with no re-encryption path.  

**Failure scenario:** SECRET_KEY is rotated after a suspected exposure; on the next cron run all three sync scripts hit InvalidToken in decrypt_value, exit 3 with status decrypt_error, and Walgreens/ResMed/CapRx enrichment stops until each credential is manually re-entered — and because the salt b"anxietywatch-settings" is committed to a public repo, a weak human-chosen SECRET_KEY is attackable with a precomputed table shared across all deployments of this open-source app (100k PBKDF2 iterations is also well below current OWASP guidance of 600k for SHA-256).  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** deferred (Phase 8 backlog)

### F-076 · P3 · confirmed · security · resmed-sync

**Anchor:** `server/resmed_client.py:MyAirClient._authenticate`  

**Summary:** The Okta one-time sessionToken is sent as a URL query parameter, and connection-failure exceptions that embed the full URL (including the token) are wrapped verbatim into MyAirAuthError, logged at ERROR, and flashed into the admin UI.  

**Failure scenario:** During Step 3 of the PKCE flow, requests.get(OKTA_AUTHORIZE_URL, params={... 'sessionToken': session_token ...}) hits a ConnectionError/ConnectTimeout; urllib3's MaxRetryError message contains the full path+query including the still-unused (therefore still-valid, ~5-min-lifetime) sessionToken. fetch_sessions wraps it via repr(exc) into MyAirAuthError, resmed_sync.py:235 logs it to stderr (container logs), and admin.py's ResMed 'sync now' additionally flashes the subprocess stderr into the admin page/session cookie.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P3, P3].  

**Disposition:** fixed (#162)

### F-077 · P3 · confirmed · security · walgreens-sync

**Anchor:** `server/walgreens_client.py:WalgreensClient._authenticate`  

**Summary:** On Walgreens login failure the client dumps 3000 chars of arbitrary page text into ERROR logs and saves an unencrypted screenshot of the login page (username field filled with the real account email) to /tmp, where it persists indefinitely.  

**Failure scenario:** Any failed login (bot detection, wrong password, site change) after the username has been typed into the form: page.screenshot writes /tmp/walgreens_login_fail.png showing the account email in the username field (password is masked); the file is never deleted and survives in the container filesystem. Simultaneously logger.error emits up to 3000 chars of page body text — which on account-specific error pages can echo the email — into container logs, violating the 'presence/length metadata only' rule.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3, P3, P3, P3].  

**Merged from 2 finder reports** (same root defect); related anchors: `server/walgreens_client.py:_authenticate`.  

**Disposition:** fixed (#162)

### F-078 · P3 · confirmed · security · caprx-sync

**Anchor:** `server/caprx_sync.py:run_sync`  

**Summary:** CapRx sync persists raw exception text into the settings table and sync_log (unlike ResMed/Walgreens which store fixed status strings), so SSO-chain exception messages containing a resolve_id — directly exchangeable for access+refresh tokens with no further auth — can be stored in the DB and rendered on the admin page.  

**Failure scenario:** A requests.ConnectionError inside _follow_saml_chain or _post_saml_form on a redirect URL carrying ?resolve_id=... propagates to run_sync's RequestException handler; log_sync(conn, f"api_error: {e}", 0) writes the message (with the URL+query from urllib3's MaxRetryError) into caprx_last_status and sync_log, and caprx_settings renders last_status; the resolve_id in it is a bearer-equivalent credential per authenticate() Step 5, which exchanges it for tokens with only a bare POST.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#162)

### F-079 · P3 · confirmed · security · server-songs

**Anchor:** `server/genius.py:fetch_lyrics_musixmatch`  

**Summary:** The Musixmatch API key is passed as a URL query parameter and log.exception on any RequestException prints a traceback whose exception message includes the full request URL — API key included — into server logs.  

**Failure scenario:** MUSIXMATCH_API_KEY is set and a lyrics fetch hits a ConnectionError/ConnectTimeout: the raised exception's message is urllib3's 'Max retries exceeded with url: /ws/1.1/matcher.lyrics.get?q_track=...&apikey=<KEY>', and log.exception("Musixmatch fetch failed...") writes that traceback (key and all) to the application log, violating the never-log-API-keys rule.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#162)

### F-080 · P3 · confirmed · security · server-credentials

**Anchor:** `server/admin.py:resmed_settings`  

**Summary:** ResMed email and Walgreens username are stored plaintext in the settings table while the CapRx email is Fernet-encrypted — the same credential-identifier class gets inconsistent at-rest protection (confirms atlas oddity #119 in the current code).  

**Failure scenario:** Anyone with read access to the Postgres settings table (backup dump, the /admin data browser if settings were ever whitelisted, or a DB compromise where SECRET_KEY is not also compromised) reads the account email/username for two of the three portals in cleartext, defeating the purpose of encrypting the paired passwords; the identifiers also render as plaintext form values in the resmed/walgreens settings pages but only as has_email booleans for CapRx.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#162)

### F-081 · P3 · confirmed · silent-failure · clinical-labs-import

**Anchor:** `AnxietyWatch/Services/ClinicalRecordImporter.swift:importLabResults`  

**Summary:** ClinicalRecordImporter drops FHIR records that fail to parse with a bare `continue` — no skip counter, no log, and no user surface — and the hourly background import is the only ingestion path, so dropped lab results are permanently invisible.  

**Failure scenario:** A provider's FHIR Observation uses a shape the minimal parser rejects (e.g. `effectivePeriod` instead of `effectiveDateTime`, a date format outside the three formatters, or JSON that fails `JSONDecoder().decode(FHIRObservation.self,...)`). `FHIRLabResultParser.parse` returns nil for both intentional registry filtering and genuine parse failures; the importer's `guard ... let parsed = ... else { continue }` skips the record with zero telemetry. Since the record's UUID is never inserted it is retried and re-dropped every hour forever; the user sees fewer lab results in LabResultsView and cannot distinguish 'provider hasn't posted it' from 'app dropped it'. Contrast: CPAPImporter/EMAYImporter both count skips via ImportSkipTracker and surface them in the import alert.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P2, P3, P3].  

**Disposition:** fixed (#164)

### F-082 · P3 · confirmed · silent-failure · health-records-auth

**Anchor:** `AnxietyWatch/Views/Settings/HealthRecordsSettingsView.swift:body`  

**Summary:** The 'Connect Health Records' button swallows authorization errors with an empty catch, giving the user zero feedback when the request fails — the button appears to do nothing.  

**Failure scenario:** User taps 'Connect Health Records' on a device where clinical-records authorization throws (Health Records unavailable in region, restricted profile, or HealthKit error). The catch block is deliberately empty ('don't show checkmark'), so no alert, no inline message, and no state change occurs; the user can't tell a failed request from a slow one and has no cue to fix the underlying condition, while lab-result import silently stays disabled.  

**Verification:** finder P3, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#164)

### F-083 · P3 · confirmed · silent-failure · server-core

**Anchor:** `server/server.py:create_app`  

**Summary:** The startup auto-migration block swallows all exceptions and logs only the exception type name at WARNING level, so a failed Alembic migration boots the app against a stale schema with no traceback anywhere.  

**Failure scenario:** A new deploy ships a migration that fails (bad SQL, lock timeout, alembic.ini path issue). create_app catches it, logs `Database init skipped: OperationalError` — no message, no traceback — and the server starts serving. Every subsequent /api/sync that touches the missing column returns a generic 500 ("Sync failed" with rollback), and the operator has to reverse-engineer the root cause because the one log line that knew it was a migration failure carries only the type name.  

**Verification:** finder P2, 3/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#164)

### F-084 · P3 · plausible · efficiency · journal

**Anchor:** `AnxietyWatch/Views/Journal/JournalListView.swift:entries`  

**Summary:** JournalListView loads the complete journal history through an unbounded @Query with no pagination or fetch limit, the only cap on a primary history list fed multiple entries per day by random check-ins and dose follow-ups.  

**Failure scenario:** After a few years of multi-daily logging (user entries + random check-ins + dose follow-ups), opening the Journal tab materializes every AnxietyEntry row into the query result before the lazy List can help; initial tab render and every entry insert re-run a fetch whose cost grows linearly with lifetime history while the visible screen shows ~10 rows.  

**Verification:** finder P3, 1/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#165)

### F-085 · P3 · plausible · accuracy · trends-baselines

**Anchor:** `AnxietyWatch/Views/Trends/HRVTrendChart.swift:baseline`  

**Summary:** HRV, AHI, and barometric trend charts compute their baseline rules anchored to .now even when the user pages into past windows, unlike HFPowerTrendChart which deliberately anchors to the window end; the sibling BaselineCalculator functions also lack the upper-bound filter that spo2Nadir/t90 added, so they cannot be safely re-anchored without that fix.  

**Failure scenario:** User pages Trends back to a 90-days-ago window: the HF Power card's 'avg' rule shows that period's trailing-30-day baseline (anchor: ws.end), while the SDNN/AHI/barometric cards on the same screen draw today's trailing-30-day baseline and the subtitle's '⚠ Below baseline' reflects the current 3-day status — two inconsistent baseline semantics presented side-by-side over past data; additionally hrvBaseline/cpapAHIBaseline/barometricPressureBaseline filter only '$0.date >= cutoff' with no '<= anchor', so passing a past anchor would silently include future snapshots.  

**Verification:** finder P3, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** deferred (Phase 8 backlog)

### F-086 · P3 · plausible · silent-failure · dose-followup-state

**Anchor:** `AnxietyWatch/Utilities/DoseFollowUpManager.swift:loadPending`  

**Summary:** DoseFollowUpManager.loadPending decodes its UserDefaults blob with `(try? ...) ?? []`, so any decode failure (e.g. a Codable schema change on app update) silently discards all pending dose follow-ups, and the next savePending permanently overwrites the old blob with the empty list.  

**Failure scenario:** A future release adds a non-optional field to `PendingFollowUp` (or the stored data is otherwise undecodable). On first launch after update, `loadPending()` returns `[]`; `cleanupStale()`/`scheduleFollowUp()` then call `savePending` and wipe the key. The already-scheduled 30-minute local notifications still fire, but `pendingFollowUpIfDue()` finds nothing, so tapping the 'How's your anxiety?' banner is a dead-end with no follow-up prompt and no error — the exact decode-to-empty-without-migration pattern.  

**Verification:** finder P3, 1/3 verify lenses confirmed, lens votes [P3, P3, P3].  

**Disposition:** fixed (#164)

### F-087 · P3 · plausible · test-gap · trends-tests

**Anchor:** `AnxietyWatchTests/TrendsDateFilteringTests.swift:swiftDataFilterCorrectCount`  

**Summary:** TrendsDateFilteringTests derives both its fixtures and its cutoff from independent unpinned `.now` reads, so a midnight boundary crossing mid-test breaks the fixed-count assertion.  

**Failure scenario:** In `swiftDataFilterCorrectCount`, ten snapshots are created inside a loop via `makeSnapshot(daysAgo:)` (each reads `Calendar.current.date(byAdding:.day,value:-day,to:.now)` then HealthSnapshot normalizes to startOfDay), and `computeStartDate(daysBack:7)` reads `.now` again for `startOfDay(now-7d)`. If the process crosses local midnight between the loop's `.now` reads and computeStartDate's `.now`, `startDate` advances one calendar day relative to the fixtures, so the day-7 boundary snapshot falls below the cutoff and `results.count` becomes 7 instead of the asserted 8 — an intermittent CI failure with no code change.  

**Verification:** finder P3, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#171)

### F-088 · P3 · plausible · test-gap · server-tests

**Anchor:** `server/tests/test_server.py:test_admin_login`  

**Summary:** test_server.py mutates process-global os.environ['ADMIN_PASSWORD'] and os.environ['SECRET_KEY'] by direct assignment with no teardown, leaking credential env state into every subsequent test in the session.  

**Failure scenario:** Admin/ResMed tests do `os.environ["ADMIN_PASSWORD"] = "testpass"` and `os.environ["SECRET_KEY"] = "test-secret-key"` (lines ~1159-1228) with no restore, unlike sibling files (test_conflicts/test_profiles/test_analysis) that use monkeypatch.setenv (auto-restored). After these run, both vars stay set for the rest of the pytest session. The autouse `_clean_tables` fixture truncates the DB but never touches os.environ. Any future test that asserts unconfigured behavior — e.g. 'admin login is rejected when ADMIN_PASSWORD is unset' (admin.py login returns invalid when `admin_password` is empty) — would falsely pass depending on test order, masking a real regression.  

**Verification:** finder P3, 0/0 verify lenses confirmed, lens votes: none captured (verify cut off by session limit).  

**Disposition:** fixed (#171)

### F-089 · P0 · confirmed · render · reports-nav · _added post-audit during Batch A review_

**Anchor:** `AnxietyWatch/Views/Reports/ExportView.swift:ExportView`  

**Summary:** ExportView declares five unbounded @Query properties (entries, doses, snapshots, CPAP sessions, lab results) and is pushed from SettingsView's "Export Data" row via a closure-form NavigationLink, with neither Equatable conformance nor `.equatable()` at the call site — the same NavigationLink+@Query render-pitfall family as F-001-F-005.  

**Failure scenario:** While ExportView is pushed, any write to one of its five queried tables (a background HealthKit mirror pass, a sync, a CPAP import) re-executes SettingsView's body; SwiftUI cannot dedupe the reconstructed destination struct, restarts the push transition, and on iOS 26 cascades into the documented ~30 Hz render loop / CA::Layer::layout_is_active use-after-free (render pitfall #2).  

**Verification:** not part of the Phase 2 audit sweep — discovered by the `swift-pre-pr-reviewer` pass during Batch A implementation and confirmed by inspection (identical structural shape to the seven audited instances fixed alongside it).  

**Disposition:** fixed (#157)

### F-090 · P2 · plausible · accuracy · sync-rr-archive · _added post-audit during Batch B review_

**Anchor:** `AnxietyWatch/Services/PolarHRMService.swift:finalizeOffline`  

**Summary:** `finalizeOffline` runs `recorder.finalize(at:)` synchronously (sets `endTime`) but dispatches `archive.finalize()` — the RR-interval file flush — on a detached background Task. `RRArchiveWriter` buffers up to 64 KB (~1.5-2.5 h of RR data) before an implicit flush, and `uploadPendingRRArchives` gates only on `session.endTime != nil` (the F-014 guard) with no check that the flush completed.  

**Failure scenario:** A sync fires immediately after Stop: `endTime` is already non-nil but the detached flush hasn't run, so `uploadPendingRRArchives` reads the file missing its final buffered chunk, uploads it, and stamps `rrArchiveUploadedAt` — the skip guard never re-examines a stamped session, so the server permanently keeps a truncated archive. Low probability in practice (a few-KB local flush usually beats a network round trip) but there is no ordering guarantee — the same race family as the F-013 staleness fix, one layer down (binary archive vs. JSON row).  

**Verification:** surfaced by the `medical-data-accuracy-reviewer` pass on the Batch B staleness-guard fix (b119cf8); pre-existing behavior introduced with the F-014 gate (e410ccf), not a regression from the guard work. Not adversarially verified — plausible.  

**Fix sketch:** have `finalizeOffline` await the archive flush before `endTime` becomes visible to the sync path, or record a distinct "archive fully flushed" marker that `uploadPendingRRArchives` checks instead of `endTime`.  

**Disposition:** fixed (#173)

### F-091 · P2 · plausible · accuracy · server-correlations · _added post-audit during Batch F work_

**Anchor:** `server/correlations.py:36`  

**Summary:** The correlation engine joins `anxiety_entries` to `health_snapshots` via `a.timestamp::date = h.date`; the cast uses the DB session timezone (UTC in deployment), so an entry logged 9 PM Pacific is bucketed to the NEXT calendar day's snapshot. Same UTC-vs-Pacific day-bucketing family as F-029, one layer down: the pre-computed `correlations` table (which also feeds the analysis prompt context) systematically mis-pairs evening subjective entries with the wrong night's physiology.  

**Failure scenario:** Every anxiety entry logged after 4/5 PM Pacific (a common logging time — evenings are when symptoms peak) lands in the next day's correlation bucket. Evening-anxiety-vs-that-night's-sleep correlations are computed against the wrong night, diluting or inverting real physiological correlations that the admin UI and Claude analysis then present as computed fact.  

**Verification:** surfaced by the F-029 fix pass (same-pattern sweep); not adversarially verified — plausible. Fix shape: `(a.timestamp AT TIME ZONE 'America/Los_Angeles')::date = h.date` (two sites, lines ~36 and ~135), plus regression tests; changes stored correlation results, so re-run the engine after deploy.  

**Disposition:** fixed (#161)

### F-092 · P2 · plausible · accuracy · spo2-provenance · _added post-audit during Batch F review_

**Anchor:** `AnxietyWatch/Services/SnapshotAggregator.swift:applyOvernightSpO2Precedence`  

**Summary:** With F-023 fixed (sparse preferred coverage keeps HK-direct T90/desats), a night can legitimately present spo2Avg/spo2NadirOvernight computed from a handful of preferred-oximeter samples alongside T90/desat counts computed from the broader HK-direct sample set — two provenance bases in one apparent overnight profile, undisclosed on LastNightCard, CPAPDetailView, and the clinician PDF.  

**Failure scenario:** EMAY connects briefly (nadir from 5 samples) while the Watch spot-checks all night (T90/desats from the mixed HK set). A clinician reading the PDF has no way to know the nadir and the T90 describe different sample populations. Not wrong per-field — each is computed against its own sufficiency gate — but an undisclosed mixed-source combination in a clinical surface.  

**Verification:** surfaced by the medical-data-accuracy-reviewer pass on Batch F; plausible. Fix sketch: record the SpO2 source basis on HealthSnapshot (schema addition the LastNightCard source-chip comment already anticipates) and annotate the rendered surfaces when nadir and T90 bases diverge; alternatively gate the avg/nadir override on the same sufficiency check as T90 (weigh against reintroducing the Watch-artifact-nadir problem the preferred-wins rule exists to prevent).  

**Disposition:** approved (queued for Batch L — post-audit follow-ups; verify mechanism first)

### F-093 · P2 · plausible · accuracy · polar-hrv-freqdomain · _added post-audit during Batch F review_

**Anchor:** `AnxietyWatch/Services/HRVSessionRecorder.swift:tick`  

**Summary:** F-026 fixed artifact splicing for RMSSD/pNN50, but the frequency-domain path still receives the spliced filtered array: `HRVCalculator.resampleRRIntervals` builds its tachogram from cumulative sums of consecutive elements, so an excised interior artifact fabricates a gap-spanning pseudo-interval at the seam, distorting LF/HF band powers and the LF/HF ratio.  

**Failure scenario:** A window with interior artifacts produces HRVReading.lfPower/hfPower/lfHfRatio computed over a compressed, spliced tachogram; these feed LFHFAggregator and the Trends LF/HF charts. Proper fix likely resamples from actual sample timestamps rather than cumulative RR sums — a deeper change than the time-domain fix, hence split out.  

**Verification:** anticipated during the F-026 fix and confirmed by the medical-data-accuracy-reviewer pass on Batch F; plausible.  

**Disposition:** approved (queued for Batch L — post-audit follow-ups; verify mechanism first)

### F-094 · P3 · confirmed · bug · restore-from-server · _added post-audit during Batch C work_

**Anchor:** `AnxietyWatch/Services/RestoreFromServer.swift:importCPAPSessions`  

**Summary:** With F-068 fixed (server stores NULL AHI for EDF-only nights instead of a fabricated 0.0), `/api/data/cpap_sessions` exports `"ahi": null` for those rows. `importCPAPSessions` requires `row["ahi"] as? Double`, so the cast fails and the session is silently skipped — an EDF-only night's leak/usage data never restores onto a new device.  

**Failure scenario:** Fresh install + Restore From Server: every EDF-only cpap_sessions row is dropped without a log line; the restored history has holes exactly where only detail EDF data existed. No crash and no fabricated zero (strictly better than pre-F-068), but silently incomplete.  

**Verification:** identified during the F-068 consumer audit (Batch C); confirmed by inspection of the guard. Fix requires making `CPAPSession.ahi` optional (SwiftData schema change) or a documented sentinel + display handling — pairs naturally with the CPAPDetailView/pressureMin precedent from F-007.  

**Disposition:** approved (queued for Batch L — post-audit follow-ups; confirmed bug)

### F-095 · P3 · plausible · accuracy · reports-pdf · _added post-audit during Batch K review_

**Anchor:** `AnxietyWatch/Views/Reports/ExportView.swift:generatePDF`  

**Summary:** `generatePDF` filters `allSnapshots` to the selected report range and passes only that array to `ReportGenerator`, whose HRV section then computes its "30-day baseline" from that array. For a report range shorter than 30 days (a common "since my last visit" 1–2 week report) the baseline is drawn from fewer samples than the "30-day" label claims, or omitted entirely below the 14-sample minimum.  

**Failure scenario:** A 2-week report prints "30-day baseline: X ms" computed from ~14 days of data — a mislabeled statistic in the clinician PDF. Fails safe (omits rather than fabricates) below the sample floor, so not a wrong-status bug, but the label overstates the window. Pre-existing (the pre-F-043 `.now`-anchored call had the same array scoping); surfaced by both Batch K pre-PR reviewers.  

**Fix sketch:** pass the full snapshot history to `ReportGenerator` and let it filter to the range only for the period-summary sections, while computing the baseline over a true 30-day window ending at `rangeEnd`. Touches ReportGenerator's parameter contract, hence deferred from Batch K.  

**Verification:** flagged by swift-pre-pr-reviewer and medical-data-accuracy-reviewer on Batch K; plausible.  

**Disposition:** fixed (#176)

### F-096 · P3 · plausible · efficiency · watch-connectivity · _added post-audit during Batch K review_

**Anchor:** `AnxietyWatch/Services/PhoneConnectivityManager.swift:session(_:didReceive:)`  

**Summary:** The phone-side receive path builds each incoming watch `HRVReading` with `syncedToServer = false` via the `#Unique(\.id)` upsert, so any WCSession redelivery of an already-synced, unchanged row re-dirties it and causes a redundant server re-upload. Batch K's watch-side `transferredToPhone` flag stops routine re-sends, but WCSession can still redeliver across a watch relaunch mid-transfer.  

**Failure scenario:** Watch relaunches between `transferFile` and `didFinish`; WCSession redelivers the (already-ingested) batch; the phone upsert flips `syncedToServer` back to false for unchanged rows → they re-upload to the server on the next sync. Bounded and rare (not the every-60s storm F-018 fixed), efficiency-only.  

**Fix sketch:** on the phone receive path, preserve `syncedToServer` when the incoming row is field-identical to the stored one (the same "only re-dirty on real change" pattern used in HealthDataCoordinator's mirror pass).  

**Verification:** flagged by swift-pre-pr-reviewer on Batch K; plausible.  

**Disposition:** fixed (#176)

## Deferred backlog

_Populated at wrap-up (Phase 8) from `deferred` entries above._
