# Tasks

## 1. Reconcile historical findings

- [ ] 1.1 Re-evaluate F-020, F-021, F-022, and F-031 against current Trends queries and paging; update `docs/plans/converted/fable5-reevaluation/FINDINGS.md` with current evidence and create focused fix tasks only for reproducible unbounded or render-risk behavior.
- [ ] 1.2 Re-evaluate F-052, F-066, F-075, F-085, F-092, and F-093 against current source/tests; record fixed, duplicate, accepted-risk, deferred-with-trigger, obsolete, or actionable disposition for each.
- [ ] 1.3 Link F-059 server pagination to the existing redesign task when it is the same `/api/data` work, or document a distinct failure and task; verify there is no duplicate implementation owner.
- [ ] 1.4 Reconcile phases 4-8 of the converted Fable plan and move every still-valid item to this change or another named OpenSpec owner; verify no unchecked legacy item remains ambiguous.

## 2. Deliver high-risk actionable fixes

- [ ] 2.1 Fix accepted Trends query/paging issues in the named `AnxietyWatch/Views/Trends/` and model/query files, adding Swift tests for dense 90-day data, empty data, and bounded fetch behavior; verify targeted tests and zero-warning build pass.
- [ ] 2.2 Fix accepted SwiftUI render or accessibility findings with regression tests for navigation, Dynamic Type, VoiceOver, NaN/empty chart input, and main-thread behavior; run `swiftui-render-pitfall-detector` and relevant chart audit on the diff.
- [ ] 2.3 Fix accepted server defects in named endpoints/tests, including pagination only when not redesign-owned; verify `python -m pytest tests/` and `flake8 . --max-line-length=120 --exclude=__pycache__` pass in `server/`.

## 3. Make quality gates provider-neutral

- [ ] 3.1 Add or consolidate a repository-owned pre-PR command that runs applicable lint, tests, stale-path checks, and OpenSpec validation without requiring a particular model; verify it succeeds from a clean documented environment.
- [ ] 3.2 Reconcile `AGENTS.md`, `CLAUDE.md`, and `.github` instructions so canonical requirements agree while tool-specific conveniences point back to the same gates; verify an instruction-file consistency scan finds no conflicting rule.
- [ ] 3.3 Replace durable dependencies on Fable/Claude session handoffs with repository paths and commands, then mark transient handoff files historical; verify a contributor can follow the workflow without the original conversation.

## 4. Establish layered runtime evidence

- [ ] 4.1 Add a reusable evidence-matrix template covering static, unit, simulator, fresh-install, restore, physical-device, server, accessibility, and performance layers; verify each row requires target, configuration, result, and evidence path.
- [ ] 4.2 Run the matrix for the highest-risk remaining paths, including first-run authorization and restore on a genuinely fresh install; record unavailable hardware layers as unvalidated rather than passed.
- [ ] 4.3 Run performance and dense-data checks applicable to Trends, sync, and watch paths; link redesign-owned memory/battery/latency gaps instead of duplicating them.

## 5. Close the program

- [ ] 5.1 Run `swift-pre-pr-reviewer` and each specialist reviewer required by touched surfaces, resolving all Will Block and non-deferred Should Address findings.
- [ ] 5.2 Update all finding and phase dispositions with PR links and post-merge notes, and verify every actionable item is complete or owned by a named active OpenSpec change.

## Workflow follow-up

- Archive this change and the transient Fable handoff documents after all dispositions and owned fixes are complete.
