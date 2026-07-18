# Anxiety Watch Full-App Demo Implementation Specification

**Status:** Implementation-ready companion to `FULL_APP_DEMO_PLAN.md`  
**Scope:** DEBUG builds of the main iPhone app only  
**Canonical launch argument:** `-demoFullAppSequence`  
**Out of scope:** Watch app, widgets, Live Activities, production behavior changes not needed to make an existing destination legitimately reachable

## 1. Purpose and governing rules

This document converts `FULL_APP_DEMO_PLAN.md` into an implementable contract. The plan remains authoritative for editorial intent; this specification is authoritative for demo state, fixtures, route ordering, safety, automation, and verification.

The implementation must:

1. Use the real app tabs, navigation stacks, sheets, forms, cards, charts, and model views.
2. Add DEBUG-only state and dependency substitution rather than a parallel fake app.
3. Never imply a display-only card is tappable and never use a hidden demo route to claim normal product reachability.
4. Use semantic control activation and semantic scroll anchors; no screen coordinates, injected mouse events, or unbounded swipe loops.
5. Preserve a retained simulator installation and HealthKit authorization while making every chapter repeatable.
6. Make all recorded data obviously fictional and all live devices visibly simulated.
7. Keep the existing iOS 26 render protections (`Equatable` destinations, bounded queries, and simple predicates) intact.

## 2. Demo runtime architecture

### 2.1 Launch configuration

`-demoFullAppSequence` is the single public switch for this demo. It implies deterministic demo fixtures, dark appearance, safe service substitutes, and the shared demo clock. It must not require `-autoRestoreFromServer` or contact a server.

Optional internal arguments:

- `-demoChapter <chapter-id>`: start or resume one chapter.
- `-demoReset`: rebuild only the isolated demo fixture/mutation state.
- `-demoResumeCheckpoint <checkpoint-id>`: recovery/debugging override.
- `-demoCaptureRun <UUID>`: associates logs and checkpoints with a capture run.

Existing screenshot arguments may remain for their current uses, but the full-app coordinator must not compose behavior by launching several unrelated screenshot modes.

### 2.2 Required types

Implement DEBUG-only equivalents of the following responsibilities (names may vary, responsibilities may not):

```swift
@MainActor @Observable
final class FullAppDemoCoordinator {
    let clock: DemoClock
    let devices: DemoDeviceSession
    let fixtureStore: DemoFixtureStore
    let safetyAudit: DemoSafetyAudit

    var chapter: DemoChapter
    var step: DemoStep
    var checkpoint: DemoCheckpoint
    var expectedScreen: DemoScreen
    var runID: UUID

    func advance(after evidence: DemoEvidence)
    func fail(_ reason: DemoFailure)
    func resume(from checkpoint: DemoCheckpoint)
}
```

The coordinator must be owned below `WindowGroup` at a scope that does not cause per-second device updates to invalidate the whole app. Views that display changing device values observe a narrow snapshot/provider, following the same containment principle already used by `RecordingStatusPill`.

### 2.3 Demo clock

Use one persisted epoch for all chapters:

- `captureEpoch`: the logical launch time for the run.
- `deviceStart = captureEpoch - 6 hours`.
- `now`: either monotonic wall time since `captureEpoch` or a deterministic accelerated clock if explicitly selected.
- Relative fixture dates, created-entry timestamps, Oura sync labels, and live elapsed durations derive from this clock.
- Relaunching a later chapter loads the same epoch; it must not reset devices to exactly six hours.
- Wall-clock discontinuities and app suspension must not make elapsed time decrease.

Persist `captureEpoch`, run ID, and checkpoint in a DEBUG-only `UserDefaults` suite such as `com.anxietywatch.full-app-demo`, not production defaults keys.

### 2.4 Appearance and accessibility

Under `-demoFullAppSequence`:

- enforce dark color scheme at the app scene/root;
- use one fixed simulator locale, calendar, timezone, content-size category, and 24/12-hour convention recorded in capture metadata;
- recommended baseline: `en_US`, Gregorian calendar, fixed US timezone, default Dynamic Type;
- assign stable accessibility identifiers to every demo control, route row, semantic scroll anchor, and evidence label;
- retain visible labels and normal accessibility semantics; identifiers are not a replacement for user-visible UI.

## 3. Fixture contracts

### 3.1 General fixture identity and isolation

All fixture records require deterministic IDs derived from a stable namespace plus a fixture key. Do not rely on insertion order or random UUIDs. The seed operation is an upsert against the demo namespace and must be safe to run repeatedly.

Required fixture groups:

- 84 daily `HealthSnapshot` rows;
- 70-day CPAP range with intentional gaps;
- recent intraday and seven-day Health samples;
- 14 nights of sleep stages;
- 30 days of barometric readings;
- completed Polar sessions and RR archive sufficient for Trends and detail charts;
- Oura read-only demo snapshot covering every rendered section;
- correlations with enough observations for non-empty charts;
- active and inactive medication definitions, doses, prescription, and active pharmacy fixture;
- five songs with deterministic artwork and lyrics;
- rich journal history and song occurrences;
- multi-point clinical lab history.

Every string that resembles identity or contact data must use the repository’s fictional values, including `Test Pharmacy #12345`, `100 Example Blvd, Anytown, ST 00000`, `555-0100`, and Rx `9999999-00001`.

### 3.2 Journal and song fixture contract

Seed exactly five catalog songs in this order:

1. In the Air Tonight — Dead When I Found Her
2. Fuck Shit Stack — Reggie Watts
3. The Man in Me — Bob Dylan
4. Mezzanine — Massive Attack
5. Tricky Kid — Tricky

Contracts:

- Lyrics are bundled and available offline.
- Capture artwork is bundled or resolved through a deterministic approved cache; no capture depends on `AsyncImage` network success.
- The Dead When I Found Her record retains the exact local metadata used by `SongSearchSheet` and is selectable under **Your Songs**.
- Remote Genius search is disabled/substituted during the full demo. The query still passes through the real search field and local filtering path.
- At least two seeded occurrences exist for “In the Air Tonight.”
- Each song has enough metadata and occurrence content to exercise its actual detail layout.

Add one featured rich journal entry with:

- stable fixture key `journal.rich-featured`;
- severity 6 or 7;
- 2–3 paragraphs of realistic but fictional prose;
- 4–6 tags;
- source context displayed by the existing detail UI;
- linked song and occurrence;
- a timestamp safely before the two entries created during the demo.

Do not include personal names, real appointments, addresses, or medical claims.

### 3.3 Multi-point lab contract

Keep the broad latest-results overview, but make one featured LOINC history materially complete. The preferred featured test is **Thyroid Stimulating Hormone**, LOINC `3016-3`, unit `mIU/L`, normal range `0.4–4.0`.

Seed six values at dates relative to the shared demo clock:

| Days before epoch | Value | Unit | Interpretation | Range |
|---:|---:|---|---|---|
| 330 | 2.40 | mIU/L | N | 0.4–4.0 |
| 270 | 2.05 | mIU/L | N | 0.4–4.0 |
| 210 | 1.88 | mIU/L | N | 0.4–4.0 |
| 150 | 1.74 | mIU/L | N | 0.4–4.0 |
| 90 | 1.69 | mIU/L | N | 0.4–4.0 |
| 2 | 1.62 | mIU/L | N | 0.4–4.0 |

Each result must have:

- a stable unique sample ID such as `demo-lab-tsh-330`;
- `sourceName = "Demo Regional Laboratory"`;
- the same unit and compatible numeric range;
- an interpretation consistent with the numeric value;
- distinct effective dates in ascending chart order.

The overview still shows only the newest value per LOINC. `LabTestHistoryView` must show:

- six chart points and a visible reference band;
- About This Test rationale;
- normal range and category;
- all six result rows, newest first;
- source, date, value, unit, and interpretation;
- a verifiable bottom marker after the last result.

Keep at least eight additional latest-only tests spanning the currently seeded categories. Additional histories are optional unless they create a materially different UI state, such as an out-of-range result. If an out-of-range fixture is added, its interpretation, color, status text, and applicable unit-specific range must agree.

### 3.4 Medication, prescription, pharmacy, and CPAP fixtures

Required states:

- Hydroxyzine 25 mg: active, PRN, anxiety prompt enabled.
- Sertraline 50 mg: active, scheduled, enough recent doses to populate recent history.
- At least one inactive medication so **Not Currently Taking** renders.
- One prescription linked to `Test Pharmacy #12345`.
- Pharmacy remains active product scope because it is reachable from `MedicationsHubView`; record list, detail, add/search, linked prescription, and log-call sheet, canceling before any external call.
- CPAP contains a newest session with populated AHI, usage, leak, pressure, event counts, overnight SpO₂, pulse, and matching day/sleep context.

### 3.5 Trends fixtures

For each chart rendered in the selected time windows, fixture coverage must avoid accidental empty states unless the empty state itself is explicitly recorded. At minimum:

- current 7-day and 30-day windows contain data;
- anxiety includes self-report and random-check-in sources;
- Polar completed sessions include selectable chart data for `PolarSessionHRDetailView`;
- LF/HF and HF power contain valid finite values only;
- glucose, oximeter, Oura, CPAP/respiratory, activity, and barometric charts are non-empty;
- correlations contain enough observations to open at least one meaningful `CorrelationChartView`.

No `.nan` or infinite chart domain/input values are permitted.

## 4. Six-hour simulated device contract

### 4.1 Shared contract

`DemoDeviceSession` represents two independent simulated sources using one start instant. It is not a `SensorSession`, does not enter SwiftData, and cannot be recovered/finalized by production recording code.

At chapter 1 launch:

- Polar status text: `Recording · 6h 00m` (allow up to 5 seconds elapsed while settling).
- EMAY status text: `Streaming · 6h 00m` or product-approved equivalent that clearly says active for six hours.
- Both surfaces visibly say `Simulated` and retain their distinct Polar H10 / EMAY source labels.
- The final Dashboard shows elapsed time strictly greater than the first Dashboard evidence.

Elapsed duration is `max(0, clock.now - deviceStart)` and never derives from a view-local timer.

### 4.2 Polar contract

Expose a read-only demo snapshot compatible with Dashboard, `RecordingStatusPill`, `PolarSettingsView`, and `HRVSessionLiveView`:

- status `.recording` in the demo provider only;
- paired name `Polar H10 (Simulated)` and deterministic fictional peripheral UUID;
- current HR varying smoothly within 58–86 bpm;
- rolling RMSSD varying smoothly within 34–58 ms;
- session start, elapsed duration, beat/interval count or other metrics currently rendered by the live view;
- deterministic waveform/value sequence based on integer seconds from epoch, not random numbers.

Recommended value generator:

```text
HR(t) = round(70 + 7*sin(t/17) + 3*sin(t/5))
RMSSD(t) = 46 + 7*sin(t/29) + 2*cos(t/11)
```

Clamp to the stated ranges. Updates may occur once per second, but the generator must produce the same value for the same demo-clock second after a chapter restart.

Prohibited in demo mode:

- `CBCentralManager` initialization that scans/connects;
- `startSession`, `stopSession`, recorder creation, Live Activity creation, or in-flight recovery;
- RR archive writes or completed-session insertion;
- destructive Stop/Unpair action. Show the controls if required, but demo choreography never activates them.

### 4.3 EMAY contract

Extend the existing synthetic streaming concept into a shared session snapshot consumed by Dashboard and `EMAYLiveView`:

- status `.streaming`;
- source `EMAY Oximeter (Simulated)`;
- SpO₂ varies smoothly within 94–99%;
- pulse varies smoothly within 57–82 bpm;
- elapsed duration uses the shared six-hour start;
- any displayed packet/sample count is deterministic and consistent with elapsed time;
- continuous-streaming preference is displayed but not persisted or toggled during capture unless backed by the demo namespace.

Recommended generator:

```text
SpO2(t) = clamp(round(97 + sin(t/23) + 0.4*cos(t/7)), 94, 99)
Pulse(t) = clamp(round(67 + 6*sin(t/19) + 2*cos(t/6)), 57, 82)
```

Prohibited:

- Bluetooth scan/connect;
- production stream persistence;
- `QuantityHealthSample`, `HealthSample`, or CNS observation writes;
- notification or alert posting.

### 4.4 Device evidence and isolation

`DemoSafetyAudit` records attempted production side effects. Tests fail if any forbidden call is attempted, even if the platform later rejects it. Required counters include BLE manager/scan/connect, HealthKit authorization/read/write, notification request/post, server request/write, external URL/call, clinical persistence, and production session creation.

## 5. Route inventory

The implementation must regenerate this inventory from source before capture and attach the completed checklist to deliverables. Status meanings:

- **INCLUDE:** exercise through the normal visible product route.
- **SHOW/CANCEL:** show boundary or confirmation and cancel before side effect.
- **READ-ONLY:** show state with a demo-safe dependency.
- **ORPHAN:** implemented view without a legitimate current product route; do not secretly push it.
- **OUT:** outside main-iPhone scope.

### 5.1 Root and Dashboard

| Route/surface | Source entry | Status | Required evidence |
|---|---|---:|---|
| Dashboard tab | `ContentView` | INCLUDE | initial and final screen |
| Polar live sheet | recording pill / Polar card | READ-ONLY | six-hour state, changing HR/RMSSD |
| Last Night → CPAP detail | Dashboard `NavigationLink` | INCLUDE | summary and detail bottom |
| Care → Lab Results | `CareSectionRowView` | INCLUDE | overview and featured history |
| Display-only vitals, glucose, activity, medication cards | Dashboard sections | INCLUDE as display | never presented as tappable |
| `GlucoseDetailView` | no current product call site | ORPHAN | include only if legitimate navigation is added |

### 5.2 Journal and Songs

| Route/surface | Source entry | Status | Required evidence |
|---|---|---:|---|
| Journal tab/list | `ContentView` | INCLUDE | complete list and bottom |
| Journal entry detail | list row | INCLUDE | featured seeded entry and newly created full entry |
| Journal edit mode | detail toolbar/action | SHOW/CANCEL | severity/tags/song fields; no fixture mutation |
| New Journal Entry | list add sheet | INCLUDE | express and full flows |
| Song search | add/edit/check-in sheet | INCLUDE | local exact-result selection |
| Songs catalog | Journal segmented/control route | INCLUDE | all five in fixture order |
| Song detail | catalog row | INCLUDE | all five; lyrics/occurrences/bottom |
| Catalog add/search sheet | catalog add action | SHOW/CANCEL | local/remote boundary; no network |
| Random check-in prompt | notification/deep presentation path | conditional INCLUDE | include if route inventory confirms a safe visible app route; otherwise document unavailable trigger |

### 5.3 Medications and care

| Route/surface | Source entry | Status | Required evidence |
|---|---|---:|---|
| Medications tab/hub | `ContentView` | INCLUDE | quick log, active/recent/inactive sections |
| Dose anxiety prompt | Log Dose for prompted medication | INCLUDE using demo mutation | PRN, severity, notes, skip interface, follow-up variant |
| Add Medication | plus sheet | SHOW/CANCEL | category, prompt default, CNS classification |
| Prescriptions list | hub link | INCLUDE | list |
| Prescription detail | list row | INCLUDE | fields and linked pharmacy |
| Add Prescription | list plus sheet | SHOW/CANCEL | form; scanner boundary |
| Prescription scanner/camera | Add Prescription | SHOW/CANCEL | scanner UI; never present real camera capture |
| Pharmacies list | hub link | INCLUDE | list |
| Pharmacy detail | list row | INCLUDE | address/phone/linked prescription |
| Add Pharmacy | list plus sheet | SHOW/CANCEL | form/search boundary |
| Pharmacy search | add sheet | SHOW/CANCEL | deterministic fictional result or empty safe state |
| Log Call | pharmacy detail sheet | SHOW/CANCEL | sheet only; no outbound call |
| CPAP list | Dashboard/Settings | INCLUDE | summary, list, bottom |
| CPAP detail | list/newest Dashboard route | INCLUDE | events, pressure, SpO₂, context, bottom |
| Add CPAP session | list sheet | SHOW/CANCEL | manual form |
| CPAP file import | list/add surface | SHOW/CANCEL | importer boundary; select no file |
| Lab Results | Dashboard and Health Records | INCLUDE once fully | overview and featured history |
| Lab test history | lab row | INCLUDE | TSH six-point contract and bottom |

### 5.4 Trends

| Route/surface | Source entry | Status | Required evidence |
|---|---|---:|---|
| Trends tab | `ContentView` | INCLUDE | materially different controls and all chart sections |
| Correlation Insights | Trends link | INCLUDE | list and bottom |
| Correlation chart | insight row | INCLUDE | at least one populated chart |
| Polar session HR detail | selectable Polar/HR chart datum | INCLUDE | deterministic night detail and bottom |
| HF/LF-HF explainer | HF Power info sheet | INCLUDE | complete explainer and bottom |
| LF/HF sessions list | no confirmed production call site | ORPHAN | include only after legitimate product navigation |
| LF/HF session detail | sessions list | ORPHAN transitively | same condition |
| Selected sleep-night detail | only if current chart exposes route | conditional | inventory must name the visible trigger |
| Glucose detail | no current product call site | ORPHAN | do not hidden-push |

Material control coverage means showing each option and recording only states that change content: 1D, 7D, 30D, 90D, Custom; All, Self-Reported, Check-Ins; and one previous-period page. The coordinator may avoid a full Cartesian product, but its route log must record each control selection at least once.

### 5.5 Settings and integrations

| Route/surface | Source entry | Status | Required evidence |
|---|---|---:|---|
| Settings root | `ContentView` | INCLUDE | top-to-bottom |
| Apple Health | Settings link | READ-ONLY | demo-safe state; no authorization prompt |
| Health Records | Settings link | READ-ONLY | summary and Lab Results link |
| CPAP | Settings link | INCLUDE or already-covered hold | route visible; avoid duplicate full traversal |
| Polar H10 | Settings link | READ-ONLY | simulated pairing, duration, resume live view |
| Polar pairing | Polar settings sheet | SHOW/CANCEL | simulated boundary only; no scan |
| EMAY live | Settings link | READ-ONLY | simulated stream, duration, text bottom |
| CNS Monitoring setup | Settings link | READ-ONLY | setup/current state without arming production services |
| CNS escalation demo | isolated labeled DEBUG destination | appendix | visibly simulated future alert; no notification/persistence |
| Oura settings | Settings link | READ-ONLY | Cloud/BLE/provenance and controls |
| View All Oura Data | Oura settings link | INCLUDE | every rendered section and bottom |
| Server Sync | Settings link | READ-ONLY/SHOW-CANCEL | status/API contract; no request/write |
| Refresh Recent Snapshots | Settings button | SHOW ONLY | do not activate |
| Rebuild All History | confirmation dialog | SHOW/CANCEL | cancel confirmation |
| Random Check-Ins settings | Settings link | READ-ONLY | frequency/active hours; no authorization or schedule |
| Export Data | Settings link | INCLUDE | ranges/formats; share boundary canceled |
| Share sheet | Export | SHOW/CANCEL | no external share destination |
| Source Code | external link | SHOW ONLY | do not activate |
| About/version | Settings root | INCLUDE | visible at bottom |

### 5.6 Excluded targets

Watch app, widgets, Live Activities, and platform authorization/settings apps are **OUT**. Camera, file picker, and share sheet may be shown only to the safe boundary described above and must not become the visual subject of a fake product route.

## 6. Exact chapter state machine

Every transition requires the listed evidence before advancement. A timeout is a failure, not permission to skip.

### 6.1 State identifiers

```text
C0.bootstrap
C1.dashboard.top
C1.polar.live
C1.emay.live
C1.dashboard.traverse
C1.dashboard.cpap
C1.dashboard.labs.overview
C1.dashboard.labs.featured
C1.complete

C2.journal.list
C2.journal.richDetail
C2.journal.edit
C2.songs.catalog
C2.songs.detail.0 ... detail.4
C2.complete

C3.journal.express.open
C3.journal.express.save
C3.journal.full.open
C3.journal.full.severity
C3.journal.full.note
C3.journal.full.tags.0 ... tags.2
C3.journal.full.songQuery
C3.journal.full.songSelect
C3.journal.full.review
C3.journal.full.save
C3.journal.full.verify
C3.complete

C4.medications.root
C4.medications.dosePrompt
C4.medications.followUp
C4.medications.add
C4.prescriptions.list/detail/add/scanner
C4.pharmacies.list/detail/add/search/logCall
C4.cpap.list/detail/add/import
C4.healthRecords.summary
C4.complete

C5.trends.root.controls
C5.trends.root.traverse
C5.trends.correlationList
C5.trends.correlationDetail
C5.trends.hfExplainer
C5.trends.polarDetail
C5.complete

C6.settings.root
C6.settings.appleHealth
C6.settings.healthRecords
C6.settings.cpap
C6.settings.polar
C6.settings.polarLive
C6.settings.emay
C6.settings.cns
C6.settings.oura
C6.settings.ouraData
C6.settings.sync
C6.settings.rebuildConfirm
C6.settings.checkIns
C6.settings.export
C6.settings.exportShare
C6.settings.aboutBottom
C6.appendix.cnsEscalation
C6.complete

C7.dashboard.final
C7.endCard
C7.complete
```

### 6.2 Transition rules

- `C0.bootstrap` verifies fixtures, safe providers, dark mode, shared epoch, and zero safety-audit violations before showing Dashboard.
- Chapter 1 begins with both device evidence labels visible. It opens Polar and EMAY through their real visible controls, returns, traverses Dashboard, then follows normal links to CPAP and Labs. Lab overview and featured six-point detail must complete before `C1.complete`.
- Chapter 2 uses the Journal tab, opens the featured entry, enters/exits edit without save, then opens Songs and visits all five rows in fixture order.
- Chapter 3 performs express save first and verifies the created row. It then performs the full typing/search/save flow and verifies persisted demo mutation fields.
- Chapter 4 follows visible links from the Medications hub. Every add/scanner/import/call surface returns by Cancel/Close/Back. Any production side-effect counter increment fails the chapter.
- Chapter 5 records control changes before the long root traversal, then reachable analytic details. ORPHAN routes are absent from the state machine unless product navigation is added and the inventory is updated.
- Chapter 6 traverses Settings and integrations. Duplicate CPAP/Labs content may use a brief route-provenance hold rather than a second complete traversal. CNS escalation is an explicitly labeled appendix state.
- Chapter 7 selects Dashboard through the real tab, scrolls to both live cards if needed, proves elapsed durations increased, and then displays the end card.

Title cards/crossfades are post-production boundaries. They may not conceal a missing route, failed back navigation, or changed device epoch.

## 7. Semantic anchors and scrolling

### 7.1 Anchor API contract

Replace fixed Y-offset automation for this demo with named anchors. Each long container exposes:

- `.top` anchor;
- one anchor per meaningful section;
- `.bottom` anchor after the final content row, not merely the last currently visible cell;
- stable accessibility identifier `demo.anchor.<screen>.<name>`.

A scroll step succeeds only when its target anchor is visible and settled for at least 300 ms. `.bottom` succeeds only when `demo.anchor.<screen>.bottom` is hittable/visible. Never issue another downward scroll after bottom succeeds.

Recommended API shape:

```swift
struct DemoScrollStop: Hashable {
    let screen: DemoScreen
    let anchor: String
    let hold: Duration
}

func traverse(_ stops: [DemoScrollStop]) async throws
```

### 7.2 Required anchor sets

| Screen | Required anchors in order |
|---|---|
| Dashboard | `top`, `risk`, `anxiety`, `lastNight`, `vitalsHero`, `vitalsGrid`, `activity`, `environment`, `medication`, `care`, `monitoring`, `bottom` (omit only sections not rendered; log omission) |
| Journal list | `top`, `featuredEntry`, `olderEntries`, `bottom` |
| Journal detail | `top`, `severity`, `notes`, `tags`, `song`, `metadata`, `bottom` |
| Song catalog | `top`, `song.0`…`song.4`, `bottom` |
| Song detail | `top`, `artworkMetadata`, `lyrics`, `occurrences`, `bottom` |
| Medications | `top`, `quickLog`, `navigation`, `recentDoses`, `inactive`, `bottom` |
| CPAP list | `top`, `summary`, `newest`, `olderSessions`, `bottom` |
| CPAP detail | `top`, `usageAHI`, `events`, `pressure`, `spo2`, `dayContext`, `bottom` |
| Labs overview | `top`, each rendered category, `bottom` |
| Featured lab | `top`, `chart`, `about`, `results`, `oldestResult`, `bottom` |
| Trends | `top`, `controls`, one anchor per rendered chart card, `correlations`, `bottom` |
| Correlations | `top`, `strongest`, `remaining`, `bottom` |
| Settings | `top`, `dataSources`, `syncData`, `checkIns`, `reports`, `about`, `bottom` |
| Polar/EMAY live | `top`, `status`, `metrics`, `controls`, `explanation`, `bottom` as applicable |
| Oura data | `top`, `daily`, `sleep`, `recovery`, `stress`, `activity`, `oxygenRespiration`, `cardiovascular`, `liveRing`, `bottom` |
| Export | `top`, `dateRange`, `formats`, `actions`, `bottom` |

For conditional sections, generate the stop list from rendered fixture capabilities before traversal. Missing a required fixture-backed anchor is a test failure.

## 8. Journal creation choreography

### 8.1 Express entry

1. Activate the visible New Entry control.
2. Confirm Express Mode is on and hold 1 second.
3. Activate severity 3 or 4 through the semantic button action.
4. Hold the pressed/selected visual state long enough to capture; the implementation may delay the save callback by 350–500 ms in demo mode, without changing production behavior.
5. Verify sheet dismissal and a new row with stable mutation key `created.express`.
6. Hold the row for 2 seconds.

### 8.2 Full entry

1. Reopen New Entry and turn Express Mode off through the visible toggle.
2. Select 7/10 and verify its selected accessibility value.
3. Focus the notes editor; require software keyboard visibility.
4. Type exactly:

   `Woke up tense after a restless night. My chest feels tight and I keep replaying tomorrow’s appointment, but slow breathing and a short walk are helping.`

5. Character delay is deterministically generated from the run ID in the range 55–140 ms. Add 180–320 ms after commas and 350–550 ms after sentence punctuation. Do not paste or assign the final string wholesale.
6. Add tags in order: `poor sleep`, `appointment`, `walk`. For each tag: focus field, type with the same engine, activate the visible Add/Submit affordance, verify the chip, then continue.
7. Open `SongSearchSheet`, focus its search field, and type `In the Air Tonight` with the same engine.
8. Wait until the **Your Songs** local result with exact title and artist is visible. Assert remote provider invocation count is zero.
9. Activate that exact row semantically. Verify selected song title, artist, and artwork on the entry form.
10. Dismiss the keyboard, show the entry timestamp, traverse to the form bottom, and activate Save.
11. Verify the created detail contains severity 7, exact note, all three tags in order, source/timestamp, and the linked Dead When I Found Her song.

If keyboard visibility, focus, exact text, local-result identity, or save verification fails, stop rather than repairing invisibly.

## 9. Safety matrix

| Capability/action | Demo behavior | Forbidden evidence | Enforcement |
|---|---|---|---|
| Polar Bluetooth | simulated provider | central manager, scan, connect, recovery | injected no-op/spy dependency; zero audit count |
| EMAY Bluetooth | simulated provider | scan/connect/packet persistence | injected no-op/spy dependency |
| HealthKit reads/backfill | fixture-only during capture | authorization/read queries, snapshot refresh | demo coordinator suppresses startup refresh/auto-sync |
| HealthKit writes | never | any save/write | unavailable dependency plus audit trap |
| Health Records authorization | read-only demo state | system authorization prompt | demo status provider |
| Notifications/check-ins | show settings only | request permission, schedule, post | no-op/spy scheduler |
| CNS monitoring | isolated read-only simulation | arm production coordinator, BLE, persistence, alert post | demo CNS provider |
| Server sync/restore/repair | status-only | URL request or DB mutation | offline demo sync client; confirmations canceled |
| Oura Cloud/BLE | deterministic snapshot | token mutation, network, BLE | demo Oura service |
| Genius | local search only | remote request | demo search client fails test on invocation |
| Artwork | bundled/cache | network dependency during capture | preflight cache verification/network disabled test |
| CPAP import | show/cancel | file read/import | cancel before selection |
| Prescription camera | show/cancel | camera capture/library import | simulator-safe boundary |
| Export | generate only if deterministic and local; share canceled | external destination/share completion | share boundary spy |
| Pharmacy call | show/cancel | `tel:` open | external URL spy |
| Source Code | show row only | browser open | never activate; URL spy |
| Refresh/Rebuild | show only/cancel | aggregation/mirroring | buttons disabled or action intercepted in demo |
| Destructive delete/deactivate/unpair/stop | never | model/device mutation | coordinator excludes activation; audit assertions |
| Journal demo creation | isolated namespace only | duplicate or production sync eligibility | mutation store/upsert contract |

The app must suppress Dashboard/Trends startup tasks that call HealthKit aggregation or server auto-sync while full-demo mode is active. Merely avoiding visible buttons is insufficient.

## 10. Idempotent mutations and checkpoints

### 10.1 Mutation model

Demo-created journal entries are real app model objects rendered by normal queries, but belong to an isolated demo namespace and are excluded from production sync. Use deterministic identity keys:

- `created.express`
- `created.full`
- optional `created.dosePrompt`

Before a chapter starts, reconcile each key to its expected precondition:

- Chapter 3 start: delete/revert only previous demo-created entries and occurrences, never baseline fixtures or user data.
- After express save: exactly one express entry.
- After full save: exactly one express and one full entry.
- Resume after save: reuse/upsert the existing deterministic record; never insert a duplicate.

If models lack a demo namespace field, use a DEBUG-only sidecar mapping keyed by stable model IDs. Do not overload clinical `source` labels in a way that could leak into production semantics.

### 10.2 Checkpoint contents

Persist after every state transition:

- schema version;
- run ID and capture epoch;
- chapter and step ID;
- selected tab;
- route path/sheet identity needed to restore to a recognizable start;
- completed semantic anchors;
- mutation reconciliation state;
- initial and latest device elapsed evidence;
- fixture manifest hash;
- safety-audit counters;
- last successful screenshot/frame timestamp.

Do not serialize arbitrary SwiftUI navigation internals. Resume by restoring data/state, selecting the documented chapter start tab, and visibly navigating from that recognizable location.

### 10.3 Chapter restart behavior

- Restarting a failed chapter preserves epoch and completed prior chapters.
- It resets only that chapter’s transient navigation and reconciles that chapter’s demo mutations.
- Device values resume deterministically at the current shared-clock second.
- A fixture manifest mismatch invalidates checkpoints and requires `-demoReset`.
- A safety violation permanently fails the run; it cannot be cleared by resuming.

## 11. Acceptance tests

Use Swift Testing for unit/state tests and UI tests for focus, navigation, scrolling, and capture evidence. All tests must use fictional data.

### 11.1 Fixture tests

1. Seeding twice produces identical counts and stable IDs.
2. Exactly five required songs exist in specified order; lyrics and approved artwork resolve offline.
3. Local query `In the Air Tonight` returns exactly the intended local title/artist as the selectable target without Genius invocation.
4. Featured TSH history has exactly six distinct dates, values listed in this spec, `mIU/L`, range 0.4–4.0, `N`, and fictional provenance.
5. Lab overview returns only newest TSH value 1.62 while detail returns all six ascending for chart/newest-first for rows.
6. Rich journal entry meets paragraph/tag/song/source requirements.
7. Every fixture-backed Trends chart has finite, non-empty input in required windows.
8. Active/inactive medication, prescription/pharmacy linkage, and newest CPAP detail fields exist.

### 11.2 Device tests

1. At epoch, both elapsed values equal six hours; after simulated advancement they increase equally and never decrease.
2. Relaunch/checkpoint restoration yields the same HR/RMSSD/SpO₂/pulse for the same logical second.
3. Generated values stay within contract ranges and change over a sampled two-minute window.
4. Dashboard, pill, Polar settings/live, and EMAY live consume the same start instant and source identity.
5. No production `SensorSession`, observation, or RR archive row is inserted.
6. BLE, HealthKit, notification, and persistence audit counters remain zero.

### 11.3 Coordinator/state tests

1. Every state has one documented successor or terminal outcome.
2. Advancement requires its evidence token; timeout/mismatched screen fails.
3. ORPHAN routes never appear in the executable state graph.
4. Restart from every chapter checkpoint preserves epoch and reconciles mutations.
5. The final state requires final elapsed > initial elapsed and zero safety violations.
6. Dark appearance and fixed environment are active in every chapter.

### 11.4 UI tests

1. Each INCLUDE route is reached by its visible tab/link/button/sheet trigger.
2. Every long view reaches its named bottom marker exactly once without overscroll.
3. Express severity shows selection, dismisses, and produces one visible row.
4. Full entry types character-by-character with focus and keyboard visible; exact resulting fields are verified.
5. Song search selects exact local title/artist and shows deterministic artwork.
6. Lab overview exposes several tests; featured detail exposes chart, About, normal range, six result rows, and bottom.
7. All five song details reach their own bottom markers.
8. Trends control options are activated and logged; reachable details open; orphan routes are absent.
9. Unsafe boundaries cancel and leave audit counters zero.
10. Final Dashboard shows both simulations still active and elapsed beyond initial evidence.

### 11.5 Regression tests

- Normal launches without `-demoFullAppSequence` use existing production services and appearance.
- Existing screenshot/demo arguments retain their prior behavior.
- Demo namespace records are not exported or synced.
- No new compiler warnings, SwiftLint failures, Semgrep failures, or iOS 26 render regressions.

## 12. Capture and verification procedure

### 12.1 Preflight

1. Use the retained iPhone 17 simulator installation.
2. Build/test through XcodeBuildMCP.
3. Confirm commit hash and clean intended working tree.
4. Launch a preflight run with network disabled after any deterministic cache is prepared.
5. Assert fixture manifest/hash, dark appearance, locale/timezone, artwork, lyrics, six-point lab history, and zero safety counters.
6. Confirm no personal simulator notifications, photos, files, contacts, or clipboard content can appear.
7. Confirm available storage and recording resolution/frame rate.

### 12.2 Chapter capture

For each chapter:

1. Launch/resume with the same run ID and epoch.
2. Record a 2–4 second recognizable start hold.
3. Execute only coordinator-approved semantic actions.
4. Capture evidence frames for required states and bottom markers.
5. Stop recording only after the chapter terminal checkpoint is persisted.
6. Record chapter filename, logical start/end, safety counters, and device elapsed values in a manifest.

Recommended filenames: `01-dashboard-devices.mp4` through `07-close.mp4`, with `06b-cns-simulated-appendix.mp4` kept separable.

### 12.3 Automated media validation

For every chapter and the concatenated master:

- `ffprobe` confirms readable video/audio streams, duration, dimensions, frame rate, and no zero-duration segment;
- sample first/last frames and every 5–10 seconds;
- OCR checks expected screen titles, `Simulated`, source labels, `6h`, song title/artist, lab title/range, and final disclaimer;
- contact sheets verify navigation continuity, dark mode, keyboard states, bottom holds, and absence of blank frames;
- detect duplicate adjacent frames long enough to suggest a hang;
- inspect crossfades for concealed jumps or transient light-mode frames.

### 12.4 Human review checklist

Reject and recapture if any of the following occurs:

- personal/private data appears;
- artwork or lyrics are missing;
- typing contains an error, paste-like instant insertion, or hidden keyboard when required;
- wrong song/artist is selected;
- a display-only card appears to be activated;
- a view stops short of its verified bottom or rubber-bands;
- device duration resets/decreases or source provenance is ambiguous;
- real authorization, Bluetooth, notification, network, call, browser, file import, or destructive action occurs;
- a chart is empty, clipped, uses invalid values, or visibly hangs;
- chapter joins produce blank/light frames or abrupt unexplained root changes.

### 12.5 Deliverables

- concatenated master MP4;
- all chapter MP4s, including separable CNS appendix;
- generated route inventory with final statuses and omission rationales;
- fixture manifest and hash;
- checkpoint/capture manifest with run ID, epoch, durations, and zeroed safety audit;
- contact sheets and OCR/media validation report;
- exact commit hash.

## 13. Definition of done

Implementation is complete only when:

1. All INCLUDE routes in the regenerated inventory pass UI coverage.
2. Every long view has a semantic bottom marker and successful one-time traversal.
3. Featured lab history satisfies the exact six-point contract.
4. Polar and EMAY begin at six hours, change deterministically, remain visibly simulated, and continue through the final Dashboard.
5. Both journal creation flows and exact local song selection pass.
6. Chapter restart is idempotent and preserves the shared epoch.
7. All safety counters remain zero.
8. Relevant unit/UI tests, build, lint, and static analysis pass without warnings.
9. Capture verification and human privacy review pass.

## 14. Unresolved implementation choices

These choices do not block the specification, but must be recorded in the implementation PR before capture:

1. **Fixed environment:** exact timezone and 12/24-hour convention for the shared demo clock.
2. **Clock policy:** real-time monotonic progression versus a deterministic accelerated clock between chapter checkpoints; either must preserve increasing elapsed duration.
3. **Demo storage:** separate SwiftData store/container versus stable-ID sidecar namespace in the retained app store. A separate store provides stronger isolation; a sidecar minimizes app plumbing.
4. **Device adaptation:** a formal protocol injected into existing Polar/EMAY consumers versus narrowly gated snapshot adapters. Prefer protocols if production service construction can be avoided cleanly.
5. **Dashboard device layout:** extend current Polar/monitoring cards or add a source-specific live-devices section so both duration/provenance requirements are truthful.
6. **Pharmacy search fixture:** deterministic fictional result versus recording the safe empty state.
7. **Random check-in prompt:** include only if the regenerated inventory identifies a safe, visible trigger that does not schedule or post a notification.
8. **Orphan analytics:** whether to add legitimate product navigation for glucose and LF/HF session details. If not, they remain documented ORPHAN routes.
9. **Out-of-range lab example:** optional additional history for a materially different state; the required TSH history remains normal and coherent.
10. **CNS appendix placement:** append after Settings or deliver only as a separate optional chapter; it must remain explicitly simulated future-alert behavior.
