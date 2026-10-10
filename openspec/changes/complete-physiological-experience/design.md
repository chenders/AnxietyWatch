# Design

## Context

See `proposal.md` for motivation. Polar, EMAY, provenance, dashboard, settings, and report work accumulated in separate plans. Much of the foundation shipped, but the remaining tasks describe one user journey: understanding where a measurement came from, what it means, how it relates to a session or dose, and what is missing.

| Legacy source | Current evidence | Disposition |
|---|---|---|
| `docs/plans/converted/phase-4-polar-integration.md` | `PolarHRMService.swift`, `PolarActor.swift`, `PolarSessionHRDetailView.swift` and tests | Keep incomplete all-chart drill-down and persona polish here |
| `docs/plans/converted/expert-review-improvement-plan.md` | Trends, reports, settings, notifications, and current tests | Re-audit each residual item; implement only current, evidence-backed gaps |
| completed dashboard, settings, provenance, overnight-stat, and Polar specs under `docs/plans/completed/` | Current views/services and merge history | Historical evidence; do not duplicate completed tasks |

The app has multiple data owners. HealthKit observations stay HealthKit-owned; app-only EMAY and session records need local persistence, export, upload, server query, and restore. Views never become the place where source arbitration is invented.

## Goals / Non-Goals

**Goals:**

- Make metric and session exploration consistent across sources and charts.
- Carry provenance, freshness, units, and availability into every relevant presentation.
- Ship in small independently testable vertical increments.

**Non-Goals:**

- Reintroducing retired pharmacy or supply-tracking features.
- Writing physiological data to HealthKit.
- Treating correlation, timing, or medication overlays as proof of causation.

## Decisions

### 1. Organize increments by user journey, not provider

Each increment runs from stored observation through aggregation, provenance, presentation, accessibility, export, and restore where applicable. Provider-specific adapters stay isolated. The rejected alternative is separate uncoordinated plans for each chart, which caused the current fragmentation.

### 2. Re-audit before converting a legacy checkbox into code

Every residual expert-review item first receives an already-satisfied, obsolete, rejected, deferred, or actionable disposition. This prevents resurrecting removed product areas and accommodates code that changed after the plan was written.

### 3. Preserve source identity through aggregation

Aggregates and reports either retain source separation or state the arbitration used. UI code consumes prepared, bounded view data; it does not silently merge unlike measurement semantics.

### 4. Use simple-first progressive disclosure

Default content is plain language and accessible. Advanced methodology is available on demand and states limitations. This serves both daily use and expert inspection without duplicating screens.

### 5. Roll out per vertical slice

Existing dashboards remain until the replacement slice has test and parity evidence. A feature-level control or routing boundary allows rollback without deleting data.

## Risks / Trade-offs

- [Broad UX scope expands indefinitely] → Prioritize discrete vertical slices and defer optional polish explicitly.
- [Source blending misleads] → Require provenance and arbitration tests at the aggregation boundary.
- [App-only records fail to restore] → Apply the upload/down-path rule before release.
- [Dense views become inaccessible] → Validate VoiceOver and large Dynamic Type for each slice.

## Migration Plan

1. Produce a current gap table from the converted legacy plans.
2. Sequence Polar continuity and provenance correctness before broader report polish.
3. Implement one metric/session slice at a time with tests and export/restore checks.
4. Keep the previous route available until parity is demonstrated.
5. Update this OpenSpec change after each merged slice with evidence and scope decisions.
