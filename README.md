<div align="center">

# Anxiety Watch

*Your experience and your physiology, together.*

[![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2018%20%7C%20watchOS%2011-007AFF)](https://developer.apple.com/ios/)
[![Status](https://img.shields.io/badge/status-active%20development-yellow)]()
[![Privacy](https://img.shields.io/badge/privacy-your%20data%20stays%20on%20your%20device-brightgreen)]()
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

You slept five hours. Your CPAP leaked. Your heart rate variability dropped below your personal baseline overnight. You already feel the anxiety creeping in before your feet hit the floor — but this morning, you know *why*.

Anxiety Watch is an iOS and watchOS app that tracks anxiety from both sides: the severity you report and the physiology your Apple Watch records. It logs your medication doses and measures whether they actually helped. It imports your CPAP data and connects sleep apnea treatment to next-day anxiety. Over weeks and months, it builds a picture of your anxiety that no single journal entry or doctor's appointment could capture alone — and generates clinical reports that turn a fifteen-minute psychiatrist visit into a data-informed conversation.

The result is not a wall of numbers. It is your own data, interpreted through your own history, making the invisible patterns visible. Anxiety is less frightening when it is less mysterious.

> **Your data never leaves your devices unless you tell it to.** There is no cloud service, no account to create, no telemetry, no analytics. Health data stays in HealthKit on your iPhone. App data stays in local SwiftData storage. The only times data goes anywhere are when *you* explicitly choose to: export a report, sync to *your own* self-hosted server, share a clinical PDF with *your* doctor, or trigger the opt-in Claude analysis on your own sync server (which forwards the selected date range to Anthropic; disabled unless you set `ANTHROPIC_API_KEY` on the server). You are in complete control.

> **This project is under active development.** The data collection layer is thorough — 25+ HealthKit data types with multi-source provenance, medication tracking with efficacy measurement, OSCAR CSV import with server-side EDF leak parsing, EMAY overnight pulse-oximeter import, Polar H10 chest-strap HRV at beat-to-beat fidelity, pharmacy benefit (CapRx) integration, clinical reports, an Alembic-migrated sync server, and a growing test suite. The first piece of the intelligence layer is live: a physiological correlation engine that identifies which health metrics most influence your anxiety, plus an opt-in server-side path that can call Claude against a chosen date range from an admin page on your own sync server. Compound triggers, proactive insights, and morning briefings are where the project is headed next.

<div align="center">
  <img src="docs/screenshots/future-dashboard.png" width="200" alt="Dashboard mockup with Today's Summary card, Log button, breathing pacer, and grouped metric sections" />
  &nbsp;&nbsp;
  <img src="docs/screenshots/future-insights.png" width="200" alt="Insights mockup showing sleep-anxiety correlation, compound triggers, exercise effect, and medication efficacy" />
  &nbsp;&nbsp;
  <img src="docs/screenshots/future-trends.png" width="200" alt="Trends mockup with weekly summary stats, HRV chart with medication dose markers, and dose-response visualization" />
</div>

<div align="center"><sub><em>Design mockups of the intelligence layer the project is building toward — illustrative data, not real health records.</em></sub></div>

---

## Why This Exists

The fifteen-minute psychiatrist appointment is one of medicine's cruelest constraints. *How have you been sleeping? Is the medication helping? Are things getting better or worse?* You answer with impressions colored by however you feel right now. Your doctor adjusts treatment based on those impressions. Everyone does their best with fragments of memory.

Anxiety Watch replaces impressions with evidence. Not because data is more "true" than your experience — it isn't — but because your experience and your physiology together tell a fuller story than either one alone. When you walk into that appointment with a clinical summary showing that your PRN medication usage is up, its efficacy is down, and sleep quality is the strongest predictor of your next-day anxiety, the conversation changes. It becomes specific. It becomes actionable.

This started as a personal tool built by someone who lives with anxiety and panic disorder. It is becoming open-source because the approach — combining what you feel with what your body measures — could help others in the same situation. It is not a commercial product. There are no engagement metrics, no subscription, no telemetry. Every feature exists because a real person needed it.

### A note about self-monitoring

For some people, tracking health data can increase anxiety rather than reduce it. If monitoring your own physiological metrics makes you feel worse, this tool may not be right for you — and that is completely okay. Anxiety Watch is designed to show you what numbers *mean for you* (e.g., "18% below your baseline, consistent with post-bad-sleep patterns") rather than raw values that invite catastrophic interpretation. But self-monitoring is not for everyone, and this app is not a substitute for working with a mental health professional.

> **If you are in crisis:** Contact the [988 Suicide & Crisis Lifeline](https://988lifeline.org/) (call or text 988) or your local emergency services. This app is not a crisis intervention tool.

---

## What It Tracks

| Feature | What It Does |
|---------|-------------|
| **Anxiety journal** | Severity (1-10) via color-coded tappable circles, notes, tags, and an optional song — with an express mode that saves in a single tap. Timestamped entries anchor all physiological data |
| **Medication tracking** | Dose logging with 30-min before/after efficacy follow-up (a personal [N-of-1 trial](https://en.wikipedia.org/wiki/N-of-1_trial)) |
| **watchOS Quick Log** | Color-coded severity circles in a tappable grid — works during panic, under five seconds |
| **Random check-ins** | Configurable push notifications at random times during waking hours prompt you to log your mood — captures data points you'd otherwise miss |
| **Physiological insights** | Correlation engine that identifies which health metrics (HRV, sleep, steps, CPAP, barometric pressure) most influence your anxiety, with scatter plots and per-metric breakdowns |
| **HealthKit integration** | 25+ data types (HRV, sleep stages, heart rate, SpO2, activity, blood pressure, walking metrics, daylight exposure, physical effort, AFib burden, and more) with personal rolling baselines and per-sample source attribution |
| **Polar H10 chest strap** | Optional Bluetooth pairing for beat-to-beat HRV at much higher fidelity than the Apple Watch. Per-minute RMSSD/SDNN/pNN50 plus frequency-domain LF/HF, background recording, state restoration, raw RR-interval archive synced to the server. See [docs/POLAR_H10.md](docs/POLAR_H10.md) |
| **CPAP import** | AirSense 11 SD card — AHI, leak rates, usage hours via on-device OSCAR CSV auto-detection (single- and multi-session-night exports); self-hosted sync server parses EDF files for leak rate percentiles; CPAP metrics feed into daily health snapshots and the correlation engine |
| **Overnight pulse oximetry** | Share an [EMAY SleepO2](https://emayinc.com/) CSV into the app from the iOS share sheet — per-second SpO2 + pulse rate land as `QuantityHealthSample` rows that dedupe against HealthKit samples written under the matching bundle ID (one EMAY app-version case-sensitivity caveat documented in the per-feature doc). See [docs/EMAY_OXIMETER.md](docs/EMAY_OXIMETER.md) |
| **CNS-depression early-warning detection (in progress)** | An internal engine that scores SpO2, respiratory rate, heart rate, and HRV against your own rolling baselines to flag a trend toward dangerous CNS depression (opioid/benzodiazepine over-sedation). Phase 1 — baseline-relative severity scoring, cross-sensor fusion, and a hysteretic alert-tier state machine — is merged and unit-tested; there is no user-facing alarm yet (no klaxon, no dashboard indicator). It is designed as an **early-warning aid only** — never an overdose rescue or a medical device — runs entirely on-device, and will never place an automated emergency call |
| **Earworm capture** | Tag a journal entry with the song stuck in your head; the sync server proxies Genius and Musixmatch for lyrics and album art |
| **Prescription management** | Supply tracking, refill alerts, OCR label scanning, pharmacy search with call logging, CapRx pharmacy benefit claim import |
| **Clinical reports** | PDF summaries structured for psychiatric appointments — anxiety, meds, sleep, HRV, CPAP, labs |
| **Data export** | JSON/CSV across 10+ entity types, plus self-hosted Flask + PostgreSQL sync server (Alembic migrations, manual schema-verification workflow) |
| **Optional server-side AI** | Admin-only page on *your own* sync server can call Claude against a chosen date range for plain-language summaries, data-quality flags, and conflict analysis. Opt-in per request; requires your own Anthropic API key set in your server's environment |

All health data stays on your device. No cloud service, no third-party SDKs, no analytics, no telemetry. See [docs/FEATURES.md](docs/FEATURES.md) for the full breakdown of every data source, the HealthKit data types table, and how personal baselines work.

> **Verification needs hardware.** Several pieces of this stack can't be tested end-to-end in the iOS Simulator: Polar H10 pairing needs a real BLE peripheral (CoreBluetooth doesn't simulate), CPAP import needs an actual AirSense 11 SD card, EMAY import needs a SleepO2 device's CSV export, watch-side sensor capture needs a real Apple Watch that supports `CMBatchedSensorManager.isAccelerometerSupported` (tested on Ultra 3; not gated on that model specifically), and CapRx pharmacy-benefit sync needs a Walgreens account plus the headless-browser scrape path on the server. The simulator covers everything else.

---

## What Makes This Different

Most anxiety apps are journals. Some add meditation. A few track mood over time. None of them do this:

### Quantified medication efficacy

The dose-triggered anxiety prompt with 30-minute follow-up produces paired before/after measurements for every dose. Over weeks, this builds a personal efficacy curve per medication. When that curve flattens — tolerance — it becomes visible in the data before you or your clinician would notice through recall alone. No consumer anxiety app tracks this. Most clinical trials don't measure it at this frequency for an individual patient.

### Sleep-apnea-anxiety pipeline

CPAP data integrated with sleep quality metrics and next-day anxiety ratings. The CPAP importer auto-detects OSCAR Summary CSV exports, and the sync server parses EDF waveform files from the SD card to extract detailed leak rate percentiles. No anxiety app tracks CPAP compliance. No CPAP app tracks anxiety. For the millions of people who have both sleep apnea and an anxiety disorder, this connection has been invisible.

### Personal baselines over population norms

"Your HRV is 18% below your 30-day average" is actionable. "Your HRV is 34ms" is noise. The app computes your rolling personal baselines and flags *your* deviations from *your* normal.

### Frequency-domain HRV from a $90 chest strap

Apple Watch HRV is a sampled SDNN value: useful, but a closed pipeline that surfaces a handful of numbers per night. Pair an off-the-shelf Polar H10 and the app streams every individual heartbeat interval over Bluetooth, buffers them into 60-second windows, and writes per-minute time-domain *and* frequency-domain HRV — LF power, HF power, the LF/HF ratio — that the Apple Watch simply doesn't expose. Background-mode recording with state restoration means an overnight session survives the app being killed mid-night. The raw RR-interval stream is archived per session and uploaded to the sync server so future HRV measures can be re-derived without ever re-pairing the device.

### Designed for your worst moments

The watchOS Quick Log uses large, color-coded tappable circles because fine motor control is unreliable during panic — no scrolling, no precision, just tap the number that matches how you feel. "Last taken" timestamps prevent the terrifying uncertainty of double-dosing during acute anxiety. The future "This Too Shall Pass" view will show your own history of panic episodes resolving — evidence from your own life that it always ends.

### Export-first, not walled-garden

Every piece of data is exportable — JSON, CSV, or clinical PDF — from day one. The optional server-side Claude analysis path leverages the best available AI for pattern detection rather than baking a mediocre ML system into the app — and it only ever runs on *your* self-hosted server, against *your* data, when you explicitly press the button on an admin page that lives behind your own password.

---

## The Road Ahead

The data collection layer is solid, and the first piece of the intelligence layer is live — a physiological correlation engine that identifies which health metrics most influence your anxiety, with per-metric breakdowns and scatter plots. Random check-ins capture mood at unprompted moments, filling gaps that voluntary journaling misses. Next: compound trigger identification (when bad sleep *plus* high barometric pressure shift predicts a bad day), medication efficacy trend detection, and proactive morning briefings that demystify bad days before they spiral.

The mockups above show where this is headed — a dashboard that tells stories instead of dumping numbers, an intelligence layer that surfaces personal patterns, and trend charts with medication dose markers that make tolerance visible.

See [PROJECT_FUTURE_PLAN.md](PROJECT_FUTURE_PLAN.md) for the full phased roadmap, North Star vision, and current status by phase.

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                     SwiftUI Views                     │
│   Dashboard · Journal · Medications · Trends          │
│   (HRV / HR / RMSSD / HF / LF/HF detail / others)     │
│   Prescriptions · Pharmacy · CPAP · Lab Results       │
│   Songs · Reports · Settings (Polar pairing)          │
├──────────────────────────────────────────────────────┤
│                       Services                        │
│   HealthKitManager (actor) · HealthDataCoordinator    │
│   SnapshotAggregator · BaselineCalculator             │
│   PolarHRMService (BLE) · HRVSessionRecorder          │
│   RRIntervalBuffer · RRArchiveWriter · LFHFAggregator │
│   CPAPImporter · EMAYImporter · CSVImportRouter       │
│   ReportGenerator · DataExporter · SyncService        │
├─────────────────────┬────────────────────────────────┤
│      HealthKit      │       SwiftData (local)         │
│  25+ data types     │  Journal, meds, Rx, CPAP,       │
│  Actor-isolated     │  snapshots, per-sample          │
│  Anchored queries   │  HealthKit mirror w/ source     │
│  Background sync    │  attribution, barometric,       │
│  Multi-source prov. │  lab results, pharmacy, songs,  │
│                     │  SensorSession + HRVReading     │
├─────────────────────┼────────────────────────────────┤
│   Core Motion       │   Polar H10 (CoreBluetooth)     │
│   (barometer)       │   Background BLE, state restore │
├─────────────────────┴────────────────────────────────┤
│        Flask + PostgreSQL (self-hosted sync)          │
│   Alembic migrations · EDF leak parser · CapRx /      │
│   ResMed myAir clients · optional Claude analysis     │
└──────────────────────────────────────────────────────┘
    + watchOS companion (WatchConnectivity)
    + WidgetKit (lock screen: HRV, anxiety, RHR)
```

**Zero external Swift dependencies.** Built entirely on Apple frameworks across iOS, watchOS, WidgetKit, and test targets: HealthKit, SwiftData, Swift Charts, Vision, MapKit, WatchConnectivity, Core Motion, CoreBluetooth, CallKit, PDFKit. No SPM packages.

See [REQUIREMENTS.md](REQUIREMENTS.md) for the full data model and specification.

---

## For Developers

If you're browsing this codebase to learn from it, here are the parts worth studying:

- **Protocol-abstracted HealthKit at scale** — `HealthKitDataSource` protocol with `HealthKitManager` (actor) conformance handles 25+ data types with anchored object queries, background delivery, structured concurrency, and per-sample source attribution (`sourceBundleID` / `sourceName` / device). The protocol extraction makes every HealthKit-dependent service testable with a mock. Most open-source HealthKit examples demonstrate 2-3 types. This is a reference implementation for the real thing.
- **Background-mode CoreBluetooth with state restoration** — `PolarHRMService` is a long-lived `CBCentralManager` owner with a stable `restoreIdentifier`, a transient-state scan latch, and a recovery initializer on `HRVSessionRecorder` that re-binds to an open `SensorSession` after the app is killed mid-overnight. A bounded reconnect backoff (capped at a 10-minute grace period) absorbs rolling-over-in-bed disconnects without prematurely finalizing the session. Real-world reference for iOS BLE that has to survive sleep, memory pressure, and the Bluetooth radio cycling. See [docs/POLAR_H10.md](docs/POLAR_H10.md) for the full pipeline.
- **Share-sheet CSV dispatcher** — `CSVImportRouter` sniffs the first non-empty header line and routes to either `CPAPImporter` (OSCAR Summary single- or multi-night) or `EMAYImporter` (1 Hz overnight SpO2 + pulse rate). Imports run on a detached task to keep ~36k-row EMAY files from stuttering the UI. Simple, extensible pattern for accepting "files from anywhere on iOS" without polluting your services.
- **Dose-triggered notification follow-up** — `DoseAnxietyPromptView` + `DoseFollowUpManager`: schedules a `UNNotificationRequest` 30 minutes post-dose, captures the follow-up rating, pairs it with the pre-dose entry via a shared `MedicationDose` relationship, and cleans up stale follow-ups after 2 hours.
- **HealthSnapshot materialized view** — `SnapshotAggregator` queries HealthKit once per day and aggregates all tracked metrics into a single SwiftData record. Charts and exports read from this local model, not from HealthKit directly. Rebuildable from source if needed.
- **CPAP SD card parsing** — `CPAPImporter` auto-detects [OSCAR](https://www.sleepfiles.com/OSCAR/) Summary CSV exports on the iOS side, and the sync server includes an EDF parser (`edf_parser.py`) that extracts 95th-percentile leak rates from AirSense 11 waveform files. One of the few Swift/Python CPAP parsing implementations.
- **Vision OCR for prescription labels** — `PrescriptionLabelScanner` extracts Rx number, medication name, dosage, quantity, and refills from photographed pill bottles using regex patterns against `VNRecognizeTextRequest` output.
- **Personal baseline statistics** — `BaselineCalculator` computes rolling mean/stddev per metric with configurable windows, outlier trimming, and deviation detection. Minimum 14 samples, sample variance (N-1). Design principle: flag when *you* deviate from *your own* normal.
- **Extracted view model pattern** — `DashboardViewModel` shows how to pull business logic out of SwiftUI views into testable `@Observable` classes, with a thorough test suite covering sample loading, baseline computation, supply alerts, and trend calculation.
- **SwiftData across a non-trivial schema** — many related `@Model` classes covering journal entries, medications, prescriptions, CPAP, songs, per-sample HealthKit mirrors, sensor sessions, and per-minute HRV readings. Relationships, cascade deletes, query-driven views, compound-predicate gotchas (see `CLAUDE.md`'s iOS 26 SwiftData notes), and a per-record sync surface. Good reference for SwiftData beyond the single-model tutorials.
- **Full-stack sync** — `SyncService` (Swift actor) pushes to a Flask/PostgreSQL backend with API key auth, upsert logic across 10+ entity types, the Polar H10 RR-archive upload path, Alembic-managed schema migrations, and CapRx/Walgreens/ResMed myAir import pipelines.
- **Physiological correlation engine** — `PhysiologicalCorrelation` pairs daily health snapshots with anxiety entries to compute per-metric correlations, p-values, and "anxiety on abnormal vs. normal days" comparisons. A good example of turning health data into actionable insight without ML.
- **Test suite** — Swift Testing (`@Test`, `#expect`) with in-memory SwiftData containers, fixed reference dates, a model factory, and a `MockHealthKitDataSource` for deterministic HealthKit testing. Good reference for testing SwiftData services and HealthKit-dependent logic without mocking frameworks.

### Debug screenshot capture

In **debug builds only**, shake the device to save a full-length PNG of the current screen (chrome + unfurled scrollable content) to the Photos library. Useful for reviewing long views (the Dashboard chart stack, Trends, etc.) as a single image rather than a string of taped-together viewport screenshots. The unfurled content is captured by scrolling through the scrollview in viewport-sized steps and stitching the snapshots — lazy `List` / `LazyVStack` rows materialize as they enter the viewport, so they appear correctly in the final PNG. Implemented in `AnxietyWatch/Utilities/DebugScreenCapture.swift`; the file and the one-line `RecordingStatusPill` accessibility-identifier hook are both `#if DEBUG`-fenced so Release builds contain zero capture code (verified by `nm` on the Release binary). The two `NSPhotoLibrary*UsageDescription` strings in `Info.plist` ship in all builds — those are tiny static strings, not capture code, and the picker fallback string is independently needed by `PrescriptionScannerView` on Simulator.

**Cap:** Scrollviews with content taller than 10,000 pt are skipped (would risk OOM); the capture falls back to chrome-only with a log message.

**Keyboard caveat:** Shake events only reach the current first responder, so a focused `TextField` / `TextEditor` will swallow them. Tap outside the field to dismiss the keyboard, then shake. (The capture pipeline reclaims first-responder status on keyboard-hide and app-foreground, so this is only an issue while the keyboard is actually on screen.)

**Permission prompt:** The first shake prompts for Photos write access. If denied, re-prompt via Settings → AnxietyWatch → Photos.

Design spec: [`docs/superpowers/specs/2026-05-13-debug-screen-capture-design.md`](docs/superpowers/specs/2026-05-13-debug-screen-capture-design.md).

---

## Getting Started

Requires **Xcode 16+** with the iOS 18 and watchOS 11 SDKs (deployment targets are pinned in `Config/Project.xcconfig` and `Config/watchOS.xcconfig`). An Apple Watch with real HealthKit data is recommended; the BLE-paired Polar H10 features additionally need a real device.

```bash
# Build (generic destination — no hardcoded simulator name)
xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'

# Unit tests (Swift Testing framework, in-memory SwiftData containers)
xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests
```

See [SETUP_GUIDE.md](SETUP_GUIDE.md) for full environment setup (Apple Developer account, signing, device installation, watchOS, and sync server). The sync server has its own deployment doc at [docs/SERVER_SETUP.md](docs/SERVER_SETUP.md).

---

## Contributing

Anxiety Watch is a personal project that welcomes contributions. Response times may vary.

If you live with anxiety and this approach resonates with you, I'd especially value your perspective — through issues, discussions, or pull requests.

**Good first contributions:**
- **Tests** — service layer has good coverage; views and coordinators need more (Swift Testing framework, in-memory SwiftData containers)
- **SwiftUI `#Preview` blocks** — a few exist for the most-used views; most views still need them
- **Accessibility** — Dynamic Type support, VoiceOver grouping, contrast fixes
- **Server features** — Python/Flask, lower barrier if you're not a Swift developer
- **Bug reports and UI/UX suggestions** via [issues](../../issues)

**Before proposing features:** This project has an opinionated design philosophy — it is an anxiety tool, not a general health dashboard. Please read [PROJECT_FUTURE_PLAN.md](PROJECT_FUTURE_PLAN.md) (especially "The Central Tension") to understand what it is and isn't trying to be.

---

## Disclaimer

Anxiety Watch is a personal tracking and self-awareness tool. It is **not a medical device**, not FDA-cleared, and not intended to diagnose, treat, cure, or prevent any condition. Medication tracking is an aide-memoire, not a substitute for professional medication management. Physiological data from consumer wearables has accuracy limitations and should not be used as the sole basis for clinical decisions. Patterns identified by the app are observational — correlation is not causation. Always discuss findings with your healthcare provider.

---

## License

[MIT](LICENSE)

---

<div align="center">

*Built by someone with anxiety, for anyone who wants to understand theirs.*

</div>
