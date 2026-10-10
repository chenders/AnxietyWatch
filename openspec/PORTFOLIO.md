# AnxietyWatch OpenSpec Portfolio

This is the master list of active OpenSpec plans. It is ordered by expected positive impact and importance, with clinical safety and preservation of user data ahead of convenience, optional-device, and repository-presentation work.

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
| 1 | [`complete-clinical-respiratory-safety`](changes/complete-clinical-respiratory-safety/) | Highest safety impact. It closes the gap between the existing CNS engine and trustworthy RR/apnea evidence, while preventing stale or invalid signals from looking reassuring. | Trusted RR/apnea sources can independently escalate through reviewed rules; faults cannot clear warnings; fresh-install/restore continuity and physical AirSense lifecycle behavior are proven. |
| 2 | [`complete-redesign-v3-migration`](changes/complete-redesign-v3-migration/) | Highest data-integrity and platform-reliability impact. It finishes storage, restore symmetry, WatchConnectivity ownership, delta sync, diagnostics, and safe retirement of legacy paths. | App-only data has a tested trip back down from the server; storage and watch transport have parity and rollback evidence; diagnostics expose failures; legacy paths retire only after controlled rollout. |
| 3 | [`complete-engineering-quality-program`](changes/complete-engineering-quality-program/) | Reduces crash, hang, unbounded-query, first-run, restore, and regression risk across all later work. It also tells us which old findings are actually still real. | Every inherited Fable finding has a current disposition, valid high-risk defects are fixed, validation evidence is layered honestly, and quality gates work independently of a specific AI tool. |
| 4 | [`complete-physiological-experience`](changes/complete-physiological-experience/) | Largest direct day-to-day user benefit after safety and reliability. It makes sensor/session information understandable, traceable, accessible, and connected to journal/medication context. | Polar sessions connect coherently to charts, metric details show provenance/freshness, EMAY/report gaps are resolved, and missing data is clearly different from normal data. |
| 5 | [`evaluate-device-capability-roadmap`](changes/evaluate-device-capability-roadmap/) | Prevents optional Oura/Ultra ideas from consuming effort or collecting sensitive data without current platform, privacy, clinical, and maintenance evidence. | Every Oura and Watch/Ultra idea has an explicit accept/defer/reject/research decision; accepted items get their own focused plans and unsupported ideas no longer appear to be promised work. |
| 6 | [`complete-public-project-readiness`](changes/complete-public-project-readiness/) | Improves contributor onboarding, public trust, privacy hygiene, and release presentation, but does not change the app's core safety or reliability. | Contributors have current templates and guidance, public claims and screenshots match reality, remote metadata is verified, and releases use a repeatable privacy/documentation checklist. |

Priority describes default sequencing, not a requirement to finish a large plan before beginning every lower item. A small independent task may proceed sooner when it does not distract from a higher-risk gate.

## 1. Complete clinical respiratory safety

**Origin and memory cue:** The CNS Klaxon phases shipped, and the AirSense 11 context feed shipped, but an older RR/apnea independent-escalation proposal was never completed. The context-feed plan also left physical reconnect/background testing and a stale-socket callback race unproven. These are grouped because all of them affect whether respiratory evidence may safely change an alert.

**Current state:** The app-level `AnxietyWatch/Services/CNSRisk/` pipeline is the clinical side-effect authority. AirSense context-feed types and integration exist. A production-authoritative, clinically reviewed independent RR/apnea path does not.

**Benefit:** Earlier warning from valid respiratory evidence without allowing missing, invalid, disconnected, or ambiguous data to create false reassurance.

**Key boundaries:** HealthKit remains read-only and authoritative for HealthKit-owned observations. New behavior remains disabled until source semantics, medical review, deterministic tests, fresh-install/restore, and physical-device evidence pass.

**Resume at:** [`proposal.md`](changes/complete-clinical-respiratory-safety/proposal.md), then [`design.md`](changes/complete-clinical-respiratory-safety/design.md) and [`tasks.md`](changes/complete-clinical-respiratory-safety/tasks.md). Historical inputs are `docs/plans/converted/rr-apnea-independent-escalation.md` and the converted AS11 plan/design.

## 2. Complete redesign v3 migration

**Origin and memory cue:** A large redesign record was recovered into this repository while the branch/worktree situation was being untangled from unrelated AnxietyWatch2 history. The unrelated branch is quarantined and must never be merged here. The actual AnxietyWatch redesign foundation already landed, but several foundations are not yet app-wired or production-authoritative.

**Current state:** Actor-isolated ingestion, GRDB/SQLite foundations, HLC/delta-sync foundations, binary watch transport foundations, and diagnostics components exist. The active checklist is currently partially complete; legacy storage, REST, and watch paths remain authoritative where replacement parity is not proven.

**Benefit:** Prevents silent data loss on device replacement, removes competing WatchConnectivity delegates, makes high-rate storage and sync deterministic, and provides measurable rollback and operations evidence.

**Key boundaries:** Implemented, tested, app-wired, and production-authoritative are separate states. Every uploaded table needs a server query and restore importer. Each phase has an independent control and rollback.

**Resume at:** [`proposal.md`](changes/complete-redesign-v3-migration/proposal.md), [`design.md`](changes/complete-redesign-v3-migration/design.md), [`tasks.md`](changes/complete-redesign-v3-migration/tasks.md), and [`RUNBOOK.md`](changes/complete-redesign-v3-migration/RUNBOOK.md). The runbook's early branch/worktree sections are a historical incident record, not an instruction to merge the quarantined AnxietyWatch2 branch.

## 3. Complete engineering quality program

**Origin and memory cue:** The Fable reevaluation generated an atlas, audit, many fixes, and phases 4-8. Most findings were fixed through PRs #157-#179, but several IDs and whole late phases never received a final disposition. A separate Claude/Copilot setup plan also left provider-neutral workflow questions.

**Current state:** Most early audit findings and repository review infrastructure shipped. Remaining candidate IDs include F-020/F-021/F-022/F-031, F-052, F-059, F-066, F-075, F-085, F-092, and F-093; these must be checked against current code rather than assumed valid.

**Benefit:** Finds the real remaining high-risk defects, avoids redoing obsolete audit work, bounds dense-data/query behavior, and makes testing/review reproducible for any contributor or assistant.

**Key boundaries:** Static evidence is not runtime proof. Work already owned by redesign, clinical, or experience plans is linked rather than duplicated. Relevant tests ship with each fix.

**Resume at:** [`proposal.md`](changes/complete-engineering-quality-program/proposal.md), [`design.md`](changes/complete-engineering-quality-program/design.md), and [`tasks.md`](changes/complete-engineering-quality-program/tasks.md). Historical evidence is preserved in `docs/plans/converted/fable5-reevaluation/` and `docs/plans/converted/claude-code-setup-improvements.md`.

## 4. Complete physiological experience

**Origin and memory cue:** Polar, EMAY, provenance, dashboard, Settings, reports, and expert-review plans were written at different times. Their foundations largely shipped, but remaining user-facing work was scattered and sometimes mixed with now-retired features.

**Current state:** Polar acquisition and a heart-rate session detail exist; provenance and several redesigned views exist. Cross-chart session continuity, consistent metric detail/provenance, some EMAY/report behavior, accessibility, and current expert-review dispositions remain incomplete or unverified.

**Benefit:** Users can understand what was measured, by which source, when it was current, how it relates to a session or dose, and what unavailable data means.

**Key boundaries:** Do not revive removed pharmacy/supply features. Do not write to HealthKit. Associations never become causal claims. App-only records require export and symmetric restore.

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

**Key boundaries:** No production behavior changes. Screenshots and examples must use fictional data. Remote GitHub settings count only after observed verification.

**Resume at:** [`proposal.md`](changes/complete-public-project-readiness/proposal.md), [`design.md`](changes/complete-public-project-readiness/design.md), and [`tasks.md`](changes/complete-public-project-readiness/tasks.md). The converted README improvement plan is historical input only.

## Portfolio dependencies and overlap rules

- `complete-redesign-v3-migration` owns SQLite cutover, restore manifests, causal/delta sync, WatchConnectivity consolidation, diagnostics wiring, and legacy retirement.
- `complete-clinical-respiratory-safety` owns whether respiratory evidence can affect clinical warnings; it consumes transport or restore work from redesign rather than recreating it.
- `complete-physiological-experience` owns user-facing sensor/session exploration; it does not redefine ingestion truth or sync infrastructure.
- `complete-engineering-quality-program` owns finding disposition and cross-cutting verification; it links to the plan that owns a discovered behavior change.
- `evaluate-device-capability-roadmap` owns decisions only. Accepted implementation becomes a new focused change.
- `complete-public-project-readiness` owns public documentation and repository presentation, not product behavior.

## Administrative change

[`reconcile-legacy-doc-plans`](changes/reconcile-legacy-doc-plans/) is the temporary governance change that created this portfolio, archived completed plans, converted still-relevant plans, and produced the document audit. It should be archived after strict validation and review. It is not an ongoing product-work priority.

## Canonical specifications are not task lists

The directories under `openspec/specs/` define accepted current behavior and implementation status. They are durable capabilities, not parallel plans. Active work belongs in the changes above; completed changes are eventually archived under `openspec/changes/archive/` after their accepted deltas are merged into canonical specs.
