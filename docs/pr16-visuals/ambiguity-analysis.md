# PR #16 newcomer ambiguity analysis

**Role:** Visual Director (GPT-5.6 Luna substitution; Claude Opus unavailable)
**Scope:** Pre-implementation review only. No PR-body edit, asset publication, or final visual production in this phase.
**Source reviewed:** PR #16 body as returned by `gh pr view 16 --json body`; implementation files listed in `evidence-ledger.md`; `PR16_VISUAL_AIDS_HANDOFF.md` and all mandatory cold-start documents. `PROJECT_FUTURE_PLAN.md` was not read.

## Executive assessment

The PR body is accurate but presents four different kinds of change in one linear list: architecture, source/provenance behavior, visual redesign breadth, and safe demo limitations. A newcomer can understand individual bullets but cannot reliably answer three high-value questions:

1. **What is connected to what?** The body names iPhone, watch, `AnxietyWatchKit`, sensors, HealthKit, Oura, CNS, storage, WatchConnectivity, and server sync without showing boundaries or direction.
2. **Which data is real, imported, cloud-derived, hardware-dependent, or fictional?** The Oura and demo bullets are correct, but the distinctions are distributed across two sections and are easy to collapse into “all metrics come from the ring” or “the demo is production monitoring.”
3. **How broad is the redesign in the actual UI?** The body lists Dashboard, Trends, labs, songs, journal, and dark-mode routes, but gives no compact visual index. A newcomer may infer that the comprehensive walkthrough coordinator is complete, despite the explicit follow-up caveat.

The minimum sufficient visual response is therefore three aids, each answering one question. More than three risks turning the PR into an asset gallery instead of a review document.

## Material ambiguities and resolution

| PR concept | Newcomer confusion | Risk | Visual resolution |
|---|---|---:|---|
| Integrated architecture | “AnxietyWatchKit” may be read as a UI module rather than shared pipeline/storage/transport foundation; server sync may be confused with HealthKit import. | High | Architecture/data-flow diagram with separate source, processing, app, persistence, transport, and server zones; arrows are labeled. |
| Oura integration | Cloud summaries, HealthKit bridging, feature-gated BLE, and simulator/demo data may be conflated; Ring 5 support may sound production-validated. | High | Provenance diagram with explicit source lanes and a hardware-dependent boundary. |
| CNS demo | “Critical CNS alert” can be read as a real notification or a clinical claim; demo controls may look like production monitoring. | High | Same provenance/safety diagram, with a visually distinct isolated demo boundary and explicit negative claims. |
| Simulated Polar/EMAY | Six-hour sessions may be interpreted as live hardware recordings or persisted sensor data. | High | Provenance diagram: simulated sessions are labeled, hardware-free, persistence-free, no HealthKit, no production `SensorSession`. |
| UI redesign breadth | Long recordings are difficult to scan and may imply a complete route; isolated screenshots lack a cohesive index. | Medium | Static labeled contact sheet, not a video. Include a “representative surfaces; not comprehensive walkthrough” caption. |
| Deterministic fixtures | A reader may mistake fictional values and names for author/user data. | Medium | Montage caption and provenance legend label fixtures as fictional/deterministic. |
| Follow-up scope | Existing prose says a full-app plan/spec exists and also says the coordinator remains incomplete. | High | Montage must not depict a complete sequence; caption explicitly bounds the aid to representative surfaces and retains follow-up wording in prose. |
| Clinical framing | Oura scores and CNS tiers could be interpreted as diagnosis or medical certainty. | High | Use neutral labels and caution copy; no “diagnosis,” “validated alarm,” or “clinical result” language. |

## What does not need a visual aid

- Individual GRDB migration, HLC, retention, or sync implementation details: linkable code and tests are sufficient once the architecture diagram establishes the layer.
- Every redesigned screen: a contact sheet of representative surfaces is sufficient; a full gallery would dilute the review.
- A full-app walkthrough video: explicitly deferred because the comprehensive coordinator and remaining route choreography are follow-up work.
- Oura protocol/decryption detail: the PR claims a feature-gated foundation and hardware-dependent validation, not a completed protocol demonstration. A visual must not imply more.
- A CNS escalation video: the existing local recording is useful source material for later review, but motion is not needed to communicate the safety boundary and would increase misinterpretation risk.

## Reader journey the aids must support

1. **Orientation:** “This is a layered app/data system, not one undifferentiated sensor stream.”
2. **Trust calibration:** “I can tell which source and execution mode produced each value, and what is not production behavior.”
3. **Scope recognition:** “The redesign is broad and coherent, but the PR does not claim that every planned walkthrough is finished.”

## Acceptance criteria for implementation

- Each aid has a visible title, a concise caption, and a meaningful text alternative.
- No color-only distinction; every source/status uses labels and/or shape.
- Source labels use the exact terms: Oura Cloud, Oura BLE, Apple Health, CPAP, Polar H10, EMAY, and fictional demo data.
- The CNS boundary says it does not arm production monitoring or send a real alert/notification.
- Simulated Polar/EMAY boundary says no production BLE activation, open production `SensorSession`, HealthKit write, or persistence as real readings.
- The Oura boundary says Ring 5 BLE decryption/protocol/key validation remains hardware-dependent and requires appropriate key provisioning.
- Montage does not claim the comprehensive full-app walkthrough coordinator is complete.
- All displayed health data is fictional/deterministic and contains no personal data.
