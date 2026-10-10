## Purpose

Defines how legacy findings are reconciled, quality work is prioritized, and repeatable provider-neutral evidence is produced before defects or modernization work are declared complete.

## ADDED Requirements

### Requirement: Finding-by-finding disposition
Every inherited finding SHALL have a current-code disposition of fixed, duplicate, redesign-owned, accepted risk, deferred with trigger, obsolete, or actionable. **Implementation status: partial.**

#### Scenario: Historical finding references changed code
- **WHEN** the original line or architecture no longer exists
- **THEN** the finding is re-evaluated against current behavior rather than copied forward as an open defect

### Requirement: Evidence-linked remediation
An actionable defect SHALL identify its observable failure, affected surface, risk, verification method, and owning OpenSpec change before implementation. **Implementation status: partial.**

#### Scenario: Finding overlaps redesign migration
- **WHEN** the correct fix is already owned by `complete-redesign-v3-migration`
- **THEN** the quality program links to that task and does not create a duplicate implementation task

### Requirement: Provider-neutral quality gates
Repository review and validation commands SHALL be executable without relying on a specific conversational model, transient session, or proprietary handoff document. **Implementation status: partial.**

#### Scenario: Contributor uses a different coding assistant
- **WHEN** the contributor prepares a substantive Swift change
- **THEN** repository instructions still identify the required checks and review roles unambiguously

### Requirement: Layered validation matrix
Quality evidence SHALL distinguish static checks, unit tests, simulator behavior, fresh-install and restore tests, physical-device behavior, server integration, and field performance. **Implementation status: partial.**

#### Scenario: Unit tests pass without physical validation
- **WHEN** a feature depends on BLE, watchOS lifecycle, or real-device behavior
- **THEN** it is recorded as unit-tested but not physical-device validated

### Requirement: Zero-warning completion
Changed code SHALL pass its applicable build, lint, and test gates with zero new warnings before its task is marked complete. **Implementation status: active project rule.**

#### Scenario: Build succeeds with a new warning
- **WHEN** validation emits a new compiler or lint warning
- **THEN** the task remains incomplete until the warning is fixed
