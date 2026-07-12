# What Anxiety Watch Tracks

Anxiety Watch combines subjective journaling with objective physiological data to build a complete picture of your anxiety. This document covers every data source and feature in detail.

---

## Your Experience

- **Anxiety journal** -- severity (1-10), free-text notes, and tags. Timestamped entries that anchor all the objective data to how you actually feel.
- **Medication doses** -- one-tap logging with a novel **dose-triggered anxiety prompt**: rate your anxiety when you take a medication, then again 30 minutes later via notification. Over time, this builds paired before/after efficacy data -- something closer to a personal [N-of-1 trial](https://en.wikipedia.org/wiki/N-of-1_trial) than anything a consumer app typically produces.
- **watchOS Quick Log** -- color-coded tappable severity grid with haptic confirmation. When your hands are shaking and your thinking is clouded, you can still log how you feel in under five seconds.
- **Random check-ins** -- configurable push notifications at random times during waking hours catch unprompted mood data points that voluntary journaling misses.
- **Earworm capture** -- tag journal entries with the song stuck in your head. The sync server proxies Genius and Musixmatch lookups for lyrics so a song you log on the phone arrives with its metadata already attached.

---

## Your Physiology

The app reads **20+ data types from HealthKit** via an [actor-isolated](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Actors) manager with anchored queries and background delivery.

The most important of these is **heart rate variability (HRV)** -- the variation in time between consecutive heartbeats, measured in milliseconds. HRV is the strongest single peripheral biomarker of your autonomic nervous system's state. When HRV drops, your body is shifting into fight-or-flight mode -- often before you consciously feel anxious. When it rises, your parasympathetic system (rest-and-digest) is in control. The app tracks *your* personal HRV baseline over 30 days and alerts you when your recent average drops below it, turning an invisible autonomic shift into something you can see and act on.

| Category | What's Tracked |
|----------|---------------|
| **Heart & autonomic** | Heart rate variability (HRV), resting heart rate, raw heart rate, VO2 max, walking heart rate |
| **Sleep** | Total duration, stages (REM, deep, core, awake), skin temperature deviation, respiratory rate |
| **Blood oxygen** | SpO2 averages |
| **Activity** | Steps, active calories, exercise minutes |
| **Blood pressure** | Systolic/diastolic (via compatible cuff -> HealthKit) |
| **Environment** | Barometric pressure (Core Motion), environmental sound levels |
| **Other** | Walking steadiness, gait metrics, atrial fibrillation burden |

Daily **HealthSnapshot** aggregation rolls these into efficient local trending and export. Personal **rolling baselines** compare you to yourself -- not population norms. The dashboard shows alerts when your HRV drops below your own 30-day baseline, not when it crosses an arbitrary threshold.

**Multi-source provenance.** HealthKit samples are mirrored locally with their full source attribution (`sourceBundleID`, `sourceName`, device model) so a SpO2 reading from a dedicated overnight oximeter isn't treated the same as a one-off wrist-sensor reading from the Apple Watch. This drives both display ("EMAY SleepO2" vs "Apple Watch Ultra 3") and clinical-stat reliability classification.

**Apple Watch Ultra 3 sensor capture.** Foundation in place for the broader sensor stack the Ultra 3 exposes — the actor-isolated HealthKit pipeline reads the full set of types currently available; new ones plug in by adding the identifier and an aggregator entry.

**Privacy by design:** All health data stays on your device. HealthKit is the source of truth -- the app reads your health data but never writes to it (except the planned Apple Health State of Mind integration). There are no third-party SDKs, no analytics, no tracking pixels, no data collection of any kind. The optional sync server is self-hosted on infrastructure you own and control. Data only leaves your device when you explicitly trigger an export, generate a clinical report, or sync to your own server.

---

## Your Polar H10 Chest Strap

For nights where you want HRV at much higher fidelity than the Apple Watch provides, the app pairs directly with a [Polar H10](https://www.polar.com/en/sensors/h10-heart-rate-sensor) chest strap over Bluetooth Low Energy and computes HRV from every individual heartbeat.

- Beat-to-beat **RR intervals** stream at ~1 Hz via the standard `0x180D` Heart Rate service.
- The app buffers RR intervals into 60-second windows and writes time-domain (RMSSD, SDNN, pNN50) and frequency-domain (LF power, HF power, LF/HF ratio) measures per minute.
- Recording continues with the screen off via `bluetooth-central` background mode and `CBCentralManager` state restoration -- iOS can wake the app after a memory-pressure termination and resume the same session.
- The raw RR stream is archived on disk per session and uploaded to the sync server so future HRV measures can be re-derived without re-pairing the device.

Polar HRV is surfaced as a second line on the HRV trend chart (alongside Apple Watch), as Polar-only RMSSD and HF Power cards, and as a per-session LF/HF detail view that breaks down a single night minute by minute.

See [POLAR_H10.md](POLAR_H10.md) for pairing, the full data flow, server schema, and known limits.

---

## Your Sleep Apnea Treatment

- **CPAP import** from AirSense 11 SD card data -- AHI, leak rates, usage hours, pressure stats, event breakdowns (obstructive, central, hypopnea)
- **OSCAR Summary CSV auto-detection** on the iOS side handles both single-night and multi-session-night exports
- **Server-side EDF leak-rate parsing** -- the sync server reads ResMed's EDF waveform files from the SD card and extracts 95th-percentile leak rates that the on-device CSV doesn't contain
- **EMAY pulse-oximeter import** via the iOS share sheet -- overnight SpO2 + pulse rate CSVs land as per-sample `QuantityHealthSample` rows tagged with the EMAY bundle ID so they dedupe cleanly against HealthKit. See [EMAY_OXIMETER.md](EMAY_OXIMETER.md).
- Connects sleep apnea treatment quality to anxiety outcomes -- a correlation that is [well-established in research](https://pubmed.ncbi.nlm.nih.gov/25766719/) but almost never quantified for a specific patient

---

## Your Medications

- **Prescription management** -- manual prescription records (medication, dose, Rx number, pharmacy, fill date, notes)
- **Pharmacy search** via MapKit with call tracking and logging
- **OCR label scanning** -- point your camera at a pill bottle and the Vision framework extracts Rx number, medication name, and dosage
- **Manual prescription entry** -- with OCR label-scan prefill

---

## Your Reports

- **Clinical PDF reports** -- multi-page summaries structured for psychiatric appointments: anxiety severity distribution, medication adherence per drug, sleep quality with stage breakdowns, HRV trends with baseline status, CPAP compliance, blood pressure, and lab results with reference ranges
- **JSON/CSV export** -- complete data dump across 10+ entity types for external analysis (pairs well with [Claude](https://claude.ai) for AI-assisted pattern detection)
- **Server sync** -- self-hosted Flask + PostgreSQL backend mirrors your data for web access. Schema changes go through Alembic migrations rather than ad-hoc DDL, and a manual `verify-schema` GitHub Actions workflow prints the deployed Alembic revision and spot-checks a few critical tables and columns (e.g. `quantity_health_samples`, `sleep_stage_events`, `health_snapshots.data_quality`) so deployment drift is visible at a glance — it doesn't (yet) hard-assert that the database is at the migration head.
- **Optional server-side AI analysis** -- an admin-only page on your self-hosted sync server can call the Claude API against a chosen date range and return plain-language summaries (with a detailed-toggle for the underlying numbers), data-quality flags, and conflict analysis. Opt-in per request, mobile-responsive admin UI, and requires *your* own Anthropic API key set in the server's environment. Your synced data already lives on your own server; no data is forwarded to Anthropic until *you* press the button.
