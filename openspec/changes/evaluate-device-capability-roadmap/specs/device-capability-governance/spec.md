## Purpose

Defines evidence and decision gates for optional wearable, platform, privacy-sensitive, and externally constrained device capabilities before implementation is authorized.

## ADDED Requirements

### Requirement: Current authoritative evidence
Every external device or platform proposal SHALL cite current official capability, policy, protocol, and availability evidence before an accept decision. **Implementation status: not implemented as a durable process.**

#### Scenario: Older plan cites a device capability
- **WHEN** the capability may have changed since the legacy plan was written
- **THEN** current official evidence is recorded before the proposal is accepted or rejected

### Requirement: Explicit decision record
Each proposed capability SHALL receive an accept, defer, reject, or research disposition with rationale, dependencies, and re-evaluation trigger. **Implementation status: not implemented.**

#### Scenario: Evidence is insufficient
- **WHEN** protocol stability, entitlement access, or platform behavior cannot be established
- **THEN** the capability is marked research or deferred rather than entering an implementation plan

### Requirement: Privacy and ownership gate
Capabilities involving location, voice, health writes, account linkage, or new data collection MUST define consent, retention, export, deletion, and source-of-truth ownership before acceptance. **Implementation status: not implemented.**

#### Scenario: Proposal would write to HealthKit
- **WHEN** an optional feature requires HealthKit writes despite the project's read-only ownership rule
- **THEN** it is rejected unless an explicit project-level ownership decision changes that rule

### Requirement: Supportability gate
Undocumented or reverse-engineered device protocols SHALL NOT become production dependencies without a recorded maintenance, compatibility, and failure-isolation strategy. **Implementation status: not implemented.**

#### Scenario: Direct BLE protocol is undocumented
- **WHEN** cloud integration exists but direct BLE depends on an unstable private protocol
- **THEN** direct BLE remains disabled unless its benefit and maintenance plan justify the risk

### Requirement: Separate implementation authorization
An accepted roadmap decision MUST create a focused implementation change before production code or data-model behavior changes. **Implementation status: this change establishes the requirement.**

#### Scenario: Capability is accepted
- **WHEN** evidence supports implementing a proposed device feature
- **THEN** a follow-on OpenSpec change defines its behavior, migration, tests, and rollback before implementation begins
