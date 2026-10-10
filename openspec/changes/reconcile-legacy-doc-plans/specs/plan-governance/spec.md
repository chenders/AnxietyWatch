# Spec Delta

## Purpose

Defines how historical work instructions are classified, archived, converted, and traced so OpenSpec remains the single authoritative backlog.

## ADDED Requirements

### Requirement: Evidence-based plan classification
Every work-instruction document SHALL be classified from current source, tests, merged Git history, and existing OpenSpec coverage rather than from unchecked boxes alone.

#### Scenario: Historical checklist is stale
- **WHEN** a legacy plan contains unchecked tasks whose implementation and tests are present on `main`
- **THEN** the plan is classified from the implementation evidence and records the discrepancy

### Requirement: Completed-plan archive
A plan whose accepted implementation scope is complete SHALL move under `docs/plans/completed/` with supporting design records and working relative references preserved where practical.

#### Scenario: Feature scope shipped with later scope changes
- **WHEN** the original deliverable shipped and later revisions changed its behavior
- **THEN** the original plan is archived as completed with the later scope change recorded in the audit report

### Requirement: Converted-plan archive
A plan with valid remaining work SHALL have that work represented in OpenSpec before the original document moves under `docs/plans/converted/`.

#### Scenario: Plan is partially implemented
- **WHEN** some tasks are supported by merged evidence and other still-valid tasks are not
- **THEN** only the remaining work enters the OpenSpec backlog and the original plan moves to the converted archive

### Requirement: No duplicate authority
Archived plans MUST be historical evidence only; active requirements and task status SHALL live in OpenSpec or an explicitly identified active runbook.

#### Scenario: Archived plan conflicts with OpenSpec
- **WHEN** an archived checkbox or instruction disagrees with an active OpenSpec artifact
- **THEN** OpenSpec governs and the archive is not treated as implementation authorization

### Requirement: Traceable audit report
The repository SHALL contain a human-readable audit mapping every moved or retained instruction document to its classification, evidence, OpenSpec destination, and unresolved limitations.

#### Scenario: Contributor encounters an archived plan
- **WHEN** a contributor needs to know why the document moved
- **THEN** the audit report identifies whether it completed, converted, or remained active and where current work is tracked

### Requirement: Shared OpenSpec validation gate
The repository SHALL provide one shared validator that runs strict OpenSpec validation, validator tests, and local Markdown-target checks from both an installable Git pre-push hook and GitHub pull-request CI.

#### Scenario: Installed pre-push validation rejects invalid OpenSpec
- **WHEN** a contributor attempts to push while the tracked Git hook is enabled and an OpenSpec artifact is invalid or contains a missing local Markdown target
- **THEN** the shared validator exits nonzero and the push is stopped

#### Scenario: Pull request bypasses or lacks the local hook
- **WHEN** a pull request changes OpenSpec artifacts or the validation implementation
- **THEN** GitHub Actions installs the pinned OpenSpec CLI and runs the same shared validator as a required-style failing check

#### Scenario: Fresh clone has not enabled tracked hooks
- **WHEN** a contributor prepares a new checkout
- **THEN** repository documentation provides the one-time `core.hooksPath` command and explains that CI remains the non-bypassable backstop
