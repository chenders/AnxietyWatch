<div align="center">

# Anxiety Watch

*Your experience and your physiology, together.*

[![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%20%7C%20watchOS%2010-007AFF)](https://developer.apple.com/ios/)
[![Status](https://img.shields.io/badge/status-active%20development-yellow)]()
[![Privacy](https://img.shields.io/badge/privacy-your%20data%20stays%20on%20your%20device-brightgreen)]()
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

You slept five hours. Your CPAP leaked. Your heart rate variability dropped below your personal baseline overnight. You already feel the anxiety creeping in before your feet hit the floor — but this morning, you know *why*.

Anxiety Watch is an iOS and watchOS app that tracks anxiety from both sides: the severity you report and the physiology your Apple Watch records. It logs your medication doses and measures whether they actually helped. It imports your CPAP data and connects sleep apnea treatment to next-day anxiety. Over weeks and months, it builds a picture of your anxiety that no single journal entry or doctor's appointment could capture alone — and generates clinical reports that turn a fifteen-minute psychiatrist visit into a data-informed conversation.

The result is not a wall of numbers. It is your own data, interpreted through your own history, making the invisible patterns visible. Anxiety is less frightening when it is less mysterious.

> **Your data never leaves your devices.** There is no cloud service, no account to create, no telemetry, no analytics. Health data stays in HealthKit on your iPhone. App data stays in local SwiftData storage. The only time data goes anywhere is when *you* explicitly choose to export a report, sync to *your own* self-hosted server, or share a clinical PDF with *your* doctor. You are in complete control.

> **This project is under active development.** The data collection layer is thorough — 20+ HealthKit data types, medication tracking with efficacy measurement, CPAP integration, clinical reports, a sync server. The intelligence layer — pattern detection, compound triggers, proactive insights — is where the project is headed next.

<!--
TODO: Screenshots — build browser mockups of key screens for consistent,
high-quality images, then screenshot them. Needed:
  1. Dashboard (today's health summary with metric cards and sparklines)
  2. Trend chart (HRV with baseline band + anxiety overlay)
  3. watchOS Quick Log (Digital Crown severity picker)
  4. Medication dose follow-up (before/after anxiety rating)
  5. Clinical PDF report (structured psychiatric summary)

<div align="center">
  <img src="docs/screenshots/dashboard.png" width="250" alt="Dashboard showing today's health summary" />
  &nbsp;&nbsp;
  <img src="docs/screenshots/trends.png" width="250" alt="HRV trend chart with anxiety overlay" />
  &nbsp;&nbsp;
  <img src="docs/screenshots/watch.png" width="150" alt="watchOS Quick Log with Digital Crown" />
</div>
-->

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

### Your Experience

- **Anxiety journal** — severity (1–10), free-text notes, and tags. Timestamped entries that anchor all the objective data to how you actually feel.
- **Medication doses** — one-tap logging with a novel **dose-triggered anxiety prompt**: rate your anxiety when you take a medication, then again 30 minutes later via notification. Over time, this builds paired before/after efficacy data — something closer to a personal [N-of-1 trial](https://en.wikipedia.org/wiki/N-of-1_trial) than anything a consumer app typically produces.
- **watchOS Quick Log** — Digital Crown severity selection with haptic confirmation. When your hands are shaking and your thinking is clouded, you can still log how you feel in under five seconds.

### Your Physiology

The app reads **20+ data types from HealthKit** via an [actor-isolated](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Actors) manager with anchored queries and background delivery:

| Category | What's Tracked |
|----------|---------------|
| **Heart & autonomic** | Heart rate variability (SDNN), resting heart rate, raw heart rate, VO2 max, walking heart rate |
| **Sleep** | Total duration, stages (REM, deep, core, awake), skin temperature deviation, respiratory rate |
| **Blood oxygen** | SpO2 averages |
| **Activity** | Steps, active calories, exercise minutes |
| **Blood pressure** | Systolic/diastolic (via compatible cuff → HealthKit) |
| **Environment** | Barometric pressure (Core Motion), environmental sound levels |
| **Other** | Walking steadiness, gait metrics, atrial fibrillation burden |

Daily **HealthSnapshot** aggregation rolls these into efficient local trending and export. Personal **rolling baselines** compare you to yourself — not population norms. The dashboard shows alerts when your HRV drops below your own 30-day baseline, not when it crosses an arbitrary threshold.

**Privacy by design:** All health data stays on your device. HealthKit is the source of truth — the app reads your health data but never writes to it (except the planned Apple Health State of Mind integration). There are no third-party SDKs, no analytics, no tracking pixels, no data collection of any kind. The optional sync server is self-hosted on infrastructure you own and control. Data only leaves your device when you explicitly trigger an export, generate a clinical report, or sync to your own server.

### Your Sleep Apnea Treatment

- **CPAP import** from AirSense 11 SD card data — AHI, leak rates, usage hours, pressure stats, event breakdowns (obstructive, central, hypopnea)
- Connects sleep apnea treatment quality to anxiety outcomes — a correlation that is [well-established in research](https://pubmed.ncbi.nlm.nih.gov/25766719/) but almost never quantified for a specific patient

### Your Medications

- **Prescription management** — supply tracking with days-remaining calculations, refill alerts, expiration monitoring
- **Pharmacy search** via MapKit with call tracking and logging
- **OCR label scanning** — point your camera at a pill bottle and the Vision framework extracts Rx number, medication name, dosage, quantity, and refill count
- **CapRx claims import** — automated prescription sync from pharmacy benefit data via the sync server

### Your Reports

- **Clinical PDF reports** — multi-page summaries structured for psychiatric appointments: anxiety severity distribution, medication adherence per drug, sleep quality with stage breakdowns, HRV trends with baseline status, CPAP compliance, blood pressure, and lab results with reference ranges
- **JSON/CSV export** — complete data dump across 10 entity types for external analysis (pairs well with [Claude](https://claude.ai) for AI-assisted pattern detection)
- **Server sync** — self-hosted Flask + PostgreSQL backend mirrors your data for web access

---

## What Makes This Different

Most anxiety apps are journals. Some add meditation. A few track mood over time. None of them do this:

### Quantified medication efficacy

The dose-triggered anxiety prompt with 30-minute follow-up produces paired before/after measurements for every dose. Over weeks, this builds a personal efficacy curve per medication. When that curve flattens — tolerance — it becomes visible in the data before you or your clinician would notice through recall alone. No consumer anxiety app tracks this. Most clinical trials don't measure it at this frequency for an individual patient.

### Sleep-apnea-anxiety pipeline

CPAP data integrated with sleep quality metrics and next-day anxiety ratings. No anxiety app tracks CPAP compliance. No CPAP app tracks anxiety. For the millions of people who have both sleep apnea and an anxiety disorder, this connection has been invisible.

### Personal baselines over population norms

"Your HRV is 18% below your 30-day average" is actionable. "Your HRV is 34ms" is noise. The app computes your rolling personal baselines and flags *your* deviations from *your* normal.

### Designed for your worst moments

The watchOS Quick Log uses the Digital Crown because fine motor control is unreliable during panic. "Last taken" timestamps prevent the terrifying uncertainty of double-dosing during acute anxiety. The future "This Too Shall Pass" view will show your own history of panic episodes resolving — evidence from your own life that it always ends.

### Export-first, not walled-garden

Every piece of data is exportable — JSON, CSV, or clinical PDF — from day one. The Claude analysis workflow leverages the best available AI for pattern detection rather than building a mediocre ML system into the app.

---

## The Road Ahead

<details open>
<summary><strong>The North Star</strong></summary>

&nbsp;

Imagine opening Anxiety Watch on a difficult morning and seeing: "Rough night — 5h 12m of sleep, high CPAP leak, HRV below baseline. On mornings like this, your anxiety has averaged 6.2 compared to 3.8 after a good night."

The anxiety is still there, but it has been demystified. You are not spiraling into *what is wrong with me?* because the app has already answered: bad sleep, predictable consequence, you have seen this before.

At the end of the week, medication dose markers appear on your HRV and anxiety charts. You can see the medication working — HRV lifts within 30 minutes of each dose. But you also notice the before/after improvement has been shrinking. The app surfaces it: "Your average anxiety reduction per dose has decreased from 3.4 points to 1.9 points over the past 6 weeks." That is a tolerance signal, and it is something to bring to your psychiatrist with evidence.

Before your appointment, you generate a one-page clinical summary. Your psychiatrist scans it in 60 seconds and says, "I see what you mean about the medication. Let's talk about options." The conversation is grounded in your data. You feel heard because your experience is validated by measurement.

**This is the direction. Not a deadline.** Every change must make the app either more useful during an anxiety episode, more insightful during calm reflection, or more effective in a clinical conversation. If it doesn't serve at least one of those purposes, it probably isn't worth building.

See [PROJECT_FUTURE_PLAN.md](PROJECT_FUTURE_PLAN.md) for the full phased roadmap.

</details>

### Current Status

| Phase | Status | What's Included |
|-------|--------|----------------|
| **Foundation** | Working | HealthKit integration (20+ types), anxiety journal, medication tracking with dose-triggered efficacy measurement, prescription/pharmacy management with OCR, 7 trend charts, CPAP import, clinical PDF reports, JSON/CSV export, server sync, watchOS companion with widgets, 23 test files |
| **Solid Ground** | Active | Dashboard performance, baseline calculator improvements, HealthKit data gap fixes, test infrastructure hardening |
| **UX Transformation** | Next | Crisis-mode interactions (large tap targets, no fine motor control required), dashboard redesign with "Today's Summary" card, breathing pacer, home screen widgets, accessibility |
| **Intelligence Layer** | Planned | Sleep-to-anxiety correlation, exercise dose-response, medication efficacy trends, benzo tolerance detection, compound trigger identification, proactive alerts |
| **Clinical Integration** | Vision | Enhanced reports with embedded charts, Apple Health State of Mind (iOS 18+), FHIR export, medication timeline visualization |
| **Desktop App** | Vision | A dedicated desktop application powered by the sync server's data, enabling deep-dive visualizations and analysis too complex for a phone or watch — compound trigger exploration, long-range trend overlays, medication timeline Gantt charts, and full clinical report authoring |

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                     SwiftUI Views                    │
│   39 views across Dashboard, Journal, Medications,   │
│   Trends (7 charts), Prescriptions, Pharmacy,        │
│   CPAP, Lab Results, Reports, Settings               │
├─────────────────────────────────────────────────────┤
│                     16 Services                      │
│   HealthKitManager (actor) · HealthDataCoordinator   │
│   SnapshotAggregator · BaselineCalculator            │
│   CPAPImporter · ReportGenerator · DataExporter      │
│   SyncService · PrescriptionLabelScanner · ...       │
├────────────────────┬────────────────────────────────┤
│     HealthKit      │       SwiftData (local)         │
│  20+ data types    │  11 @Model classes: journal,    │
│  Actor-isolated    │  meds, Rx, CPAP, snapshots,     │
│  Anchored queries  │  health samples, barometric,    │
│  Background sync   │  lab results, pharmacy          │
├────────────────────┼────────────────────────────────┤
│   Core Motion      │    Flask + PostgreSQL           │
│   (barometer)      │    (self-hosted sync server)    │
└────────────────────┴────────────────────────────────┘
    + watchOS companion (WatchConnectivity)
    + WidgetKit (lock screen: HRV, anxiety, RHR)
```

**Zero external Swift dependencies.** 101 Swift files across iOS, watchOS, and WidgetKit targets — built entirely on Apple frameworks: HealthKit, SwiftData, Swift Charts, Vision, MapKit, WatchConnectivity, Core Motion, CallKit, PDFKit. No SPM packages.

See [REQUIREMENTS.md](REQUIREMENTS.md) for the full data model and specification.

---

## For Developers

If you're browsing this codebase to learn from it, here are the parts worth studying:

- **Actor-isolated HealthKit at scale** — `HealthKitManager` handles 20+ data types with anchored object queries, background delivery, and structured concurrency. Most open-source HealthKit examples demonstrate 2-3 types. This is a reference implementation for the real thing.
- **Dose-triggered notification follow-up** — `DoseAnxietyPromptView` + `DoseFollowUpManager`: schedules a `UNNotificationRequest` 30 minutes post-dose, captures the follow-up rating, pairs it with the pre-dose entry via a shared `MedicationDose` relationship, and cleans up stale follow-ups after 2 hours.
- **HealthSnapshot materialized view** — `SnapshotAggregator` queries HealthKit once per day and aggregates 19+ metrics into a single SwiftData record. Charts and exports read from this local model, not from HealthKit directly. Rebuildable from source if needed.
- **CPAP SD card parsing** — `CPAPImporter` reads AirSense 11 CSV data in the format documented by the [OSCAR](https://www.sleepfiles.com/OSCAR/) project. One of the few Swift implementations.
- **Vision OCR for prescription labels** — `PrescriptionLabelScanner` extracts Rx number, medication name, dosage, quantity, and refills from photographed pill bottles using regex patterns against `VNRecognizeTextRequest` output.
- **Personal baseline statistics** — `BaselineCalculator` computes rolling mean/stddev per metric with configurable windows and deviation detection. Design principle: flag when *you* deviate from *your own* normal.
- **SwiftData with 11 related models** — relationships, cascade deletes, and query-driven views across a non-trivial schema. Good reference for SwiftData beyond the single-model tutorials.
- **Full-stack sync** — `SyncService` (Swift actor) pushes to a Flask/PostgreSQL backend with API key auth, upsert logic across 10 entity types, and CapRx/Walgreens prescription import pipelines.

---

## Getting Started

<details>
<summary><strong>Prerequisites</strong></summary>

- **Xcode 15+** with iOS 17 and watchOS 10 SDKs
- **Apple Watch** paired with your iPhone (for real HealthKit data — the simulator has limited health data support)
- **Python 3.12+** and **Docker** (optional — only needed for the sync server)

</details>

```bash
# Build the iOS app
xcodebuild build -scheme AnxietyWatch \
  -destination 'generic/platform=iOS Simulator'

# Build the watchOS companion
xcodebuild build -scheme "AnxietyWatch Watch App" \
  -destination 'generic/platform=watchOS Simulator'

# Run tests (23 test files, Swift Testing framework)
xcodebuild test -scheme AnxietyWatch \
  -destination 'generic/platform=iOS Simulator' \
  -only-testing:AnxietyWatchTests

# Sync server (optional)
cd server && pip install -r requirements.txt
docker compose --env-file server/.env -f server/docker-compose.yml up
```

See [SETUP_GUIDE.md](SETUP_GUIDE.md) for environment setup and [CLAUDE.md](CLAUDE.md) for the full project structure and coding conventions.

> **Note:** This started as a personal project for one user's devices. You will need to configure your own HealthKit permissions, CPAP data source, and (optionally) sync server. The codebase is designed to be readable and adaptable to your own setup.

---

## Contributing

Anxiety Watch is a personal project that welcomes contributions. Response times may vary.

If you live with anxiety and this approach resonates with you, I'd especially value your perspective — through issues, discussions, or pull requests.

**Good first contributions:**
- **Tests** — service layer has good coverage; views and coordinators need more (Swift Testing framework, in-memory SwiftData containers)
- **SwiftUI `#Preview` blocks** — none exist yet, high-impact developer experience improvement
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
