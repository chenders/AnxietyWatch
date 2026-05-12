# Claude Code Setup Improvements — Reducing the Copilot-Round Tax

**Status:** Living document — proposals are tracked in the implementation order below. Open for discussion.
**Date:** 2026-05-11
**Author:** Claude (with the maintainer)
**Context:** Review of the `claude-code-ios-dev-guide` repo on GitHub against our actual Copilot review history.

---

## TL;DR

We are spending too many commits on Copilot-review rounds. The fix is **not** "make Copilot quieter" — Copilot's feedback is mostly good. The fix is **catching the same recurring issue categories *before* a PR opens**, using local tooling and pre-PR review agents.

The external guide is broadly sensible but only ~40% of it applies to this repo. The high-value adoptions are: a strict SwiftLint hook, a project-scoped pre-PR review subagent, a small set of slash commands, and pinning recurring-issue patterns into the appropriate instruction files — cross-cutting items in `CLAUDE.md` and `.github/copilot-instructions.md`, Swift-specific patterns in `.github/instructions/swift.instructions.md`. Almost everything else (PRD-driven workflow, Plan Mode default, plugin scaffolding, sandbox tiers) is overkill for a solo public-repo project that already has tight `CLAUDE.md` + `AGENTS.md` + path-scoped Copilot instruction-file coverage.

---

## The diagnostic — where are the rounds coming from?

### Volume

| Window | Copilot-round commits |
|---|---|
| Last 500 commits (all branches) | 165 (33%) |
| Since 2026-03-01 (~10 weeks) | 255 |
| PR #123 | 17 rounds |
| PR #128 | 13 rounds |
| PR #129 | 9 rounds |
| PR #132 (final) | **16 rounds (39 inline comments)** |

A third of our commit history right now is round-trips with Copilot. That's the real cost.

### Recurring issue categories (from PRs #128, #129, #130, #132)

These show up over and over:

1. **Source-label / constant drift.** Hardcoded `"polar_h10"` literals instead of `PolarHRMService.sourceLabel`. Caught at least 5 times in PR #132 alone (in `@Query` predicates where the macro can't see the constant — fine — *and* in initializers, previews, and tests, where it could have).
2. **`@Query` scope problems.** New SwiftData queries fetch all rows of a type and filter in-memory, instead of pushing predicates into the fetch. This is both a performance bug *and* a correctness bug as new writers of the same table appear.
3. **Window/date-anchor bugs.** Computing baselines off `Date.now` instead of the displayed window's `upperBound`, so historical browsing shows wrong deltas.
4. **VoiceOver / on-screen value mismatch.** `Int(hf)` (truncate) in accessibility strings vs `%.0f` (round) on screen — different numbers spoken vs shown. Wording drift like "LF over HF" vs "LF/HF".
5. **SwiftUI navigation/button hit-target conflicts.** `Button` inside `NavigationLink` label, sheet-can-be-dismissed-while-recording with no Stop affordance.
6. **State-machine completeness.** `unpair()` only handles `.recording`, not `.connecting` — connection finishes after unpair and re-starts a session.
7. **Empty-state gates not updated.** New data source added; `hasAnyData` not extended; users with only that source see "No Data Yet".
8. **Deterministic ordering.** `Dictionary(grouping:).map { }` returning arbitrary order, then `LineMark` drawing the result in arbitrary order.
9. **Doc-comment drift.** Comment says "chronological", `@Query` says `order: .reverse`. Easy miss in review, easy catch by re-reading docstrings against code.
10. **Statistical edge cases.** `Int(Double(count) * 0.95)` picks `max` at small `count`. Off-by-one issues in percentile/quantile code.
11. **SwiftLint line-length.** Long inline `Text("...")` literals failing the 200-char error gate after push.
12. **PR scope vs description drift.** "Server-side only" PRs that also touch iOS Info.plist and CI workflows. Several rounds on #130 just to align the description with what shipped.
13. **Magic-number / threshold duplication.** A constant like `3 * 3600` (overnight threshold) repeated as a literal across 4 files instead of a named `LFHFAggregator.overnightThresholdSeconds`. Same family as source-label drift but a separate category because magic numbers tend not to trigger "drift" pattern matching.
14. **Float equality in tests.** `#expect(x == -0.18)` instead of `abs(actual - expected) < epsilon`. Brittle to representation/optimization differences across platforms.
15. **Day-alignment of date math.** Computing a "30 days ago" cutoff as `Date - 2_592_000` instead of `Calendar.current.startOfDay(for: Date - 30.days)`. Causes the cutoff to depend on time-of-day and silently exclude sessions earlier on the boundary day.
16. **Padded vs unpadded date range conflation.** Reusing a chart-padded `dateRange.upperBound` (e.g., `+12h` for visual spacing) for non-visual baseline math. The padding is correct for axis scaling, wrong for "what counts as in-window".
17. **Empty-state derived from filtered subset.** `validWindowMeans` (sessions with non-nil HF) used as both the "empty" gate *and* the source of "latest". Result: card appears empty even when `windowMeans` has data; "latest" silently falls back to an older session while UI still labels it "most recent".
18. **Anchor timing precision.** Anchoring a "night" to the earliest *reading* timestamp rather than `SensorSession.startTime` — readings can lag start by ~60s, mis-bucketing sessions that begin within a minute of midnight into the next day.
19. **Testability gaps in views.** Non-trivial pure computation (e.g., baseline/delta/subtitle logic with 3+ states) buried inside a SwiftUI view without unit tests. Catchable rule: any `View` body that contains >5 lines of pure derivation should be extracted to a testable helper.
20. **Per-render recomputation.** A computed property accessed N times in the same `body` (empty-state check, title, summary card, range computation, each chart sub-view) recomputes the sort/map/filter every access. Distinct from category 2 (unbounded fetch) — the fix here is "cache in `body` as `let`," not "narrow the fetch."
21. **Nil-discriminator backwards-compatibility.** When a column like `source` is added mid-flight to a SwiftData model, legacy rows have `nil`. New `@Query` predicates of the form `source == "polar_h10"` silently exclude them. Catchable rule: any new predicate filtering on a discriminator column should either handle nil explicitly (`source == X || source == nil`), or the PR must include a backfill that eliminates nils.
22. **Fallback-state UX honesty.** When "latest" or "isEmpty" gates are derived from a filtered subset (category 17), the fallback path needs honest user-facing text — not silently displaying an older session as "most recent", not rendering `30-day avg: X · —` when the delta is nil. Refinement of category 17 specifically for the user-visible side.

These are almost all **catchable** without a human reviewer if we run the right checks before pushing.

### Categories 1-12 are originals; 13-22 surfaced in PR #132 rounds 10-16

Worth noting: **most of categories 13-22 were present in the original commit
of PR #132** — they got surfaced incrementally as Copilot's relevance ranking
allowed, not introduced by intermediate fixes. The day-alignment bug, the
magic-number duplication, the float-equality assertions, the per-render
recomputation, and the missing tests for `LFHFChartView` all existed at
round 1. This is fresh empirical support for the "relevance budget, not
output budget" finding in the research section below.

### The cascade pattern: round 2 → round 16

Some rounds 10-16 issues are genuine *cascade revelations* — fixes from
earlier rounds exposing the next layer. The clearest example, and the
strongest single piece of evidence in this whole document:

- **Round 2** (commit `242b34d`): "push source filter into @Query."
  Copilot correctly flagged a performance issue — `@Query` was fetching
  all `HRVReading` rows and filtering in-memory. The fix moved the filter
  into the SwiftData predicate: `source == "polar_h10"`.
- **Round 16** (14 rounds later): Copilot flagged that *this exact
  predicate* excludes legacy rows where `source` is nil (pre-source-tracking
  rows, Watch→phone transfer pipeline rows). Surfaced in 4 places. The
  round 2 fix introduced a real bug that took 14 rounds of refinement to
  reach the top of the relevance ranking.

Other cascade examples in this PR:

- Round 8 fixed `Date.now` → `dateRange.upperBound`. Round 11 then
  surfaced that `dateRange.upperBound` is padded by +12h for chart
  spacing — so the round 8 fix introduced an off-by-12h baseline bug.
- Round 11 introduced session-start anchoring. Round 13 then flagged
  that the 30-day cutoff isn't day-aligned.

These cascade issues are the hard ones. Neither Copilot tuning nor the
pre-PR agent will catch them all without actually understanding the
surrounding system. They're a structural argument for **fewer, smaller PRs
with their own review cycles** rather than for more reviewer tooling.
A PR that's narrower in scope contains its cascade depth — fewer fixes
means fewer opportunities for fix-X-creates-Y. PR #132 touched 8 files
and introduced a new feature with novel state handling; that's about
where the cascade depth gets expensive.

This suggests a complementary lever to "review better": **scope PRs more
tightly**. Splitting PR #132 into (a) the pure `LFHFAggregator` helper,
(b) the `TrendsView` integration, (c) the drill-down screens — each as
its own PR — would likely have spent ~5 rounds total instead of 16,
because each PR's cascade depth would have been smaller.

---

## The guide — what it proposes, and what fits us

Quick scorecard against this repo:

| Guide recommendation | Already have? | Adopt? | Notes |
|---|---|---|---|
| Native CLI install | Yes | — | |
| Model selection (Opus plan / Sonnet exec) | Implicit | — | We already do this implicitly via `/fast`, etc. |
| Tiered settings (user / project / local) | Partial | **Improve** | The maintainer's machine has a local `.claude/settings.local.json` (gitignored); the repo has no committed `.claude/settings.json` yet — adding one is planned for the SwiftLint-hook follow-up PR. |
| Tight `CLAUDE.md` with quick-ref + DO-NOT | Yes (verbose) | **Refine** | Ours is comprehensive but missing a few of the recurring patterns above |
| Feature-scoped `CLAUDE.md` (`Features/X/CLAUDE.md`) | No | **No** | Our folder layout is by type (`Views/`, `Services/`), not by feature |
| PRD / specs / tasks scaffold (`docs/PRD.md`, `docs/specs/`, `docs/tasks/`) | Partial (`REQUIREMENTS.md`, `PROJECT_FUTURE_PLAN.md`) | **No** | Overkill for solo public-repo project; we already plan in those files |
| `defaultMode: "plan"` | No | **No** | Conflicts with the maintainer's preference for executing directly when implications are clear (rather than always asking for plan approval) |
| `.mcp.json` (project-scoped) | No (XcodeBuildMCP is global) | **Yes (low pri)** | Useful for any future collaborators / reproducibility |
| Custom slash commands (build, test, run-app, create-view, refactor-view) | One (`respond-to-copilot`) | **Selectively** | Most are thin wrappers over `xcodebuild`; we already have CLAUDE.md commands. The high-value ones are `/pre-pr-review` and `/swift-self-review` |
| Skills (`.claude/skills/`) | No project skills | **Yes (one or two)** | A `swiftdata-query-audit` skill is high value |
| Subagents (`.claude/agents/`) | No | **Yes** | This is the single highest-value adoption |
| Output styles | N/A | **No** | Niche |
| Plugins | N/A | **No** | Solo repo, no need to bundle |
| Sandbox permission tiers | No | **No** | Conflicts with current trust model and the maintainer's "execute when implications are clear" preference |
| `PostToolUse` SwiftLint hook | No (we have a provenance hook) | **Yes** | High value — catches lint-after-push round-trips |
| `PreToolUse` file-protection hook | No | **Maybe** | We already have CLAUDE.md sensitive-data rules; a hook is belt-and-suspenders |
| `SessionStart` env-report hook | No | **No** | Cute, low value |
| `swift-format` | No | **No** | SwiftLint is enough; adding another formatter doubles config surface |

---

## Proposals — ranked

### P0 — Pre-PR review subagent (the single biggest lever)

Create `.claude/agents/swift-pre-pr-reviewer.md`. The agent runs against `git diff main...HEAD` and is **explicitly trained on the recurring categories above**. It's the local equivalent of the Copilot review pass, run before push.

Key elements:

- **Inputs:** current branch diff vs `main`.
- **Checklist (concrete, not vague):**
  - Hardcoded source-label strings (`"polar_h10"`, `"healthkit"`, etc.) outside `#Predicate` macros — flag and propose the typed constant.
  - New `@Query` declarations — assert the predicate filters by `source` and bounds by date where the underlying table grows unboundedly (`HRVReading`, `BarometricReading`).
  - VoiceOver strings — check that any `accessibilityLabel`/`accessibilityValue` numeric formatting matches the on-screen formatting (`Int(x.rounded())` vs `String(format: "%.0f", x)`).
  - SwiftUI nav patterns — flag `Button` inside `NavigationLink` label, sheets dismissible during recording without Stop affordance, missing `interactiveDismissDisabled` for in-progress states.
  - State machines — for any service with a status enum, check that destructive actions (`unpair`, `disconnect`, `cancel`) handle all in-flight states, not just the obvious one.
  - Empty-state predicates — when a new data source is wired into a view, `hasAnyData`/equivalent gate must include it.
  - Deterministic ordering — flag `Dictionary(grouping:).map`, `Set.map`, etc. immediately before any visualization or sequenced output.
  - Doc-comment drift — re-read every `///` comment touched in the diff against the code below it.
  - Magic-number duplication — grep the diff for the same numeric literal appearing in 2+ files, especially threshold/window/timeout values. Propose a named constant.
  - Float-equality in tests — flag `#expect(x == y)` where both sides are `Double`; require `abs(x - y) < epsilon` form.
  - Day-alignment of date math — any `Date` arithmetic that subtracts days/weeks should typically wrap `Calendar.current.startOfDay(for:)` unless the intent is explicitly time-of-day-sensitive.
  - Padded-vs-unpadded date range — if a `dateRange` is computed with padding for visual spacing, any non-visual consumer (baseline math, predicate bounds, "in window?" checks) must use an unpadded sibling value.
  - Empty-state derived from filtered subset — if a view derives both `isEmpty` and `latest` from the same `.compactMap`-filtered array, flag and ask which definition is correct for each.
  - Testability of view-embedded pure computation — any SwiftUI `View` body containing >5 lines of pure derivation (baselines, deltas, formatting branches) should be extracted to a testable helper with Swift Testing coverage.
  - Per-render recomputation — any computed property accessed 2+ times in the same `body` should be cached as a `let` at the top of `body`. Grep the diff for computed properties and count their call sites in their declaring view.
  - Nil-discriminator backwards-compatibility — any new `@Query` predicate that filters on a recently-added discriminator column (`source`, `kind`, `provider`, etc.) must either include `|| <col> == nil` or the PR must include a backfill of legacy rows. Cross-reference against the `@Model` definition's docstrings for column history.
  - Fallback-state UX honesty — if a view falls back to an older record when "latest" is invalid, the on-screen label must reflect that (not silently call it "most recent"). If a status string can collapse to "—" or empty in some branch, propose a meaningful alternative.
  - AccessibilityElement combine anti-pattern — if a container with interactive children (`Button`, `NavigationLink`) applies `.accessibilityElement(children: .combine)`, the children collapse into a single VoiceOver element and become unfocusable. Recommend `children: .ignore` on the container and moving the summary onto the interactive label.
  - Filter granularity vs aggregation unit — when the diff includes pre-aggregation filtering, check whether the filter's granularity matches the aggregation's unit. Filtering per-reading before per-session means produces partial means at window boundaries; filter the resulting per-session values instead.
  - SwiftLint pre-run (`swiftlint lint --strict --quiet` on changed files).
  - Test build (`xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`) and run (`-only-testing:AnxietyWatchTests`).
  - PR-description sanity — if the PR is titled "server-side only", grep the diff for non-server paths and surface them.
- **Output:** a categorized list (Will Block / Should Address / Nit), ready to feed into a fix loop.

Current invocation (until the slash command lands as a follow-up PR) is direct dispatch via the `Task` tool with `subagent_type: swift-pre-pr-reviewer` — typically prompted with the diff range to review (e.g., "Review `git diff main...HEAD`" or "Review the current branch vs main"). The planned future invocation:

```bash
# Planned — slash command (not yet implemented; tracked as a follow-up PR):
/pre-pr-review                  # current branch vs main
/pre-pr-review --commits ae9b2bc..HEAD   # since a marker commit
```

This agent is the one most likely to compress 16 rounds into 3-4. (Some cascade-revelation rounds are structurally unavoidable without splitting the PR — see "The cascade pattern" above.)

### P0 — `PostToolUse` SwiftLint hook on Swift edits

When the SwiftLint-hook follow-up PR lands, this block will be added to a new `.claude/settings.json` (project-scoped, committed — does not exist yet in this repo):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/swiftlint-edited.sh"
          }
        ]
      }
    ]
  }
}
```

`swiftlint-edited.sh` runs `swiftlint lint --strict --quiet --path <file>` on `.swift` files only; non-blocking but it feeds violations back into the conversation so Claude fixes them immediately rather than discovering them in CI after push.

This **alone** would have killed several of the recurring `line_length` round-trips and probably 1-2 unrelated lint issues per PR.

The existing `post-tool-call.py` provenance hook should stay; we just chain a second hook for SwiftLint. The settings.json snippet above already shows both can coexist as separate matchers.

### P0 — Pin the recurring categories into the path-scoped instruction files

Right now both files describe coding conventions in general. They don't enumerate the *specific* patterns we keep getting bitten by. Add a new section:

```markdown
## Common pitfalls (catch these before pushing)

- **Source-label drift:** Outside `#Predicate` / `@Query` macros, use the typed
  constant (`PolarHRMService.sourceLabel`), not the literal `"polar_h10"`.
  String literals are only acceptable where the macro can't capture types.
- **`@Query` scope:** Any new `@Query` on `HRVReading`, `BarometricReading`, or
  another unbounded table must filter by `source` *and* bound by date. Don't
  fetch the whole table to filter in-memory.
- **VoiceOver consistency:** Round before truncating (`Int(x.rounded())`), and
  match the on-screen format string. `Int(hf)` vs `%.0f` is a bug.
- **SwiftUI nav:** Never put a `Button` inside a `NavigationLink` label —
  the inner button becomes non-interactive. Split hit targets.
- **State-machine completeness:** Destructive actions (`unpair`, `stopSession`,
  `disconnect`) must handle all in-flight states, not just the terminal one.
- **Empty-state gates:** When wiring a new data source into a view, update
  `hasAnyData`/equivalent so users with only that source don't see "No Data".
- **Deterministic ordering:** `Dictionary(grouping:)` and `Set` produce
  arbitrary order. Sort explicitly before any rendering or sequential output.
- **Doc-comment drift:** When you change a sort order or filter, re-read every
  `///` comment in the diff and update it.
- **SwiftLint line-length:** 150 warn, 200 error. Long inline `Text("...")`
  strings must be split with `+` concatenation or multi-line literals.
- **Magic-number duplication:** Any threshold/window/timeout used in 2+ files
  belongs in a named constant (`LFHFAggregator.overnightThresholdSeconds`,
  not `3 * 3600`).
- **Float-equality in tests:** Never `#expect(x == y)` on `Double`. Use an
  epsilon tolerance — `abs(actual - expected) < 0.001`.
- **Day-alignment of date math:** Any "N days ago" cutoff should typically
  wrap `Calendar.current.startOfDay(for:)` so the boundary doesn't depend
  on time-of-day.
- **Padded vs unpadded date range:** A `dateRange.upperBound` padded by `+12h`
  for chart spacing is wrong for baseline math, predicate bounds, or
  in-window checks. Keep an unpadded sibling for non-visual consumers.
- **Empty-state derived from filtered subset:** Don't derive both `isEmpty`
  and `latest` from the same `.compactMap`-filtered array — the empty gate
  should usually key off the unfiltered set; "latest" needs explicit
  handling for the all-invalid case.
- **Anchor to authoritative timestamps:** Bucket sessions by
  `SensorSession.startTime`, not the earliest reading timestamp. Readings
  can lag start by up to a minute and mis-bucket near-midnight sessions.
- **Testability of view-embedded computation:** If a SwiftUI view body has
  >5 lines of pure derivation (baselines, deltas, multi-state subtitles),
  extract to a helper and write Swift Testing coverage.
- **Per-render recomputation:** Any computed property accessed 2+ times in
  the same `body` should be cached as a `let` at the top of `body`. Don't
  call the same `.sorted().map { ... }` chain five times in one render.
- **Nil-discriminator BC:** When filtering on a recently-added column
  (`source`, `kind`, `provider`), legacy rows likely have `nil`. Either
  include `|| col == nil` in the predicate or backfill before adding the
  filter. Check the `@Model` docstring for the column's history.
- **Fallback-state UX honesty:** If "latest" or "isEmpty" gates fall back
  to a filtered/older subset, the user-visible label must say so. Don't
  silently present an older session as "most recent". Status strings that
  can collapse to "—" should emit a meaningful alternative for that branch.
- **AccessibilityElement combine on interactive children:** Don't wrap a
  container with interactive children (info `Button`, `NavigationLink`)
  in `.accessibilityElement(children: .combine)` — it collapses them into
  a single VoiceOver element and the children become unfocusable. Use
  `children: .ignore` and put the summary on the interactive label.
- **Filter granularity vs aggregation unit:** When filtering before
  aggregation, the filter granularity must match the aggregation unit.
  Filtering per-reading before per-session means produces partial means
  for sessions that straddle the window boundary. Filter the resulting
  per-session values instead.
```

Swift-specific items go into `.github/instructions/swift.instructions.md` (path-scoped to `**/*.swift`); only cross-cutting items belong in `.github/copilot-instructions.md`. The same author-facing list lives in `CLAUDE.md`'s "Common pitfalls" section. This costs us nothing and gives both the local agent *and* Copilot itself the same checklist.

### P1 — Project-scoped `.claude/settings.json` (committed)

Today the repo has no committed `.claude/settings.json`; the maintainer's machine has a local `.claude/settings.local.json` (gitignored) but that's per-machine. The guide's distinction is right: stuff like the SwiftLint hook, the `xcodebuild test` permission allowlist, and project env vars (`DEFAULT_SIMULATOR=iPhone 17 Pro`) belong in a committed file so any future contributor (or the maintainer on a new machine) gets them automatically. Personal stuff (`DEVELOPMENT_TEAM`, model preferences) stays in the gitignored `.local.json`.

Suggested minimum:

```json
{
  "permissions": {
    "allow": [
      "Read", "Write", "Edit",
      "Bash(xcodebuild *)",
      "Bash(swiftlint *)",
      "Bash(git *)",
      "Bash(gh pr:*)",
      "Bash(gh api:*)",
      "mcp__XcodeBuildMCP__*"
    ],
    "deny": [
      "Bash(rm -rf *)",
      "Read(.env*)",
      "Write(.env*)"
    ]
  },
  "env": {
    "PROJECT_NAME": "AnxietyWatch",
    "DEFAULT_SIMULATOR": "iPhone 17 Pro",
    "IOS_DEPLOYMENT_TARGET": "18.0"
  },
  "hooks": {}
}
```

(Populate `"hooks"` with the SwiftLint `PostToolUse` block from P0 above.)

### P1 — A second subagent: `swiftdata-query-auditor`

Narrower than the pre-PR reviewer. Triggers when any `@Query` declaration or `FetchDescriptor` is added/modified. Reads the surrounding `@Model` definition to determine whether the table is unbounded (HRVReading: yes; AnxietyEntry: bounded by user input rate, so OK).

This could be a **skill** rather than a separate agent — invoked automatically when Claude touches a SwiftData query.

### P1 — `/respond-to-copilot` improvements

The existing `.claude/commands/respond-to-copilot.md` is excellent and we use it heavily. One improvement: after each round, append the *category* of each addressed comment into a running tally (in a `.claude/copilot-stats.json` say). Over 5-10 PRs we'd see, empirically, which categories are now caught locally and which are still leaking — drives further `CLAUDE.md` tightening.

### P2 — `.mcp.json` (project-scoped, committed)

Today XcodeBuildMCP is configured at user scope. Moving it to a checked-in `.mcp.json` makes the setup reproducible for anyone cloning the repo (or for the maintainer on a fresh machine). Low immediate value since this is a solo project, but it's three lines of JSON and the cost is trivial:

```json
{
  "mcpServers": {
    "XcodeBuildMCP": {
      "command": "npx",
      "args": ["-y", "xcodebuildmcp@latest"],
      "env": {
        "INCREMENTAL_BUILDS_ENABLED": "true",
        "XCODEBUILDMCP_DYNAMIC_TOOLS": "true",
        "XCODEBUILDMCP_SENTRY_DISABLED": "true"
      }
    }
  }
}
```

### P2 — A small set of slash commands

Avoid bloating `.claude/commands/`. The ones with real ROI:

- `/build` — wraps the exact `xcodebuild` invocation from `CLAUDE.md` (saves a lookup).
- `/test` — same for tests.
- `/pre-pr-review` — invokes the P0 subagent.
- `/swift-self-review` — lighter pass: runs SwiftLint + builds + runs tests, no agent analysis.

Skip `/create-view`, `/refactor-view`, `/implement-feature` — these are general scaffolding that the model handles fine from a natural-language request.

---

## Tuning Copilot's review behavior

The same `.github/copilot-instructions.md` we'd update for our own benefit (P0,
"Common pitfalls") doubles as Copilot's PR-review prompt. This section is
**complementary** to the pre-PR reviewer agent, not a substitute.

### What GitHub actually documents

I went looking for the comment cap I assumed existed. There is no documented
hard cap. Instead, per GitHub's own data across 60M+ reviews:

- **Average is 5.1 comments per review**, not a ceiling — driven by relevance
  filtering, not budget.
- **29% of reviews surface zero comments** ("silence preferred over noise").
- Instructions have a **~4,000-character budget**; longer files get inconsistent
  application, and >1,000-line instruction files are flagged as causing
  degradation.
- **Critical caveat:** Automated PR reviews use a *cached model context* and
  "don't always fetch or apply new custom instructions from the repo at
  runtime." Recent edits to `.github/copilot-instructions.md` may be ignored on the
  next automated review. Documented workaround: manually re-request Copilot
  review after pushing instruction changes, which can force a refresh.
- **Structural output changes don't reliably work.** GitHub PM guidance is
  explicit: instructions work as *contextual guidance* (what to look for, what
  matters most), not as *output formatters* (forcing severity tags, custom
  comment shapes, mandatory sections).

So the "limiting itself" pattern we see isn't a budget — it's a relevance
filter tuned to 5.1 avg. We can't break that, but we *can* shift which
issues clear the relevance bar by pinning what we care about as context.

### What our PR #132 history suggests

Rounds 1 surfaced 6 issues, but the `Date.now` baseline (round 8), the
doc-comment "chronological vs reverse" drift (round 5), and the `Int(hf)`
truncate-vs-round bug (round 7) were all present in the original commit.
They got incrementally surfaced as Copilot's relevance ranking allowed,
not introduced by intermediate fixes. Better-primed context could plausibly
have pushed them above the relevance threshold on round 1.

### Realistic expectations

Even fully tuned, expect 16 rounds to compress to roughly 8-10, not 1-2.
Combined with the pre-PR agent (P0), 3-4 is plausible. Driving below 3 on a
PR the size of #132 would require splitting it — see "The cascade pattern"
above for why.

### Four additions to `.github/copilot-instructions.md`, ranked by ROI:

### 1. Explicit review priorities (biggest single lever — documented to work)

```markdown
## Review Priorities (highest to lowest)

When you have limited comments to make, spend them in this order:

1. **Correctness bugs** — wrong output, off-by-one, missing state branches,
   non-deterministic ordering that affects rendering, predicate scope bugs
2. **Performance footguns** — unbounded `@Query` fetches, work done on every
   render that could be conditional, `O(n)` rebuilds in hot paths
3. **Accessibility / a11y consistency** — VoiceOver text not matching
   on-screen formatting, missing labels, nav/button hit-target conflicts
4. **State-machine gaps** — destructive actions that only handle the obvious
   state, sheets dismissible mid-recording with no Stop affordance
5. **Source-of-truth drift** — hardcoded constants where a typed reference
   exists, doc comments contradicting the code below them
6. **API / public-repo safety** — PII, real-looking test data, leaked secrets

**Skip or deprioritize:** import ordering, trailing whitespace, doc-comment
punctuation, naming bikesheds — caught by SwiftLint or don't matter.
```

Tells Copilot's planner where to spend its budget.

### 2. Concrete pattern enumeration

Same "Common pitfalls" content as the P0 author-facing section, but framed
*for the reviewer*. Copilot is good at matching against named patterns when
they're listed concretely:

```markdown
## Patterns to actively look for in every review

Check every diff for these specific patterns, even if not obviously broken:

- **Hardcoded source-label strings** outside `#Predicate`/`@Query` macros
  where `PolarHRMService.sourceLabel` (or similar) is available.
- **New `@Query` on `HRVReading`, `BarometricReading`, or other unbounded
  tables** that don't filter by `source` and bound by date.
- **Accessibility numeric formatting** — `Int(x)` (truncates) where the
  on-screen format uses `%.0f` (rounds). Spoken value ≠ displayed value.
- **`Button` inside `NavigationLink` label** — the inner button becomes
  non-interactive.
- **`Dictionary(grouping:).map { }`** immediately before rendering — order
  is arbitrary; needs explicit sort.
- **`Date.now` in baseline/window math** where the displayed window's
  `upperBound` is the correct anchor.
- **Sheet `.presentationDetents` without `interactiveDismissDisabled`**
  on screens that own in-progress state (recording, scanning, syncing).
- **Doc comments** describing chronology/order that contradict the
  `@Query order:` parameter or sort below them.
- **PR scope vs description** — if the PR title says "server-side only",
  check the diff for non-server paths and surface them.
```

### 3. Confidence threshold + explicit skip list (documented to work)

This is the technique [documented on dev.to][devto-copilot-tuning] from
real-codebase experience, and it aligns with GitHub's own guidance about
contextual framing:

```markdown
## Review philosophy

Only comment when you have HIGH CONFIDENCE (>80%) that an issue exists.
Prefer silence over uncertainty. Avoid hedging language like "consider",
"maybe", "you might want to" — if a fix is right, state it; if uncertain,
don't comment.

Be concise: one sentence per comment when possible.

## Skip these — caught elsewhere or low value

Do not comment on:
- Formatting, whitespace, import ordering — SwiftLint enforces these in CI.
- Doc-comment punctuation or capitalization.
- Naming bikesheds when the existing name is clear.
- Style preferences that aren't in our conventions.
- Issues already caught by `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` in our CI.

## CI context

This repo runs SwiftLint `--strict` and treats Swift warnings as errors in
CI. You don't need to flag lint or warning-level issues — those will block
merge regardless. Spend your slots on issues CI can't catch.
```

The "high confidence + skip list + CI context" framing is what most directly
moves the 5.1 average toward higher-signal comments. Explicit
deprioritization frees Copilot to spend its relevance budget on substantive
issues.

### 4. What I'd skip (was: "anti-budget framing" — downgraded)

I'd originally proposed an "anti-budget" instruction telling Copilot to
"surface 10 issues" instead of its usual 5-6. Based on the research, this
likely won't work: 5.1 is the documented *average across 60M reviews*, not
a per-instruction budget. Prompt-based attempts to force more comments are
in the category of structural output changes that GitHub explicitly says
"may not produce consistent results." Severity tagging (`[BUG]`/`[PERF]`)
falls in the same bucket — same downgrade.

The lever isn't volume, it's relevance ranking. Priorities + skip list +
confidence threshold all push the *quality* of those 5-6 comments up.

### What demonstrably doesn't help (sourced)

- **Structural output changes** — "include a risk assessment section",
  "tag comments with severity", "use this exact format" — GitHub staff
  have confirmed in the community discussion these don't apply reliably
  in automated reviews.
- **Vague directives** — "be more accurate", "be thorough", "be exhaustive"
  — flagged explicitly as anti-patterns in GitHub's blog on instruction
  files.
- **Long instruction files** — >4,000 chars gets inconsistent application;
  >1,000 lines is documented as degrading.
- **Expecting instant effect** — automated PR reviews use a cached context
  and may ignore recent instruction file edits. Re-request review manually
  after instruction changes to force a refresh.

### Measurement

We'd know this is working by tracking:

- **Comments-per-round-1** (baseline: ~6 for us; target: stay around 5-6
  but with composition shifted toward our priority categories 1-4).
- **Total rounds to merge** (baseline: 9-17 on recent PRs, 16 on PR #132; target: ≤8 with this change
  alone, ≤2 with the pre-PR agent on top).
- **Comment composition** — what % of round-1 comments are correctness/perf/
  a11y vs. style/nits. Easy to eyeball from the existing PR history.

If after 3 PRs the round-1 composition hasn't shifted, the cached-context
issue is likely the culprit — try re-requesting reviews manually after
instruction pushes.

### Sources

- [GitHub Blog: Unlocking the full power of Copilot code review][gh-blog-power]
- [GitHub Blog: 60 million Copilot code reviews and counting][gh-blog-60m]
  (source of the 5.1 avg / 29% silent / 71% actionable figures)
- [GitHub Community Discussion #178108][gh-disc-178108] (cached-context
  caveat, PM guidance on structural-vs-contextual instructions)
- [dev.to: How I taught GitHub Copilot Code Review to think like a
  maintainer][devto-copilot-tuning] (confidence threshold + skip list pattern)
- [GitHub Changelog: Better handling of large PRs][gh-changelog-large-pr]

[gh-blog-power]: https://github.blog/ai-and-ml/github-copilot/unlocking-the-full-power-of-copilot-code-review-master-your-instructions-files/
[gh-blog-60m]: https://github.blog/ai-and-ml/github-copilot/60-million-copilot-code-reviews-and-counting/
[gh-disc-178108]: https://github.com/orgs/community/discussions/178108
[devto-copilot-tuning]: https://dev.to/techgirl1908/how-i-taught-github-copilot-code-review-to-think-like-a-maintainer-3l2c
[gh-changelog-large-pr]: https://github.blog/changelog/2025-07-02-copilot-code-review-better-handling-of-large-pull-requests/

---

## What I'd skip from the guide, and why

- **PRD-driven dev with `docs/PRD.md`, `docs/specs/NNN-feature.md`, `docs/tasks/`.** We already have `REQUIREMENTS.md`, `PROJECT_FUTURE_PLAN.md`, and the existing `docs/plans/` scratch space. Adding a third planning hierarchy creates drift, not clarity. Where I *do* think a per-feature spec helps: for the multi-phase Polar H10 work that's gone 3+ PRs and 30+ rounds, a single `docs/specs/polar-h10.md` with explicit acceptance criteria would have caught some of the empty-state / nav / accessibility issues earlier. But the *scaffold* shouldn't be a project-wide convention until we see it pull its weight.
- **Plan Mode as default.** Conflicts with the maintainer's stated preference to default to execution when the implications of a task are clear, rather than always pausing for plan approval. Plan Mode is a great tool for big architectural moves (the Polar BLE design phase would have benefited) but defaulting to it would create friction on small tasks.
- **Sandbox permission tiers.** Same conflict. We trust the agent inside this repo. The CLAUDE.md "Public Repository" rules already cover the most important deny-list (secrets, PII).
- **`swift-format` alongside SwiftLint.** Two formatters with overlapping rules is a maintenance trap. Stick with SwiftLint.
- **Per-feature `CLAUDE.md` files (`Features/X/CLAUDE.md`).** Our directory layout is by type (`Views/`, `Services/`, `Models/`), not by feature. The convention doesn't match the layout.
- **Plugins system.** This is a solo public repo; we don't ship Claude tooling as a package.

---

## Suggested implementation order

1. **Done.** Pitfalls list landed in the path-scoped layout that earlier steps in this PR introduce, not in both files as originally written. The author-facing "Common pitfalls" section lives in `CLAUDE.md`; the reviewer-facing "Patterns to actively look for in Swift reviews" with the same items lives in `.github/instructions/swift.instructions.md` (path-scoped to `**/*.swift`); cross-cutting review priorities, philosophy, and CI context live in `.github/copilot-instructions.md`. The four-file sync rule is documented in `CLAUDE.md`'s "Keeping Instruction Files Updated" section.
2. **Done.** Review-priorities, philosophy, CI context, and the "Patterns to actively look for" pattern enumeration shipped in `.github/copilot-instructions.md` (cross-cutting) and `.github/instructions/swift.instructions.md` (path-scoped) earlier in this PR. The "manually re-request a Copilot review" tip remains a live tactic — automated reviews use a cached context and may ignore fresh instruction-file edits; manually re-requesting forces a refresh. **Round-1 baseline measurement** was captured on this PR (PR #133) and recorded in its review history.
3. **Next PR.** SwiftLint `PostToolUse` hook + project-scoped `.claude/settings.json`. (~1 hour.) Neither file exists in the repo yet.
4. **Done.** Drafted `.claude/agents/swift-pre-pr-reviewer.md` and ran a manual calibration pass against PR #132's first commit (`fa2f184`). Result: **30 of 32 substantive Copilot comments caught (94%)** before the agent was even formalized; the remaining 7 of 39 were cascade-revelation comments not present at `fa2f184` (issues introduced by intermediate Copilot-round fixes). The 2 misses surfaced two checklist additions now reflected in `CLAUDE.md`, `.github/instructions/swift.instructions.md`, and this doc's pre-PR agent checklist: (a) `.accessibilityElement(children: .combine)` on a container with interactive children, and (b) filter-granularity vs aggregation-unit at window boundaries.
5. **Next branch:** Add `/pre-pr-review` slash command that wraps the agent. Use it on the next non-trivial PR before pushing. Compare round count to historical baseline (and to the Copilot-tuning-only baseline from step 2).
6. **After 3-5 PRs with the new flow:** Decide whether `swiftdata-query-auditor` warrants its own skill or stays as a checklist item in the main reviewer.

---

## Open questions for the maintainer

- The maintainer's preference is to simulate a multi-agent debate before escalating a question to the human. The `pr-review-toolkit:code-reviewer`, `silent-failure-hunter`, `type-design-analyzer`, and `coderabbit:code-review` agents are already installed globally — should `/pre-pr-review` dispatch *those* in parallel instead of building a new subagent? It probably should, with the project-specific checklist passed as the prompt rather than as agent definition. **Recommend:** yes, dispatch existing agents; project-specific knowledge goes in the slash command body, not in a new agent file.
- Is there appetite for retroactively running `/pre-pr-review` on PR #132 right now to validate the design before merging?
