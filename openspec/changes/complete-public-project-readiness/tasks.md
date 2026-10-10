# Tasks

## 1. Audit public entry points

- [ ] 1.1 Compare `README.md`, current build/setup files, `.github/`, `docs/pr16-visuals/`, and repository metadata with `docs/plans/converted/readme-expert-improvement-plan.md`; add a current disposition table to `design.md`, verified by one owner for every remaining item.
- [ ] 1.2 Check all public setup commands and documentation links from a clean checkout context; record working commands, broken links, and platform prerequisites in the disposition table.

## 2. Contributor and community documentation

- [ ] 2.1 Add or update `.github/ISSUE_TEMPLATE/` with focused bug and feature forms that request reproducible, privacy-safe information; verify generated forms do not solicit credentials or personal health data.
- [ ] 2.2 Add `CONTRIBUTING.md` covering setup, testing, OpenSpec, review roles, fictional fixtures, screenshots, and sensitive-data rules; verify every command runs as documented or is explicitly environment-dependent.
- [ ] 2.3 Add a code of conduct and cross-link README/contributor/community entry points; verify relative links resolve and support/escalation boundaries are clear.

## 3. Public presentation and privacy

- [ ] 3.1 Re-audit README capability claims against current implementation states and update overstated or stale content; verify links point to current setup or authoritative plan locations.
- [ ] 3.2 Review every retained README/repository screenshot for current UI and fictional data, replacing only stale or unsafe assets with simulator captures; verify visual inspection and repository sensitive-data scan pass.
- [ ] 3.3 Verify privacy, export, server-mirror, HealthKit ownership, and support statements against current behavior; record any product discrepancy in its owning OpenSpec change instead of hiding it with copy.

## 4. Repository metadata and release checklist

- [ ] 4.1 Propose and apply accepted GitHub description, topics, website, and support metadata, then verify the remote repository shows the exact intended values.
- [ ] 4.2 Add a public-release documentation checklist under `docs/` covering claims, links, screenshots, fictional data, community files, privacy, and repository metadata; verify one dry run is recorded.
- [ ] 4.3 Decide whether release notes, launch narrative, or project history are in scope and either create the accepted artifact or record rejection/defer rationale in this change.

## Workflow follow-up

- Archive the change after the first complete public-release review is recorded.
