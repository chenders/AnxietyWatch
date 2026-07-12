# CNS-Depression Early-Warning Klaxon — Design Spec

**Status:** Draft for review · **Date:** 2026-07-09
**Setting name (user-facing):** "Klaxons if CNS depressant danger level is approaching"

## 1. What this is (and what it is not)

An **opt-out (on by default)** safety feature. When the app detects physiological signs that the user is *trending toward* dangerous CNS depression (opioid / benzodiazepine over-sedation), it escalates through a local alert sequence ending in a **loud klaxon** that continues until the user clears it with a deliberate **slide-to-dismiss** gesture.

### Honesty framing (non-negotiable)

This is an **early-warning** aid, **not** an overdose rescue or a medical device. In a *true* overdose the person is unrousable and no alarm will wake them; the only value an alarm can add is (a) catching the *decline* while the user is still rousable, or (b) alerting a person physically nearby. Every piece of user-facing copy must say this plainly. No wording may imply detection of, or protection against, a completed overdose.

### Hard non-goals (explicit user constraints)

- **No automated outbound emergency communication — ever.** No 911 / emergency-services call, no automatic call / SMS / push to any contact. The mechanism is a **local** alarm only. "Escalation" means louder / more-persistent *local* alert, never external notification.
- Not a diagnostic. Not a substitute for naloxone, supervision, or medical care.

## 2. Threat model & primary scenario

Highest risk: after a CNS-depressant dose, especially overnight while asleep and unobserved. The user's sensor loadout is **unpredictable** — sometimes nothing, sometimes Apple Watch, sometimes Polar H10, sometimes an oximeter, in any combination, and any device can run out of battery mid-session. The design must degrade gracefully across the entire matrix and never *silently* stop protecting.

## 3. Clinical basis (evidence-grounded thresholds)

Opioids depress the **respiratory rate** (brainstem µ-receptors); benzodiazepines reduce **tidal volume** (not necessarily rate). Combined, they are the classic lethal synergy. Consequences:

- **Respiratory rate (bradypnea)** is the most specific opioid sign, but **RR alone misses benzo-dominant depression** (shallow breathing at a normal rate). Therefore **SpO₂ is essential** — it catches both, and is the single most predictive continuous signal.
- The **PRODIGY** trial defined *terminal* respiratory-depression episodes (RR ≤ 5, SpO₂ ≤ 85%, apnea > 30 s) and — critically — found that **multiple such episodes precede** a clinical adverse event. This validates the early-warning approach: watch the **trajectory** and alert well *above* those terminal floors, while the user is still rousable.

### The confound (central design problem)

The target user population includes people with **sleep apnea who use a CPAP** (a population this app explicitly supports — see the CPAP integration). For such users, overnight SpO₂ desaturations and sleep bradycardia are **normal**. A naïve absolute-threshold alarm would fire on ordinary apnea events every night → alarm fatigue → feature disabled → no protection. Therefore detection is **deviation-from-personal-baseline** (leveraging the existing `BaselineCalculator` rolling baselines), with absolute floors used **only** as a hard backstop set *well below* the user's own normal nadir. CPAP data is **not** real-time (SD-card / myAir cloud), so it cannot gate detection live; its role is to inform the personal baseline offline.

### Working thresholds (early-warning, baseline-relative; to be tuned)

These are starting points for the detection model, deliberately *above* PRODIGY's terminal floors so the alert fires on the *approach*:

| Signal | Watch-window / early-warning trigger (sustained ≥ ~60–90 s) | Notes |
|---|---|---|
| SpO₂ | sustained below min(88%, personal-nadir − N) | absolute backstop well under a personal apnea-inclusive baseline |
| Respiratory rate | sustained < ~8–10 /min, or a sharp downward trend vs baseline | opioid-dominant sign; benzo may not show here |
| Heart rate | sustained bradycardia vs personal baseline | corroborating, not primary |
| HRV | acute collapse vs baseline | corroborating |

> **Erratum (Phase 1, 2026-07-09):** the SpO₂ trigger originally read `max(88%, nadir − N)`;
> for an apnea-lowered nadir that puts the trigger *above* the user's normal nightly dips —
> the exact nightly-false-alarm failure this section's confound paragraph forbids. Implemented
> (and corrected here) as `min` — see `CNSThresholds.spo2Onset(nadirBaseline:)` and
> `docs/plans/klaxon-phase-1-detection-engine.md` § "Spec erratum". The same degenerate-ramp
> hazard applies one level deeper wherever a personalized onset can cross a fixed severity
> floor: the implementation scales the floor with the onset (`spo2Ramp`, `heartRateRamp`)
> rather than clamping the onset to the floor.

## 4. Sensor inventory & real-time capability

| Source | Real-time? | Signals | Notes |
|---|---|---|---|
| Apple Watch | HealthKit (latency; SpO₂ is periodic **spot-checks**, not continuous) | HR, HRV (sparse), resp-rate (sleep), SpO₂ spot | broadest availability; weakest for continuous SpO₂ |
| Polar H10 | **live BLE** (`PolarHRMService`; `bluetooth-central` bg) | HR, RR-intervals/HRV | excellent HR/HRV; no SpO₂ |
| EMAY SleepO2 | **live BLE — now supported** (`EMAYRealtimeService`, this project) | continuous SpO₂ + pulse | reverse-engineered + verified; the best continuous SpO₂ we have |
| PLX-standard oximeter (e.g. Nonin) / Wellue O2Ring | live BLE (future adapter) | continuous SpO₂ + pulse | standards-first ingestion; O2Ring also has its own desat vibration |
| CPAP (ResMed) | **not** real-time | resp events, leak | baseline-informing only (SD/cloud); BLE `FD56` is a separate future spike |

**Real-time respiratory rate** is the weakest link on a Watch-only night (spot SpO₂ + sparse RR); a continuous oximeter (EMAY / PLX / O2Ring) materially raises sensitivity. The engine must run on whatever is present and be honest about reduced sensitivity when it isn't.

## 5. Detection engine

### 5.1 Per-signal validity × severity scoring

Each signal, **only when its source is connected and reporting physiologically plausible data**, contributes:
- a **severity** score 0–1 (how far toward danger, baseline-relative), and
- a **confidence** weight 0–1 (sample density, contact stability, source fidelity).

Invalid / no-finger / artifact samples contribute nothing (never coerced to a value).

### 5.2 Cross-sensor fusion (deliberately not over-aggressive)

- A **lone** sensor screaming while others read normal → low confidence (likely artifact: off-finger, motion, contact loss) → raises *watchfulness*, does **not** klaxon alone.
- **Multiple independent** signals trending toward danger → confidence compounds → escalate.
- A single sensor may escalate **only** if its reading is both extreme **and** passes strict validity (stable contact, physiologically coherent, sustained).

This yields a composite **risk score** (0 = clear → 1 = imminent) with an explicit **"insufficient data"** state when nothing capable is reporting.

### 5.3 Risk score → alert tiers

`clear → watch → confirm → klaxon`. Thresholds hysteretic (must sustain to rise, decisively clear to fall) to avoid flapping.

## 6. Activation & gating

Monitor **only when risk is real** (kills false positives, saves battery). Settings offer a **multi-select** (pick any combination that makes sense):

- **Auto-detect sleep** (iOS/HealthKit sleep state) — offered only if reliable enough on-device.
- **Manual "I'm going to sleep"** button.
- **After a logged CNS-depressant dose** — the app already logs clonazepam doses; monitor through the pharmacokinetic risk window. Most *specific* trigger (a depressant is actually onboard); composes with sleep.
- **Ad-hoc "monitor me now"** — start any time (e.g. "took too much, just realized"), independent of sleep/day.

### Companion mode (per-monitor-start)

At each start, the user may mark **"someone is here who would hear the klaxon."** This adjusts strategy: with a companion present the klaxon is an *effective* intervention (someone can act), so the tier timing can lean on it; **alone**, the system fires **earlier** (while the user is still rousable) and leans harder on watch haptics. A **warning** is shown that they must ensure the person stays, and to **re-mark "alone"** if they become alone (which re-tightens thresholds).

### Manual-start minimum-bar guardrail

If the feature is enabled and the user manually starts monitoring, and the currently-connected sensors are insufficient to meaningfully detect CNS depression, the app must **tell them the bare-minimum device(s)/state required** rather than silently "monitoring" with nothing useful. (Minimum bar TBD in implementation — at least one source capable of a danger-relevant continuous signal.)

## 7. Device-state matrix & per-device fallback

For each device × state (present-and-reporting / present-but-idle / absent-from-start / **died mid-session**) the engine must have a defined behavior. Research/implementation task: enumerate the full matrix and mark which states are **safely ignorable** (e.g. "H10 absent from start on a Watch+EMAY night" is fine) vs which **degrade sensitivity** (must be disclosed) vs which **end monitoring** (must alert).

**Per-device battery/absence fallback** — a **separate configurable setting for each device** (Apple Watch, Polar H10, EMAY) answering *"what to do when this device's battery dies / it stops reporting mid-monitoring":* options **klaxon** / **gentler wake-up alarm** / (other, e.g. notify-only). Rationale: losing your only continuous-SpO₂ source mid-sleep is itself a dangerous silent gap; the user decides how loudly to be told.

## 8. Alerting pipeline (local only)

Tiered, escalating, all local:
1. **Watch haptic** tap (guaranteed felt on-wrist; solves "phone in another room").
2. **Escalating haptic + soft "Are you OK?" confirmation** — dismiss = false alarm cancelled silently; no response within ~X s → escalate. *This confirmation tier is what lets the system be sensitive (safe) without alarm fatigue — most false positives become a silent tap the user clears.*
3. **Full phone klaxon** — loud, continues until slide-to-dismiss.

**Dismissal:** a deliberate **finger-across-the-bottom slide** (not a tap) to resist accidental/unconscious dismissal. If never dismissed: continue the klaxon (local escalation only — never external).

### iOS platform constraint (must-solve)

There is currently **no** loud-alarm capability while backgrounded/locked/silenced (no `audio` background mode, no Critical-Alerts entitlement). Options to evaluate:
- **Critical Alerts entitlement** (`com.apple.developer.usernotifications.critical-alerts`) — plays sound bypassing mute/DND; needs Apple approval (feasible for a personal/dev-profile app).
- **`audio` background mode** + an active audio session to play the klaxon while backgrounded.
- **watchOS extended-runtime / workout session** to keep sensors live and deliver on-wrist haptics + audio.
The watch is the most reliable delivery path for the wearer (haptics are always felt); the phone klaxon covers audibility for a nearby person.

## 9. UI

- **Settings:** master toggle (on by default) + activation multi-select + per-device battery/absence fallback + companion-mode default + "test the klaxon" button.
- **Dashboard front-page indicator** (near top of the launch view, using the **same line/color idiom** as existing baseline widgets): (a) simple "in the clear, CNS-wise" unless the user disabled all CNS monitoring; (b) the risk value if connected devices can determine it; (c) an **"insufficient info to determine"** indicator (symbol + short text) when nothing capable is connected/reporting.
- **Tap-through detail view** (when reporting + CNS monitoring is on, even if not klaxon-armed): an intuitive visual of **how far from CNS-depressant risk** the user is, as a **rolling ~1-hour trailing trend up to now**, **live-updating** while open (never stale) — composite distance-from-risk over the last hour, ideally with per-signal contributions.
- **"Am I protected right now?" transparency** — a persistent, honest indicator of whether monitoring is actually live (a dead-sensor silent gap while the user believes they're covered is itself a hazard).

## 10. Architecture

- **`CNSRiskMonitor`** (new, `@Observable` / actor) — owns the fusion engine: subscribes to sensor adapters, computes the rolling composite risk score, drives activation gating + the alert tier state machine. Pure scoring/fusion logic extracted into testable helpers.
- **Sensor adapters** — thin bridges publishing normalized `(signal, value, confidence, timestamp)`: `EMAYRealtimeService` (**built**), `PolarHRMService` (exists), a HealthKit/Watch adapter, and a future PLX/Wellue adapter (standards-first).
- **`KlaxonAlarmService`** (new) — owns the tiered alert pipeline (watch haptic → confirmation → phone klaxon), the audio/entitlement mechanism, and the slide-to-dismiss surface.
- **watchOS role** — extended-runtime sensor session + haptic delivery.
- **Data model** — a monitoring-session record + rolling risk-assessment samples (for the 1-hour view); settings persisted.

## 11. Failure modes & safety analysis (fail-safe bias)

- Sensor dies mid-session → per-device fallback fires; never a silent stop.
- App killed / backgrounded → the platform-alarm mechanism must survive backgrounding, or the transparency indicator must make the gap visible.
- Sleep mis-detection (thinks awake) → dose-window + manual start backstop it.
- Invalid data → contributes nothing; never fabricates a "safe" reading (false reassurance is the worst outcome).
- Ambiguity resolves toward **alerting** (false positive = annoyance; false negative = potentially fatal) — tempered only by the confirmation tier so sensitivity doesn't cause fatigue.

## 12. Testing strategy

- Can't test with a real overdose. Provide a **synthetic-trace replay harness** (declining RR/SpO₂ traces across sensor combinations) to validate detection + the alert pipeline end to end.
- **"Test the klaxon"** button so the user can verify audibility + the dismiss gesture on their actual device.
- Unit tests for the pure scoring/fusion, baseline-relative severity, activation gating, and the device-state matrix decisions. Extract all logic out of views per project convention.

## 13. Phasing

- **v1:** klaxon + slide-dismiss + confirmation tier + the detection/fusion engine + sleep/dose/manual activation + companion mode + per-device fallback + dashboard indicator + 1-hour detail view + settings + test harness. Local-only escalation.
- **Already done (dependency):** real-time EMAY SpO₂/pulse (`EMAYRealtimeService`).
- **Deferred / separate:** PLX-standard + Wellue O2Ring adapters; ResMed CPAP real-time BLE (`FD56`) spike; open-sourcing the EMAY integration (its own public project).

## 14. Resolved design decisions (research-backed, 2026-07-09)

Four of the five original open questions are resolved with evidence (citations in the research notes / this section). All values are **design inputs, not medical advice**, and are tunable envelopes over population data — surface that uncertainty in the UI.

### 14.1 Dose-window (activation) — RESOLVED
Heightened monitoring window measured from the **logged dose time**, per drug class, always taking the **later** expiry when doses stack (re-arm/extend, never shorten):
- **Benzodiazepine (clonazepam) alone: 12 h.** Covers Tmax 1–4 h + both combination-risk peak cohorts (≤1 h in ~58%, 2–6 h in ~42%) + tail. Deliberately NOT the 30–40 h half-life (single-dose sedation wanes far sooner; a multi-day alert = alarm fatigue).
- **IR opioid alone: 8 h** (peak resp-depression ~1–2 h). **ER/long-acting opioid: 24 h.** **Methadone / unknown long-acting: ≥72 h + "initiation/dose-change" flag** (delayed cumulative depression; treat unknown formulation as long-acting = fail-safe).
- **Any benzo + any opioid onboard together (the lethal synergy): `max(class windows) + 12 h` from the later dose, 24 h floor** — because residual clonazepam keeps potentiating a later opioid.
*(PK: clonazepam Tmax 1–4 h / t½ 30–40 h; IR opioid Tmax ~0.5–1 h / t½ ~2–4 h. FDA labels + PMR observational study.)*

### 14.2 Data-quality "insufficient to judge" gate — RESOLVED (per-source)
A rolling **60 s** window is **indeterminate** ("can't assess" — never alert *and* never reassure) unless it passes, and the gate is **per-source** because the sensors expose different quality signals:
- **Coverage:** ≥ **30 s of *contiguous* good-quality data** within the 60 s (not scattered fragments); good = SQI ≥ 90%.
- **Perfusion (oximeters exposing PI):** **PI < 0.6 → don't trust the value** (below it, SpO₂ *overestimates*, discrepancy OR ~3.36 — the false-reassurance case); **PI < 0.4 → hard reject.** Apple Watch exposes **no PI** (reflectance, internal gating, HR>150/motion refusal) → gate on sample recency + HR context + cross-sample agreement only. Polar H10 = HR/RR only (no SpO₂).
- **Artifact:** > **5%** artifact/ectopic samples in the window → indeterminate (HRV standard).
- **Asymmetry rule:** *reassure* only on a fully-passing window; *escalate* only when the alarming trend persists ≥ 2 consecutive good windows (or one high-confidence window); a low-quality window that *can't rule out* danger surfaces as "can't assess," never "OK."
*(Wearable-SpO₂ SQI/30 s precedent, PI/Bland-Altman study, Kubios <5% artifact, ISO 80601-2-61.)*

### 14.3 Sleep auto-detect as a gate — RESOLVED: do NOT rely on it
iOS/HealthKit sleep is **retrospective** (category samples written *after* the session, surfacing minutes–hours later, sync only when iPhone unlocked) with **low wake-specificity** (~47–76%; over-calls sleep). There is **no real-time "asleep now" API** and no reliable onset signal. → **Default trigger = manual "going to sleep" toggle + the post-dose timer (14.1).** Auto-sleep is an *optional best-effort* layer only: Sleep Focus/Schedule as a soft "arm the monitor?" nudge, retrospective `sleepAnalysis` to annotate sessions — **never** the sole arming condition, and auto-signals may only *add* coverage, never withhold it.
*(Apple HealthKit docs + independent PSG-validation studies.)*

### 14.4 Companion-mode threshold delta — RESOLVED (direction; magnitude is tunable)
Different physiology, different alarm job: **alone** → the only rescuer is the user, whose arousability decays on the *same* few-minute clock as hypoxia (severe desat within ~3 min; hypoxic injury 3–6 min), so fire at the **earliest defensible threshold, haptics-first, fast escalation**, tolerating more false positives to catch it *while still rousable*. **Companion present** → the loud klaxon recruits an external actor who can act *after* unconsciousness, so you may trade a **small** amount of sensitivity for specificity (alarm-fatigue cost). **Keep the delta modest** — present bystanders actually administer help only ~26–32% of the time — and **when companion-attentiveness is uncertain, default to alone-mode behavior** (fail-safe). Magnitude is a tunable judgment call; instrument it and revisit with usage data (no calibrated arousability-vs-time curve exists).
*(Witnessed-vs-unwitnessed overdose survival modeling, RI/BC bystander data, sedation/arousability literature, alarm-fatigue reviews.)*

*Phase-1 note (2026-07-09):* the threshold half of alone-mode is implemented (`aloneModeThresholdDelta`); the "fast escalation" half (shorter sustains when alone) is deliberately deferred to the phase that ships the confirmation tier — worst-case detection-to-klaxon latency and its remediation are tracked in the Phase 1 plan's implementation notes.

### 14.5 Alarm platform mechanism — RESOLVED
**Mechanism (how PagerDuty / medical / safety apps do it):** the **Critical Alerts** entitlement `com.apple.developer.usernotifications.critical-alerts` + runtime `UNAuthorizationOptions.criticalAlert` permission + a **critical sound** payload / `UNNotificationInterruptionLevel.critical`. This is the *only* mechanism that plays a loud alert **bypassing the ringer/mute switch AND Focus/DND** at a system-controlled volume, even while the phone is locked/suspended. (Time-Sensitive notifications break Focus but **respect the mute switch** and need no entitlement — insufficient for a klaxon-through-silent.) `audio` background mode / `AVAudioSession.playback` plays through the silent switch only while the app is active/backgrounded-with-audio and can't reliably start from a suspended+locked state — so it's a supplement, not the bypass.

**Approval:** Apple grants the entitlement **only for health/safety/security/emergency** use cases (this qualifies), via a manual request (developer.apple.com/contact/request/notifications-critical-alerts-entitlement/), days–weeks, sometimes needing resubmission. It must be enabled on the **App ID before** it can go in a provisioning profile — **including for a personal/sideloaded dev build** (no confirmed way to use a functioning critical alert without Apple enabling it on the App ID). Precedent: open-source sideloaded medical apps (Nightscout/Trio) pursue the same entitlement for exactly this.

**Decision:** pursue the entitlement (submit the health/safety justification for the App ID). **The feature is NOT blocked on Apple's approval** — it ships **watch-haptic-first** (on-wrist haptics need no entitlement and are always felt) plus foreground `.playback` audio; the **phone-klaxon-through-silent/locked upgrade activates once the entitlement is granted.** The user must also grant the runtime Critical Alert permission (and can revoke it), so the UI must handle that being off.
*(Apple Critical Alerts docs + developer-forum/community guidance.)*

---

## 15. Phase 2 implementation notes (2026-07-12)

Phase 2 (`docs/superpowers/plans/2026-07-12-klaxon-phase2-monitoring.md`) built the monitoring layer this design depends on: drug classification, the §14.1 dose-window gate, sensor adapters, the §7 device-state matrix, `CNSMonitoringCoordinator`'s 1 Hz tick loop, and a minimal arm/status Settings surface. Condensed record of the plan's autonomous scope decisions (full rationale in the plan doc):

1. **Adapters thread `perfusionIndex`/`isArtifact`, not "confidence"** — `CNSSignalSample`'s shipped shape governs over §10's wording; `CNSSeverityScorer` derives confidence downstream.
2. **Auto-sleep detection stays OUT of Phase 2** (§14.3 forbids it as a gating condition). Default triggers shipped: manual toggle + post-dose windows.
3. **Live sources are EMAY and Polar only.** The 1 Hz quality gate assumes continuous ~1 Hz sampling; Apple Watch SpO₂/HRV are cadence-mismatched and feed `CNSBaselines` only (spo2Nadir/restingHR/hrvMean/respRateMean from `HealthSnapshot`), never the gate directly. A cadence-aware sparse-source gate is deferred to Phase 3/2b.
4. **Drug classification is a stored, conservatively-defaulted model field** (`MedicationDefinition.cnsDepressantClass`), classifier-derived once from category/name, user-editable in `AddMedicationView`, never auto-downgraded from an explicit value.
5. **Minimum-bar guardrail:** monitoring can arm on any source, but reports "can't assess" unless EMAY (the only primary-capable continuous SpO₂ source) is present-and-reporting — disclosed on `statusLine`, not just internally gated.
6. **Per-device fallback: detect + persist config now, loud-alert in Phase 3.** `CNSDeviceFallbackConfig` persists the klaxon/gentle-alarm/notify-only choice per device; the interim measure is a standard local notification regardless of the configured action — never a silent stop.
7. **Companion re-mark is state-preserving.** `CNSDetectionPipeline.setCompanionPresent(_:)` threads the flag to the tier machine without rebuilding the pipeline, so mid-sustain escalation state survives a mid-session re-mark.
8. **Session/sample persistence is local-only** (`MonitoringSession`, `CNSRiskSampleRecord` — the `HealthSample` precedent): registered in both SwiftData `Schema` lists, never touched by `DataExporter`/`SyncService`/`RestoreFromServer`.
9. **EMAY service promotion was already done** on `main` before Phase 2 started (app-scoped `@State` + `.environment` injection) — verified, no task needed.
10. **Minimal arm/disarm surface ships now** (Settings → "CNS Monitoring"): arm/disarm toggle, ad-hoc "Monitor me now", companion toggle + the §6 re-mark warning, live status line (statusLine, tier, reporting sources, active triggers, dose-window expiry). No klaxon, no haptics, no dashboard changes — Phase 3 redesigns this screen entirely.
11. **Alone-mode fast escalation stays deferred to Phase 3** (with the confirmation tier, per the Phase 1 note above); Phase 2 only wires `companionPresent` → the existing `aloneModeThresholdDelta`.
12. **Synergy detection is the UNION of two rules** (amended mid-execution, 2026-07-12): a 24h dose-pairing horizon OR §14.1 monitoring-window overlap. The horizon-only variant missed a benzo dosed 20+h before an opioid (the window is deliberately shorter than the half-life); the overlap-only variant missed a benzo dosed 50h into a methadone window (methadone's 72h window vs. the pairing formula's t0+134h). Constants: `CNSMonitoringConstants.synergyPairingHorizon`/`synergyWindowExtension`/`synergyWindowFloor`.

**Pending clinical review** (design calls made by the implementing agent, not a clinician):
- The synergy union rule above (decision 12) — the 24h pairing horizon and the "later dose + max(class windows) + 12h, 24h floor" formula.
- The buprenorphine → 24h (opioidER-class) window assignment from Task 1's classifier — buprenorphine's partial-agonist ceiling effect may warrant a different window than full-agonist ER opioids; assigned conservatively (same window as other ER opioids) pending review.

**Open question, not resolved by Phase 2:** `RestoreFromServer.importMedDoses` (`RestoreFromServer.swift:752`) inserts restored `MedicationDose` rows directly against the model context — it does not go through either UI dose-log call site (`MedicationsHubView`/`DoseAnxietyPromptView`), so restored doses never call `CNSMonitoringCoordinator.doseLogged(_:)`. A server restore that brings in a benzo/opioid dose still inside its §14.1 window will NOT auto-arm monitoring for it — `handleLaunch()`'s re-arm path only replays the app's own persisted `[LoggedCNSDose]` list, which restore doesn't populate. Left open for Phase 3 (or a dedicated fix) to decide whether restore should also feed the dose-window gate.

---

*Related: `reference-emay-realtime-ble` (protocol), `EMAYRealtimeService.swift` (built), `PolarHRMService.swift` (pattern), `BaselineCalculator` (personal baselines).*
