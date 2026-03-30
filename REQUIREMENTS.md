# Anxiety Watch — Requirements & Specification

## Purpose

A personal iOS + watchOS app for tracking anxiety through a combination of subjective journaling and objective physiological data from multiple sources. The app correlates these data streams to surface patterns, predict anxiety episodes, and generate clinical reports for psychiatric care.

This app started as a personal tool and is now open-source. It is not a commercial product — there are no App Store plans, no subscriptions, no telemetry. It is designed to be built from source via Xcode and adapted to each user's own devices and data sources.

---

## Target Devices & Platform

- **iPhone**: Primary interface for journaling, medication logging, data review, and reports
- **Apple Watch Series 8** (GPS + Cellular, watchOS 10+): Companion app for quick journal entries, real-time HRV display, and complication for current anxiety-relevant metrics
- **iOS 17+ / watchOS 10+**: Minimum deployment targets (enables SwiftData, latest HealthKit APIs)
- **Swift / SwiftUI**: Primary language and UI framework
- **SwiftData**: Local persistence (preferred over Core Data for new projects targeting iOS 17+)

---

## Data Sources — Prioritized

### Tier 1: HealthKit + Core Motion (build first, no new hardware)

All of these are read from HealthKit or Core Motion. Implement as a single `HealthKitManager` actor class that requests authorization for all types and provides a unified async query interface.

| # | Data Source | HealthKit Identifier / API | Why It Matters for Anxiety |
|---|-----------|---------------------------|---------------------------|
| 1 | **Heart Rate Variability (HRV)** | `HKQuantityTypeIdentifier.heartRateVariabilitySDNN` | Best single physiological biomarker of autonomic nervous system state. Low HRV = sympathetic dominance = anxiety. Track personal baseline and deviations. |
| 2 | **Resting Heart Rate** | `HKQuantityTypeIdentifier.restingHeartRate` | Elevated RHR over days/weeks is a reliable chronic stress signal. |
| 3 | **Sleep Staging & Duration** | `HKCategoryTypeIdentifier.sleepAnalysis` (includes `.asleepREM`, `.asleepDeep`, `.asleepCore`, `.awake`) | Poor sleep is both cause and effect of anxiety. Track architecture changes. |
| 4 | **Skin Temperature** | `HKQuantityTypeIdentifier.appleSleepingWristTemperature` | Stress causes measurable thermoregulatory changes. Apple Watch Series 8 measures this during sleep. |
| 5 | **Respiratory Rate** | `HKQuantityTypeIdentifier.respiratoryRate` | Elevated respiratory rate at rest = sympathetic activation. Measured during sleep by Watch. |
| 6 | **Blood Oxygen (SpO2)** | `HKQuantityTypeIdentifier.oxygenSaturation` | Context for overnight respiratory quality. Anxiety-driven hyperventilation affects O2/CO2 balance. |
| 7 | **Activity / Steps** | `HKQuantityTypeIdentifier.stepCount`, `.activeEnergyBurned`, `.appleExerciseTime` | Exercise is a strong anxiety modulator. Track dose-response relationship. |
| 8 | **Environmental Sound** | `HKQuantityTypeIdentifier.environmentalAudioExposure` | Chronic noise exposure elevates cortisol. |
| 9 | **Barometric Pressure** | `CMAltimeter.startRelativeAltitudeUpdates()` (Core Motion, NOT HealthKit) | Some people are significantly pressure-sensitive. Trivial to add. |
| 10 | **Heart Rate (raw)** | `HKQuantityTypeIdentifier.heartRate` | Momentary spikes during anxiety episodes; useful for real-time correlation with journal entries. |

### Tier 1 (cont): App-native data (build first, no external dependencies)

| # | Data Source | Storage | Why It Matters |
|---|-----------|---------|---------------|
| 11 | **Anxiety Journal** | SwiftData | Timestamped free-text notes with 1-10 severity rating. Optional tags (situation, location, trigger). This is what makes objective data interpretable. |
| 12 | **Medication Log** | SwiftData | Drug name, dose, time taken. Enables correlation of dose timing with physiological signals. Creates useful clinical records. |

### Tier 2: New hardware, moderate integration (build soon)

| # | Data Source | Integration Path | Cost | Notes |
|---|-----------|-----------------|------|-------|
| 13 | **Blood Pressure (manual)** | Omron Evolv smart cuff → Omron app → HealthKit (`HKQuantityTypeIdentifier.bloodPressureSystolic`, `.bloodPressureDiastolic`) | ~$80 | Spot-check BP a few times daily. Syncs through HealthKit like Tier 1 data. Buy from Amazon/Best Buy. |
| 14 | **CPAP Data (AirSense 11)** | SD card → custom parser (SQLite/EDF files, reverse-engineered by OSCAR community) OR ResMed cloud via unofficial `myAir-resmed` Python API | $0 ($10-15 for SD card reader) | AHI, leak rates, pressure data, usage hours. High-leak or high-AHI nights explain next-day anxiety. Most "custom" integration piece. |

### Tier 3: V2 additions, high signal but higher cost/friction

| # | Data Source | Integration Path | Cost | Notes |
|---|-----------|-----------------|------|-------|
| 15 | **Blood Pressure (continuous)** | Hilo Band → likely HealthKit or Hilo API | ~$280 + possible subscription | Cuffless, up to 50 passive readings/day including sleep. FDA-cleared, launching in US 2026. Game-changer for anxiety tracking. Requires monthly calibration with included cuff. |
| 16 | **Continuous Glucose** | Dexcom G7 or Libre 3 → Apple HealthKit (`HKQuantityTypeIdentifier.bloodGlucose`) | ~$75-150/mo (insurance) or ~$200/mo (Levels) | Disambiguates anxiety symptoms from blood sugar events. Requires prescription (PCP or Levels service). |
| 17 | **Oura Ring Gen 3** | Oura app → HealthKit (most metrics) + Oura REST API (temperature deviation, readiness score) | ~$300 + $6/mo | Supplemental HRV/sleep/temperature. Finger-based HRV has less motion artifact than wrist. Lower priority since Series 8 covers most of this. |

### Tier 4: Deprioritized

| # | Data Source | Why Deprioritized |
|---|-----------|------------------|
| 18 | **EDA / Galvanic Skin Response** | No good HealthKit-compatible consumer device. Fitbit Sense 2 requires Fitbit Web API. Skip until better options exist. |
| 19 | **Air Quality Sensors** | Lower direct anxiety signal. REST API integration, not HealthKit. Punt to future version. |

---

## Data Model

### Core Entities (SwiftData)

```
AnxietyEntry
  - id: UUID
  - timestamp: Date
  - severity: Int (1-10)
  - notes: String
  - tags: [String] (optional, e.g. "work", "social", "health", "trigger:caffeine")
  - location: CLLocationCoordinate2D? (optional, for pattern detection)

MedicationDose
  - id: UUID
  - timestamp: Date
  - medicationName: String
  - doseMg: Double
  - notes: String?

MedicationDefinition
  - id: UUID
  - name: String
  - defaultDoseMg: Double
  - category: String (e.g. "benzodiazepine", "SSRI", "supplement")
  - isActive: Bool

CPAPSession
  - id: UUID
  - date: Date
  - ahi: Double
  - totalUsageMinutes: Int
  - leakRate95th: Double (L/min)
  - pressureMin: Double
  - pressureMax: Double
  - pressureMean: Double
  - obstructiveEvents: Int
  - centralEvents: Int
  - hypopneaEvents: Int
  - importSource: String ("sd_card" or "resmed_cloud")

BarometricReading
  - id: UUID
  - timestamp: Date
  - pressureKPa: Double
  - relativeAltitudeM: Double

HealthSnapshot
  // Periodic aggregation of HealthKit data for efficient querying
  - id: UUID
  - date: Date
  - hrvAvg: Double? (ms, SDNN)
  - hrvMin: Double?
  - restingHR: Double? (bpm)
  - sleepDurationMin: Int?
  - sleepDeepMin: Int?
  - sleepREMMin: Int?
  - sleepCoreMin: Int?
  - sleepAwakeMin: Int?
  - skinTempDeviation: Double? (°C from baseline)
  - respiratoryRate: Double? (breaths/min)
  - spo2Avg: Double? (%)
  - steps: Int?
  - activeCalories: Double?
  - exerciseMinutes: Int?
  - environmentalSoundAvg: Double? (dBa)
  - bpSystolic: Double? (mmHg, if available)
  - bpDiastolic: Double? (mmHg, if available)
  - bloodGlucoseAvg: Double? (mg/dL, if available)
```

### Design Notes

- **HealthSnapshot** is a daily aggregation table. HealthKit is the source of truth for raw samples; the snapshot exists for efficient trending, correlation queries, and data export. Rebuild from HealthKit if needed.
- **AnxietyEntry** and **MedicationDose** are the subjective/manual data the user creates.
- **CPAPSession** is imported data from the AirSense 11 (not from HealthKit).
- **BarometricReading** is stored locally since Core Motion barometric data is not persisted by the system.

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                    SwiftUI Views                 │
│  (Journal, Meds, Dashboard, Trends, Reports)    │
└──────────────┬──────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────┐
│              View Models / Services              │
│  - JournalService                                │
│  - MedicationService                             │
│  - DashboardService (correlation engine)         │
│  - ReportGenerator                               │
│  - SyncService (future server sync)              │
└──────────────┬──────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────┐
│              Data Layer                          │
│  ┌────────────────┐  ┌────────────────────────┐  │
│  │ HealthKitManager│  │ SwiftData ModelContext  │  │
│  │ (actor)         │  │ (journal, meds, CPAP,  │  │
│  │                 │  │  snapshots, barometric) │  │
│  └────────────────┘  └────────────────────────┘  │
│  ┌────────────────┐  ┌────────────────────────┐  │
│  │ CPAPImporter    │  │ BarometerService       │  │
│  │ (SD card parser)│  │ (CMAltimeter)          │  │
│  └────────────────┘  └────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### Key Architectural Decisions

1. **HealthKitManager as a Swift actor** — thread-safe, single point of authorization and queries. All HealthKit reads go through this.
2. **SwiftData for local persistence** — simpler than Core Data for iOS 17+ targets. Journal entries, medication logs, CPAP data, and daily health snapshots.
3. **Daily HealthSnapshot aggregation** — a background task that runs daily (or on app foreground) to pull the last 24h of HealthKit data into a local summary row. This avoids hammering HealthKit for trend queries.
4. **CPAP data as a separate import flow** — not HealthKit. Either SD card file import via Files app / share sheet, or background fetch from ResMed cloud.
5. **Barometric data captured in-app** — Core Motion's `CMAltimeter` gives relative pressure. Store readings periodically when app is active or via background tasks.
6. **Export-first design** — all data should be exportable as JSON and/or CSV from day one. This enables server sync, Claude analysis, and clinical report generation.

---

## UI Screens (High Level)

### iPhone App

1. **Dashboard** — today's summary: current HRV vs baseline, last anxiety rating, medication status, sleep score from last night, CPAP AHI. Traffic-light indicators for metrics significantly above/below personal baseline.

2. **Journal** — chronological list of anxiety entries. Tap to add new entry (severity slider, free text, optional tags). Show nearby HealthKit data points alongside each entry (e.g., "HR was 92bpm, HRV was 28ms when you logged this").

3. **Medications** — list of active medications with quick-log buttons. History view showing all doses. Configurable reminders.

4. **Trends** — multi-day charts for all tracked metrics. Overlay anxiety severity on physiological data to visualize correlations. Selectable time ranges (7d, 30d, 90d). Highlight periods where metrics deviate significantly from baseline.

5. **CPAP Import** — import screen for SD card data or cloud sync status.

6. **Reports** — generate clinical reports (PDF or structured text) summarizing a date range. Include all metrics, medication adherence, anxiety trends, CPAP compliance, and notable correlations. Designed to hand to a psychiatrist.

7. **Export** — export all data as JSON/CSV for external analysis. Share sheet integration.

8. **Settings** — HealthKit permissions, medication definitions, notification preferences, server sync config (future), personal baseline configuration.

### watchOS Companion App

1. **Quick Log** — anxiety severity (1-10) with optional voice note. Digital Crown for severity selection.
2. **Current Stats** — glanceable current HRV, HR, and last anxiety rating.
3. **Complication** — shows current HRV or last anxiety rating on watch face.

---

## Correlation & Pattern Detection

The core value of this app is correlating subjective anxiety with objective signals. Key patterns to detect:

1. **HRV baseline deviation** — rolling 30-day average; flag when 3-day rolling average drops below 1 standard deviation from baseline.
2. **Pre-anxiety physiological signals** — did HR spike or HRV drop in the 30-60 minutes before a journal entry? Build a lookback window around each entry.
3. **Sleep → next-day anxiety** — correlate previous night's sleep quality (duration, deep sleep %, HRV overnight, CPAP AHI) with next-day anxiety severity.
4. **Medication timing effects** — how do physiological signals change in the hours following a medication dose?
5. **Exercise → anxiety** — does exercise on a given day correlate with lower anxiety severity that day or the next?
6. **Barometric pressure → anxiety** — correlate pressure changes with anxiety entries.
7. **Compound patterns** — e.g., "nights with AHI > 5 AND sleep < 6 hours predict next-day anxiety severity > 7 with 80% accuracy."

### Implementation Approach

Start simple: daily summary statistics and visual overlay charts. More sophisticated correlation (rolling windows, predictive models) can come in V2. The export-to-Claude workflow handles complex analysis in the near term.

---

## Data Export & External Integration

### Export Formats

1. **JSON export** — complete data dump of all entities, suitable for Claude analysis. Include metadata (date range, data source versions).
2. **CSV export** — one CSV per entity type, for spreadsheet analysis.
3. **Clinical report (PDF)** — formatted summary for psychiatrist visits. Includes:
   - Date range and data completeness metrics
   - Anxiety severity trend chart
   - Medication adherence summary
   - Sleep quality summary (Watch + CPAP)
   - HRV trend with baseline reference
   - Blood pressure summary (when available)
   - Notable correlations or patterns observed
   - Raw data appendix (optional)

### Server Sync (Future — V2+)

- Sync all data to a personal server for viewing on larger displays
- Architecture: REST API endpoint on user's server, app pushes daily snapshots + journal entries
- Auth: API key or mutual TLS (personal server, no need for OAuth complexity)
- Consider: CloudKit as an intermediate option (Apple's own sync, no server needed, works across devices)

### Claude Analysis Workflow

Export JSON → upload to Claude → ask for pattern analysis, anomaly detection, and clinical summary generation. This is a manual workflow for V1; could be automated via API in V2.

---

## Build Order

### Phase 1: Foundation (Week 1-2)
- [ ] Create Xcode project (iOS + watchOS targets)
- [ ] Set up SwiftData models for all entities
- [ ] Implement HealthKitManager actor with authorization and query methods for all Tier 1 types
- [ ] Basic journal entry UI (add/edit/list)
- [ ] Basic medication logging UI (define meds, log doses)
- [ ] Daily HealthSnapshot aggregation task

### Phase 2: Dashboard & Trends (Week 2-3)
- [ ] Dashboard view with today's key metrics
- [ ] Trend charts (Swift Charts) for HRV, HR, sleep, anxiety severity
- [ ] Overlay anxiety entries on physiological charts
- [ ] HRV baseline deviation detection

### Phase 3: CPAP & Barometric (Week 3-4)
- [ ] Barometric pressure capture via CMAltimeter
- [ ] CPAP SD card data parser (based on OSCAR format documentation)
- [ ] CPAP import UI
- [ ] Integrate CPAP data into dashboard and trends

### Phase 4: Watch App (Week 4-5)
- [ ] watchOS companion app with quick anxiety log
- [ ] Watch complication for HRV or anxiety rating
- [ ] Sync journal entries between Watch and iPhone via WatchConnectivity

### Phase 5: Reports & Export (Week 5-6)
- [ ] JSON/CSV data export
- [ ] Clinical report PDF generation
- [ ] Share sheet integration for exports

### Phase 6: Blood Pressure Integration (when hardware arrives)
- [ ] HealthKit BP data integration (works automatically if Omron writes to HealthKit)
- [ ] BP trends in dashboard and charts
- [ ] Hilo Band integration (when available — likely HealthKit, possibly API)

### Phase 7: Server Sync & Advanced Analysis (V2)
- [ ] Server sync architecture
- [ ] CloudKit or REST API sync
- [ ] Automated Claude analysis pipeline
- [ ] Advanced correlation engine
- [ ] CGM integration (if pursued)

---

## Non-Functional Requirements

- **Privacy**: All data stored locally on device. No third-party analytics or telemetry. Server sync only to user's own infrastructure.
- **Performance**: HealthKit queries should be async and not block UI. Daily snapshot aggregation handles the heavy lifting.
- **Reliability**: Background refresh for HealthKit data and barometric readings. Graceful handling of missing data (not all metrics available every day).
- **Accessibility**: Standard iOS accessibility support (VoiceOver, Dynamic Type).
- **Data integrity**: Never delete HealthKit data. Local SwiftData is the app's data; HealthKit is Apple's. Export early and often.
