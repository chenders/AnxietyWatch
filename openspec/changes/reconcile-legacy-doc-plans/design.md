# Design

## Context

See `proposal.md` for motivation. The repository currently has three planning systems in `docs/`: completed Superpowers implementation plans with stale unchecked boxes, partially completed roadmap/audit plans, and the active OpenSpec redesign-v3 runbook. Classification must use the current tree and merged history, not document syntax.

The conversion is documentation-only. Later implementation remains subject to the repository's HealthKit ownership, restore round-trip, single-WCSession-owner, actor-isolation, public-repository, zero-warning, and specialized-review rules.

### Current-state evidence

| Legacy work | Observed evidence | Classification and remaining boundary |
|---|---|---|
| March-April implementation plans: myAir, medication UI, dose prompts, real-time dashboard, OSCAR/CPAP, HealthKit testability, random check-ins, correlation, and data quality | Merged commits `85b0f93`, `9e0e234`, `b7150e3`, `e24c0e6`, `1f85870`, `97b88eb`, `3b1b76f`, `c13886b`, `b93bd44`, and `bcc3184`; corresponding current source/tests | Completed; archive plan/design pairs |
| Polar H10 implementation | Merged phase commits `7a6e3ea` through `a2976e9`, trend integration `7b3ce41`, live surfaces, and session detail `f2c89e5`; `AnxietyWatch/Views/Trends/PolarSessionHRDetailView.swift` and tests | Core phases completed; Phase 4 plan still contains valid chart drill-down/persona polish and future tooling work, so convert that plan |
| CNS Klaxon phases 1-3 and redundant server channel | `AnxietyWatch/Services/CNSRisk/`, `CNSMonitoringCoordinator.swift`, `AlertChannelUploader.swift`, `server/api/alert_channel.py`, and focused Swift/Python tests; merged commits `06d77c4`, `55bf243`, `4ddd042`, `e05e9f0` | Implemented historical plans; archive them. Preserve remaining RR/apnea and clinical-review debt in `complete-clinical-respiratory-safety` |
| AS11 context feed | PR #28 / `7ad4f2c`; `AS11WebSocketClient`, coordinator integration, server endpoints, and tests | Code shipped, but plan explicitly records unperformed physical lifecycle validation and a missing stale-socket race harness; convert |
| Redesign v3 | Merge `720609a`; current `complete-redesign-v3-migration` reconciles implemented, wired, and authoritative states | Already converted; move `redesign_plan.md` and `redesign_status.md` to converted archive, retain active runbook |
| Oura Ring plan | Oura cloud models/client/UI, server ingest, OAuth, webhook, and BLE foundation landed through PRs #16, #33, and #34 | Automated Phase 1/2 scope implemented; live-account/legal validation and optional BLE production decision remain, so convert |
| Ultra 3 roadmap | `SensorCaptureSession`, `AccelerometerProcessor`, derived models, sync, server persistence, and restore implement the sensor foundation | Predictive, voice/action, location, ECG, and other roadmap items are not implemented or require a product decision; convert |
| Expert review/public-launch plans | CI, Makefile, screenshots, dashboard redesign, testability, widgets, and many fixes shipped; issue templates, conduct/contribution docs, several clinical UX ideas, and some quality items do not exist | Convert only still-valid work; explicitly retire pharmacy/supply and HealthKit-write proposals that conflict with current product decisions |
| Fable 5 reevaluation | Atlas and audit merged; most findings are marked fixed through PRs #157-#179 | Convert stable remaining IDs F-020/021/022/031, F-052/059/066/075/085/092/093 and unfinished phases 4-8; do not recreate fixed findings |
| Claude/Copilot workflow plan | Pre-PR reviewer, hooks, specialized agents, Semgrep, and instruction rules exist under `.claude/`, `.github/`, and `.semgrep/` | Convert provider-neutral remaining decisions such as a stable invocation wrapper and auditor consolidation; do not require a historical model/session |

## Goals / Non-Goals

**Goals:**

- Preserve the historical record while making OpenSpec the only active backlog.
- Maintain traceability from each converted source document to concrete remaining tasks.
- Separate already-shipped behavior, validated behavior, pending validation, and speculative roadmap ideas.
- Avoid duplicate work with `complete-redesign-v3-migration`.

**Non-Goals:**

- Implementing any recovered task in this documentation change.
- Reopening removed pharmacy import or prescription-supply features.
- Approving HealthKit writes, location tracking, predictive clinical behavior, or optional BLE merely because an old document proposed them.
- Moving operational guides, research reports, feature references, or PR visual-review records that are not work-instruction sources.

## Decisions

### 1. Use a small portfolio of cohesive changes

This change owns only document classification and portfolio governance. Remaining work is grouped by durable outcome into `complete-clinical-respiratory-safety`, `complete-physiological-experience`, `evaluate-device-capability-roadmap`, `complete-engineering-quality-program`, and `complete-public-project-readiness`.

**Alternative considered:** one consolidated legacy backlog. Rejected because it coupled clinical logic, product UX, optional hardware, repository governance, and audit cleanup without a shared implementation or rollout boundary.

### 2. Archive by accepted scope, not unchecked boxes

A historical plan counts as completed when its stated accepted deliverable is present, tested, and merged, even if later maintenance changed details or the original checkboxes were never updated. Scope changes are recorded in the audit instead of making a finished plan perpetually active.

**Alternative considered:** classify any unchecked file as unfinished. Rejected because nearly every March-April plan is unchecked despite direct merge evidence.

### 3. Preserve archive-relative plan/spec structure

Completed Superpowers plan/design pairs move to `docs/plans/completed/superpowers/{plans,specs}`. Converted sources move to `docs/plans/converted/`, using subdirectories for bundles. Repository references are updated to the archive path where a historical design remains useful.

### 4. Keep canonical and operational references live

The CNS parent design referenced by repository instructions, device guides, `DEVELOPMENT_TIMELINE.md`, `FEATURES.md`, research, and PR visual records remain in their current locations. The redesign runbook moves into `complete-redesign-v3-migration`; `docs/FINAL_REDESIGN_v3_WORK` remains only as a compatibility pointer. Explicit future-work bullets in reference documents are summarized in this change, but operational/reference material is not mistaken for a second active backlog.

### 5. Require decision gates for speculative roadmap work

Ultra/watch, location, predictive modeling, HealthKit writes, and optional Oura BLE become decision tasks before implementation tasks. Absence of code is not treated as implementation authorization.

### 6. Respect existing ownership boundaries

HealthKit remains the source of truth and is read-only. App-level `Services/CNSRisk` remains the clinical side-effect owner. `complete-redesign-v3-migration` owns SQLite migration, symmetric restore, WCSession consolidation, delta sync, diagnostics wiring, and retirement. This change links those tasks rather than duplicating them.

### 7. Use one validator for local and hosted enforcement

The repository keeps the executable OpenSpec checks in one shared script. That script runs its own focused unit tests, `openspec validate --all --strict`, and a local Markdown-target scan across `openspec/`. A tracked `.githooks/pre-push` delegates to the shared script; contributors enable it once with `git config core.hooksPath .githooks`. GitHub Actions invokes the same script for pull requests that change OpenSpec or its validator, using the repository's known-working `@fission-ai/openspec` version rather than an unpinned latest release.

**Alternative considered:** duplicate validation commands in the hook and workflow. Rejected because the two gates could silently drift and accept different content.

## Risks / Trade-offs

- **A plan is classified complete although a later regression exists** -> Record completion as historical scope, then track the regression by stable finding or a new OpenSpec task.
- **The consolidated backlog becomes too broad to implement safely** -> Split a coherent task group into a focused OpenSpec change before applying code; keep stable source IDs in both records.
- **Moved links break** -> Preserve paired directory layout and run a repository-wide stale-path scan after moves.
- **Speculative ideas look approved** -> Put product/privacy/clinical decision tasks before implementation and state that not-implemented roadmap items are not commitments.
- **Overlap with redesign-v3 causes duplicate edits** -> Every implementation task checks both active changes and cites the authoritative task instead of copying it.
- **Medical behavior is changed from old prose without review** -> Require `medical-data-accuracy-reviewer`, focused tests, and explicit clinical-review evidence for every CNS, HealthKit, CPAP, Polar, EMAY, SpO2, RR, or apnea task.
- **Tracked Git hooks are not enabled automatically by cloning** -> Document the one-time `core.hooksPath` command, configure the current checkout, and retain pull-request CI as the authoritative non-bypassable backstop.
- **Local and CI OpenSpec versions diverge** -> Pin CI to the repository's known-working CLI release and make the shared validator print the detected local version for diagnosis.

## Migration Plan

1. Create this OpenSpec change and capture remaining requirements and tasks.
2. Move completed plans/designs into the completed archive and partial/superseded instructions into the converted archive.
3. Update references whose historical target moved and add `docs/PLAN_DOCUMENT_AUDIT.md`.
4. Add the shared validator, its focused tests, the tracked pre-push hook, activation documentation, and the path-filtered GitHub Actions check.
5. Run strict OpenSpec validation, Markdown/link/path scans, validator failure-path tests, and verify that no original instruction file exists in two locations.
6. Implement future task groups only through their focused OpenSpec change and dependency order in `openspec/PORTFOLIO.md`.

Rollback is a documentation-only revert restoring the prior paths and removing this change. No database, HealthKit, server, watch, or user-data migration occurs during conversion.
