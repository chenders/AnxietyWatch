# Phase 6 — Maximizing reliable sensor data consumption

**Goal:** maximize the reliability and completeness of physiological data ingestion from the three live sources — Apple Watch (via HealthKit), EMAY pulse oximeter, and Polar H10 chest strap. The question is not "is the code correct" (Phase 2 covered that) but **"how much data are we losing, and how do we lose less?"**

## Method

### 1. Quantify actual data loss first

Ground the work in real numbers before proposing fixes: `/query-prod` against the sync DB + on-device HealthKit queries to measure —
- nights with missing/partial Polar sessions; session fragmentation rates (post-PR-#148 coalescing)
- EMAY import gaps
- HealthKit metrics with observer/backfill holes
- sync-drain failures

Per the standing assumption: **missing data means not-captured/not-imported, never "user skipped"** — every gap is a defect to explain. Findings describe gap shapes and counts, never actual health values (public repo).

### 2. Per-source reliability deep-dive (parallel agents, atlas-armed)

- **Apple Watch / HealthKit:** observer-query + background-delivery coverage per type; anchored-query cursor integrity; backfill/gap-fill correctness and self-healing; authorization edge cases (reads always report `.notDetermined`); WatchConnectivity transfer reliability (queued transfers surviving app termination).
- **Polar H10:** full BLE lifecycle — connection drops mid-session, auto-reconnect and session resume, overnight recording survival (background execution limits), battery-low behavior, RR-interval integrity through drops, fragmented-session coalescing under real dropout patterns.
- **EMAY oximeter:** import-pipeline robustness across file-format variants; partial/corrupt file handling; dedup + arbitration against HK-sourced SpO2 (`SpO2SourceArbiter`); user friction in the import flow itself (friction = data loss).

### 3. Reliability engineering proposals

Reconnect/retry with backoff, session watchdogs, ingest-time data-integrity checks, and — key UX tie-in with Phase 5 — a user-visible **data-health surface**: per-source freshness/completeness indicators and "source went silent" alerting so gaps are noticed the next morning, not weeks later.

### 4. Physical-device test protocol

BLE and overnight behavior can't be simulated — define a concrete protocol with Chris in the loop: N instrumented test nights (Polar + Watch + EMAY simultaneously), induced-dropout tests (walk out of range, battery pull), and a scorecard of data captured vs. expected.

### 5. Register + implementation

Findings + proposals append to `FINDINGS.md` (tagged `reliability`); triage; batched implementation PRs, each proving its value against the step-1 loss metrics.

## Done when

Loss metrics quantified before and after; approved reliability work merged; device-protocol nights show measurable completeness improvement (or explicitly documented external causes).

## Implementation notes (post-merge)

_Pending._
