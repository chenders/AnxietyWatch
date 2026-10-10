# Settings Redesign — Design Spec

**Date:** 2026-05-14
**Branch:** `feat/settings-redesign`
**Mockup:** `.superpowers/brainstorm/84242-1778757917/content/settings-redesign.html`

## Problem

The current `SettingsView` (`AnxietyWatch/Views/Settings/SettingsView.swift`, 377 lines, 10 sections) reads as overwhelming and non-standard. Five independent reviewers — iOS UX, user persona, pharmacy/insurance domain, accessibility, and a codebase-explorer ground-truth pass — converged on the same diagnosis: **Settings is being used as a content surface instead of a configuration surface.**

Concrete evidence the reviewers surfaced:

- **`Section("Manage Medications")`** (`SettingsView.swift:70-89`) lists every `MedicationDefinition` row with an inline `Toggle("Active")` — and is a redundant, unsorted, unfiltered duplicate of what `MedicationsHubView` (the dedicated Medications tab) already presents correctly with active/inactive grouping and proper sorting.
- The screen has **10 sections**, several with only one row, with no consistent hierarchy.
- **`Section("Random Check-Ins")`** (`SettingsView.swift:150-215`) inlines a toggle + stepper + two hour pickers + a derived caption — 65 lines of dense control logic on the Settings root rather than behind a destination.
- The Polar H10 section (`polarSection`, lines 229-329) renders 6 distinct multi-state UIs at the root level — another 100 lines that belong behind a destination.
- Missing standard sections the codebase explorer confirmed are absent app-wide: **Notifications**, **Privacy / Permissions audit**, **Appearance**, **About → Source Code / Acknowledgments**.

## Goal

Make the Settings tab feel like a default iOS app: a short, scannable, grouped list of destinations and a small number of inline preferences. Apple's rule: **Settings configures the app, not its data.**

## Non-goals (deferred to follow-up PRs)

To keep this PR shippable, the following are explicitly out of scope:

- **Status subtitles on source rows** ("Connected · 14 categories", "Last import yesterday"). Each requires data plumbing — HealthKit counts, CPAP last-import lookup, etc.
- **New Privacy detail screen** (HealthKit permissions audit). Requires research on what we can honestly report given iOS opacity around read-auth.
- **New Appearance section** (theme picker, text-size preview). Requires persisted preferences.
- **New Connected Providers / Connected Health Records destination screens**.
- **New "Clinical Report" PDF entry**. The existing `ExportView` covers exports for now.
- **Settings.app-style colored leading SF-Symbol tiles** on every row. The Form's default leading-icon rendering is sufficient; full tile styling can land later.

These are documented here so the next contributor (or next-me) can pick them up without re-discovering them.

## Design

### New top-level structure

```
Settings
├── Data Sources
│   ├── Apple Health         → destination (auth + caption)
│   ├── Health Records       → destination (Connect button + Lab Results link + caption)
│   ├── CPAP                 → destination (existing CPAPListView)
│   └── Polar H10            → destination (extracted polarSection)
├── Sync & Data
│   ├── Server Sync          → destination (existing SyncSettingsView)
│   ├── Refresh Today's Snapshot   (action)
│   └── Rebuild All History…       (action, opens confirmation)
├── Notifications & Check-Ins
│   └── Random Check-Ins     → destination (extracted controls)
├── Reports & Export
│   └── Export Data          → destination (existing ExportView)
└── About
    ├── Version              (LabeledContent, value = commit hash)
    └── Source Code          → link out to GitHub repo
```

**Section count drops from 10 to 5. Inline controls on the Settings root drop from ~10 to 3 actions.**

### Files to add

| Path | Purpose | Source content |
|---|---|---|
| `Views/Settings/AppleHealthSettingsView.swift` | Apple Health authorization destination | Extracted from `Section("Health Data")` (lines 25-41) |
| `Views/Settings/HealthRecordsSettingsView.swift` | Clinical Records connect + Lab Results entry | Extracted from `Section("Clinical Records")` (lines 43-68) |
| `Views/Settings/PolarSettingsView.swift` | Polar H10 pairing + session control | Extracted from `polarSection` (lines 229-329) |
| `Views/Settings/CheckInSettingsView.swift` | Random Check-Ins config | Extracted from `Section("Random Check-Ins")` (lines 150-215) |

Each new view is a `View` struct containing its `Form` content; consumers wrap it in a `NavigationLink { … } label: { Label(name, systemImage:) }` on the Settings root.

### Files to modify

- `Views/Settings/SettingsView.swift` — refactor body from 10 sections / 215 in-line lines into the 5-section index above. Drop `@Query allMeds`, `@State` random-check-in mirrors, and `deleteMeds(_:)`. Keep `refreshTodaySnapshot()` and `rebuildAllSnapshots()`.

### Files to delete

None. (No call sites reference the deleted `Section("Manage Medications")` or the `allMeds` query.)

### Behavioral rules

1. **No `@Query` on `MedicationDefinition` in `SettingsView`.** Removed entirely. Medications management is the Medications tab's job.
2. **"Source Code" row** opens GitHub via `Link(_:destination:)` with the repo URL `https://github.com/chenders/AnxietyWatch` (confirmed via `git remote`).
3. **`Rebuild All History…`** keeps its trailing ellipsis to signal a confirmation dialog will follow (Apple's HIG convention).
4. **Random Check-Ins destination** must preserve all current behavior: `RandomCheckInManager.isEnabled`, `frequencyPerDay`, `activeHoursStart`, `activeHoursEnd` mutators, and the `cancelAll` → `scheduleNextCheckIn` re-arm sequence on each change. No semantic changes to scheduling.
5. **Polar destination** must preserve every state branch (`.idle`, `.scanning`, `.recording`, `.connecting`, `.bluetoothOff`, `.bluetoothUnauthorized`, `.bluetoothUnsupported`, `.error`) and the existing `recordingPresentation.showingLiveView` plumbing.
6. **HealthKit destination** must preserve the "iOS does not report read-auth back to apps" caption — that text matters for user trust and is the closest thing the app has to a privacy disclosure today.

### Visual rules

- Standard SwiftUI `Form { Section("Header") { … } }`. No custom cards, gradients, or hero treatments.
- Each section gets one short **footer** explaining what it does, matching Settings.app idiom. (`Text("…").font(.caption).foregroundStyle(.secondary)` placed at the end of the section body is the existing pattern in this file.)
- All NavigationLink labels use `Label(title, systemImage:)` so the leading-icon rendering matches the existing project convention.
- No new SF Symbol icons introduced; reuse symbols already in use in the codebase where possible.

## Testing

The codebase explorer confirmed **no existing tests touch `SettingsView`**. The new destination views are mostly UI structure — pure logic already lives in `RandomCheckInManager`, `PolarHRMService`, and `HealthKitManager`, each of which has its own tests.

### What we'll add

A single new test file: `AnxietyWatchTests/SettingsViewSmokeTests.swift`. Pure smoke tests that construct each view inside a seeded `ModelContainer` and assert non-crash. These are cheap insurance against typos / bad initializers; they don't try to verify visual structure.

```swift
@Test func settingsViewConstructsCleanly() async throws {
    let container = try PreviewHelpers.makeSeededContainer()
    _ = SettingsView()
        .modelContainer(container)
        .environment(PolarHRMService(modelContext: ModelContext(container)))
        .environment(RecordingPresentationCoordinator())
}
// + one similar test per new destination view
```

### Regression safety

- `RandomCheckInManagerTests` (existing) already covers the persistence layer that `CheckInSettingsView` mutates — no new logic to test.
- The deleted `Section("Manage Medications")` had no automated tests, so its removal frees test maintenance burden rather than adding any.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Polar section state machine has 8 branches; extraction could drop a case. | Move the entire `polarSection` body verbatim; only the wrapping section header / NavigationLink boundary changes. |
| Random Check-Ins `onChange` re-arming logic is subtle (cancel → set enabled → schedule). | Move the `@State` + `onChange` blocks verbatim into the new view; only the `NavigationLink` wrapping changes. |
| Users on `main` who currently use the Settings → toggle-a-med flow will lose it. | The dedicated Medications tab provides the same toggle via `MedicationsHubView`'s active/inactive sections — no user-facing capability is removed, only a duplicate path. |
| `SwiftLint --strict` may flag long inline `Label` strings or files near the 150-line warn threshold. | Each extracted view stays well under 200 lines; the new `SettingsView` shrinks by ~250 lines. |
| `Link` in a Form opens Safari, not an in-app browser. | Acceptable — Apple's own Settings app does the same for external links. |

## Pre-PR checklist

Per `CLAUDE.md`:

- Run `swift-pre-pr-reviewer` agent on the unpushed diff before `git push`.
- Zero new warnings; CI runs with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and `SwiftLint --strict`.
- All tests green.
- Update this spec doc with an `## Implementation notes (post-merge)` section if scope shifts during execution.

## Open questions

1. **Acknowledgments row in About** — mocked in the design but no destination exists in the codebase. Deferred to a follow-up PR rather than blocking this one.

## Implementation notes (post-merge)

**Shipped on `feat/settings-redesign` (commits `a0aaeaf`..`b3bb921`, 2026-05-14).**

**In-scope as shipped:**
- Deleted `Section("Manage Medications")` and the redundant `@Query allMeds` + `deleteMeds(_:)` plumbing
- Extracted 4 destination views: `AppleHealthSettingsView`, `HealthRecordsSettingsView`, `PolarSettingsView` (all 8 status branches preserved verbatim), `CheckInSettingsView`
- Regrouped root into 5 sections: Data Sources / Sync & Data / Notifications & Check-Ins / Reports & Export / About
- Added Source Code GitHub link in About (`https://github.com/chenders/AnxietyWatch`)
- Section footers added throughout
- `Rebuild All History` gained its trailing ellipsis (HIG convention for actions that open a confirmation dialog)
- 5 view-construction smoke tests added to `SettingsViewSmokeTests`
- `SettingsView.swift`: 377 → 152 lines

**Verification:**
- 899/899 tests pass
- Zero compiler warnings, zero SwiftLint violations
- Pre-PR review (`swift-pre-pr-reviewer` per CLAUDE.md): 0 Will Block, 1 Should Address (deferred — smoke tests are construction-only, a pre-existing codebase pattern), 4 Nits (deferred — pre-existing debt or low-urgency)

**Deferred (still open, tracked for follow-up PRs):**
- Status subtitles on source rows (e.g., "Connected · 14 categories", "Last import yesterday") — requires data plumbing
- Privacy detail screen / HealthKit permissions audit — requires research on what we can honestly report given iOS read-auth opacity
- Appearance section (theme picker, text-size preview) — requires persisted preferences
- Connected Providers destination inside Health Records
- Clinical Report PDF entry (existing `ExportView` covers exports for now)
- Settings.app-style colored leading SF-Symbol tiles
- Acknowledgments destination in About
- Smoke tests that render `body` rather than just constructing the view (would catch environment-injection crashes)
- Closure-based `NavigationLink` destinations containing `@Query` (`LabResultsView`, `CPAPListView`, `ExportView`) — pre-existing iOS 26 render-loop risk per CLAUDE.md, not introduced by this PR
