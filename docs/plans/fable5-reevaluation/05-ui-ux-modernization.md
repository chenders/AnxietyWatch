# Phase 5 — UI/UX modernization

**Goal:** evaluate the entire UI/UX — iOS app, watch app, widgets — against current Apple HIG and iOS 18/26-era SwiftUI design practice, and propose improvements ranging from polish to whole-screen overhauls where a real argument exists. Register-first: nothing gets rebuilt until Chris triages the proposals.

## Method

1. **Current-state inventory.** XcodeBuildMCP screenshot capture of every screen in every view area — seeded dense data (via the PR #152 restore tool with `-autoRestoreFromServer`), light + dark (`set_sim_appearance`), default + large Dynamic Type — plus the watch app on the watchOS simulator. This inventory doubles as the "before" record for any overhaul.
2. **Multi-lens evaluation panel (Workflow fan-out)** — each screen judged through five independent lenses:
   - **HIG compliance** — navigation patterns, sheet vs. push semantics, toolbar/tab conventions, platform-idiomatic controls.
   - **Information architecture** — is the 12-area tab/nav structure still right post-dashboard-redesign (PR #147)? Task frequency vs. reachability: daily actions ≤2 taps; the journal-is-the-anchor principle should shape hierarchy.
   - **Accessibility** — VoiceOver flow, contrast, hit-target size, Dynamic Type resilience (holistic, not per-diff like the existing hook).
   - **Visual design** — typography scale consistency, spacing rhythm, color semantics (ChartPalette vs. ad-hoc accents), per-screen hierarchy.
   - **Interaction cost** — taps/scrolls for the core loops: log an anxiety entry, check last night's data, log a med dose, start an HRV session.
3. **Verdict per screen:** `fine` / `polish` / `redesign`, each with rationale. An overhaul proposal must argue which user goal is served better — "looks dated" doesn't qualify. Known seed: the watch `QuickLogView` wastes screen space and needs larger buttons (from memory).
4. **Prototype before committing.** Top redesign candidates get HTML/artifact mockups or a throwaway branch prototype for Chris to react to before real implementation. Use the `frontend-design` skill for direction; `chart-ux-auditor` guards any Trends changes.
5. **Output:** `UI_UX_PROPOSALS.md` (screen-by-screen verdict table + proposals). Approved work ships in batched PRs with before/after screenshots in the description (screenshots PII-reviewed per repo rules — the restore tool's demo data is real health data; prefer synthetic-looking captures or verify values are unremarkable).

## Done when

Every screen has a verdict, proposals triaged, approved batches merged, "after" screenshots captured.

## Implementation notes (post-merge)

_Pending._
