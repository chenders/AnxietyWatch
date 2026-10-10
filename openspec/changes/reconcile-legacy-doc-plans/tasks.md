# Tasks

## 1. Inventory and classify

- [x] 1.1 Inventory work-instruction documents under `docs/` and compare their checklists with current source, tests, OpenSpec coverage, and merged Git history; verify every candidate is classified completed, converted, or retained in `docs/PLAN_DOCUMENT_AUDIT.md`.
- [x] 1.2 Separate active plans from operational guides, research, feature references, and PR visual records; verify retained non-plan documents have a stated reason in the audit.

## 2. Archive without losing history

- [x] 2.1 Move 45 completed plan/design records under `docs/plans/completed/` while preserving their original content as historical evidence; verify the audit lists every destination.
- [x] 2.2 Move 25 partially complete, superseded, or still-actionable records under `docs/plans/converted/` only after their remaining work has an OpenSpec owner; verify the audit maps every converted group to that owner.
- [x] 2.3 Update live README, code-comment, instruction, canonical-design, redesign-runbook, and OpenSpec references to moved documents; verify a stale-path scan has no live broken target.

## 3. Create the coherent OpenSpec portfolio

- [x] 3.1 Create focused changes for clinical respiratory safety, physiological experience, device-capability decisions, engineering quality, and public-project readiness; verify each has proposal, specs, design, tasks, evidence, rollback, and resume context.
- [x] 3.2 Preserve `complete-redesign-v3-migration` as the owner of its coupled storage/watch/sync/diagnostics rollout and remove duplicate ownership from new plans; verify overlap rules are explicit in `openspec/PORTFOLIO.md`.
- [x] 3.3 Add the priority-ordered `openspec/PORTFOLIO.md` master list with origin, current state, benefit, completion outcome, boundaries, dependencies, and resume links for every active plan.

## 4. Verify and report

- [x] 4.1 Create `docs/PLAN_DOCUMENT_AUDIT.md` with method, exact archive inventory, evidence, conversion mapping, retained references, limitations, and the resulting portfolio.
- [x] 4.2 Run `openspec validate --all --strict`, `git diff --check`, stale-path scans, and Markdown target checks; resolve every failure and record the final result in the audit.

## Workflow follow-up

- Archive this governance change after review; the portfolio and focused changes remain active.
