# Phase 7 — Runtime validation & performance

**Goal:** find what static analysis can't — behavior and timing on a running app — and measure whether the efficiency work actually helped.

## 7a. iOS functional pass (XcodeBuildMCP)

- `session_show_defaults` → `build_run_sim`; scripted walk of all 12 view areas using `snapshot_ui` + `screenshot` + `tap`/`swipe`, capturing simulator log output throughout (watch for runtime warnings: SwiftData, layout loops, constraint breaks, main-thread I/O).
- **Matrix per screen:** empty data vs. seeded dense data (`-autoRestoreFromServer` restore tool from PR #152), dark mode (`set_sim_appearance`), large Dynamic Type. Dispatch `chart-ux-auditor` for the Trends suite (its three-density protocol).
- **Risky flows end-to-end:** full sync round-trip against a local docker server; restore-from-server; CPAP import; Polar session lifecycle (start/stop/unpair mid-session — state-machine completeness); prescription scanner with a fixture image.

## 7b. Timing & performance measurement

- **Instrument first:** a small PR adding `os_signpost` intervals around the known-hot paths — app launch → first dashboard render, dashboard rebuild with N snapshots, each Trends chart render, backfill loop, sync round-trip.
- **Measure:** simulator log capture + `record_sim_video` for perceived jank; ≥3 runs, medians recorded in a timing table (baseline vs. post-fix wherever Phase 3 touched a hot path).
- **Caveat (standing):** simulator timing is directional only; anything surprising gets confirmed on the physical device before being treated as a finding.
- **Memory:** repeated navigation cycles watching for growth (leak proxy); the documented render-loop patterns get specific reproduction attempts.

## 7c. Server runtime pass

`docker compose up` locally (dedicated test env, NOT the prod deployment); API smoke tests against every endpoint (with and without auth headers — verifying auth coverage); admin UI walk via browser MCP; endpoint latency table at seeded data volume; cron-client dry-runs with fixture payloads.

## Register + close-out

Findings append to `FINDINGS.md` (tagged `runtime`), triage, then a final fix batch + re-measure loop within the phase.

## Done when

Every screen-matrix cell captured and reviewed; timing table complete; runtime findings dispositioned; re-measure confirms no regressions.

## Implementation notes (post-merge)

_Pending._
