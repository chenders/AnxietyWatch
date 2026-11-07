# Spec Delta

## Purpose

Defines the permanent absence of CNS-depression detection and klaxon alarm behavior in this application, and the documentation and ownership boundary with the superseding AnxietyWatch2 system.

## ADDED Requirements

### Requirement: No CNS-depression detection product
This application MUST NOT compute CNS-depression risk scores, alert tiers, dose-window respiratory watches, or klaxon alarm decisions from physiological or medication inputs. **Implementation status: not implemented (target after this change).**

#### Scenario: Physiological samples continue to arrive
- **WHEN** SpO2, respiratory-rate, heart-rate, HRV, or CPAP-related observations are ingested for journaling or trends
- **THEN** the app stores or displays them without producing a CNS risk score, alert tier, or alarm command

#### Scenario: User logs a benzodiazepine or opioid dose
- **WHEN** a medication dose is logged that previously would have armed overnight CNS monitoring
- **THEN** the app records the dose for journal and adherence use only and does not arm a monitoring session or respiratory watch

### Requirement: No klaxon or clinical alarm presentation
This application MUST NOT present a CNS klaxon, clinical escalation notification, watch klaxon haptic storm, or server-driven backstop push as a CNS-depression warning. Ordinary non-clinical reminders remain allowed. **Implementation status: not implemented (target after this change).**

#### Scenario: App is running overnight with live sensors
- **WHEN** the phone and optional watch are active with Polar, EMAY, or HealthKit data flowing
- **THEN** no CNS klaxon audio, clinical escalation banner, or `cnsKlaxonHaptic` watch message is emitted by this app

#### Scenario: Server receives SpO2 samples
- **WHEN** the sync server stores oximetry or related samples
- **THEN** it does not evaluate a CNS backstop floor or enqueue a CNS/backstop APNs payload for this product

### Requirement: No user-facing CNS monitoring surface
Settings, dashboard, medications, and demo entry points MUST NOT offer CNS Monitoring arm/status UI, CNS depressant class pickers used to arm watches, or demo sequences that simulate klaxon tiers. **Implementation status: not implemented (target after this change).**

#### Scenario: User opens Settings
- **WHEN** the Settings root is displayed
- **THEN** no navigation row or copy presents CNS Monitoring, klaxon status, or overnight respiratory-depression arming

#### Scenario: User adds a medication
- **WHEN** a medication definition is created or edited
- **THEN** the form does not require or expose a CNS-depressant class control for alarm arming

### Requirement: Public claims match non-alarm product
Public README, feature lists, diagrams, and repository metadata MUST NOT claim that this app provides CNS-depression early warning, klaxon, or overdose-related monitoring. Historical archive docs MAY describe past work only when marked superseded. **Implementation status: not implemented (target after this change).**

#### Scenario: Contributor reads the README
- **WHEN** the README feature table and architecture sections are reviewed
- **THEN** they describe journaling, physiology trends, and device import without an in-progress or shipped CNS klaxon capability for this app

#### Scenario: Archive plan is opened
- **WHEN** a completed klaxon plan under `docs/plans/completed/` is read
- **THEN** it remains historical evidence and is not linked as an active implementation instruction

### Requirement: Superseding system ownership boundary
CNS-depression detection, multi-modal alarm output, and Pi-side vitals fusion SHALL be treated as owned by AnxietyWatch2 (external repository), not by this application. This repository MUST NOT reintroduce a parallel clinical-alert engine without a new OpenSpec change that explicitly reverses retirement. **Implementation status: active policy after this change.**

#### Scenario: New alert-like feature is proposed
- **WHEN** a contributor proposes on-device tiered respiratory alarming in this repo
- **THEN** work is rejected unless a new accepted OpenSpec change supersedes `cns-klaxon-retirement` and updates public claims

#### Scenario: GEN1 parity expectation is applied
- **WHEN** phone responsibilities are compared to the AnxietyWatch2 Apple-client parity ledger
- **THEN** local CNS tier computation is treated as removed from this app's product scope

### Requirement: Klaxon-only data paths are retired safely
Export, sync upload, server persistence, and restore inventories MUST omit CNS-only entities after retirement. Upgrade and fresh-install paths MUST NOT crash when historical CNS models or tables are absent or residual. **Implementation status: not implemented (target after this change).**

#### Scenario: Upgrade from a build that had monitoring sessions
- **WHEN** a user upgrades to a post-retirement build with residual local CNS rows or model types
- **THEN** the app launches, opens its store, and continues journaling without requiring those rows for correctness

#### Scenario: Restore completeness gate runs
- **WHEN** restore-manifest or upload inventory validation runs after retirement
- **THEN** no CNS-only table is required as an upload-without-restore pair for app operation

#### Scenario: Fresh install
- **WHEN** the app is installed with an empty store
- **THEN** first-run does not present CNS monitoring onboarding or create monitoring-session state
