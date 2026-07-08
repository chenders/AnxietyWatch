# Phase 4 — Best-practices modernization

**Goal:** bring code, dependencies, methods/practices, and the instruction/tooling layer up to current best practice. Register-first here too: a modernization-proposals doc, Chris triages, then batches.

## 4a. Swift/iOS currency

- **Swift 6 strict-concurrency readiness audit** — Sendable conformance, actor boundaries, `@MainActor` hygiene. Even if the flag doesn't flip yet, produce the gap list.
- **Deprecated/superseded API sweep** given the iOS 18+/watchOS 11+ floor (the xcconfig deployment targets are the source of truth — verify first): newer SwiftUI, Swift Charts, HealthKit APIs that simplify existing code.
- **Consistency sweeps:** ChartPalette adoption completeness, magic-number → named-constant, view-size discipline (>100-line views), typed-error adoption.

## 4b. Server/Python currency

- `requirements.txt` dependency audit — version currency + known security advisories (Flask 3, psycopg2, cryptography, aiohttp, etc.).
- Python 3.12 idioms; flake8-vs-ruff consideration; Alembic migration hygiene vs. `schema.sql` drift; docker-compose hardening.

## 4c. Practices & CI

- Workflow currency (runner images, action versions), coverage-target ratchet vs. the Phase 0 baseline (app target 30.7%; widget/live-activity extensions at 0%), missing CI gates (e.g., Semgrep on server paths).

## 4d. Instruction & tooling refresh (the Claude/Copilot layer) — key step

- **Accuracy pass:** diff every instruction file against reality — CLAUDE.md's project-structure tree is stale (46 services vs. ~20 listed; `Views/Songs/` missing; server modules like the 3 sync clients, `crypto.py`, `edf_parser.py` undocumented). Fix all five files in sync per the `/sync-instruction-files` mandate.
- **Fable 5 recalibration:** the agents/hooks/Semgrep layer was tuned for a previous model's blind spots. Re-evaluate each: which deterministic hooks still pay for themselves, which agent checklists should grow (new pitfall categories from Phases 2–3) or shrink, whether agent model/effort settings should change.
- **Known hook fixes (seeded from Phase 0):** `block-pii-in-fixtures.py` false-positives on UUID literals (digit runs match its phone-number regex — e.g. `22222222-2222-…`); exempt UUID-shaped strings.
- **Document the test-DB convention** (throwaway Docker Postgres on :5434, never the Homebrew system Postgres, never the compose prod DB — the pytest fixture TRUNCATEs all tables) in CLAUDE.md's Commands/Testing sections.
- **Pitfalls list curation:** fold new recurring categories from Phases 2–3 into CLAUDE.md Common Pitfalls (mirror to Copilot files). Candidate from Phase 0: "fixed fixture dates + unpinned `now` = time-bomb test."
- **Fable 5 phrasing discipline** (see master plan): add guidance to agent definitions whose prompts contain security vocabulary.

## Done when

Proposals triaged, approved batches merged, all five instruction files consistent with each other and with reality.

## Implementation notes (post-merge)

_Pending._
