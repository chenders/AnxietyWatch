# Apple Watch Ultra 3 Upgrade — Design Spec

## Context

Chris upgraded from Apple Watch Series 8 to Apple Watch Ultra 3 on 2026-04-20. The Ultra 3's 42-hour battery, S10 chip, dual-frequency GPS, and watchOS 26 APIs unlock a class of features that were impractical on Series 8. This spec defines the full scope of Ultra 3-specific enhancements to AnxietyWatch.

**Paired iPhone:** iPhone 14 ("Theodore") — does NOT support Apple Intelligence / FoundationModels framework. All LLM work goes through the existing server-side Claude API integration.

**Approach:** Two parallel implementation tracks that converge once sufficient labeled data accumulates for ML features.

| Track 1 (Foundation) | Track 2 (UX + Intelligence) |
|---|---|
| 1. 24/7 sensor capture session | 1. Action Button ControlWidget + voice journaling |
| 2. Derived metrics (HRV, tremor, breathing) | 2. HKStateOfMind + watchOS 26 medication data |
| 3. Panic episode classifier | 3. Smart place tracking on iPhone |
| 4. Predictive next-day anxiety | 4. Per-dose ECG capture protocol |
| | 5. Watch complications + Smart Stack |
| | 6. Clinical narratives + medication efficacy (server-side Claude) |
| | 7. Enhanced data export |

---

## Track 1: Sensor Capture Foundation

### T1.1 — 24/7 Sensor Capture Session

**Purpose:** An invisible background `HKWorkoutSession(.mindAndBody, .indoor)` that keeps watch sensors in high-rate mode for continuous anxiety-relevant data collection.

**New file:** `AnxietyWatch Watch App/SensorCaptureSession.swift`

**Actor: `SensorCaptureSession`**

Responsibilities:
- Start and maintain an `HKWorkoutSession` with `HKWorkoutConfiguration(activityType: .mindAndBody, locationType: .indoor)`
- Create an `HKLiveWorkoutBuilder` with `HKLiveWorkoutDataSource` to receive HR, HRV, respiratory rate deltas
- Start `CMBatchedSensorManager` accelerometer and gyroscope streams (200Hz / 800Hz respectively)
- Chain `WKExtendedRuntimeSession(.mindfulness)` calls for indefinite runtime outside active workout contexts
- Handle lifecycle interruptions gracefully (user starts a real workout, Low Power Mode, charging)

**Data streams produced:**
- 1Hz heart rate (vs ~5min passive sampling)
- Beat-to-beat RR intervals via `HKHeartbeatSeriesQuery` during the active session
- 200Hz 3-axis accelerometer via `CMBatchedSensorManager`
- 800Hz 3-axis gyroscope via `CMBatchedSensorManager`

**Lifecycle:**
- Starts automatically when watch app launches or via background refresh
- Persists across app suspension via `WKExtendedRuntimeSession` hand-off chaining (start next session from `extendedRuntimeSessionWillExpire:`)
- When user starts a separate workout (e.g., walking): pause sensor capture session, resume when their workout ends
- On Low Power Mode activation: gracefully stop, resume when LPM exits
- On charging: continue running (Ultra 3 supports charging + session concurrently)
- Discard the workout or save with a distinguishing metadata tag so it doesn't pollute Fitness rings/history

**Storage strategy:**
- Raw 200Hz accelerometer = ~50MB/day quantized to Int16. Too much for watch long-term.
- **10-second FFT spectrograms** instead of raw samples — captures tremor (4-12Hz) and breathing (0.2-0.4Hz) bands in ~4KB per bin. 30 days ~ 1GB, tractable.
- 1Hz HR and per-minute HRV vectors are tiny — store directly in SwiftData.
- Rolling 48-hour raw accelerometer buffer on watch for real-time panic detection inference. Older data is spectrogram-only.
- Sync spectrograms + HRV data to iPhone via `WCSession.transferFile()`, then to server via `SyncService`.

**New SwiftData models:**

```swift
@Model class SensorSession {
    var id: UUID
    var startTime: Date
    var endTime: Date?
    var interruptions: [SensorInterruption]  // Codable struct array
    var batteryAtStart: Int
    var batteryAtEnd: Int?
}

struct SensorInterruption: Codable {
    var reason: String  // "userWorkout", "lowPowerMode", "charging"
    var startTime: Date
    var endTime: Date?
}

@Model class HRVReading {
    var id: UUID
    var timestamp: Date
    var rmssd: Double
    var sdnn: Double
    var pnn50: Double
    var lfPower: Double
    var hfPower: Double
    var lfHfRatio: Double
    var sensorSession: SensorSession?
}

@Model class AccelSpectrogram {
    var id: UUID
    var timestamp: Date        // start of 10-second window
    var tremorBandPower: Double   // 4-12Hz spectral power
    var breathingBandPower: Double // 0.2-0.4Hz spectral power
    var activityLevel: Double     // overall RMS acceleration
    var sensorSession: SensorSession?
}

@Model class DerivedBreathingRate {
    var id: UUID
    var timestamp: Date
    var breathsPerMinute: Double
    var confidence: Double  // quality of the estimate
    var source: String      // "accelerometer" or "healthkit_sleep"
    var sensorSession: SensorSession?
}
```

**Impact on existing code:**
- `HealthKitManager` — add query methods for `HKHeartbeatSeriesQuery` and ECG voltage readings
- `WatchConnectivityManager` — add `transferFile()` methods for sensor data batches
- `PhoneConnectivityManager` — receive and persist sensor data to SwiftData
- `HealthDataCoordinator` — incorporate derived metrics (HRV averages, tremor levels, breathing rates) into daily `HealthSnapshot`

---

### T1.2 — Derived Metrics

**Purpose:** Transform raw sensor streams into anxiety-relevant derived metrics.

Computed from the sensor capture session data, either on-watch in real-time or on iPhone during sync:

**Full-spectrum HRV (per-minute):**
- RMSSD, SDNN, pNN50 from beat-to-beat RR intervals
- LF power (0.04-0.15Hz), HF power (0.15-0.4Hz), LF/HF ratio via Welch's method on the RR series
- Stored in `HRVReading` model

**Tremor analysis (per 10-second window):**
- Spectral power in the 4-12Hz band from accelerometer FFT
- Known elevated in acute anxiety, medication side effects (SSRI activation, stimulants), and hypoglycemia
- Stored in `AccelSpectrogram` model

**Breathing rate (per-minute):**
- Extracted from the 0.2-0.4Hz band of the accelerometer signal (wrist motion from breathing)
- Independent of HealthKit's sleep-only `respiratoryRate`
- Hyperventilation detection: flag when derived rate >22/min sustained for 60 seconds → haptic alert on watch
- Stored in `DerivedBreathingRate` model

**Fidget/agitation index (per-minute):**
- RMS acceleration magnitude in the 0.5-4Hz band (below tremor, above breathing)
- Captures restlessness, fidgeting, pacing
- Stored as a field on a per-minute summary or in `AccelSpectrogram`

**Nocturnal HR dip (per night):**
- Ratio of sleeping average HR to waking average HR
- Impaired dipping (<10% drop) is a replicated chronic anxiety marker
- Computed from 1Hz HR stream during detected sleep periods
- Stored in `HealthSnapshot` as a new field

---

### T1.3 — Panic Episode Classifier

**Purpose:** An on-device CoreML model trained on the user's own labeled episodes that detects panic episodes in real-time.

**Training data pipeline:**
- Every `AnxietyEntry` with severity >= 8, logged during an active sensor capture session, becomes a candidate "panic" label
- The 30-minute physiological window around each entry provides features:
  - HR mean, max, slope (from 1Hz stream)
  - RMSSD, SDNN, LF/HF (from beat-to-beat HRV)
  - Tremor band power (4-12Hz from accelerometer)
  - Breathing band power (0.2-0.4Hz from accelerometer)
  - Overall activity level
  - Wrist temperature delta (from HealthKit, if available)
  - Time-of-day, recent medication timing, hours since last PRN dose
- Entries with severity <= 3 during active sensor coverage become "baseline" labels
- Severity 4-7 entries with sensor coverage become "elevated-arousal" labels

**Minimum data threshold:** ~20 labeled panic episodes with full sensor coverage before first training attempt. The app tracks this count and surfaces it ("12/20 labeled episodes collected — 8 more needed for classifier training").

**Training (iPhone-side):**
- `BGProcessingTask` — runs nightly when charging
- `CreateML` `MLBoostedTreeClassifier` trained on `EpisodeFeatureVector` corpus
- Output classes: `{panic, elevated-arousal, baseline}` with confidence scores
- Trained model (`.mlmodel`) transferred to watch via `WCSession.transferFile()`
- Retrained weekly as new labeled data accumulates

**Watch-side inference:**
- During active sensor capture session, runs classification every 30 seconds against the rolling feature window
- Detection threshold: `episodeLikelihood > 0.7` sustained for 2 consecutive evaluations (60 seconds)
- On detection:
  - Gentle haptic alert
  - Prompt: "Elevated arousal detected — is this a panic episode?" → Yes / No / Dismiss
  - If confirmed: logged as `DetectedEpisode`, merged with journal if user creates entry within 60 minutes
  - If dismissed: negative label fed back to improve training
- Confidence threshold adjustable by user (default 0.7, can lower for more sensitivity or raise for fewer alerts)

**Presentation principle:** Restrained, not alarming. "Elevated arousal detected" not "PANIC DETECTED." The user confirms or dismisses; the system doesn't diagnose.

**New SwiftData models:**

```swift
@Model class EpisodeFeatureVector {
    var id: UUID
    var timestamp: Date
    var label: String           // "panic", "elevated-arousal", "baseline"
    var userConfirmed: Bool
    var hrMean: Double
    var hrMax: Double
    var hrSlope: Double
    var rmssd: Double
    var sdnn: Double
    var lfHfRatio: Double
    var tremorBandPower: Double
    var breathingBandPower: Double
    var activityLevel: Double
    var wristTempDelta: Double?
    var timeOfDay: Double       // fractional hours (e.g. 14.5 = 2:30pm)
    var hoursSinceLastPRN: Double?
    var sensorSessionID: UUID?
}

@Model class DetectedEpisode {
    var id: UUID
    var timestamp: Date
    var modelVersion: String
    var confidence: Double
    var predictedLabel: String
    var userConfirmedLabel: String?  // nil = not yet responded
    var linkedEntryID: UUID?        // linked AnxietyEntry if user logs within 60min
    var featureVector: EpisodeFeatureVector?
}
```

---

### T1.4 — Predictive Next-Day Anxiety

**Purpose:** Morning briefing predicting today's anxiety severity range and high-episode probability.

**Implementation:** Server-side Claude analysis (since iPhone 14 can't run FoundationModels).

**Nightly pipeline:**
- After daily sync, server compiles last 7 days of features:
  - Daily anxiety severity averages and peaks
  - HRV trend (improving / declining / stable relative to baseline)
  - Sleep quality metrics (duration, efficiency, stage distribution, nocturnal HR dip)
  - Medication timing patterns
  - Breathing rate trends, tremor levels
  - Detected episodes count
  - Place-anxiety associations from recent entries
- Sends structured JSON to Claude API: "Given these 7-day physiological and behavioral patterns, estimate tomorrow's anxiety severity range and probability of a high-severity episode, with reasoning"
- Returns: `{predictedSeverityRange: [low, high], highEpisodeProbability: Float, reasoning: String, topContributingFactors: [String]}`
- Synced to iPhone, surfaces on dashboard at wake time
- Also available via Smart Stack widget relevance (morning routine context)

**Long-term improvement path:** Once prediction-vs-actual pairs accumulate (60+ days), train a proper `MLBoostedTreeRegressor` on-device as a replacement for the Claude-based heuristic approach.

---

## Track 2: UX + Intelligence

### T2.1 — Action Button ControlWidget + Voice Journaling

**Action Button ControlWidget:**

**New files:**
- `AnxietyWatch Watch App/LogAnxietyIntent.swift` — `AppIntent` implementation
- `AnxietyWatchWidgets/AnxietyLogControl.swift` — `ControlWidget` configuration

**Flow:**
1. User presses Action Button (configured in watchOS Settings to AnxietyWatch's control)
2. `AppIntentControlConfiguration` triggers `LogAnxietyIntent`
3. Watch app opens to a capture flow: severity picker (existing 1-10 grid) → optional voice note → confirm
4. Writes `AnxietyEntry` via existing WatchConnectivity path
5. Writes `HKStateOfMind` to HealthKit (see T2.2)
6. If sensor capture session is active, marks the timestamp for episode feature extraction

The same `ControlWidget` appears in Control Center and Smart Stack.

**Voice Journaling:**

After severity selection, a "Speak" button starts audio capture:
- `AVAudioEngine` on watch, 16kHz mono, 30-60 seconds max
- On-watch `SFSpeechRecognizer` (`.supportsOnDeviceRecognition`) transcribes in <500ms
- Transcript shown immediately as the entry's `notes` field — user can accept or re-record
- Raw audio saved temporarily on watch, transferred to iPhone via `WCSession.transferFile()`
- User can skip voice entirely — severity-only or type a note, same as today

**Vocal Biomarker Pipeline (iPhone-side):**

Runs as `BGProcessingTask` overnight or on-demand when phone receives an audio file.

Extracts per-entry:
- **F0 (fundamental frequency):** mean, variability, range via autocorrelation on `AVAudioPCMBuffer`. Elevated F0 variability is a replicated stress/anxiety marker.
- **Jitter:** cycle-to-cycle F0 perturbation. Increased in high arousal.
- **Shimmer:** cycle-to-cycle amplitude perturbation. Increased in high arousal.
- **Speech rate:** words per minute from transcript length / audio duration.
- **Pause distribution:** silence segmentation via energy thresholding — count, mean duration, longest pause. Teferra et al. 2023 found pause patterns distinguished generalized anxiety from baseline.
- **Sentiment:** `NLTagger(.sentimentScore)` on transcript text.
- **Topic tags:** Server-side Claude call — "extract 1-3 topic tags from this journal entry" with structured JSON response.

Raw audio deleted from iPhone after processing. Only numeric biomarkers + transcript are retained and synced.

**New SwiftData model:**

```swift
@Model class VoiceEntryAnalysis {
    var id: UUID
    var entryID: UUID           // linked AnxietyEntry
    var f0Mean: Double
    var f0Variability: Double
    var f0Range: Double
    var jitter: Double
    var shimmer: Double
    var speechRateWPM: Double
    var pauseCount: Int
    var pauseMeanDuration: Double
    var pauseMaxDuration: Double
    var sentimentScore: Double   // -1.0 to +1.0
    var topicTags: [String]     // JSON-encoded array
    var processedAt: Date
}
```

**Privacy:** Raw audio never leaves the devices, never syncs to server. Only extracted numeric biomarkers and transcript sync.

---

### T2.2 — HKStateOfMind + watchOS 26 Medication Data

**HKStateOfMind Integration:**

Every `AnxietyEntry` (watch or phone) also writes an `HKStateOfMind` sample to HealthKit:
- **Valence:** linear mapping from severity. 1 → +1.0, 5 → 0.0, 10 → -1.0
- **Arousal:** defaults to severity-derived estimate (low severity → low arousal, high severity → high arousal). Simplified mapping — capturing arousal independently is a future enhancement.
- **Labels:** `.anxious` always. Additional labels mapped from tags or voice topic tags: `.worried`, `.stressed`, `.scared`, `.calm`, `.frustrated`
- **Associations:** mapped from topic tags: `.work`, `.family`, `.health`, `.selfCare`

Reading back: `HKStateOfMind` samples from Apple's own Health app mood prompts also get imported, so mood data logged via Apple's UI flows into AnxietyWatch.

**HKScoredAssessment (GAD-7 / PHQ-9):**
- Write structured assessment results to HealthKit when assessment data exists
- Plumbing in place for future in-app assessment feature — not a priority for initial build

**watchOS 26 Medication Data (`HKUserAnnotatedMedicationType`):**

- Read medication schedules, adherence, and side-effect logs from Apple's Medications app via `requestPerObjectReadAuthorization(for:)`
- Import medications not already tracked in AnxietyWatch
- Reconciliation logic: if a medication exists in both systems, prefer AnxietyWatch's `MedicationDose` data (richer metadata: `isPRN`, `triggerDose`). Flag discrepancies — missed dose in Apple Medications that shows as taken in AnxietyWatch (or vice versa).
- Side-effect entries from Apple Medications imported and correlated with anxiety severity.

**Impact on existing code:**
- `HealthKitManager` — add write methods for `HKStateOfMind` and `HKScoredAssessment`, read methods for `HKUserAnnotatedMedicationType`
- `AnxietyEntry` creation flow (both watch and phone paths) — post-save step writes `HKStateOfMind`
- `HealthDataCoordinator` — add observer for medication data changes from Apple Health
- New reconciliation logic (could live in `HealthKitManager` or a dedicated service)

---

### T2.3 — Smart Place Tracking

**Architecture:** Runs entirely on iPhone. No watch GPS.

**Location monitoring:**
- `CLLocationManager` with `startMonitoringSignificantLocationChanges()` — wakes app on ~500m moves using cell tower triangulation. Near-zero battery impact.
- On each significant change, reverse-geocode via `CLGeocoder` and store location context.

**Place learning:**

```swift
@Model class FrequentPlace {
    var id: UUID
    var name: String            // user-editable, auto-suggested from reverse geocoding
    var latitude: Double
    var longitude: Double
    var radius: Double          // meters, default 50
    var visitCount: Int
    var firstSeen: Date
    var lastSeen: Date
    var meanAnxietySeverity: Double
    var entryCount: Int         // number of anxiety entries at this place
}
```

- After 30 days of data, cluster visited coordinates using 50m distance threshold
- Any cluster with >= 5 visits becomes a `FrequentPlace`
- Auto-suggest names from reverse geocoding ("Near 100 Main St") — user renames to "Work", "Therapist", etc. via settings
- Register each `FrequentPlace` as a `CLCircularRegion` for geofence monitoring (iOS limit: 20 simultaneous regions — prioritize by visit frequency)

**Anxiety tagging:**
- When an `AnxietyEntry` is created, check: is the phone inside a known `FrequentPlace` geofence?
- If yes, link the entry to that place via a new optional `placeID` relationship on `AnxietyEntry`
- Over time, each place accumulates an anxiety profile: mean severity, severity distribution, time-of-day patterns

**Surfacing:**
- Trends view gets a "Places" section: per-place average severity, sorted by highest anxiety
- Exportable in standard data export
- Server-side Claude analysis includes place patterns in weekly clinical narratives

**What this does NOT do:**
- No continuous GPS tracking or breadcrumb trails
- No map UI (could add later — the value is in correlation data, not visualization)

---

### T2.4 — Per-Dose ECG Capture Protocol

**Flow:**
1. When a PRN `MedicationDose` is logged (watch or phone), schedule three ECG reminders:
   - **Pre-dose baseline:** immediately ("Take an ECG now before your dose kicks in")
   - **Peak response:** dose + 30 minutes
   - **Post-response:** dose + 2 hours
2. Each reminder is a local notification. Apple doesn't allow launching the ECG app programmatically — the prompt guides the user to open it.
3. User opens ECG app, holds finger on Digital Crown for 30 seconds.

**Data capture:**
- New ECG samples appear in HealthKit as `HKElectrocardiogram`
- `HealthKitManager` observes new ECGs via `HKObserverQuery`
- When a new ECG arrives within the time window of a scheduled capture (+/- 10 minutes), link it to the dose event

**Analysis (iPhone-side):**

Read raw voltage measurements at 512Hz via `HKElectrocardiogramQuery`:
- **Full HRV suite:** RMSSD, SDNN, pNN50 from R-R intervals extracted from voltage trace
- **LF/HF power ratio:** via Welch's method on the R-R series — sympathovagal balance
- **QT interval estimate:** R-peak to T-wave-end detection. Relevant for psychiatric medications affecting cardiac conduction.
- **R-wave morphology:** amplitude, width — autonomic state markers
- Compare pre-dose vs post-dose metrics to quantify autonomic medication response

**New SwiftData models:**

```swift
@Model class ECGCaptureProtocol {
    var id: UUID
    var doseID: UUID
    var scheduledPreTime: Date
    var scheduledPeakTime: Date     // dose + 30min
    var scheduledPostTime: Date     // dose + 2hr
    var actualPreECGID: UUID?       // linked HKElectrocardiogram sample UUID
    var actualPeakECGID: UUID?
    var actualPostECGID: UUID?
    var status: String              // "pending", "partial", "complete", "expired"
}

@Model class ECGAnalysis {
    var id: UUID
    var ecgHealthKitID: UUID        // HKElectrocardiogram sample identifier
    var captureRole: String         // "pre", "peak", "post"
    var protocolID: UUID?           // linked ECGCaptureProtocol
    var rmssd: Double
    var sdnn: Double
    var pnn50: Double
    var lfPower: Double
    var hfPower: Double
    var lfHfRatio: Double
    var qtInterval: Double?         // nullable — not always extractable
    var rWaveAmplitude: Double
    var rWaveWidth: Double
    var analyzedAt: Date
}
```

**Graceful degradation:**
- If user captures 1 of 3 — still useful, less comparative data
- ECG arriving outside any protocol window — analyzed and stored, just not linked to a dose
- Protocol status: pending → partial → complete/expired (expire after 3 hours)
- No nagging — each reminder fires once

---

### T2.5 — Watch Complications + Smart Stack

**Complications (WidgetKit):**

Built within the existing `AnxietyWatchWidgets/` target.

- **Current state** (all complication families): Last logged severity with color indicator (existing 1-10 color scale) + time since last entry
- **Today's trend** (graphicRectangular): Mini sparkline of today's severity entries
- **HRV status** (all families): Current HRV relative to personal baseline — displayed as context ("Below baseline", "Normal", "Elevated"), NOT raw numbers

Tap-through opens the watch app to the relevant view.

**Smart Stack relevance (`WidgetRelevanceEntity`):**
- Morning routine: show predicted severity + overnight sleep quality summary
- After detected elevated arousal: show quick-log prompt
- Around therapy schedule (Mon 2:30pm, Thu 1pm, Fri 2pm): show weekly summary card

**Design principle:** Complications show context, not raw numbers. "Below your baseline" not "RMSSD: 23ms". Detailed numbers available in tap-through views, trends, and exports — contexts for reflection, not in-the-moment.

---

### T2.6 — Server-Side Intelligence (Claude Integration)

**Weekly Clinical Narrative Drafts:**

Triggered by server-side scheduled task (Sunday night Pacific) or on-demand from app.

Server compiles past week's data:
- All `AnxietyEntry` records with severity, notes, transcripts, topic tags, place associations
- Daily `HealthSnapshot` summaries (HRV trends, sleep, HR, BP)
- `MedicationDose` records with timing
- `VoiceEntryAnalysis` biomarker trends
- `DetectedEpisode` records (once classifier is active)
- `ECGAnalysis` results linked to medication doses

Sends structured JSON to Claude API. Returns structured output:
```json
{
    "weekSummary": "string",
    "medicationObservations": ["string"],
    "sleepAnxietyCorrelation": "string",
    "notableEpisodes": ["string"],
    "questionsForProvider": ["string"]
}
```

Stored in server database as `clinical_narrative_drafts` table. Synced to iPhone for review. Exportable as a section in PDF clinical reports via `ReportGenerator`.

**Medication Efficacy Modeling:**

Monthly server-side batch job. For each medication, Claude analyzes:
- Pre/post dose anxiety severity changes across all doses
- ECG-derived autonomic response data (RMSSD change, LF/HF shift)
- Time-to-relief distributions
- Tolerance trends: efficacy change over cumulative exposure

Output per medication: effect size estimate, confidence narrative, tolerance slope observation, cross-medication comparison.

Stored in server database as `medication_efficacy_reports` table. Synced to app.

**New server database tables:**
- `clinical_narrative_drafts` — id, week_start, week_end, summary JSON, created_at, reviewed (bool)
- `medication_efficacy_reports` — id, medication_name, report_json, period_start, period_end, created_at

**Impact on existing code:**
- `SyncService` — new endpoints for narrative drafts, efficacy reports, and predictions
- Server `admin.py` / routes — extend existing Claude analysis infrastructure with new analysis types
- `ReportGenerator` — incorporate narrative drafts into PDF exports

---

### T2.7 — Enhanced Data Export

**Current state:** `DataExporter` service exists with JSON/CSV export.

**Additions:**
- Sensor data export: HRV readings, accelerometer spectrograms, derived breathing rates
- Vocal biomarker export: `VoiceEntryAnalysis` data as CSV columns alongside linked anxiety entries
- ECG analysis export: per-capture HRV suite, QT intervals, linked to medication dose context
- Place correlation export: per-place anxiety averages, visit counts, severity distributions
- Clinical narrative export: weekly drafts as standalone documents or embedded in PDF reports

**Export formats:**
- **CSV** — one file per data type, for Python/R/Excel analysis
- **JSON** — structured export of everything for programmatic consumption
- **PDF** — extend `ReportGenerator` with new data types (HRV trends, medication efficacy summaries, narrative drafts, place correlations)

Skip Parquet/HDF5/JSON-LD — over-engineered for n=1. Easy to add later if needed.

**"Analyze with Claude" button:**
- Dedicated action in export view
- Compiles structured summary of last 90 days
- Sends to sync server's Claude analysis endpoint
- Returns results in-app

**Impact on existing code:**
- `DataExporter` — extended with new export methods per data type
- `ReportGenerator` — extended with new PDF sections
- Export view UI — updated with new options

---

## New SwiftData Models Summary

| Model | Section | Purpose |
|---|---|---|
| `SensorSession` | T1.1 | Tracks capture session lifecycle |
| `HRVReading` | T1.1 | Per-minute full-spectrum HRV vectors |
| `AccelSpectrogram` | T1.1 | 10-second FFT bins (tremor, breathing, activity) |
| `DerivedBreathingRate` | T1.1 | Per-minute breathing rate from accelerometer |
| `EpisodeFeatureVector` | T1.3 | Labeled feature vectors for classifier training |
| `DetectedEpisode` | T1.3 | Model-detected episodes with user confirmation |
| `VoiceEntryAnalysis` | T2.1 | Vocal biomarkers per voice journal entry |
| `FrequentPlace` | T2.3 | Learned places with anxiety profiles |
| `ECGCaptureProtocol` | T2.4 | Per-dose ECG reminder schedule and completion |
| `ECGAnalysis` | T2.4 | Derived metrics from raw ECG voltage |

**Modifications to existing models:**
- `AnxietyEntry` — add optional `placeID` relationship to `FrequentPlace`
- `HealthSnapshot` — add `nocturnalHRDip` field

## New Server Database Tables

| Table | Section | Purpose |
|---|---|---|
| `clinical_narrative_drafts` | T2.6 | Weekly Claude-generated progress notes |
| `medication_efficacy_reports` | T2.6 | Monthly per-medication efficacy analysis |

## Existing Services Modified

| Service | Changes |
|---|---|
| `HealthKitManager` | Beat-to-beat HRV queries, ECG voltage queries, HKStateOfMind writes, HKScoredAssessment writes, HKUserAnnotatedMedicationType reads |
| `HealthDataCoordinator` | Incorporate derived sensor metrics into HealthSnapshot, observe medication data changes, observe new ECG samples |
| `WatchConnectivityManager` | Transfer sensor data files, transfer trained ML model, transfer audio files |
| `PhoneConnectivityManager` | Receive and persist sensor data, receive audio for biomarker processing |
| `SyncService` | New endpoints for narratives, efficacy reports, predictions |
| `DataExporter` | Export methods for all new data types |
| `ReportGenerator` | New PDF sections for narratives, efficacy, HRV trends, places |
| `BaselineCalculator` | Incorporate HRV and sensor-derived baselines |

## Presentation Philosophy

Capture = aggressive. Surface everything the sensors can provide.

In-the-moment presentation = restrained. Complications and alerts show context ("below baseline", "elevated arousal detected"), not raw numbers. No big red digits during panic.

Reflection/clinical presentation = full fidelity. Trends view, exports, PDF reports, and clinical narratives show all the numbers, charts, confidence intervals, and statistical analysis.
