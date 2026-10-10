# Design

## Context

See `proposal.md` for motivation. The Oura plans include implemented OAuth, cloud, server, UI, and BLE foundations, while the Ultra plan combines shipped sensor capture with proposals ranging from prediction to location and HealthKit writes. A source file or passing unit test proves a foundation, not platform availability or production support.

| Legacy source | Current evidence | Disposition |
|---|---|---|
| `docs/plans/converted/oura/oura_ring_5_spec.md` and detailed companion | Oura client/server/UI files and tests | Verify live cloud integration; decide direct BLE separately |
| `docs/plans/converted/superpowers/specs/2026-04-20-ultra3-upgrade-design.md` | current watch target, sensor services, and completed sensor commits | Inventory shipped foundation; decide optional ideas individually |

## Goals / Non-Goals

**Goals:**

- Produce durable decisions that can be understood without the original session.
- Separate current evidence, desired behavior, and implementation authorization.
- Prevent privacy-sensitive or unsupported device ideas from entering code by inertia.

**Non-Goals:**

- Implementing accepted capabilities in this change.
- Reverse engineering a private protocol as an assumed production commitment.
- Changing HealthKit's read-only ownership boundary without a separate explicit decision.

## Decisions

### 1. One decision record per capability

Oura cloud, Oura BLE, Action button, voice, State of Mind, location, ECG, prediction, and Smart Stack each receive their own evidence and disposition. The rejected alternative is accepting or rejecting an entire device plan as a unit.

### 2. Evidence has an expiry and authority

Official current documentation is primary for platform and legal constraints. Live tests validate the existing implementation but do not override published policy. Undocumented protocol experiments are labeled as such.

### 3. Accepted work becomes a separate OpenSpec change

This roadmap remains a decision plan. Each accepted capability gets its own behavioral spec, storage/restore analysis, permission flow, testing matrix, and rollback. This prevents a research conclusion from being mistaken for shipped behavior.

### 4. Data ownership is decided before collection

Each capability states whether data is HealthKit-owned, provider-cloud-owned, device-direct/app-only, or derived. App-only persisted rows need export and restore. Location and voice need explicit minimization and retention decisions.

## Risks / Trade-offs

- [External policies change] → Record source date and re-evaluation trigger.
- [Existing foundation creates sunk-cost bias] → Judge production support on current benefit and supportability, not code volume.
- [Roadmap becomes permanent research] → Time-box evidence collection and make defer/reject valid outcomes.
- [Sensitive capability expands data collection] → Require consent, minimization, export, and deletion before acceptance.

## Migration Plan

1. Inventory shipped foundations and unverified assumptions.
2. Gather current official and live-integration evidence.
3. Record prioritized dispositions with re-evaluation triggers.
4. Open focused implementation changes only for accepted capabilities.
5. Archive this decision change after all items have a durable outcome.
