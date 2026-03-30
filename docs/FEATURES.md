# What Anxiety Watch Tracks

Anxiety Watch combines subjective journaling with objective physiological data to build a complete picture of your anxiety. This document covers every data source and feature in detail.

---

## Your Experience

- **Anxiety journal** -- severity (1-10), free-text notes, and tags. Timestamped entries that anchor all the objective data to how you actually feel.
- **Medication doses** -- one-tap logging with a novel **dose-triggered anxiety prompt**: rate your anxiety when you take a medication, then again 30 minutes later via notification. Over time, this builds paired before/after efficacy data -- something closer to a personal [N-of-1 trial](https://en.wikipedia.org/wiki/N-of-1_trial) than anything a consumer app typically produces.
- **watchOS Quick Log** -- Digital Crown severity selection with haptic confirmation. When your hands are shaking and your thinking is clouded, you can still log how you feel in under five seconds.

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

**Privacy by design:** All health data stays on your device. HealthKit is the source of truth -- the app reads your health data but never writes to it (except the planned Apple Health State of Mind integration). There are no third-party SDKs, no analytics, no tracking pixels, no data collection of any kind. The optional sync server is self-hosted on infrastructure you own and control. Data only leaves your device when you explicitly trigger an export, generate a clinical report, or sync to your own server.

---

## Your Sleep Apnea Treatment

- **CPAP import** from AirSense 11 SD card data -- AHI, leak rates, usage hours, pressure stats, event breakdowns (obstructive, central, hypopnea)
- Connects sleep apnea treatment quality to anxiety outcomes -- a correlation that is [well-established in research](https://pubmed.ncbi.nlm.nih.gov/25766719/) but almost never quantified for a specific patient

---

## Your Medications

- **Prescription management** -- supply tracking with days-remaining calculations, refill alerts, expiration monitoring
- **Pharmacy search** via MapKit with call tracking and logging
- **OCR label scanning** -- point your camera at a pill bottle and the Vision framework extracts Rx number, medication name, dosage, quantity, and refill count
- **CapRx claims import** -- automated prescription sync from pharmacy benefit data via the sync server

---

## Your Reports

- **Clinical PDF reports** -- multi-page summaries structured for psychiatric appointments: anxiety severity distribution, medication adherence per drug, sleep quality with stage breakdowns, HRV trends with baseline status, CPAP compliance, blood pressure, and lab results with reference ranges
- **JSON/CSV export** -- complete data dump across 10 entity types for external analysis (pairs well with [Claude](https://claude.ai) for AI-assisted pattern detection)
- **Server sync** -- self-hosted Flask + PostgreSQL backend mirrors your data for web access
