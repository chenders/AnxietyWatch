# Anxiety Watch Full-App Demo Plan

## Objective
Produce a dark-mode, deterministic, fictional-data walkthrough that exposes as much meaningful app functionality as practical while remaining understandable. The recording must begin on Dashboard, use visible user-like navigation, scroll every long view to its true bottom once, and avoid mouse/coordinate injection, rubber-banding, and abrupt root replacement.

## Safety and demo isolation
- Launch only with DEBUG demo arguments and preserve the installed simulator app/HealthKit authorization.
- Polar H10 and EMAY are explicit simulated live sources, each showing a six-hour active recording at launch with believable changing vitals and session metrics.
- Simulated devices must never start CoreBluetooth, write HealthKit, post real alerts, or persist fabricated clinical observations as production data.
- Oura Cloud, Oura BLE, Apple Health, EMAY, Polar H10, CPAP, and demo provenance remain visibly distinct.
- Use dark mode and deterministic fictional data throughout.

## Recording architecture
Scope is the **main iPhone app**. Watch, widgets, and Live Activities are separate targets and require separate appendix recordings if requested; they are not silently represented as iPhone views.

A single uninterrupted movie would likely exceed 8–12 minutes and become difficult to verify. Capture one master walkthrough in chapters, then concatenate them with short title cards/crossfades. Each chapter starts from a recognizable app location and uses visible tabs, links, sheets, and back navigation. Also retain chapter files for review.

Use SwiftUI-owned demo choreography:
- semantic route state rather than coordinate taps;
- `ScrollPosition` with finite precomputed stops and exactly one final bottom stop;
- visible pressed/selection/typing states;
- human-paced text insertion (variable 55–140 ms per character, longer punctuation pauses);
- 2–4 second holds on important screens and 1–2 second holds at the bottom of detailed screens.

## Proposed sequence

### 1. Dashboard and live devices
1. Launch to Dashboard with 84-day demo history.
2. Show top status and summary.
3. Polar H10 card: **Recording · 6h 00m**, live HR/HRV and source label.
4. EMAY card: **Streaming · 6h 00m**, SpO2/pulse and source label.
5. Open the Polar live view and EMAY live view once near the beginning, showing changing source-specific values and six-hour continuity, then return without stopping either simulation.
6. Slowly traverse every Dashboard section to the true bottom: risk, last anxiety, sleep/CPAP, Oura context, vitals, activity, medication, care, environment, and monitoring.
7. Open each genuinely tappable Dashboard detail surfaced by seeded data and traverse it. Do not imply that a display-only card is tappable; implemented-but-unreachable destinations are classified separately in the route inventory.

### 2. Journal read paths and Songs
1. Open Journal and traverse the complete list.
2. Open a rich seeded journal post with a multi-paragraph realistic note, 4–6 tags, linked song, and source context; show severity, full note, tags, linked song, logged date, then bottom.
3. Enter Edit briefly to expose editable severity/tags/song fields; exit without changing fixture data.
4. Open Songs from Journal.
5. Traverse the requested five-song catalog.
6. Open every song detail in catalog order; show artwork/metadata, lyrics, occurrence history, and one clean bottom stop, then return.

### 3. Journal creation
1. Open New Entry with Express Mode on; pause over controls.
2. Tap a low/moderate severity to demonstrate instant express save and return to Journal. Hold visibly on the newly created row so the save cannot be mistaken for a dismissal.
3. Open New Entry again.
4. Turn Express Mode off; select anxiety **7 / 10**.
5. Human-type: “Woke up tense after a restless night. My chest feels tight and I keep replaying tomorrow’s appointment, but slow breathing and a short walk are helping.”
6. Add realistic tags such as `poor sleep`, `appointment`, and `walk`.
7. Open song search; visibly focus the search field and human-type “In the Air Tonight”; choose the exact **local** result **In the Air Tonight — Dead When I Found Her** with its real cover artwork. Do not invoke remote Genius during capture.
8. Show selected song and timestamp, scroll to bottom, save.
9. Open the newly created post to verify every field and linked song.

### 4. Medications and care records
1. Traverse Medications top to bottom: quick log, active medications, recent doses, inactive medications.
2. Open each available detailed record/view: prescriptions, prescription detail, dose anxiety prompt (including PRN, severity, notes, skip, and follow-up variants), and add-medication interface (category, anxiety-prompt default, CNS classification; cancel without saving).
3. Pharmacy is explicitly reconciled before capture. If retired, remove/omit its unreachable legacy views and document that decision; if active, include pharmacy list/detail, add/search, linked prescription, and log-call sheet without placing a call.
4. Open CPAP sessions, summary, newest session detail, events, pressure, overnight SpO2, and day context to bottom; expose manual-add and file-import boundaries, then cancel.
5. Open Lab Results and clearly hold on the recent-results overview long enough to read several values, dates, status text, and source provenance. Numeric reference ranges are shown in the detailed history view unless the overview product UI is intentionally enhanced.
6. Open at least one richly populated lab result (prefer the newest result with multiple historical points), then traverse its **About This Test** explanation and complete **Results** history to the true bottom. Open additional seeded lab histories when they add materially different content.
7. Show Health Records summary where available.

### 5. Trends and analytic drill-down
1. Traverse Trends for every available time window/source control state needed to expose materially different content.
2. Show anxiety, heart rate, HRV/RMSSD/HF/LF-HF, sleep/respiratory, glucose, activity, weather/barometric, Oximeter, Polar, Oura, and correlations.
3. Open all genuinely reachable analytic detail destinations, including correlation insights/charts, HF/LF-HF explainer, and Polar session HR detail. LF/HF session list/detail, selected sleep-night detail, glucose detail, or other currently orphaned destinations are included only after adding legitimate product navigation; otherwise classify them as implemented-but-unreachable without hidden DEBUG pushes.
4. Use one deterministic top-to-bottom pass per long destination.

### 6. Settings and integrations
1. Traverse Settings from top to bottom.
2. Apple Health settings and authorization state.
3. Health Records settings.
4. CPAP settings/import surface if linked.
5. Polar H10 settings: paired simulated device, **Recording for 6 hours**, resume live view; traverse live metrics/session details to bottom; return without stopping.
6. EMAY Oximeter settings/live view: simulated connected/streaming state, **Recording for 6 hours**, live SpO2/pulse, continuous-streaming control and explanatory text to bottom; return without stopping.
7. CNS Monitoring setup and completed escalation demo if appropriate as a short appendix.
8. Oura Ring settings: simulated Cloud and BLE/source state, connection controls, HealthKit bridge, synchronization metadata.
9. Open **View All Oura Data** and traverse all daily score, sleep, recovery, stress, activity, oxygen/respiration, cardiovascular, and live Ring sections to bottom.
10. Check-in settings, server sync/status/API contract, export/report interface, About/version, and other non-destructive settings destinations.

### 7. Close
1. Return visibly to Dashboard.
2. Hold on the still-recording Polar and EMAY cards, now showing elapsed time greater than six hours.
3. End card: “Fictional demo data · Simulated devices · No medical diagnosis.”

## Detailed-view coverage rule
Before implementation, generate a route inventory from all `NavigationLink`, `navigationDestination`, `sheet`, and full-screen presentation call sites. Mark each route as:
- included;
- destructive/unsafe (show interface but cancel);
- unavailable in simulator (replace with clearly labeled isolated mock surface);
- retired/out of scope (omit with rationale).

No detail route with meaningful seeded content is omitted silently. Camera scanning, outbound phone calls, destructive unpair/stop actions, real server writes, and real authorization prompts are not executed.

## Implementation work
1. Add a DEBUG `FullAppDemoCoordinator` state machine and launch argument (proposed `-demoFullAppSequence`).
2. Add deterministic demo-route hooks to existing views rather than a parallel fake app.
3. Add a shared simulated-device clock/session model with six-hour initial elapsed duration and smooth Polar/EMAY fixtures. Never represent simulation by opening a production `SensorSession`.
4. Make existing Dashboard, Polar settings/live view, EMAY settings/live view consume explicit demo snapshots only under the launch argument.
5. Drive journal note, tag, and song-query typing through focused controls with the software keyboard visible, deterministic variable keystroke delays, punctuation pauses, visible Add actions, and keyboard dismissal before scrolling/saving. Use the exact local Dead When I Found Her result.
6. Replace offset-only scrolling with named semantic anchors plus a verifiable final bottom marker for every long list/detail.
7. Create an isolated/idempotent demo mutation model so retakes do not duplicate journal entries while preserving the app install and HealthKit authorization.
8. Create chapter checkpoints backed by one shared demo epoch so device durations and relative dates remain continuous across chapter launches.
9. Bundle or deterministically cache approved artwork used in capture.
10. Seed 4–8 coherent historical values for at least one featured lab test, with consistent units, dates, numeric reference ranges, interpretation, and fictional provenance.
11. Enforce dark appearance for every chapter under the demo contract rather than relying on retained simulator state.
12. Add UI/state tests asserting route order, simulated provenance, six-hour durations, journal creation, song selection, lab-history fixture depth, dark appearance, and no real service activation.

## Verification and deliverables
- Build and test with XcodeBuildMCP.
- Record in dark mode on the retained iPhone 17 simulator installation.
- Validate each chapter with `ffprobe`, sampled frames, OCR, and contact sheets.
- Specifically assert visible evidence of: both six-hour sessions, every alert/source label, rich journal detail, express save, non-express typed note, selected Dead When I Found Her song/artwork, every song detail, the Lab Results overview plus at least one complete lab detail/history view, every Oura section, and final Dashboard return.
- Inspect final concatenation for blank frames, keyboard mistakes, clipped text, overscroll, repeated gestures, missing artwork, abrupt navigation, or accidental private data.
- Deliver master MP4, chapter MP4s, route-coverage checklist, contact sheets, and the exact commit hash.
