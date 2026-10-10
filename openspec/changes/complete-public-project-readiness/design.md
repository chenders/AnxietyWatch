# Design

## Context

See `proposal.md` for motivation. The README modernization and screenshot work largely shipped, while community files, repository metadata, and a repeatable public-release check remain. The converted source is `docs/plans/converted/readme-expert-improvement-plan.md`.

| Legacy area | Current evidence | Disposition |
|---|---|---|
| README structure and screenshots | `README.md`, `docs/pr16-visuals/` | Re-audit currency and fictional-data safety; do not recreate completed work |
| Build entry point | current repository build instructions and scripts | Verify rather than assume the old checklist is current |
| Issue templates, conduct, contributing, metadata | `.github/` and repository settings | Complete missing public-project surfaces here |

## Goals / Non-Goals

**Goals:**

- Give new contributors a safe, current path into the project.
- Make public claims and visuals match the actual app.
- Turn privacy review and release presentation into a repeatable checklist.

**Non-Goals:**

- Marketing promises for unshipped roadmap items.
- Publishing personal screenshots, health data, credentials, or session artifacts.
- Changing application behavior.

## Decisions

### 1. Public entry points form one maintained set

README, CONTRIBUTING, code of conduct, issue templates, security/privacy guidance, and repository metadata cross-link and use consistent support boundaries. The rejected alternative is independent documents with duplicated setup text.

### 2. Current behavior wins over the legacy checklist

Every inherited item is verified against the repository and GitHub configuration. Already-complete items are recorded as evidence; outdated launch suggestions can be rejected.

### 3. Visuals require a privacy and currency gate

Committed screenshots use fictional simulator data, are visually inspected, and identify the app version or capture context when useful. Existing visuals are retained only when they still represent the current UI.

### 4. External metadata is tracked explicitly

Changes to GitHub description, topics, or other remote settings are separate checklist tasks with observed confirmation. A local file edit does not count as completing remote configuration.

## Risks / Trade-offs

- [Documentation drifts] → Link review to release boundaries and material feature changes.
- [Screenshot leaks personal data] → Use fictional demo data and visual review before commit.
- [Public claims overstate support] → Tie claims to current implementation status and setup paths.
- [Remote metadata cannot be verified locally] → Record it as pending until the GitHub state is observed.

## Migration Plan

1. Inventory current public entry points and remote metadata.
2. Add missing community files with cross-links and privacy rules.
3. Re-audit setup commands, screenshots, links, and claims.
4. Apply and verify accepted remote metadata changes.
5. Adopt the release checklist and record the first completed pass.
