# CNS Klaxon Program — Execution Handoff (for a herdr/pi conductor)

**Purpose:** hand this document to a herdr/pi conductor to organize and dole out the
three-sub-project CNS-depression-klaxon program to worker agents. It points at every spec and
plan, states the non-negotiable constraints, and gives parallelization guidance.

**Date:** 2026-07-20. **Repo:** `AnxietyWatch` (iOS/watchOS + Flask/Postgres server).

---

## 0. Read-first framing (do not skip — this is life-safety code)

The CNS-depression klaxon is an **early-warning alarm for opioid/benzodiazepine-driven
respiratory depression**. Two boundaries constrain every task:

1. **The primary alarm is on-device.** Sub-project **A** (CoreBluetooth state restoration +
   Critical Alerts) is the authoritative path. Sub-project **C** (server push) is **redundant
   only** — it may *add* an alert, never *suppress or replace* the on-device decision. Never move
   the klaxon decision server-side ("Option B" was explicitly rejected; see the 2019 Dexcom
   Follow outage lesson in the research doc).
2. **Research reality:** no socket/tick loop survives iOS suspension. The only real background
   path is direct BLE + CoreBluetooth state preservation/restoration computing alerts on-device
   (the Dexcom model). Do not attempt keep-alive hacks (silent audio, VoIP, infinite bg tasks);
   they fail App Review and don't work.

**Core CNS invariants — enforce in every CNSRisk task** (from `CLAUDE.md` → CNS Detection
Engine and the parent design §5/§11/§14.2):
- **Asymmetry:** indeterminate ≠ safe ≠ dangerous. Low-quality/missing data surfaces as "can't
  assess," never "OK" and never an escalation.
- **Primary-informed only:** escalation past *watch* AND clearing a raised tier both require
  observed SpO₂/respiratory-rate evidence. HR/HRV can trigger *watch* but can never push to
  confirm/klaxon nor launder a missing primary into "all clear."
- **Invalid data contributes nothing;** missing data **holds** the current tier.
- **Never a silent stop.**

---

## 1. The three sub-projects (build order **A → B → C**)

| | Sub-project | Spec (on `main`) | Plan (local, gitignored) |
|---|---|---|---|
| **A** | On-device Phase 3 — CB state restoration wiring the CNS pipeline + Critical Alerts, watch-haptic-first. **The primary path.** | `docs/superpowers/specs/2026-07-20-klaxon-phase3-ondevice-design.md` | `docs/superpowers/plans/2026-07-20-klaxon-phase3-ondevice.md` |
| **B** | AS11 context feed — server WebSocket push + foreground/BLE-session iOS ingest, making AS11 a live primary-capable SpO₂ source. **Includes all dormant AS11 fixes deferred from PR #23.** | `docs/superpowers/specs/2026-07-20-as11-context-feed-design.md` | `docs/superpowers/plans/2026-07-20-as11-context-feed.md` |
| **C** | Server redundant alert channel — APNs backstop + heartbeat + status. **Redundant only.** | `docs/superpowers/specs/2026-07-20-server-redundant-alert-channel-design.md` | `docs/superpowers/plans/2026-07-20-server-redundant-alert-channel.md` |

**Supporting references every worker should have:**
- Parent design (authoritative): `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md`
- Research: repo-root `Keeping a Real-Time Health Feed Alive on a Backgrounded iOS App- What Actually Works.md`
- AS11 integration context: repo-root `Integration Plan- aircannect - AnxietyWatch.md`
- The just-merged scaffold this builds on: PR #23 (`feat: Aircannect AS11 Integration (Mocked)`), merge commit `4bcaef4`.

**Where the specs live:** all three specs (PR #25) and the #23 AS11 scaffold are on **`main`** — both PRs are merged. **Branch every sub-project off `main`**, not off the concurrent `feature/cns-klaxon-live-selftest` branch (which predates them and lacks the specs). The plans + this handoff are gitignored local working docs present in the repo working tree regardless of branch.

---

## 2. Execution model (how workers should operate)

- **Subagent-driven, one worker per task.** Each plan lists discrete `- [ ]` TDD tasks. Assign
  one worker per task; review between tasks.
- **Strict TDD:** write the failing test → watch it fail → minimal code to pass → commit. Every
  task ends with a passing test and a commit. Never production code without a failing test first.
- **MANDATED reviewers (blocking):** every task that touches `AnxietyWatch/Services/CNSRisk/` (or
  `CNSMonitoringCoordinator`) must pass **`medical-data-accuracy-reviewer` AND
  `swift-pre-pr-reviewer`** before the task is accepted. The plans mark these tasks. For
  server-only tasks, run a `silent-failure-hunter` pass on error paths.
- **Green gates per task:** iOS — `xcodebuild test` clean + zero warnings (CI is
  warnings-as-errors) + SwiftLint `--strict`. Server — `flake8 --max-line-length=120`, `uvx
  bandit -r server -x server/tests -l -ii`, `pytest` against a test Postgres.

---

## 3. Global constraints (apply to every task, every sub-project)

- **Git:** branch per sub-project off `main` (`git checkout -b <name> main`); **never commit to
  `main`**. Safe git only — no `reset --hard`/`checkout -B`/`switch -C`; stage files by name (no
  `git add -A`/`.`). `git pull --rebase`. Commit trailers required (`Co-Authored-By: Claude Opus
  4.8 (1M context) <noreply@anthropic.com>` + `Claude-Session:` URL). Run `swift-pre-pr-reviewer`
  before any push with substantive Swift.
- **Public repo:** no PII; obviously-fictional test data only; never log credentials/PII (metadata
  only — presence/length).
- **Constants:** every threshold/window/sustain lives in `CNSThresholds`/`CNSMonitoringConstants`
  — never re-type a literal. Source labels via typed constants, not string literals outside
  `#Predicate`.
- **Swift specifics:** single-clause `@Query`/`#Predicate` (compound predicates hang iOS 26);
  `Calendar`-based date math; `nonisolated` for Sendable statics used off the main actor; extract
  >5-line view-body derivations to tested helpers; round-before-truncate for VoiceOver.
- **Tests:** Swift Testing (`@Test`/`#expect`), in-memory `ModelContainer`, fixed reference dates
  (never `Date.now` in assertions), epsilon tolerance for `Double` equality.
- **Instruction-file sync:** if a task changes conventions/commands, update `CLAUDE.md`, `AGENTS.md`,
  and the `.github/*instructions*` files in the same commit.

---

## 4. Resolved decision (do not re-litigate)

**`.monitoringPaused` rise-candidate reset — DECIDED: do NOT reset** (align
`CNSAlertTierMachine.ingest`'s `.monitoringPaused` branch with the gap-guarded
`.insufficientData`/`.monitoringDegraded` path; rely on `advanceRise`'s `sustainMaxGapSeconds`
guard rather than force-resetting). Rationale: a brief mask-slip during a real desaturation must
not restart the klaxon sustain timer from zero. Implemented in **plan B, Task 8.**

---

## 5. Parallelization & dependency guidance for the conductor

**Sub-project level:**
- **A first** — it is the primary safety path and gates the real alarm. Within A: **A1 (loud
  path)** and **A2 (background survival)** are largely independent and can run in parallel; **A3
  (confirmation tier + UI)** depends on A1/A2.
- **B** can start in parallel with A: its **server WS** work (plan B Tasks 1–2), its **iOS WS
  client** (Tasks 3–5), and — importantly — its **CNS fix tasks (Tasks 6–11, the PR-#23-deferred
  findings)** are independent of A and can proceed immediately. B depends on A only for the
  *actual alarm* it ultimately feeds, not for its own tasks.
- **C last** — redundant layer. Shares A's Critical Alerts entitlement but ships Time-Sensitive
  first, so it does not block on A. Independent of B (works with EMAY/Polar alone).

**Within each plan:** tasks are ordered for TDD build-up; most are sequential (later tasks consume
earlier interfaces — the plan's "Interfaces" blocks name them). The high-parallelism opportunity
is **B's Tasks 6–11**, which are mostly independent CNS-correctness fixes each with its own test,
and can be doled out to several workers concurrently (each still needs the two mandated reviewers).

**Suggested first wave of workers:**
1. A / Task 1 (`CNSAlarmChannelPolicy`, pure) — unblocks A1.
2. A / Task 6 (CB state restoration wiring) — unblocks A2.
3. B / Task 1 (server WS endpoint) — unblocks B server side.
4. B / Task 6 (`isOnlyPrimarySource` — the PR-#23 Will-Block) — independent CNS fix.
5. B / Task 7 (strip AS11 HR during faults) — independent CNS fix.

---

## 6. What "done" looks like

Each sub-project ships as its own PR(s) off `main`, all gates green, mandated reviewers passed on
CNSRisk tasks, and the parent design doc (`2026-07-09-cns-depression-klaxon-design.md`) updated
with an `## Implementation notes (post-merge)` entry per the project's phase-plan-doc rule.
Sub-project B additionally closes every finding in its spec §7 (the PR-#23-deferred set), each
with a regression test.

---

*Note on the concurrent branch:* an unrelated session's branch `feature/cns-klaxon-live-selftest`
(EMAY dongle emulator + klaxon self-test) exists off `main`; it carries an accidental duplicate
commit (`a175d96`, already relocated to the merged #23) that can be dropped with `git reset
--hard origin/feature/cns-klaxon-live-selftest`. Not part of this program.
