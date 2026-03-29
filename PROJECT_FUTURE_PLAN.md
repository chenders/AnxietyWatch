# PROJECT_FUTURE_PLAN.md -- Long-Term Vision for AnxietyWatch

## Where the App Is Today

AnxietyWatch is a deeply personal tool built by someone who lives with anxiety and panic disorder, for that same person. It is not a commercial product and never will be. That constraint is also its greatest strength: every design decision serves one user's actual needs, not a product manager's engagement metrics.

### What Has Been Built

The foundation is substantial and well-architected:

- **Comprehensive HealthKit integration** -- 20+ health data types are read via an actor-based `HealthKitManager`, with anchored object queries providing near-real-time updates and background delivery keeping data fresh. Daily `HealthSnapshot` aggregation provides efficient trending and export.

- **A full anxiety journal** -- timestamped entries with 1-10 severity, free-text notes, and tags. Journal entries are the subjective anchor that gives all the objective data its meaning.

- **Medication tracking with clinical-quality follow-up** -- one-tap dose logging, a novel dose-triggered anxiety rating system with 30-minute follow-up notifications, PRN vs. scheduled distinction, and integration with pharmacy prescription data via CapRx. The before/after anxiety measurement around medication doses produces data that most clinical trials would envy.

- **Prescription and pharmacy management** -- supply calculations, refill alerts, OCR scanning for pill bottle labels, pharmacy search, call tracking. A full medication lifecycle system.

- **Trend visualization** -- seven chart views using Swift Charts, with anxiety entries overlaid on physiological data, HRV baseline reference lines, and configurable time windows (7/30/90 days).

- **CPAP data integration** -- SD card import for AirSense 11 data (AHI, leak rates, usage hours), connecting sleep apnea treatment quality to anxiety outcomes.

- **Barometric pressure tracking** -- capturing atmospheric pressure data to test the hypothesis that pressure changes affect anxiety.

- **Clinical report generation** -- PDF reports structured for psychiatric appointments, with anxiety summaries, medication adherence, sleep quality, and HRV trends.

- **Data export pipeline** -- JSON and CSV export for external analysis, with a documented Claude analysis workflow.

- **Server sync** -- a Flask/PostgreSQL sync server with prescription import from CapRx, providing a web-accessible data mirror.

- **watchOS companion** -- Quick Log with Digital Crown severity selection and haptic feedback. The single best-designed interaction for acute anxiety moments.

- **Solid test infrastructure** -- 20 test files using Swift Testing, in-memory SwiftData containers, and good coverage of core services (BaselineCalculator, PrescriptionSupplyCalculator, CPAPImporter, DataExporter, etc.).

### What Works Well

The data collection layer is thorough. The app captures an unusually rich picture of a person's daily experience: how they slept, what their autonomic nervous system is doing, whether they exercised, what medications they took, how their CPAP performed, and -- most importantly -- how they actually feel. Very few personal health tools bring this many streams together for a single condition.

The medication tracking is genuinely novel. The dose-triggered anxiety prompt with follow-up creates paired before/after measurements that directly quantify medication efficacy. No consumer anxiety app does this.

The watchOS Quick Log is well-calibrated to the reality of panic. Digital Crown, one number, one button, haptic confirmation. It respects the cognitive constraints of acute distress.

The export-to-Claude workflow is pragmatic and powerful. Rather than building a mediocre ML system into the app, it leverages the best available analysis tool through a simple JSON export. This was a good architectural instinct.

### What the Foundation Enables

The data model and service architecture can support everything described in this document without a rewrite. The `HealthSnapshot` aggregation system, the `HealthSample` cache, the `BaselineCalculator`, and the medication timeline data are all building blocks that just need a smarter layer on top. The hard part -- getting the data in -- is largely done. The remaining work is in making that data speak.

---

## The North Star: What AnxietyWatch Becomes

Imagine opening AnxietyWatch on a difficult morning.

You slept badly. You know it before the app tells you, because you are already feeling the edges of anxiety creeping in. But the app knows why. It shows you a single summary: "Rough night -- 5h 12m of sleep, CPAP leak was high, and your HRV dropped below your baseline overnight. On mornings like this, your anxiety has averaged 6.2 compared to 3.8 after a good night. Consider gentle movement and your usual morning routine."

That is not a wall of numbers. It is your own data, interpreted through your own history, giving you context for what your body is doing. The anxiety is still there, but it has been demystified. You are not spiraling into "what is wrong with me?" because the app has already answered: bad sleep, high leak, predictable consequence. You have seen this pattern before. You know what to do.

You tap "Log" and rate yourself a 6. The app remembers your most-used tags and shows them as tappable chips -- "morning," "sleep," "work." Two taps and you have captured the moment. No typing, no slider, no form.

Later, your anxiety spikes. You reach for your lorazepam. When you log the dose, the app shows "Last taken: none today" and you know you have not already taken one (a real fear during panic). You skip the anxiety prompt because your hands are shaking, and the app respects that choice completely. Thirty minutes later, a gentle notification: "How are you feeling now?" You tap "5" directly from the notification. Done.

At the end of the week, you open the Trends tab. The app has placed medication dose markers on your HRV and anxiety charts. You can see the benzos working -- HRV lifts within 30 minutes of each dose. But you also notice something: the before/after improvement has been shrinking over the past month. The app has noticed too: "Your average anxiety reduction per lorazepam dose has decreased from 3.4 points to 1.9 points over the past 6 weeks." That is a tolerance signal, and it is something to bring to your psychiatrist.

Before your appointment, you generate a one-page clinical summary. It leads with the headline: medication usage is up, efficacy is down, sleep quality correlates strongly with next-day anxiety. Your psychiatrist scans it in 60 seconds and says, "I see what you mean about the lorazepam. Let's talk about options." The conversation is grounded in evidence, not hazy memory. You feel heard because your experience is validated by data.

Back on a calm Sunday morning, you explore the Insights tab. The app has computed your personal correlations: exercise days predict lower anxiety, caffeine after 2 PM predicts worse sleep which predicts worse next-day anxiety, your anxiety clusters on weekday mornings. None of this is surprising when you see it, but seeing it quantified changes something. The patterns become levers. You start going for a walk every morning. Not because an app told you to, but because your own data showed you it works.

This is the vision: an app that turns anxiety from an invisible, incomprehensible force into a pattern you can see, understand, and work with. Not by adding more data, but by making the data you already have tell your story.

---

## Phase 1: Solid Ground

*Foundation fixes, developer experience, code quality, and bug fixes. The work that makes everything else possible.*

### What the User Experiences After Phase 1

Honestly, not much visible change. The app looks and feels almost the same. But it is faster, more reliable, and the person building it can move three times faster on everything that follows. This phase is infrastructure investment.

The one visible improvement: the dashboard loads noticeably faster. The fetch that previously pulled all HealthSample records is now bounded. The six `@Query` properties that caused unnecessary re-renders have been rationalized. Pull-to-refresh works on both the Dashboard and Trends.

### Key Technical Changes

**Code architecture:**
- Extract `DashboardViewModel` from the 700-line `DashboardView`, moving all sample loading, baseline computation, supply alert filtering, trend computation, and color mapping into a testable `@Observable` class.
- Consolidate the triplicated supply alert filtering logic (Dashboard, MedicationsHub, PrescriptionList) into a single `SupplyAlertFilter` utility.
- Extract `PrescriptionImporter` from `SyncService` to isolate the JSON-to-model mapping for testing.
- Remove dead code (`MedicationListView` -- a near-exact duplicate of `MedicationsHubView`).
- Extract `severityColor` and related color mappings to a shared utility (currently duplicated in 6+ files).
- Convert raw-string enums (`PharmacyCallLog.direction`, `CPAPSession.importSource`) to proper Swift enums.

**HealthKit fixes:**
- Fix the anchored query predicate bug that drops samples when the anchor is older than 7 days.
- Add `HKWorkoutType` reading -- the single biggest data gap. Without it, exercise HR contaminates baseline calculations and triggers false anxiety correlations.
- Add `timeInDaylight` and `physicalEffort` to read types (trivial additions with high anxiety-correlation value).
- Add deduplication logic to `HealthSample` insertion.
- Log `enableBackgroundDelivery` and anchored query errors instead of silently discarding them.
- Query blood pressure as `HKCorrelation` to properly pair systolic/diastolic readings.

**Baseline calculator improvements:**
- Increase minimum sample count from 3 to 14 (3 data points cannot establish a meaningful baseline).
- Switch from population variance (N) to sample variance (N-1) for correctness with small samples.
- Add outlier handling (trimmed mean or median absolute deviation).
- Add baselines for sleep duration and respiratory rate, not just HRV and resting HR.

**Testing infrastructure:**
- Create shared `TestHelpers.swift` with a single `makeFullContainer()` matching the app's schema.
- Create `ModelFactory.swift` with factory methods for common test models.
- Add `#Preview` blocks to the five most-used views with in-memory sample data.
- Create `SampleData.swift` for previews, tests, and a future demo mode.
- Fix `BaselineCalculatorTests` to use fixed reference dates.

**Developer experience:**
- Create a `Makefile` with targets for build, test, lint, coverage, server-up.
- Wire `generate-version.sh` into Xcode build phases.
- Remove `continue-on-error: true` from iOS CI (making tests actually gate merges).
- Add SwiftLint to CI.
- Add a watchOS build step to CI.
- Replace `print()` logging with `os.Logger` for structured, filterable logs.
- Replace `try?` silent error swallowing with `do/catch` + logging throughout `HealthDataCoordinator`.

**Prescription data improvements:**
- Store `daysSupply` on the Prescription model and use it as primary input for run-out calculations.
- Store `patientPay`, `planPay`, `dosageForm`, and `drugType` from CapRx claims (currently extracted and discarded).
- Fix the staleness filter to be relative to each prescription's own days supply (a 90-day fill should not expire from alerts at 60 days).
- Show "Unknown" for refills on claims-sourced records rather than misleading "0".
- Filter out reversed/rejected claims in the server import pipeline.

### What This Unlocks

Everything in Phases 2-4 depends on this work. The `DashboardViewModel` extraction makes the dashboard redesign in Phase 2 structurally possible. The baseline calculator improvements make the intelligence layer in Phase 3 trustworthy. The testing infrastructure makes it safe to make sweeping UI changes without breaking data logic. The HealthKit fixes (especially workout data) eliminate false signals that would undermine pattern detection.

---

## Phase 2: An App That Meets You Where You Are

*UX transformation: crisis mode, dashboard redesign, journal improvements, and the features that make the app usable during the moments when it matters most.*

### What the User Experiences After Phase 2

The app feels fundamentally different depending on when you open it.

**During a crisis:** A prominent "Log" button sits at the top of the dashboard. One tap opens a minimal severity picker -- ten large, color-coded numbered circles (not a slider that requires fine motor control with trembling hands). Your most-used tags appear as tappable chips. No typing required. The whole interaction takes 5 seconds. Below the log button, you see reassurance from your own data: "You have logged 47 episodes rated 7+. Average time until you felt better: 34 minutes. You have gotten through every one." And a simple breathing pacer: inhale 4, hold 4, exhale 6, animated, accessible from both the iPhone and Watch.

If you took a medication recently, it says so: "You took lorazepam 0.5mg 22 minutes ago." During panic, knowing whether you already took something prevents the dangerous confusion of double-dosing.

**During a calm morning check-in:** The dashboard opens with a "Today's Summary" card synthesizing the night's sleep quality, current HRV vs. baseline, yesterday's anxiety trend, and medication adherence status into 3-5 readable bullet points. Below that, metrics are organized into collapsible sections -- "Anxiety & Mood" (always pinned at top), "Sleep," "Heart & Autonomic," "Activity" -- rather than the previous flat scroll of 20 undifferentiated cards. Metrics that do not meaningfully relate to anxiety moment-to-moment (VO2 Max, walking steadiness, environmental sound, headphone audio) are hidden by default. The app tells stories, not numbers: "Your HRV is 18% below your 30-day average" rather than "HRV: 28ms."

**When logging medications:** Each medication in Quick Log shows "Last taken: 8:15 AM" to prevent double-dosing. After completing a 30-minute follow-up, the app shows the delta: "Before: 7 -- After: 4. Improvement of 3 points." This small feedback loop is motivating and helps calibrate whether the medication is working.

**When reviewing trends:** Medication dose markers appear on the HRV and Anxiety charts as small pill icons. You can see when you took a benzo and watch the HRV lift. An insight card at the top summarizes: "Average anxiety was 4.8 this week, down from 5.6 last week. You had 2 fewer high-anxiety episodes." For 30-day and 90-day views, anxiety data aggregates to daily averages instead of illegible point clouds.

### Key Technical Changes

**Dashboard redesign:**
- "Today's Summary" card at the top that synthesizes overnight sleep, HRV baseline status, anxiety trend, and medication adherence into natural language.
- Grouped, collapsible metric sections with configurable visibility.
- "Log Anxiety" button directly on the dashboard -- not buried in the Journal tab.
- "Today's Meds" section showing taken/not-taken status for each active medication.
- Loading state with skeleton cards during initial data fetch.
- Error state guiding users to grant HealthKit permissions when data is missing.
- Contextual metric display: "Your heart rate is 95 bpm -- elevated, but typical for your stress episodes (your average during anxiety is 92 bpm)."

**Journal improvements:**
- Replace the severity slider with tappable numbered circles (minimum 44x44pt, color-coded).
- Quick-tag chips populated from most-used tags, with free-text entry as secondary option.
- "Express mode" that captures severity with one tap and dismisses. Notes added retroactively.
- Descriptive severity anchors: 1-2 (calm), 3-4 (mild unease), 5-6 (moderate), 7-8 (high / physical symptoms), 9-10 (panic/crisis).

**Crisis and grounding features:**
- Breathing pacer (inhale/hold/exhale with simple animation), accessible from Dashboard, Watch, and as an Action button.
- "This too shall pass" view showing personal history of panic episodes resolving.
- Context around heart rate readings: whether the current reading is normal for the time of day and activity level.

**Medication UX:**
- "Last taken" timestamp next to each Quick Log button.
- Before/after delta display after follow-up completion.
- Configurable follow-up timing per medication (15/30/45/60 minutes).
- UNNotificationAction on follow-up notifications for in-notification anxiety rating.
- "Missed follow-up" grace path when the app is not opened within the prompt window.

**Watch improvements:**
- Default Quick Log severity to last logged value instead of 5.
- Replace modal confirmation alert with auto-dismissing checkmark.
- Show "Last: 6, 2 hours ago" context at top of Quick Log.
- Implement watchOS complication from REQUIREMENTS.md.
- Add breathing pacer accessible from the Quick Log screen.

**Widgets:**
- Home-screen WidgetKit widget: quick-log variant (opens to severity picker) and status variant (last HRV, last anxiety, sleep quality).
- Lock Screen widget showing HRV vs. baseline.

**Accessibility:**
- `accessibilityElement` grouping on `LiveMetricCard` (compose as single element: "Heart Rate: 72 beats per minute, rising, 5 minutes ago").
- Accessibility representations for `SparklineView`, `ProgressBarView`, `SleepStagesView`, `RecentBarsView`.
- Fix yellow severity badge contrast (white on yellow is unreadable).
- Replace fixed-size fonts (8pt, 9pt) with scaled alternatives for Dynamic Type.
- Context-dependent trend arrow colors (rising HR is bad, rising HRV is good -- currently both show orange).

**Navigation cleanup:**
- Move Export/Reports to be accessible from the Trends tab or a more prominent location.
- Fix `.navigationDestination` scoping in `MedicationsHubView` (currently conditional on supply alerts being visible).
- Fix `.alert` binding anti-pattern in `ExportView` and `CPAPListView`.
- Promote Lab Results to a more discoverable navigation path.

### What This Unlocks

After Phase 2, the app is genuinely usable during the moments when anxiety is worst, not just during calm retrospection. The dashboard tells a story instead of dumping numbers. The journal captures data in seconds rather than minutes. The medication tracking is safer (double-dose prevention) and more motivating (efficacy feedback). The breathing pacer provides an in-the-moment coping tool.

Most importantly: the app's relationship with the user changes. It is no longer a data collection chore. It becomes something that helps in real time and earns the user's trust. That trust is what makes them want to keep logging, which is what makes the intelligence layer in Phase 3 possible. Data quality depends on user engagement, and engagement depends on the app being useful when it matters.

---

## Phase 3: The Intelligence Layer

*Pattern detection, medication analysis, computed insights, and the features that turn data into understanding.*

### What the User Experiences After Phase 3

The app starts telling you things you did not know about yourself.

An insight card appears: "On days you exercise 30+ minutes, your average anxiety is 3.2. On sedentary days, it is 5.8. You have 14 data points supporting this pattern." You already knew exercise helped. But seeing it quantified, from your own life, makes it feel different. It becomes a lever you trust.

Another card: "Your anxiety clusters on weekday mornings. Sunday evenings are also elevated -- possibly anticipatory." You had never noticed the Sunday evening pattern. Now you can plan for it.

The medication section shows a trend you had been vaguely sensing: "Your PRN lorazepam usage has increased from 8 doses in February to 14 doses in March. Average efficacy has decreased from 3.2 points to 1.9 points per dose." The tolerance signal is clear. You schedule a psychiatrist appointment.

Your clinician's report now includes a "Medication Efficacy" section: "Patient took lorazepam 0.5mg 14 times this month. Average pre-dose anxiety: 7.4. Average 30-min post-dose anxiety: 5.5. Average reduction: 1.9 points (down from 3.2 points 8 weeks ago)." Your psychiatrist reads this and immediately understands the trajectory. The conversation that follows is specific and productive.

The app has also derived overnight HRV as a separate metric, and it is noticeably more stable than the all-day average. It has detected that your HRV circadian rhythm (the natural dip during the day and rise at night) has been flattening -- a sign of chronic stress. It shows this as a trend over the past 90 days.

On one particularly bad day, you check your trends and the app highlights: "The last 3 times you had a 9+ anxiety episode, you had slept under 5 hours AND had CPAP leak above 15 L/min AND had caffeine after 2 PM." Compound triggers, surfaced from your own data. Not a vague correlation from a research paper -- your actual life.

### Key Technical Changes

**In-app pattern detection engine:**
- Sleep-to-next-day-anxiety correlation (the most evidence-backed and frequently requested pattern).
- Exercise-to-anxiety correlation (dose-response: 30+ min exercise vs. sedentary days).
- Tag-based analysis (average severity when tagged "caffeine" vs. untagged entries).
- Day-of-week and time-of-day clustering (heatmap: when does anxiety concentrate?).
- Compound trigger detection (multi-factor analysis: sleep + CPAP + caffeine combinations).
- Barometric pressure rate-of-change correlation (delta kPa/hr rather than absolute pressure).
- Pre-episode physiological signature detection (HR/HRV in the 15-45 minutes before high-severity entries).
- "What was different about good days?" reverse analysis.

**Medication intelligence:**
- Benzo tolerance detection: rolling PRN frequency trend + efficacy decay (before/after severity delta over time).
- Rebound anxiety detection: compare severity in the 4-8 hour post-dose window vs. the 12-24 hour window.
- SSRI onset tracking: 7-day rolling average from start date, with expected timeline annotations.
- SSRI activation syndrome detection: flag if anxiety/RHR increases in weeks 1-2 after starting.
- Discontinuation syndrome detection: flag HRV drops and anxiety spikes 2-5 days after doses stop.
- Stimulant-anxiety timing analysis: anxiety ratings during peak effect (2-6 hours post-dose) vs. wearing-off (8-12 hours).
- Per-medication follow-up timing based on onset characteristics (benzos: 15-20 min, beta-blockers: 45-60 min).
- "Medication Efficacy" report section aggregating before/after ratings with trend analysis.

**Advanced baseline calculations:**
- 90-day baseline window with 7-day rolling "current" comparison (prevents baseline contamination during extended anxious periods).
- Configurable threshold per metric type (HRV is noisier than RHR which is noisier than sleep duration).
- Weekday/weekend stratification (many people have systematically different patterns).
- Overnight HRV as a separate, clinically cleaner metric.
- HRV circadian rhythm monitoring (daytime vs. overnight ratio; flattening = chronic stress).
- Sleep onset latency derivation from existing sleep stage data.
- Nocturnal HR spike detection (max overnight HR vs. resting HR).
- Heart rate recovery computation from workout + HR data (vagal tone marker).

**Derived insights:**
- "Anxiety Risk" composite score synthesizing HRV deviation, sleep quality, exercise, and CPAP compliance into a single daily number.
- Proactive notifications: "Your HRV has been dropping all afternoon and your resting HR is elevated. Consider taking some preemptive steps."
- Personal correlation coefficients for each tracked factor (exercise, sleep, caffeine, barometric pressure) displayed as a "what affects your anxiety" summary.
- Medication timeline visualization (Gantt-chart style: start dates, dose changes, stops, overlaid with anxiety trend).

**Pharmacy intelligence:**
- Refill eligibility date alongside supply run-out date (when insurance will pay vs. when pills run out).
- DEA schedule awareness with appropriate messaging (Schedule II: "new prescription required").
- Therapy gap detection from consecutive fill dates.
- Cost trend tracking across fills.
- Prescription grouping by medication in the UI (patient thinks "4 medications," not "12 prescriptions").

**HealthKit integration expansion:**
- Write `HKStateOfMind` (iOS 18+) when journal entries are created -- puts AnxietyWatch data into Apple Health's Mental Wellbeing section, enabling bidirectional data flow with the Health ecosystem.
- Write `HKCategoryTypeIdentifier.mindfulSession` for journal entries and breathing exercises.
- Read `appleSleepingBreathingDisturbances` (iOS 18+) as Apple-native AHI.
- Read ECG data for completeness (frequency of checks is itself useful metadata for anxiety tracking).
- Read stand hours as a sedentary behavior indicator.
- Add menstrual cycle data reading for users where cyclical anxiety patterns are relevant.

### What This Unlocks

Phase 3 is where AnxietyWatch transitions from a data collection tool to a data interpretation tool. The patterns it surfaces are not generic health advice -- they are personal discoveries derived from the user's own life. That is fundamentally different from an app telling you "exercise reduces anxiety." It is the app showing you that exercise reduces *your* anxiety by a specific, measured amount, based on your actual experience over the past 90 days.

This phase also makes the clinical reports dramatically more valuable. Medication efficacy trends, compound trigger analysis, and benzo tolerance detection are the kind of data that changes prescribing conversations. A psychiatrist who sees quantified tolerance development will respond differently than one who hears "I think the medication isn't working as well."

---

## Phase 4: Clinical Integration and the Broader Ecosystem

*Reports, provider sharing, Apple Health ecosystem, and the features that bridge personal tracking and clinical care.*

### What the User Experiences After Phase 4

Your psychiatrist opens a one-page clinical summary on their iPad. At the top: anxiety severity trend (improving), medication usage pattern (benzo frequency up but efficacy declining, SSRI adherent at 97%), sleep-anxiety correlation strength (r=0.62), and a list of compound triggers unique to you. Below the summary, embedded charts show the HRV trend with baseline band, the anxiety distribution heatmap, and the medication timeline.

The report includes a "Questions for Discussion" section, auto-generated from the data: "PRN benzodiazepine efficacy has decreased 40% over 8 weeks -- discuss tolerance management. Sleep quality remains the strongest predictor of next-day anxiety (r=0.62) -- discuss CPAP optimization. Exercise correlates with 42% lower anxiety on active days -- discuss exercise prescription."

Your Apple Health app now shows your anxiety data in the Mental Wellbeing section, alongside mindful minutes from your breathing exercises. Apple's own correlation engine picks up patterns between your State of Mind data and your sleep, exercise, and heart metrics. The two apps reinforce each other.

When you share the PDF with your psychiatrist, it includes data completeness metrics ("HRV data: 27/30 days, CPAP data: 25/30 days, journal entries: 42 this month") so the clinician can assess the reliability of the analysis.

### Key Technical Changes

**Enhanced clinical reports:**
- Embed Swift Charts-rendered trend charts in the PDF (render to UIImage and draw into the PDF context).
- One-page executive summary with the six most clinically relevant data points (medication efficacy trend, anxiety distribution, sleep correlation, compound triggers, HRV baseline status, PRN frequency).
- "Medication Efficacy" section aggregating dose-triggered before/after ratings per medication.
- Data completeness metrics per section ("Sleep data: 27/30 days").
- Structured medication list for appointment reference (one-tap "current medications" export).
- Dose-anxiety correlation data: "Patient self-reported anxiety decreased an average of 1.9 points within 30 minutes of lorazepam doses across N=14 administrations this month."

**Apple Health ecosystem integration:**
- Bidirectional `HKStateOfMind` flow (write anxiety entries, read from other mental health apps).
- `HKCategoryTypeIdentifier.mindfulSession` writing for breathing exercises and reflective journal entries.
- FHIR-formatted export capability for integration with electronic health records.
- Consideration of Apple's CareKit framework for structured care plan integration.

**Advanced export and sharing:**
- Time-scoped export with enriched context (nearby physiology for each journal entry, as specified in DATA_AND_REPORTS.md).
- Shareable clinical summary via AirDrop, Messages, or provider portal link.
- Automated weekly Claude analysis workflow (scheduled export + API call + summary delivery).

**Structured clinical data:**
- Expanded journal tags capturing phenomenology: onset speed (sudden/gradual/triggered), physical symptoms (palpitations, SOB, dizziness, GI, muscle tension), and episode duration. These enable panic attack vs. GAD vs. situational pattern differentiation without imposing diagnostic categories.
- Side effect logging with temporal correlation to medication changes.
- Adherence tracking (expected vs. actual doses per day for scheduled medications).

### What This Unlocks

Phase 4 closes the loop between personal tracking and clinical care. The app becomes not just a tool for the user to understand their anxiety, but a communication channel between patient and provider. The reports are specific, quantified, and structured for the 15-minute medication management visit. The Apple Health integration means AnxietyWatch's data contributes to the broader ecosystem of the user's health record rather than existing in isolation.

---

## The Killer Features: What Only AnxietyWatch Can Do

Several features emerge from this plan that no other anxiety app -- consumer, clinical, or research -- currently offers. These are possible because AnxietyWatch uniquely combines deep HealthKit integration, medication tracking with efficacy measurement, personal baseline calculations, and the context of a single user who knows their own data intimately.

### 1. Quantified Medication Efficacy

The dose-triggered anxiety prompt with 30-minute follow-up produces paired before/after measurements for every medication dose. Over time, this builds a personal efficacy curve for each medication. No consumer app tracks this. No clinical trial measures it at the individual level with this frequency. When the efficacy curve flattens (tolerance) or the frequency curve rises (dependence), the app detects it before the user or their clinician would notice.

### 2. Pre-Episode Physiological Detection

By correlating cached HealthKit samples with journal entry timestamps, the app can identify the user's personal pre-anxiety physiological signature. Research shows that HR increases and HRV decreases begin 15-45 minutes before subjective anxiety awareness. Once the app has enough data points (20-30 high-severity entries with corresponding physiological data), it can potentially alert the user to an emerging episode before they are fully aware of it.

### 3. Compound Trigger Identification

Single-factor correlations are easy. What is hard -- and what only a personal tracking tool with multiple data streams can do -- is identifying compound triggers: "The last 3 times you had a 9+ episode, you had slept under 5 hours AND had high CPAP leak AND had caffeine after 2 PM." These multi-factor patterns are invisible in clinical interviews and impossible to detect without longitudinal, multi-stream personal data.

### 4. Sleep-Apnea-Anxiety Pipeline

The integration of CPAP data with sleep quality metrics and next-day anxiety ratings is genuinely unique. No other anxiety app tracks CPAP compliance, and no CPAP app tracks anxiety. The connection between untreated sleep apnea and anxiety is well-established in the literature but almost never quantified for an individual patient. Showing a psychiatrist that high-AHI nights predict next-day anxiety severity with a specific correlation coefficient can change treatment priorities.

### 5. Personal Autonomic Baselines with Contextual Interpretation

Most health apps show you a number: "HRV: 34ms." AnxietyWatch shows you what that number means for you: "18% below your 30-day baseline, consistent with the pattern you see after poor sleep." The combination of personal baselines, deviation detection, and correlation with subjective experience turns raw physiological data into personally meaningful context. When the app says "your body is more stressed than usual today," it is not guessing from population norms -- it is comparing you to yourself.

### 6. The "This Too Shall Pass" View

Simple but profound: your own history of panic episodes resolving. "You have survived 47 episodes rated 7+. Average time to resolution: 34 minutes. Longest: 2 hours." During acute panic, the conviction that "this will never end" is overwhelming. Your own historical evidence that it always ends is one of the most powerful grounding tools available. No anxiety app currently surfaces this.

---

## The Central Tension: Health Dashboard vs. Anxiety Tool

Nine expert reviews converged on a single tension at the heart of this app. The lived experience expert stated it most directly:

> "The app tries to be a comprehensive health dashboard AND an anxiety tool. Those are different things. The dashboard suffers from showing everything because it can, not because it should."

This tension is real and it must be resolved intentionally rather than by accident. Here is the resolution:

**AnxietyWatch is an anxiety tool that happens to collect comprehensive health data.** The health data exists to serve the anxiety mission, not the other way around. Every metric on the dashboard, every chart in Trends, every section in the clinical report earns its place by answering one question: "Does this help me understand, predict, manage, or communicate about my anxiety?"

By that standard:
- HRV, resting HR, sleep quality, CPAP data, exercise, and medication timing all pass easily. They have direct, evidence-based connections to anxiety and they answer questions the user actually asks.
- Barometric pressure, blood pressure, and time in daylight pass conditionally -- they may matter for this specific user, and the app should compute the personal correlation before deciding whether to surface them.
- VO2 Max, walking steadiness, headphone audio, environmental sound, AFib burden, and walking gait metrics do not pass. They are interesting health data, but they do not help with anxiety in any actionable way. They should be hidden by default and available only for users who specifically want them.

The practical implementation of this principle is the dashboard redesign in Phase 2: the "Today's Summary" card at the top tells an anxiety-relevant story. Collapsible sections let the data-curious user drill into everything. But the default experience is focused, interpreted, and actionable rather than comprehensive and overwhelming.

There is a deeper dimension to this tension. For someone with health anxiety, a wall of physiological metrics can be actively harmful. Seeing your heart rate in big red numbers during a panic attack does not help -- it amplifies the panic. The lived experience expert identified this clearly: raw numbers without personal context are anxiety-amplifying. The app must present data with interpretation ("elevated but within your normal range for stress episodes") rather than as isolated values that invite catastrophic interpretation.

The north star is not "show all the data." It is "tell the story that helps."

---

## A Note on Scope and Realism

This document describes years of work. It should be read as a direction, not a deadline. The phases are sequential but open-ended -- Phase 1 might take months, Phase 3 might take a year. The user is a single developer working on a personal project. The app does not need to ship to the App Store. There are no stakeholders to satisfy, no engagement metrics to hit, no quarterly roadmap to deliver.

That is the liberating part. Every feature can be built when it is ready, tested until it is right, and refined based on actual lived experience. The app evolves alongside the person using it. The expert recommendations in this document are guideposts, not mandates. If a feature does not help when it is built, it can be removed. If something unexpected emerges from the data, the app can pivot to follow it.

The one commitment worth making: every change should make the app either more useful during an anxiety episode, more insightful during calm reflection, or more effective in a clinical conversation. If a change does not serve at least one of those three purposes, it probably is not worth making.
