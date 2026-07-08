# Sync Instruction Files

Mirror a change made in one AnxietyWatch instruction file across the other four. CLAUDE.md mandates this synchronization in the same commit; today it's done by memory and drifts. This command enforces it.

## Arguments

- `$ARGUMENTS` — optional path to the file you just edited. If omitted, the command infers from `git diff --name-only` which instruction file(s) have unstaged changes.

## The five files

These five files MUST stay in sync where their topics overlap (coding conventions, testing rules, sensitive-data rules, design principles, common pitfalls):

1. **`CLAUDE.md`** — project context for Claude Code (root)
2. **`AGENTS.md`** — multi-agent tooling instructions (root)
3. **`.github/copilot-instructions.md`** — cross-cutting Copilot review instructions
4. **`.github/instructions/swift.instructions.md`** — Swift/iOS Copilot rules (path-scoped to `**/*.swift`)
5. **`.github/instructions/python.instructions.md`** — Python/server Copilot rules (path-scoped to `server/**/*.py`)

`REQUIREMENTS.md` is a sixth instruction-adjacent file but it documents the *spec* (data model, build plan), not conventions, so changes there don't usually need mirroring.

## Instructions

### 1. Identify the source-of-change file

If `$ARGUMENTS` is set, that's the source. Otherwise:

```bash
git diff --name-only -- 'CLAUDE.md' 'AGENTS.md' '.github/copilot-instructions.md' '.github/instructions/*.instructions.md'
```

If multiple instruction files have unstaged changes, list them and ask the user which to use as the source-of-truth.

### 2. Diff the source

```bash
git diff -- <source_file>
```

For each non-trivial addition, modification, or deletion in the diff, classify by topic:

- **Cross-cutting** (applies to all languages) — should appear in `CLAUDE.md`, `AGENTS.md`, AND `.github/copilot-instructions.md`. The `.github/instructions/*.instructions.md` files inherit by path scope; only duplicate there if the rule has Swift- or Python-specific phrasing.
- **Swift-specific** — `CLAUDE.md` (author-facing) + `.github/instructions/swift.instructions.md` (reviewer-facing).
- **Python-specific** — `CLAUDE.md` + `.github/instructions/python.instructions.md`.
- **Process / tooling / workflow** — usually `CLAUDE.md` + `AGENTS.md`; `.github/*` only if reviewers also need to know.

### 3. Read the other instruction files

For each topic-classified change, read the corresponding sections in the other instruction files. Find:

- An existing section covering this topic → propose an edit that brings it in sync.
- No existing section → propose where in the file to insert it (which heading, which list).

Different files have different framings — author-facing in `CLAUDE.md` ("before pushing X"), reviewer-facing in `.github/instructions/swift.instructions.md` ("flag X"). Adapt the phrasing, don't copy verbatim, but the rule itself must be the same.

### 4. Present the diffs for approval

For each file that needs an update, show the proposed diff (in `+++/---` form) and ask the user to confirm before applying. Do not auto-apply — instruction-file edits affect every collaborator and Copilot review run.

### 5. Apply approved changes

After confirmation, use `Edit` to apply each diff. Stage all five files together with a single `git add` of explicit paths (per CLAUDE.md "Avoid `git add -A`").

### 6. Sanity check

After applying, re-grep the key topic across all five files and confirm wording is consistent where it should be. Common pitfalls list, Sensitive Data Rules, Testing Expectations — these are the highest-drift sections, double-check them.

## Notes

- If the source-of-change is purely cosmetic (typo fix, reflow), don't mirror — say so and exit.
- If the change is a *removal* (a deleted rule), mirror the removal everywhere — leaving dead rules in `.github/instructions/*.instructions.md` after their parent died in `CLAUDE.md` is a defect.
- This command does NOT commit. Surface the staged diff so the user reviews before the actual commit.
