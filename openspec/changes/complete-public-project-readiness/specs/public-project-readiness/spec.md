## Purpose

Defines the public repository documentation, contributor onboarding, privacy review, and release-presentation standards required for a trustworthy and maintainable project.

## ADDED Requirements

### Requirement: Contributor entry points
The repository SHALL provide current contribution guidance, issue-reporting paths, and community conduct expectations appropriate to a public health-data project. **Implementation status: partial.**

#### Scenario: New contributor finds a bug
- **WHEN** a contributor opens the repository without prior project context
- **THEN** they can find setup, testing, privacy, issue-reporting, and pull-request expectations from public documentation

### Requirement: Current repository metadata
Public description, topics, links, platform requirements, and support boundaries SHALL match the current application and repository. **Implementation status: partial.**

#### Scenario: Project behavior changes
- **WHEN** a release materially changes a documented capability or requirement
- **THEN** the public metadata and entry documentation are reviewed in the same release cycle

### Requirement: Fictional public artifacts
Screenshots, examples, fixtures, and public documentation MUST contain only reviewed fictional data and MUST NOT expose personal information, credentials, or authenticated-session artifacts. **Implementation status: active rule; existing assets require periodic re-audit.**

#### Scenario: Screenshot is proposed for the README
- **WHEN** a new screenshot is prepared
- **THEN** it is captured from fictional demo data and reviewed before commit

### Requirement: Verified public links and claims
Public links, setup commands, privacy statements, and capability claims SHALL be verified before release. **Implementation status: partial.**

#### Scenario: README names a supported integration
- **WHEN** a public document claims an integration is available
- **THEN** the linked setup path and current implementation state support that claim

### Requirement: Repeatable release review
The repository SHALL maintain a reusable checklist for public documentation and repository presentation at release boundaries. **Implementation status: not implemented.**

#### Scenario: Release candidate is prepared
- **WHEN** a public release is proposed
- **THEN** maintainers can verify documentation, screenshots, metadata, privacy, contribution files, and links without reconstructing the checklist from history
