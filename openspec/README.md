# AnxietyWatch OpenSpec

This directory is the source of truth for behavior specifications and planned changes.

## Layout

- `config.yaml` — project context, artifact rules, and apply/archive guidance.
- `PORTFOLIO.md` — priority-ordered master list of every active plan, its origin, benefit, completion outcome, dependencies, and resume path.
- `specs/` — canonical current behavior. Status labels distinguish active, foundation-only, partial, and not-implemented behavior.
- `changes/` — proposed changes and implementation planning.
- `changes/archive/` — completed changes after their deltas have been merged into canonical specs.

Start with `PORTFOLIO.md` when choosing or resuming work. The redesign-v3 baseline is split into seven capabilities under `specs/`. Remaining redesign work is in `changes/complete-redesign-v3-migration/`. Its `design.md` contains the reconciled T01–T40 implementation ledger and traceability from the removed `docs/redesign_spec.md`; its operational detail is in `RUNBOOK.md` in the same change.

## Workflow

Use OpenSpec CLI 1.14.1 or newer from the repository root:

```sh
openspec list --specs
openspec status --change complete-redesign-v3-migration
openspec validate --all --strict
```

Do not implement an in-flight change until its proposal, spec deltas, design, and tasks are reviewed. When behavior ships, update implementation evidence and rollout state before archiving the change.

Project-local integrations were generated for Codex (`.agents/skills`), Claude (`.claude`), GitHub Copilot (`.github`), and Pi (`.pi`). Some developer-specific tool directories are intentionally excluded from Git but remain available in a configured checkout.
