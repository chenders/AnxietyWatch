# Fable 5 Re-Evaluation — Findings Register

The living register for Phases 2 (static audit), 6 (sensor reliability), and 7 (runtime). Each finding is one row. Only adversarially-verified findings are marked **confirmed**; everything else is **plausible** until a verify pass or cheap experiment settles it.

## Format

| Field | Meaning |
|-------|---------|
| ID | `F-NNN` stable identifier |
| Subsystem | code area (e.g. `polar-hrv`, `sync`, `server-auth`) |
| Severity | P0 (data corruption / crash / security) → P3 (cosmetic / nit) |
| Confidence | `confirmed` (≥2 of 3 verify lenses agree) / `plausible` |
| Effort | S / M / L |
| Tag | `bug` / `accuracy` / `efficiency` / `render` / `silent-failure` / `security` / `test-gap` / `reliability` / `runtime` |
| Disposition | `open` / `approved` / `deferred` / `rejected` / `fixed (#PR)` |

## Register

_No findings yet — populated starting Phase 2._

| ID | Subsystem | Sev | Conf | Effort | Tag | Summary | Failure scenario | Anchor | Disposition |
|----|-----------|-----|------|--------|-----|---------|------------------|--------|-------------|
| — | — | — | — | — | — | _(pending Phase 2)_ | — | — | — |

## Deferred backlog

_Populated at wrap-up (Phase 8) from `deferred` entries above._
