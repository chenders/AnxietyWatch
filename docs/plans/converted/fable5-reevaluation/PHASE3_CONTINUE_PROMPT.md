# Phase 3 — Continuation Prompt (new session)

Paste the block below into a fresh Claude session opened in this repo, after switching the model to Fable 5.

---

Continue the Fable 5 re-evaluation, Phase 3 (fix passes). First switch the session model to Fable 5 via `/model` (getting Fable back is why we restarted).

Read `docs/plans/fable5-reevaluation/PHASE3_HANDOFF.md` in full — it's the handoff from the prior session. Also skim `00-master-plan.md` (ground rules, defensive-QA phrasing) and `FINDINGS.md` (the accepted triage + fix-batch plan).

**Immediate task: FINISH BATCH B.** The branch `fable5/phase-3-sync-integrity` (commit `e410ccf`) is pushed with F-013/F-014/F-016 fixed and 76 tests green, but it has an unaddressed ⛔ BLOCKING race finding (see the handoff's Batch B section): `markSamplesSynced` flips `SensorSession.syncedToServer=true` with no `pendingSyncVersion`-style staleness guard, so a finalize interleaving an in-flight sync's network `await` can permanently strand the session server-side. Fix that (extend the `flagSnapshotsSynced` version-guard pattern to `SensorSession`/`HRVReading` + a race regression test), re-run `swift-pre-pr-reviewer` and `medical-data-accuracy-reviewer`, then open the PR, run `/respond-to-copilot` until clean, and squash-merge.

Then work down the batch queue in the handoff (Batch F next), one PR per batch: implement → build/test via XcodeBuildMCP → pre-PR review agents → PR → `/respond-to-copilot` → merge. Also do the pending register bookkeeping (mark F-001–005/F-032/F-073 fixed #157 + the ExportView finding; F-013/F-014/F-016 after Batch B merges). Proceed autonomously without asking for input where possible; only stop for genuinely ambiguous, irreversible decisions.
