# Design

## Context

See `proposal.md` for motivation. The production app already has a staged CNS pipeline and an AirSense 11 context-feed foundation, but the independent RR/apnea proposal was never implemented and physical lifecycle evidence remains incomplete. Missing evidence must not be treated as either failure or completion.

| Legacy source | Current evidence | Disposition |
|---|---|---|
| `docs/plans/converted/rr-apnea-independent-escalation.md` | `AnxietyWatch/Services/CNSRisk/CNSDetectionPipeline.swift`, `CNSThresholds.swift`, and existing CNS tests | Convert remaining trusted-source and independent-escalation work here |
| `docs/plans/converted/superpowers/plans/2026-07-20-as11-context-feed.md` | `AS11StreamSource.swift`, `AS11StreamModels.swift`, server context-feed code and tests | Preserve shipped foundation; retain hardware lifecycle and stale-callback gaps |
| `docs/plans/completed/superpowers/plans/2026-07-20-klaxon-phase3-ondevice.md` | CNSRisk implementation and tests | Historical evidence, not an active plan |

HealthKit remains authoritative for HealthKit-owned respiratory observations. App-only dose or monitoring records require symmetric server restore. CNS tuning lives in `CNSThresholds`; no task may scatter replacement literals.

## Goals / Non-Goals

**Goals:**

- Establish an evidence chain from source trust through quality gating to escalation and clearing.
- Make every new rule deterministic, reviewable, testable, and independently reversible.
- Validate once-per-install and physical-device paths that ordinary regression tests do not exercise.

**Non-Goals:**

- Diagnosing apnea or replacing emergency medical care.
- Enabling unsupported hardware data because a model or placeholder type exists.
- Rewriting the completed CNS phases or making a server mirror authoritative.

## Decisions

### 1. Source admission precedes clinical scoring

Respiratory data enters the risk path only after source identity, units, timestamp semantics, freshness, and quality are validated. This preserves the existing `CNSQualityGate` → scoring → fusion → tier-machine boundary. The rejected alternative is accepting any numeric RR value and filtering later; that can allow invalid data to influence a safety decision.

### 2. Independent escalation does not mean independent clearing

Trusted RR/apnea evidence may escalate without simultaneous SpO2 evidence, but clearing continues to require observed, primary-informed evidence consistent with existing CNS invariants. Missing or disconnected data is indeterminate. The rejected alternative is symmetric escalation/clearing from one signal, which increases false-reassurance risk.

### 3. Existing behavior remains authoritative behind a disabled control

The new path is introduced disabled, shadow-evaluated, and enabled only after medical-data review and evidence. Rollback disables only the new path and does not remove stored observations or alter HealthKit.

### 4. Hardware lifecycle is a release gate

Physical validation covers initial connection, reconnect, background/foreground, network loss, and stale callback delivery. The stale-socket race gets an injectable deterministic harness before device testing so a passing manual run is not the only evidence.

### 5. Restore verification is part of clinical continuity

Fresh-install tests start with an actually empty store. Restored app-only records preserve server IDs, are marked synced, participate in empty-store guards, and do not duplicate on later sync. HealthKit-owned observations are re-derived from HealthKit rather than made server-authoritative.

## Risks / Trade-offs

- [Source semantics are ambiguous] → Keep the source out of production scoring until documented and validated.
- [Independent escalation raises false positives] → Require persistence, fault suppression, shadow evidence, and medical-data review.
- [Hardware tests are intermittent] → Pair deterministic race tests with a recorded physical lifecycle matrix.
- [Restore changes duplicate clinical records] → Assert stable IDs, synced state, and second-sync idempotency on a fresh store.

## Migration Plan

1. Reconfirm source semantics and current code gaps.
2. Implement deterministic source and fault fixtures before production wiring.
3. Add shadow-only evaluation and diagnostics.
4. Complete medical-data, general Swift, and relevant UI review.
5. Run fresh-install, restore, simulator, server, and physical lifecycle gates.
6. Enable only the accepted source path; disable the control to roll back without deleting data.
