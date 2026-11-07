# Design

## Context

See `proposal.md` for motivation. AnxietyWatch2 is the superseding local-first Pi + thin Apple client system; its GEN1 parity ledger marks phone-side CNS/baseline/trend **analysis** as `remove`, and its architecture places detection and multi-modal alarming in `vitals-core` / designed `klaxond`, not in this app.

This design inventories what exists **in this repository today**, decides deletion vs retention boundaries, and sequences removal so builds, restore gates, and public claims stay coherent.

### Current-state evidence (generation-one klaxon in this repo)

| Area | Evidence paths | Role |
|---|---|---|
| App detection engine | `AnxietyWatch/Services/CNSRisk/*` (quality, severity, fusion, tier, pipeline, thresholds, adapters, AS11 stream, dose window, depressant class/classifier, alarm presenter/policy, device matrix, notification helpers) | Clinical detection + presentation |
| App coordinator / DI | `AnxietyWatch/Services/CNSMonitoringCoordinator.swift`, `AnxietyWatch/App/AnxietyWatchApp.swift`, medication/dose views injecting coordinator | Arming and runtime ownership |
| Models | `MonitoringSession.swift`, `MonitoringSessionStore.swift`, `CNSRiskSampleRecord.swift`, `MedicationDefinition.cnsDepressantClass` | SwiftData + med metadata |
| UI | `Views/Settings/CNSMonitoringView*.swift`, `CNSMonitoringDemoView.swift`, Settings row, `AddMedicationView` CNS picker | User-facing product |
| Package pipeline | `AnxietyWatchKit/.../Pipeline/CNS*.swift`, `PipelineStep.swift`, `PipelineState.swift` (AlertTier/commands), related tests | Redesign dual engine |
| Watch | `WatchConnectivityManager` `cnsKlaxonHaptic` | Alarm haptic relay |
| Phone connectivity / upload | `PhoneConnectivityManager`, `AlertChannelUploader`, tests `*Klaxon*`, `AlertChannelUploaderTests` | Redundant channel |
| Server | `server/backstop.py`, `server/apns.py`, `server/api/alert_channel.py`, alembic `0013_medication_cns_class`, `c5d7e9f10a2b_add_alert_channel_tables`, tests `test_backstop`, `test_alert_channel`, `test_apns` | Server backstop + APNs |
| Docs / agents | `README.md`, `docs/FEATURES.md`, `docs/diagrams/cns_pipeline.svg`, `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md`, `AGENTS.md` / `CLAUDE.md` CNS sections, portfolio #1 `complete-clinical-respiratory-safety` | Claims + future work |
| Completed history | `docs/plans/completed/**` klaxon phase plans/designs | Archive only |
| Converted follow-ons | `docs/plans/converted/rr-apnea-independent-escalation.md`, AS11 context-feed converted plan/design; OpenSpec `complete-clinical-respiratory-safety` | Would extend removed product |
| Superseding system (external) | `../AnxietyWatch2` README, `docs/specs/AMENDMENTS.md` (esp. multimodal alerting), `docs/research/klaxon-alarm-timing-reassessment.md`, `clients/apple/GEN1-PARITY.yaml` (`analysis.baselines_trends_cns_correlations` → remove) | Authority after retirement |

### Constraints

- Public repo: no PII in fixtures; do not commit live alarm captures.
- Restore rule still applies to **remaining** synced tables; removing CNS entities must update manifest/inventory together.
- Redesign v3 storage/sync/watch transport continues; do not gut BLE actors solely because CNS used them.
- Historical migrations on deployed servers are not rewritten; forward code stops using retired tables.

## Goals / Non-Goals

**Goals:**

- One coherent product story: this app is not a CNS klaxon.
- Compile-clean app, watch, package, and server with zero warnings after deletion.
- Tests and OpenSpec portfolio no longer schedule work that finishes the removed product.
- Explicit data policy for leftover CNS rows and medication class fields.
- Clear pointer that AnxietyWatch2 supersedes clinical-alert development.

**Non-Goals:**

- Implementing or porting AnxietyWatch2 `klaxond` / `vitals-core` into this repo.
- Removing Polar/EMAY/HealthKit/CPAP **as data sources** for journals and trends.
- Rewriting git history or deleting `docs/plans/completed/` blobs.
- Forcing production DB DROP of alert-channel tables in the same PR (optional later ops note).
- Changing ordinary dose-anxiety or random check-in notifications.

## Decisions

### D1 — Full product removal, not feature-flag hide

**Choice:** Delete code paths and UI; do not leave a disabled “CNS Monitoring” flag or shadow engine.

**Why:** A disabled clinical engine still implies ownership, accrues review rules, and confuses dual-repo contributors. AnxietyWatch2 already replaced the product direction.

**Alternatives:** Runtime flag off (rejected: residual surface and claims); move sources to a package submodule “for later” (rejected: later is the other repo).

### D2 — Retain sensor capture; delete alert consumers

**Choice:** Keep Polar, EMAY, HealthKit, OSCAR/ez Share, and server AS11/collector code that serves **import, charts, and sync**. Delete app `AS11StreamSource` / CNS adapters and any path whose only consumer is tier/klaxon.

**Why:** Proposal non-goal preserves physiology journaling. AS11 **context feed for CNS** is not the same as optional CPAP data engineering elsewhere.

**Test:** If deleting a file only breaks CNS tests/UI, delete it; if it breaks Trends/import, keep and sever CNS call sites.

### D3 — Package pipeline: remove CNS types; keep ingestion shells as redesign owns them

**Choice:** Remove `CNSFusionEngine`, `CNSAlertTierMachine`, `CNSMonitoringCoordinator` (package), and CNS-oriented `PipelineStep` tier logic. If redesign still needs a pure step function for non-alert routing, replace with a minimal pass-through or delete the step and call storage/router directly—**no AlertTier**.

**Why:** Canonical `sensor-processing` today mandates deterministic CNS transition; this change removes that requirement. Leaving dead tier machines invites revival.

**Alternatives:** Rename CNS→“VitalsPipeline” without clinical semantics (rejected for this change: still a second analysis engine; out of scope unless redesign explicitly needs it later).

### D4 — Medication model: drop CNS class from product; tolerate legacy column

**Choice:** Remove UI and app logic for `cnsDepressantClass`. Prefer stopping encode/decode in sync payloads. Server column may remain nullable unused (no destructive down-migration required). Classifier types deleted.

**Why:** Class existed to arm pharmacokinetic windows for the klaxon. Journal meds remain.

### D5 — SwiftData model drop strategy

**Choice:** Remove `MonitoringSession` and `CNSRiskSampleRecord` from the model container. Use an explicit migration plan:

1. Prefer a lightweight/migration path that drops retired entities if already supported; or
2. Versioned schema migration that deletes those stores; or
3. Document one-time store reset only if migration cost is unjustified—**last resort**, because it risks non-CNS data.

**Default preference:** schema migration that preserves journal, doses, snapshots, samples. Add an upgrade test with a fixture store that still contains monitoring rows.

### D6 — Server: delete handlers; leave old Alembic revisions

**Choice:** Remove `backstop` job registration, `alert_channel` blueprint routes, and klaxon APNs kinds from runtime. Keep historical alembic revisions. Optionally stop selecting retired tables in `ENTITY_QUERIES`. Do not require operators to DROP tables for app correctness.

**Why:** Deployed DBs may have rows; forward-safe code ignores them.

### D7 — OpenSpec portfolio surgery

**Choice:**

- Archive or mark **cancelled** `complete-clinical-respiratory-safety` (do not implement).
- Update `openspec/PORTFOLIO.md`: remove clinical-respiratory as priority #1; note retirement change; keep redesign as highest remaining platform work.
- Edit `complete-redesign-v3-migration` notes so task 2.5 / dual-engine language becomes “CNS removed” rather than “app owns clinical effects.”
- Add `cns-klaxon-retirement` to canonical specs on archive of this change.

**Why:** Leaving `complete-clinical-respiratory-safety` active would schedule rebuilding what we delete.

### D8 — Documentation retention

**Choice:**

- **Delete or gut** live claims: README table rows, FEATURES CNS section, `docs/diagrams/cns_pipeline.svg` references, agent “CNS Detection Engine” mandatory sections.
- **Keep** `docs/plans/completed/**` and parent design under `docs/superpowers/specs/` with a short supersession banner pointing at AnxietyWatch2 (and this change), not as build instructions.
- Converted RR/apnea / AS11 escalation docs stay under `converted/` but lose OpenSpec owners that implement them.

### D9 — Watch and notification scope

**Choice:** Remove only CNS/klaxon message types and presenters. Keep dose follow-up and check-in notifications. Strip `AlertChannelUploader` and AppDelegate hooks used solely for redundant CNS channel.

### D10 — Cross-repo reference style

**Choice:** In README/PORTFOLIO, refer to AnxietyWatch2 by repository name and high-level role only. Do not vendor AW2 paths as build dependencies. Never merge `quarantine/anxietywatch2-*` into this app.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Accidental deletion of shared BLE/import code | Per-file consumer audit; tests for Polar/EMAY/CPAP import remain green |
| SwiftData upgrade crash on missing models | Upgrade fixture test; explicit migration before releasing |
| RestoreManifest fails CI after entity removal | Update manifest, server queries, exporters, importers in the same PR |
| Public README still claims klaxon | Checklist task + sensitive/public claim scan |
| Redesign tasks still reference CNS ownership | Patch redesign design/tasks/notes in-repo in the same change series |
| Orphan server tables confuse operators | SERVER_SETUP note: tables inert; optional future DROP |
| User expects overnight alarm from this app | Explicit README disclaimer; no Settings affordance |
| Dual-repo contributor re-adds engine | `cns-klaxon-retirement` requirement + agent doc removal of CNS workflow |

**Trade-off:** Losing in-app early-warning code that partially shipped. Accepted: superseding system is the product direction; half-enabled phone klaxon is worse than honest absence.

## Migration Plan

1. **Planning merge:** this OpenSpec change + portfolio/cancel clinical-respiratory-safety (docs-only OK first).
2. **Code PR(s)** (may split server vs client but each must leave CI green):
   - Delete app CNSRisk + UI + models wiring; fix medications/settings.
   - Delete package CNS pipeline + tests; fix kit startup.
   - Delete watch haptic path; phone connectivity/uploader.
   - Server backstop/alert_channel/APNs klaxon kinds + tests.
   - Export/restore/manifest/ENTITY_QUERIES.
   - Docs/agents/README/FEATURES/diagrams.
3. **Validation:** full iOS tests (XcodeBuildMCP), server pytest + flake8, `openspec validate --all --strict`, zero warnings, fresh-install smoke, upgrade-from-CNS-store smoke.
4. **Rollout:** normal app release; no feature flag. Server deploy removes endpoints; old clients that still POST alert-channel should get clean 404/410 without crashing server.
5. **Rollback:** git revert before or after release restores code; clinical ownership remains discouraged pending explicit reverse OpenSpec. Data dropped from local CNS tables may not return.

## Open Questions

None that block specs or task breakdown. Optional later ops: whether production Postgres should DROP `alert_channel_*` tables—defer to server maintenance, not app correctness.
