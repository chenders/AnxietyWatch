# Design

## Context

See `proposal.md` for motivation. The converted Fable reevaluation contains completed phases, unresolved IDs, provisional handoffs, and broad later-phase checklists. The converted setup plan also includes both implemented repository support and unfinished model-specific ideas. This program owns the remaining engineering-quality work, but not feature requirements already owned elsewhere.

| Legacy source | Current evidence | Disposition |
|---|---|---|
| `docs/plans/converted/fable5-reevaluation/` | `FINDINGS.md`, current source/tests, and merged fixes | Reconcile unresolved IDs and remaining phases against current code |
| `docs/plans/converted/claude-code-setup-improvements.md` | `AGENTS.md`, `.claude/`, `.github/`, CI and repository scripts | Keep provider-neutral tooling gaps; retire session/model-specific instructions |
| `complete-redesign-v3-migration` | active storage, sync, watch, diagnostics tasks | Link overlapping work; do not duplicate it |

The major unresolved candidates include Trends query/paging findings F-020/F-021/F-022/F-031, server pagination F-059, deferred F-052/F-066/F-075/F-085, and queued F-092/F-093. Their IDs are historical handles, not proof they remain defects.

## Goals / Non-Goals

**Goals:**

- Produce a complete current disposition for inherited findings.
- Fix valid high-impact defects through focused, test-backed increments.
- Make quality gates repeatable across tools and execution environments.

**Non-Goals:**

- Re-running every historical audit exactly as originally scripted.
- Duplicating redesign migration, clinical, or UX feature tasks.
- Treating static analysis as runtime confirmation.

## Decisions

### 1. Reproduction and ownership precede implementation

Each unresolved finding is checked against current code and assigned an owner. If another OpenSpec plan already owns the behavior, this plan links to it. The rejected alternative is copying all unchecked boxes forward.

### 2. Findings are delivered in risk-based batches

Data-loss, clinical correctness, first-run/restore, crash/hang, and unbounded-query issues precede maintainability polish. Each batch remains small enough for targeted review and rollback.

### 3. Validation evidence is layered

Static, unit, simulator, fresh-install, restore, server, physical-device, and field-performance evidence are recorded separately. No lower layer implies a higher one.

### 4. Repository workflow is provider-neutral

Durable commands, hooks, instructions, and review roles live in the repository. Model-specific convenience may exist, but it cannot be the only way to satisfy a gate.

### 5. Data and actor boundaries follow owning specs

HealthKit ownership, restore symmetry, actor isolation, WCSession delegate ownership, and phased migration come from the canonical specs. A quality fix may enforce those boundaries but cannot silently redefine them.

## Risks / Trade-offs

- [Historical finding is stale] → Require current reproduction or structural evidence before coding.
- [One program becomes a dumping ground] → Route feature and migration behavior to their owning changes.
- [Runtime matrix is expensive] → Apply only relevant layers while explicitly recording not-applicable and not-run.
- [Tooling overfits one assistant] → Keep canonical commands and criteria model-neutral.

## Migration Plan

1. Build the finding disposition table and link duplicate owners.
2. Address the highest-risk actionable batch first.
3. Establish the validation matrix and provider-neutral review entry point.
4. Complete remaining valid batches and runtime evidence.
5. Archive transient handoff documents once their information is durable here.
