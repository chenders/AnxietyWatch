# Proposal

## Why

The public repository has a useful README and screenshots, but its remaining contributor, governance, repository-metadata, and launch tasks are mixed into an old README improvement checklist. This change gives those public-facing tasks one bounded home and keeps them separate from app behavior.

## What Changes

- Add or refresh issue templates, contribution guidance, and a code of conduct.
- Verify repository description, topics, links, privacy statements, setup instructions, and support boundaries.
- Re-audit screenshots and examples for current UI, fictional data, and absence of personal information.
- Decide which release notes, launch materials, or project history belong in the repository and which are explicitly out of scope.
- Add a repeatable public-release checklist so documentation does not drift after feature changes.

## Capabilities

### New Capabilities

- `public-project-readiness`: Public documentation, contributor onboarding, repository hygiene, and release-presentation requirements.

### Modified Capabilities

- None.

## Impact

Affected surfaces are README and repository documentation, `.github` community files, screenshots, and GitHub repository metadata. There is no production app, HealthKit, first-run, restore, server, or watchOS behavior change. Rollback is ordinary document/file reversion. User-data-loss risk is none, but accidental publication of personal information is a material repository-safety risk.
