# Proposal

## Why

The Fable reevaluation and setup-improvement plans contain a mixture of completed fixes, still-valid defects, obsolete findings, and model-specific workflow ideas. A single engineering-quality program can close the remaining evidence-backed work while keeping feature delivery and public-project polish out of its scope.

## What Changes

- Reconcile every unresolved Fable finding against current code and assign it to fix, redesign dependency, explicit deferral, or obsolete disposition.
- Complete remaining Trends query/paging, server pagination, accessibility, render-safety, and runtime-validation work that remains valid.
- Replace model-specific pre-PR workflow assumptions with provider-neutral repository commands and documented review gates.
- Establish a repeatable simulator, hardware, server, first-run, restore, and performance validation matrix.
- Finish finding dispositions and archive transient handoff/session documents once their durable content is represented.

## Capabilities

### New Capabilities

- `engineering-quality-program`: Durable defect disposition, validation-matrix, and provider-neutral quality-gate requirements.

### Modified Capabilities

- `diagnostics-operations`: Expand release evidence so remaining runtime, accessibility, first-run, restore, and performance gates are tracked consistently.

## Impact

Affected areas may include Trends/SwiftData queries, server pagination, SwiftUI accessibility and render safety, CI/review tooling, and test infrastructure. This program must coordinate with `complete-redesign-v3-migration` rather than duplicate its storage or sync tasks. Any HealthKit, restore, server, or watchOS fix follows the existing ownership and round-trip rules. Rollback is per fix or tooling change; no bulk rewrite is authorized. User-data-loss risk varies by finding and must be recorded before implementation.
