# Plan Document Audit and OpenSpec Reorganization

Date: 2026-10-09
Branch: `codex/reconcile-docs-plans`

## Outcome

OpenSpec is now the single active backlog. The audit found a large set of stale unchecked plans whose accepted work had already shipped, plus several mixed or partially completed documents whose remaining tasks still mattered. The reorganization:

- moved 45 completed plan/design records to `docs/plans/completed/`;
- moved 25 converted source records to `docs/plans/converted/` after assigning their remaining work to OpenSpec;
- kept operational guides, research, feature references, the canonical CNS parent design, and PR visual evidence in place;
- retained the existing redesign migration as one coupled staged program;
- created five focused active changes instead of one miscellaneous legacy backlog; and
- added `openspec/PORTFOLIO.md` as the priority-ordered master list and resume guide.

No application behavior, data model, clinical threshold, entitlement, or production setting was changed by this documentation reorganization.

## Method

Classification did not rely on checkboxes. Each candidate was compared with current source and tests, Git history, merged implementation evidence, and existing OpenSpec ownership. The audit distinguished four states that old plans often conflated: implemented, tested, app-wired, and production-authoritative.

The main evidence commits included:

| Area | Merged evidence used |
|---|---|
| myAir, medication UI, dose prompts, realtime dashboard | `85b0f93`, `9e0e234`, `b7150e3` |
| OSCAR and CPAP/barometric phases | `e24c0e6`, `1f85870`, `97b88eb` |
| HealthKit testability, random check-ins, correlation, data quality | `3b1b76f`, `c13886b`, `b93bd44`, `bcc3184` |
| song, overnight stats, provenance | `6e79908`, `1ca9453`, `ea68841`, `d09cf5e` |
| Polar foundation/integration/detail | `7a6e3ea` through `a2976e9`, `7b3ce41`, `f2c89e5` |
| debug capture, Settings, dashboard | `e093602`, `ac15402`, `a9a8a6c` |
| CNS phases 1-3 and redundant channel | `06d77c4`, `55bf243`, `4ddd042`, `e05e9f0` |
| HealthKit smart detection, AS11 context, ez Share | `723b345`, `7ad4f2c`, `80c35a0` |

These commits prove historical accepted scope landed; they do not prove that every later regression, device lifecycle, rollout, or aspirational follow-on is complete.

## Resulting active OpenSpec portfolio

The full context, benefit, expected completion state, dependencies, and resume instructions are in `openspec/PORTFOLIO.md`. Default priority is:

1. `complete-clinical-respiratory-safety` — trusted RR/apnea escalation, fault suppression, clinical review, restore continuity, and physical AS11 validation.
2. `complete-redesign-v3-migration` — data preservation, SQLite cutover, one watch-session owner, causal sync, diagnostics, rollout, and legacy retirement.
3. `complete-engineering-quality-program` — current disposition and remediation of valid Fable findings plus provider-neutral, layered validation.
4. `complete-physiological-experience` — coherent Polar/session/metric provenance, EMAY, reports, medication context, and accessibility.
5. `evaluate-device-capability-roadmap` — current evidence and explicit decisions for Oura and optional Watch/Ultra capabilities.
6. `complete-public-project-readiness` — contributor/community files, accurate public claims, safe screenshots, metadata, and release review.

`reconcile-legacy-doc-plans` is the temporary administrative change for this audit and conversion. It should be archived after review and does not compete with the product priorities above.

## Completed archive

The original content is retained as historical evidence. Old commands and old paths inside these records remain as-authored and are not current instructions.

### Completed standalone plan

- `docs/plans/completed/klaxon-phase-1-detection-engine.md`

### Completed Superpowers plans

- `docs/plans/completed/superpowers/plans/2026-03-24-resmed-myair-integration.md`
- `docs/plans/completed/superpowers/plans/2026-03-26-medications-tab-improvements.md`
- `docs/plans/completed/superpowers/plans/2026-03-28-dose-anxiety-prompt.md`
- `docs/plans/completed/superpowers/plans/2026-03-28-realtime-health-data.md`
- `docs/plans/completed/superpowers/plans/2026-03-30-oscar-cpap-import.md`
- `docs/plans/completed/superpowers/plans/2026-03-30-phase1-remaining.md`
- `docs/plans/completed/superpowers/plans/2026-03-31-phase3-cpap-barometric.md`
- `docs/plans/completed/superpowers/plans/2026-04-01-healthkit-testability.md`
- `docs/plans/completed/superpowers/plans/2026-04-03-random-check-ins.md`
- `docs/plans/completed/superpowers/plans/2026-04-04-correlation-engine.md`
- `docs/plans/completed/superpowers/plans/2026-04-17-data-quality-layer.md`
- `docs/plans/completed/superpowers/plans/2026-07-12-klaxon-phase2-monitoring.md`
- `docs/plans/completed/superpowers/plans/2026-07-12-remove-pharmacy-import.md`
- `docs/plans/completed/superpowers/plans/2026-07-12-remove-supply-tracking.md`
- `docs/plans/completed/superpowers/plans/2026-07-18-healthkit-access-smart-detection.md`
- `docs/plans/completed/superpowers/plans/2026-07-20-cns-klaxon-abc-handoff.md`
- `docs/plans/completed/superpowers/plans/2026-07-20-klaxon-phase3-ondevice.md`
- `docs/plans/completed/superpowers/plans/2026-07-20-server-redundant-alert-channel.md`
- `docs/plans/completed/superpowers/plans/tasks-healthkit-access-smart-detection.md`

### Completed Superpowers design records

- `docs/plans/completed/superpowers/specs/2026-03-24-resmed-myair-integration-design.md`
- `docs/plans/completed/superpowers/specs/2026-03-26-medications-tab-improvements-design.md`
- `docs/plans/completed/superpowers/specs/2026-03-28-dose-anxiety-prompt-design.md`
- `docs/plans/completed/superpowers/specs/2026-03-28-realtime-health-data-design.md`
- `docs/plans/completed/superpowers/specs/2026-03-30-oscar-cpap-import-design.md`
- `docs/plans/completed/superpowers/specs/2026-03-30-phase1-remaining-design.md`
- `docs/plans/completed/superpowers/specs/2026-03-31-phase3-cpap-barometric-design.md`
- `docs/plans/completed/superpowers/specs/2026-04-01-healthkit-testability-design.md`
- `docs/plans/completed/superpowers/specs/2026-04-03-random-check-ins-design.md`
- `docs/plans/completed/superpowers/specs/2026-04-04-correlation-engine-design.md`
- `docs/plans/completed/superpowers/specs/2026-04-17-conflict-analysis-design.md`
- `docs/plans/completed/superpowers/specs/2026-04-17-data-quality-layer-design.md`
- `docs/plans/completed/superpowers/specs/2026-04-18-song-tracking-design.md`
- `docs/plans/completed/superpowers/specs/2026-05-04-overnight-clinical-stats-ui-design.md`
- `docs/plans/completed/superpowers/specs/2026-05-05-cgm-spo2-provenance-design.md`
- `docs/plans/completed/superpowers/specs/2026-05-10-polar-h10-ble-design.md`
- `docs/plans/completed/superpowers/specs/2026-05-13-debug-screen-capture-design.md`
- `docs/plans/completed/superpowers/specs/2026-05-14-settings-redesign-design.md`
- `docs/plans/completed/superpowers/specs/2026-05-16-dashboard-trim-design.md`
- `docs/plans/completed/superpowers/specs/2026-05-16-polar-session-hr-detail-design.md`
- `docs/plans/completed/superpowers/specs/2026-07-18-healthkit-access-diagnostic-design.md`
- `docs/plans/completed/superpowers/specs/2026-07-18-healthkit-access-smart-detection-design.md`
- `docs/plans/completed/superpowers/specs/2026-07-20-klaxon-phase3-ondevice-design.md`
- `docs/plans/completed/superpowers/specs/2026-07-20-server-redundant-alert-channel-design.md`
- `docs/plans/completed/superpowers/specs/2026-07-23-ezshare-cpap-ingest-design.md`

## Converted archive and OpenSpec destination

| Converted source records | Remaining-work destination | Reason |
|---|---|---|
| `docs/plans/converted/rr-apnea-independent-escalation.md`; converted AS11 plan/design under `docs/plans/converted/superpowers/` | `complete-clinical-respiratory-safety` | RR/apnea was unstarted; AS11 shipped but physical lifecycle and stale-callback evidence remain |
| `docs/plans/converted/phase-4-polar-integration.md`; `docs/plans/converted/expert-review-improvement-plan.md` | `complete-physiological-experience` plus quality/public plans where explicitly mapped | Polar 4a/4b and much expert work shipped; remaining UX, provenance, report, accessibility, and current-gap decisions remain |
| `docs/plans/converted/oura/oura_ring_5_spec.md`; `oura_ring_5_spec_detailed.md`; converted Ultra design | `evaluate-device-capability-roadmap` | Foundations exist, but live/legal/protocol validation and optional product decisions remain |
| all 13 files under `docs/plans/converted/fable5-reevaluation/`; `docs/plans/converted/claude-code-setup-improvements.md` | `complete-engineering-quality-program` | Most findings and tooling shipped; unresolved IDs, later audit phases, runtime evidence, and provider-neutral tooling remain |
| `docs/plans/converted/readme-expert-improvement-plan.md` | `complete-public-project-readiness` | README/screenshots/build entry points largely shipped; community files, metadata, current audit, and release checklist remain |
| `docs/plans/converted/redesign/redesign_plan.md`; `redesign_status.md` | `complete-redesign-v3-migration` | Already reconciled into OpenSpec; stale checkboxes preserved only as historical input |

The exact converted AS11 and Ultra paths are:

- `docs/plans/converted/superpowers/plans/2026-07-20-as11-context-feed.md`
- `docs/plans/converted/superpowers/specs/2026-07-20-as11-context-feed-design.md`
- `docs/plans/converted/superpowers/specs/2026-04-20-ultra3-upgrade-design.md`

## Documents retained in place

| Path or group | Classification and reason |
|---|---|
| `openspec/changes/complete-redesign-v3-migration/RUNBOOK.md` | Active redesign operational runbook; moved into OpenSpec so task-bearing plans have one home. `docs/FINAL_REDESIGN_v3_WORK` is now only a compatibility pointer |
| `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md` | Canonical CNS parent design referenced by repository instructions; remains live supporting architecture, while active remaining work is in OpenSpec |
| `docs/DEVELOPMENT_TIMELINE.md`, `docs/FEATURES.md` | Historical/current feature reference, not authoritative implementation checklists |
| `docs/EMAY_OXIMETER.md`, `docs/POLAR_H10.md`, `docs/SERVER_SETUP.md` | Device and operational guides |
| `docs/research/` | Research and explanatory material, not accepted implementation authorization |
| `docs/pr16-visuals/`, `docs/pr-assets/`, `docs/diagrams/`, `docs/screenshots/` | Supporting visual evidence/assets; public-readiness plan owns future privacy and currency review |

## Important decisions made during regrouping

- The redesign migration was not split. Storage cutover, restore completeness, watch delegate ownership, delta sync, diagnostics, and retirement share explicit phase and rollback dependencies.
- Clinical respiratory work was separated from general sensor UX because its source-trust and clearing rules require medical review and fail-safe activation.
- Optional Oura/Ultra ideas are decision work first. Existing code does not automatically authorize production support.
- Removed pharmacy and supply features were not revived. Old proposals to write to HealthKit were not carried forward because HealthKit remains read-only unless a separate project-level ownership decision changes that rule.
- Historical archived documents remain unedited where possible, including old commands and old paths. Current instructions always point to OpenSpec.

## Limitations

- Classification used current repository evidence and Git history; it did not rerun every historical physical-device or production rollout scenario.
- Passing unit tests or the existence of a type was not counted as physical-device validation or production authority.
- External Oura/Apple policy and capability claims require fresh official verification during the device-roadmap change.
- Remaining Fable IDs require current reproduction or structural evidence before implementation.

## Verification

Completed on 2026-10-09:

- `openspec validate --all --strict`: 14 items passed, 0 failed.
- `git diff --check`: passed.
- Live stale-path scan: no references remained to the moved plan locations outside the intentionally verbatim completed/converted archives.
- Markdown local-target check across OpenSpec, this audit, and the redesign runbook: passed.
- Archive integrity check: every deleted original plan/design matched exactly one completed/converted destination before the public-repository privacy pass. Technical content was preserved; personal names, personalized device names, and absolute home paths were normalized in the archived copies where found.
- All seven active changes report complete planning artifacts. Task completion remains tracked independently inside each change; a complete artifact set does not mean its implementation tasks have shipped.
