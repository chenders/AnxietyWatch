# Proposal

## Why

`docs/` contains legacy implementation plans whose checkboxes no longer describe the repository: most shipped months ago, several are partially complete, and a smaller set still names valid work. Leaving them intermixed makes completed work look pending and creates competing sources of truth beside OpenSpec.

Observed current behavior is that completed features are represented by source, tests, and merged commits while many originating plans remain unchecked; redesign-v3 work is already tracked separately in `complete-redesign-v3-migration`. The target is a documented archive of completed and converted plans plus a coherent OpenSpec portfolio for remaining verified work.

## What Changes

- Archive completed implementation plans and their supporting design records under `docs/plans/completed/`, preserving relative plan-to-design links where practical.
- Move partially complete, superseded, or still-actionable instruction documents under `docs/plans/converted/` after their remaining work is represented here.
- Add a repository audit report recording classification evidence, moved paths, merged implementation evidence, exclusions, and unresolved work.
- Create focused OpenSpec changes for clinical respiratory safety, physiological experience, optional device capabilities, engineering quality, and public-project readiness.
- Add an OpenSpec portfolio index that explains scope, dependencies, source documents, and overlap boundaries for every active change.
- Add a repository-owned OpenSpec validator, an installable Git pre-push hook, and a GitHub Actions check that invoke the same validation path before invalid planning artifacts can merge.
- Keep `complete-redesign-v3-migration` authoritative for storage, restore-manifest, delegate ownership, causal sync, diagnostics, and staged retirement work already in its scope; this change MUST reference rather than duplicate those tasks.
- **BREAKING:** None. This proposal reorganizes documentation and plans future work; it does not enable a data path, change a clinical threshold, or alter production behavior.

## Capabilities

### New Capabilities

- `plan-governance`: Classification, archival, traceability, portfolio structure, and single-source-of-truth rules for historical work instructions.

### Modified Capabilities

None. Feature and quality behavior is intentionally owned by separate focused changes.

## Impact

The impact is documentation and repository validation tooling: `docs/plans/completed/`, `docs/plans/converted/`, moved legacy files, an audit report in `docs/`, `openspec/PORTFOLIO.md`, the focused OpenSpec changes created by this conversion, and shared local/CI validation files. Application and server runtime behavior remain unchanged.

No production data is migrated by this change, so its rollback boundary is the documentation and validation-tooling commit. Later implementation involving HealthKit, server restore, sensor ingestion, watchOS, or CNS behavior requires its own tests, rollout boundary, medical review, and rollback evidence. The principal future data-loss risks are dropped restore/sync rows and incomplete sensor archives; those remain governed by `complete-redesign-v3-migration` and are not weakened here.

Non-goals are implementing any recovered task now, enabling optional BLE or remote data collection, changing clinical thresholds without review, reviving removed pharmacy/supply features, or treating aspirational roadmap ideas as approved product commitments.
