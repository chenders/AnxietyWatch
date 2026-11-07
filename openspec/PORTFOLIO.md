# AnxietyWatch OpenSpec Portfolio

This is the master list of active OpenSpec plans. It is ordered by expected positive impact and importance, with preservation of user data and platform reliability ahead of convenience, optional-device, and repository-presentation work.

**CNS-depression klaxon ownership:** On-device CNS detection and alarm product work no longer belongs in this repository. It is superseded by the separate **AnxietyWatch2** project (local-first Pi vitals core and multi-modal alarm design). Active removal is tracked in [`remove-cns-klaxon`](changes/remove-cns-klaxon/). Do not schedule new in-app klaxon, tier-engine, or RR/apnea escalation features here.

Use this file when returning after time away:

1. Read the priority table below.
2. Open the selected change's `proposal.md` for why and scope.
3. Read `design.md` for current-state evidence, decisions, ownership, and rollback.
4. Run `openspec status --change <name>` and continue from the first unfinished group in `tasks.md`.
5. Re-check current code and external constraints before implementing old assumptions.
6. Update the plan's evidence and implementation status in the same PR as shipped work.

## Priority order

| Priority | OpenSpec plan | Why it matters | What will be different when complete |
|---:|---|---|---|
| 1 | [`remove-cns-klaxon`](changes/remove-cns-klaxon/) | Removes a superseded clinical-alert product surface so this app no longer claims or maintains dual ownership of CNS-depression detection/alarming. | No on-device CNS engine, klaxon UI/alarms, server backstop, or public early-warning claims remain; AnxietyWatch2 is the sole product home for that line. |
| 2 | [`complete-redesign-v3-migration`](changes/complete-redesign-v3-migration/) | Highest data-integrity and platform-reliability impact. It finishes storage, restore symmetry, WatchConnectivity ownership, delta sync, diagnostics, and safe retirement of legacy paths. | App-only data has a tested trip back down from the server; storage and watch transport have parity and rollback evidence; diagnostics expose failures; legacy paths retire only after controlled rollout. |
| 3 | [`complete-engineering-quality-program`](changes/complete-engineering-quality-program/) | Reduces crash, hang, unbounded-query, first-run, restore, and regression risk across all later work. It also tells us which old findings are actually still real. | Every inherited Fable finding has a current disposition, valid high-risk defects are fixed, validation evidence is layered honestly, and quality gates work independently of a specific AI tool. |
| 4 | [`complete-physiological-experience`](changes/complete-physiological-experience/) | Largest direct day-to-day user benefit after reliability. It makes sensor/session information understandable, traceable, accessible, and connected to journal/medication context. | Polar sessions connect coherently to charts, metric details show provenance/freshness, EMAY/report gaps are resolved, and missing data is clearly different from normal data. |
| 5 | [`evaluate-device-capability-roadmap`](changes/evaluate-device-capability-roadmap/) | Prevents optional Oura/Ultra ideas from consuming effort or collecting sensitive data without current platform, privacy, clinical, and maintenance evidence. | Every Oura and Watch/Ultra idea has an explicit accept/defer/reject/research decision; accepted items get their own focused plans and unsupported ideas no longer appear to be promised work. |
| 6 | [`complete-public-project-readiness`](changes/complete-public-project-readiness/) | Improves contributor onboarding, public trust, privacy hygiene, and release presentation, but does not change the app's core reliability. | Contributors have current templates and guidance, public claims and screenshots match reality, remote metadata is verified, and releases use a repeatable privacy/documentation checklist. |

Priority describes default sequencing, not a requirement to finish a large plan before beginning every lower item. A small independent task may proceed sooner when it does not distract from a higher-risk gate.

## 1. Remove CNS klaxon (superseded product)

**Origin and memory cue:** Generation-one shipped an on-device CNSRisk engine, dose-window arming, package pipeline dual engine, server backstop/alert channel, and docs claiming early-warning detection. AnxietyWatch2 supersedes that product line (Pi-side detection/alarm design; phone is not an analysis engine per GEN1 parity).

**Current state:** Removal is in progress under [`remove-cns-klaxon`](changes/remove-cns-klaxon/). Code and claims may still exist until that change's tasks complete.

**Benefit:** Single ownership boundary, honest public claims, and no maintenance of a parallel clinical-alert stack in this app.

**Key boundaries:** Keep Polar/EMAY/HealthKit/CPAP as journal and trend data sources. Do not merge quarantined AnxietyWatch2 branches into this repo. Do not reintroduce a klaxon without a new OpenSpec change that explicitly reverses retirement.

**Resume at:** [`proposal.md`](changes/remove-cns-klaxon/proposal.md), [`design.md`](changes/remove-cns-klaxon/design.md), and [`tasks.md`](changes/remove-cns-klaxon/tasks.md).

## 2. Complete redesign v3 migration

**Origin and memory cue:** A large redesign record was recovered into this repository while the branch/worktree situation was being untangled from unrelated AnxietyWatch2 history. The unrelated branch is quarantined and must never be merged here. The actual AnxietyWatch redesign foundation already landed, but several foundations are not yet app-wired or production-authoritative.

**Current state:** Actor-isolated ingestion, GRDB/SQLite foundations, HLC/delta-sync foundations, binary watch transport foundations, and diagnostics components exist. The active checklist is currently partially complete; legacy storage, REST, and watch paths remain authoritative where replacement parity is not proven. Package/app CNS dual-engine language is being retired by `remove-cns-klaxon`.

**Benefit:** Prevents silent data loss on device replacement, removes competing WatchConnectivity delegates, makes high-rate storage and sync deterministic, and provides measurable rollback and operations evidence.

**Key boundaries:** Implemented, tested, app-wired, and production-authoritative are separate states. Every uploaded table needs a server query and restore importer. Each phase has an independent control and rollback.

**Resume at:** [`proposal.md`](changes/complete-redesign-v3-migration/proposal.md), [`design.md`](changes/complete-redesign-v3-migration/design.md), [`tasks.md`](changes/complete-redesign-v3-migration/tasks.md), and [`RUNBOOK.md`](changes/complete-redesign-v3-migration/RUNBOOK.md). The runbook's early branch/worktree sections are a historical incident record, not an instruction to merge the quarantined AnxietyWatch2 branch.

## 3. Complete engineering quality program

**Origin and memory cue:** The Fable reevaluation generated an atlas, audit, many fixes, and phases 4-8. Most findings were fixed through PRs #157-#179, but several IDs and whole late phases never received a final disposition. A separate Claude/Copilot setup plan also left provider-neutral workflow questions.

**Current state:** Most early audit findings and repository review infrastructure shipped. Remaining candidate IDs include F-020/F-021/F-022/F-031, F-052, F-059, F-066, F-075, F-085, F-092, and F-093; these must be checked against current code rather than assumed valid.

**Benefit:** Finds the real remaining high-risk defects, avoids redoing obsolete audit work, bounds dense-data/query behavior, and makes testing/review reproducible for any contributor or assistant.

**Key boundaries:** Static evidence is not runtime proof. Work already owned by redesign or experience plans is linked rather than duplicated. Relevant tests ship with each fix.

**Resume at:** [`proposal.md`](changes/complete-engineering-quality-program/proposal.md), [`design.md`](changes/complete-engineering-quality-program/design.md), and [`tasks.md`](changes/complete-engineering-quality-program/tasks.md). Historical evidence is preserved in `docs/plans/converted/fable5-reevaluation/` and `docs/plans/converted/claude-code-setup-improvements.md`.

## 4. Complete physiological experience

**Origin and memory cue:** Polar, EMAY, provenance, dashboard, Settings, reports, and expert-review plans were written at different times. Their foundations largely shipped, but remaining user-facing work was scattered and sometimes mixed with now-retired features.

**Current state:** Polar acquisition and a heart-rate session detail exist; provenance and several redesigned views exist. Cross-chart session continuity, consistent metric detail/provenance, some EMAY/report behavior, accessibility, and current expert-review dispositions remain incomplete or unverified.

**Benefit:** Users can understand what was measured, by which source, when it was current, how it relates to a session or dose, and what unavailable data means.

**Key boundaries:** Do not revive removed pharmacy/supply features. Do not write to HealthKit. Associations never become causal claims. App-only records require export and symmetric restore. Do not revive CNS Monitoring UI.

**Resume at:** [`proposal.md`](changes/complete-physiological-experience/proposal.md), [`design.md`](changes/complete-physiological-experience/design.md), and [`tasks.md`](changes/complete-physiological-experience/tasks.md). The converted Phase 4 Polar and expert-review plans are historical input only.

## 5. Evaluate device capability roadmap

**Origin and memory cue:** The Oura plans mixed completed cloud/OAuth/server/UI work with optional direct BLE. The Ultra 3 plan mixed a shipped sensor foundation with much more speculative ideas such as Action button workflows, voice, State of Mind, location, ECG, prediction, and Smart Stack.

**Current state:** Substantial Oura and watch sensor foundations exist and have tests, but live account/legal validation and production support decisions are incomplete. Several Ultra ideas may conflict with privacy, platform availability, clinical boundaries, or the HealthKit read-only rule.

**Benefit:** Time and sensitive-data exposure are spent only on supportable capabilities with a clear user benefit. Accepted ideas become small, reviewable implementation plans.

**Key boundaries:** This is a decision plan, not blanket authorization. Each idea gets its own current evidence and disposition. Accepted work requires a separate OpenSpec implementation change.

**Resume at:** [`proposal.md`](changes/evaluate-device-capability-roadmap/proposal.md), [`design.md`](changes/evaluate-device-capability-roadmap/design.md), and [`tasks.md`](changes/evaluate-device-capability-roadmap/tasks.md). Historical inputs are under `docs/plans/converted/oura/` and the converted Ultra design.

## 6. Complete public project readiness

**Origin and memory cue:** The README improvement effort produced the current README, screenshots, and build entry points, but contributor/community files, remote repository metadata, and a repeatable public release review were left unfinished.

**Current state:** Public presentation is substantially improved. Missing or unverified work includes issue templates, contribution guidance, code of conduct, current repository description/topics, screenshot re-audit, and release documentation checks.

**Benefit:** New contributors can work safely without rediscovering repository rules, and public users see accurate, privacy-safe claims and visuals.

**Key boundaries:** No production behavior changes. Screenshots and examples must use fictional data. Remote GitHub settings count only after observed verification. Public claims must not describe an in-app CNS klaxon after `remove-cns-klaxon` ships.

**Resume at:** [`proposal.md`](changes/complete-public-project-readiness/proposal.md), [`design.md`](changes/complete-public-project-readiness/design.md), and [`tasks.md`](changes/complete-public-project-readiness/tasks.md). The converted README improvement plan is historical input only.

## Cancelled — not scheduled

### `complete-clinical-respiratory-safety` (cancelled)

**Status:** **Cancelled.** Would have finished RR/apnea independent escalation and AirSense lifecycle validation on top of the generation-one CNS klaxon. That product line is retired from this repository by [`remove-cns-klaxon`](changes/remove-cns-klaxon/). Do not implement the change directory's tasks. Historical artifacts remain only until archive cleanup.

## Portfolio dependencies and overlap rules

- `remove-cns-klaxon` owns deletion of CNS/klaxon code, docs claims, server backstop/alert channel, and cancellation of clinical-respiratory follow-ons.
- `complete-redesign-v3-migration` owns SQLite cutover, restore manifests, causal/delta sync, WatchConnectivity consolidation, diagnostics wiring, and legacy retirement (without dual CNS clinical engines after removal).
- `complete-physiological-experience` owns user-facing sensor/session exploration; it does not redefine ingestion truth or sync infrastructure and must not revive CNS Monitoring.
- `complete-engineering-quality-program` owns finding disposition and cross-cutting verification; it links to the plan that owns a discovered behavior change.
- `evaluate-device-capability-roadmap` owns decisions only. Accepted implementation becomes a new focused change.
- `complete-public-project-readiness` owns public documentation and repository presentation, not product behavior.

## Administrative change

[`reconcile-legacy-doc-plans`](changes/reconcile-legacy-doc-plans/) is the temporary governance change that created this portfolio, archived completed plans, converted still-relevant plans, and produced the document audit. It should be archived after strict validation and review. It is not an ongoing product-work priority.

## Canonical specifications are not task lists

The directories under `openspec/specs/` define accepted current behavior and implementation status. They are durable capabilities, not parallel plans. Active work belongs in the changes above; completed changes are eventually archived under `openspec/changes/archive/` after their accepted deltas are merged into canonical specs.
