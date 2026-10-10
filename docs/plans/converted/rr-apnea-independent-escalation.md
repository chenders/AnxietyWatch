# Independent Respiratory-Rate / Apnea Fast Escalation — Klaxon Plan

**Status:** Proposed — not started. Next CNS-klaxon PR after the timing re-work (#35).
**Date:** 2026-07-22
**Author:** Claude (with the maintainer)
**Context:** Follow-up flagged by `medical-data-accuracy-reviewer` during the klaxon timing re-work (PR #35). PR #35 built a severity-scaled critical fast path but, by design, it only fires for SpO₂ today. This plan closes the respiratory-rate / apnea side.

---

## TL;DR

On a user managing sleep apnea with a CPAP **and** CNS depressants, **SpO₂ is a lagging sign**: supplemental O₂ / CPAP pressure keeps saturation up while ventilation is already failing (Chest 2004; APSF OIRD guidance). The leading, earlier signal of respiratory depression is **falling respiratory rate and prolonged apnea** — RR ≤ 5/min or an apnea > ~30 s should reach the klaxon **on its own, without waiting for SpO₂ to fall**.

Today it can't:
1. **No trusted RR source exists.** `sourceFidelity` gives Apple-Watch RR only 0.6 (a sleep-session estimate) and every other source 0 — including the AS11 bridge (`(_, .as11Bridge) → 0`). The critical fast path PR #35 built requires a source at/above `trustedContinuousPrimaryFidelity` (0.8), so no RR reading can ever take the express lane.
2. **There is no apnea-duration signal at all** — the engine models RR only as a rate; a discrete apnea event (breathing stopped for N seconds) is invisible to it.

**Key architectural insight:** the fast-path machinery from PR #35 **already spans respiratory rate.** `CNSAlertTierMachine.ingest`'s `criticalPrimary` gate iterates *primary* contributions (`.spo2 || .respiratoryRate`), and `CNSFusionEngine` already treats RR as a primary signal with MAX-not-average fusion. So the moment a **trusted** RR source emits samples that score critical, RR fast-escalation and SpO₂-independence come essentially for free. **This is primarily a data-plumbing + thresholds task, not a state-machine rebuild.**

---

## Where the pieces stand today

| Piece | State | Where |
|---|---|---|
| Critical fast path (→ klaxon in `criticalFastPathSustainSeconds`) | ✅ built (PR #35), gate spans `.spo2 \|\| .respiratoryRate` | `CNSAlertTierMachine.advanceCriticalFastPath` + `ingest`'s `criticalPrimary` |
| RR treated as a primary signal in fusion (MAX, un-muzzle applies) | ✅ | `CNSFusionEngine` (`primary = spo2 \|\| respiratoryRate`) |
| RR severity ramp (population 10 → 5, saturates at RR ≤ 5) | ✅ | `CNSSeverityScorer.severity` `.respiratoryRate` case; `respiratoryRateOnset`/`respiratoryRateFloor` |
| A **trusted** RR source (fidelity ≥ `trustedContinuousPrimaryFidelity` 0.8) | ❌ none — Watch RR = 0.6, AS11/EMAY/Polar RR = 0 | `CNSThresholds.sourceFidelity` |
| AS11 bridge emitting RR as a `CNSSignalSample` | ❌ AS11 emits SpO₂ (0.9) + HR (0.8) only; `(_, .as11Bridge) → 0` for RR | AS11 adapter / `AS11StreamSource`, sample collection |
| Apnea-duration / apnea-event signal | ❌ does not exist | — |

So the fast path is wired for RR but **starved of input**. Two things must land: a trusted RR source, and an apnea model.

---

## Clinical thresholds (evidence, not this user's data)

Population / guideline thresholds — safe to encode as `CNSThresholds` members:

- **RR ≤ 5/min sustained** — PRODIGY terminal bradypnea; already `respiratoryRateFloor = 5` (severity → 1.0 here).
- **RR ≤ 8/min** — RRT / NEWS2 escalation trigger (mid-severity; roughly the current `respiratoryRateOnset = 10` band).
- **Apnea > ~30 s** — clinically significant central/obstructive event; a *cluster* of shorter apneas is also meaningful.
- **Severity-scaled latency** — IEC 60601-1-8: alarm speed scales with speed-of-harm. A critical RR/apnea should use the same ~12 s critical fast path, not the ~150 s graded ladder.
- **Independence from SpO₂** — O₂/CPAP masks hypoventilation, so RR/apnea must escalate even while SpO₂ reads normal (Chest 2004; APSF).

Tune the exact apnea-duration threshold and any apnea-cluster rule against the user's own recorded AS11 traces before shipping. Keep this doc free of the user's personal measurements (public repo).

---

## Design

### Requirement A — a trusted continuous RR source

The natural source is the **AirSense 11 CPAP itself**: it measures respiratory rate and flags apnea events (central/obstructive) with durations directly. So the AS11 feed (the Phase-B AS11 context feed / bridge) should carry RR and apnea events, and the engine should trust AS11 RR the way it trusts AS11 SpO₂ (fidelity 0.9).

- Add `(.respiratoryRate, .as11Bridge) → 0.9` (or a considered value ≥ `trustedContinuousPrimaryFidelity`) to `CNSThresholds.sourceFidelity`, replacing the current `(_, .as11Bridge) → 0` catch-all for RR.
- The AS11 adapter must emit RR as `CNSSignalSample(kind: .respiratoryRate, source: .as11Bridge, …)` with the **local receipt timestamp** (per the AS11 clock-skew fix already in place), plausibility-gated the same way SpO₂/HR are (reject ≤ 0 / absurd / NaN).
- **Dependency / risk:** this is blocked on the AS11 feed actually exposing RR + apnea. If the current WebSocket/SD-card feed doesn't, that plumbing is the real first task (and may need ResMed myAir / EDF parsing work). If AS11 RR is not yet available, the interim options are (a) ship the apnea-event path first if apnea events arrive before RR, or (b) *temporarily* allow Apple-Watch sleep RR to escalate the **ladder only** (never the fast path — it stays fidelity 0.6), documented as a stopgap. Do **not** raise Watch RR fidelity to 0.8 — it's a sleep-stage estimate, not a real-time measurement, and would fast-path on motion artifacts.

### Requirement B — apnea-duration escalation

An apnea is "breathing stopped," which the RR-rate ramp doesn't capture well (a 30 s gap isn't the same as a steady RR of 6). Two modeling options:

- **Option 1 — synthetic RR = 0 for the apnea window.** Map each AS11 apnea event to `CNSSignalSample(kind: .respiratoryRate, value: 0, …)` spanning its duration. Pro: reuses the RR ramp (0 ≤ floor 5 → severity 1.0) and the existing fast path with zero new machinery; a > `criticalFastPathSustainSeconds` apnea auto-fast-paths. Con: conflates "apnea event" with "measured RR of 0"; the quality gate's contiguous-good-samples logic must accept these synthesized samples.
- **Option 2 — a dedicated apnea signal + rule.** Add an apnea-duration input and an explicit "apnea > threshold → escalate" rule alongside the RR ramp. Pro: explicit, tunable (duration threshold, cluster rule), clearly separable in logs. Con: new signal kind + new escalation path to wire through fusion + the tier machine + tests.

**Recommendation:** start with **Option 1** (synthetic RR = 0) because it rides the fast path PR #35 already validated and needs the least new surface, and add Option 2's explicit cluster rule only if real traces show short-but-clustered apneas that a single-event RR-0 model misses. Decide during implementation against the user's AS11 data.

### Independence from SpO₂ (already guaranteed, must be tested)

Because fusion is MAX-not-average across primary signals and the fast path is evaluated per-primary-contribution, a critical RR/apnea reading reaches klaxon even with SpO₂ = severity 0. No new logic — but this is the whole clinical point, so it needs an explicit regression test (critical RR + healthy SpO₂ → klaxon fast).

---

## Implementation tasks (ordered)

All under `AnxietyWatch/Services/CNSRisk/` + the AS11 adapter, `medical-data-accuracy-reviewer` **required** per CLAUDE.md, plus `swift-pre-pr-reviewer`. Add regression tests + an emulator/self-test scenario per item.

1. **AS11 feed carries RR + apnea events.** Confirm/extend the AS11 context feed (Phase B) to expose respiratory rate and apnea events with durations. If unavailable, this is the blocking data task — scope it first. (Dependency gate for everything below.)
2. **Emit AS11 RR samples.** AS11 adapter → `CNSSignalSample(kind: .respiratoryRate, source: .as11Bridge)` with local receipt time + plausibility gate. Add `(.respiratoryRate, .as11Bridge)` fidelity ≥ 0.8 to `sourceFidelity` (remove the RR case from the `(_, .as11Bridge) → 0` catch-all).
3. **Apnea → escalation (Option 1).** Map AS11 apnea events to synthesized RR = 0 samples over the event window; confirm the quality gate accepts them and the fast path fires for apnea > `criticalFastPathSustainSeconds`. Add an `apneaMinEscalationSeconds` (~30 s) threshold to `CNSThresholds` if gating apnea separately from raw RR.
4. **Verify fast-path + independence.** With #2/#3 in place, a critical RR/apnea from AS11 should fast-path via the existing `criticalPrimary` gate. Add tests: RR ≤ 5 from AS11 → klaxon in ~`criticalFastPathSustainSeconds` **with SpO₂ normal**; apnea > threshold → klaxon; Apple-Watch RR (0.6) at RR ≤ 5 → ladder only, never fast path; no RR source → behavior unchanged; RR/apnea during AS11 `maskOffLeak`/`bridgeDown` → suppressed/degraded (not a false alarm), per the existing AS11-state gating.
5. **Thresholds housekeeping.** Any new constant (apnea duration, RR fast-path cutoff if distinct from the ramp) goes in `CNSThresholds` with a doc comment — never a re-typed literal. Reuse `criticalFastPathSustainSeconds` / `criticalPrimarySeverity` where the semantics match.
6. **Docs.** Update the klaxon design doc's implementation-sequence item 4 to "shipped," and note the apnea-model decision (Option 1 vs 2) actually taken.

---

## Testing

Swift Testing, fixed reference dates, constants via `CNSThresholds.standard` (per `CNSKlaxonFastPathTests` conventions):

- `respiratoryRateCriticalFastPathsWithHealthySpO2` — trusted AS11 RR ≤ 5 + SpO₂ severity 0 → klaxon in one fast-path window (the clinical crux: don't wait for SpO₂).
- `prolongedApneaFastPaths` — an apnea longer than the threshold → klaxon; a short apnea does not.
- `lowFidelityWatchRRNeverFastPaths` — Apple-Watch RR ≤ 5 stays on the ladder (fidelity 0.6 < trusted bar), mirroring `lowFidelityPrimaryNeverFastPaths`.
- `rrEscalationSuppressedDuringMaskOffLeak` — RR/apnea during AS11 non-`streamingOK` states doesn't fire (reuses the AS11-state gating).
- Emulator/self-test scenario driving an RR decline + an apnea, verifying the tier progression end-to-end.

---

## Risks & edge cases

- **AS11 RR/apnea availability** — the whole plan gates on the feed exposing these; verify before committing to Option 1. This is the single biggest unknown.
- **Apnea vs. mask-off** — a removed mask can look like "no breathing." The existing AS11 `maskOffLeak`/`bridgeDown` state gating must suppress RR/apnea escalation in those states (do not treat mask-off as apnea).
- **RR artifacts** — plausibility-gate AS11 RR like SpO₂/HR; a spurious RR = 0 spike must not fast-path (the `criticalFastPathSustainSeconds` sustain + quality gate already guard single-sample glitches, but confirm for the synthesized-apnea samples).
- **Alarm fatigue** — apnea users have *many* short apneas nightly; the escalation threshold must be for *prolonged*/clustered events, not routine sleep-disordered breathing. Tune against real traces; err toward alarm only for genuinely prolonged events.

---

## Out of scope

- Deriving RR from Polar/ECG or PPG (a future sensor-fusion phase; Polar RR fidelity stays 0 for now).
- Raising Apple-Watch RR fidelity — it stays a ladder-only corroborator; it is a sleep-stage estimate, not a real-time measurement.
- Any change to the SpO₂ fast path shipped in #35.

---

## References

- Klaxon design/evidence review (local-only, has the maintainer's SpO₂ calibration data): `docs/research/klaxon-alarm-timing-reassessment.md`, implementation-sequence item 4.
- PR #35 (severity-scaled fast path) — the machinery this builds on.
- CLAUDE.md "CNS Detection Engine" — pipeline shape, invariants (asymmetry, primary-only escalation, invalid-data-contributes-nothing), and the `medical-data-accuracy-reviewer` requirement.
- Evidence: PRODIGY (Khanna et al., Anesth Analg 2020); APSF OIRD guidance; Fu et al. Chest 2004 (O₂ masks hypoventilation); IEC 60601-1-8; NEWS2/RRT.
