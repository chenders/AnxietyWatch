# Dose-Triggered Anxiety Prompt — Design Spec

**Date:** 2026-03-28
**Status:** Draft

## Problem

When logging a benzodiazepine or stimulant dose, there's no mechanism to capture the user's anxiety level at the time of dosing or to follow up 30 minutes later to measure the medication's effect. This before/after data is valuable for understanding which medications help and how quickly.

## Goals

1. **Prompt for anxiety rating when logging specific medications** — severity (1-10), optional notes, PRN/scheduled toggle
2. **Schedule a 30-minute follow-up** — local notification that buzzes the Watch, with foreground fallback
3. **Link anxiety entries to the triggering dose** — enabling before/after paired analysis
4. **Keep everything optional** — every prompt is skippable/cancellable, dose still logs regardless

## Non-Goals

- Changing the quick-log behavior for medications without `promptAnxietyOnLog`
- Dose reminders or recurring medication schedules
- Watch app integration beyond the automatic notification mirroring

## Data Model Changes

### MedicationDefinition — add field

```swift
var promptAnxietyOnLog: Bool  // default: false
```

When creating a new medication, default to `true` if `category` is "Benzodiazepine" or "Stimulant". Manually toggleable via AddMedicationView for any medication.

### MedicationDose — add field

```swift
var isPRN: Bool  // default: true
```

Set at log time via the prompt sheet. Stored per dose (not per medication) since the same medication might be taken PRN sometimes and on schedule other times.

### AnxietyEntry — add fields

```swift
var triggerDose: MedicationDose?  // relationship to the dose that prompted this entry
var isFollowUp: Bool              // default: false; true for the 30-min follow-up entry
```

Before/after pairs: two AnxietyEntry rows pointing at the same MedicationDose — one with `isFollowUp: false` (at dosing time) and one with `isFollowUp: true` (30 minutes later).

## UI Flow

### Logging a prompted medication

When the user taps "Log Dose" on a medication with `promptAnxietyOnLog == true`:

1. A **sheet** appears (`DoseAnxietyPromptView`) containing:
   - **PRN / Scheduled toggle** — checkmark indicating PRN (default true) vs timed schedule
   - **Anxiety severity slider** — 1-10, default 5 (matches existing `Constants.defaultSeverity`)
   - **Notes text field** — optional free-text for journal context
   - **"Log Dose" button** — inserts MedicationDose (with `isPRN`), inserts AnxietyEntry (linked to dose, `isFollowUp: false`), schedules 30-min notification, dismisses sheet
   - **"Skip" button** — inserts MedicationDose only (no anxiety entry, no follow-up timer), dismisses sheet
   - **Cancel (X)** — dismisses sheet, nothing logged

2. For medications with `promptAnxietyOnLog == false`: behavior unchanged — one-tap silent insert, no sheet.

### 30-minute follow-up

3. After 30 minutes, a **local notification** fires:
   - Title: "How's your anxiety?"
   - Body: "You took [medication name] 30 minutes ago"
   - Mirrors to paired Apple Watch automatically (haptic + visual) when phone is locked
   - Notification identifier: `"dose-followup-{doseID}"`

4. Tapping the notification opens the app and presents a follow-up sheet:
   - **Anxiety severity slider** — 1-10
   - **Notes text field** — optional
   - **"Log" button** — creates AnxietyEntry linked to the same dose with `isFollowUp: true`
   - **"Skip" / Cancel** — dismisses, no entry created
   - No PRN toggle (already captured on the initial prompt)

5. **Foreground fallback:** on `scenePhase` change to `.active`, check for pending follow-ups past their scheduled time. If found and no follow-up AnxietyEntry exists for that dose, present the sheet. Clean up stale entries after 2 hours.

## Notification Infrastructure

- Request `UNUserNotificationCenter` authorization on first prompted dose log (not at app launch)
- Schedule with `UNTimeIntervalNotificationTrigger(timeInterval: 1800, repeats: false)`
- Track pending follow-ups in UserDefaults: `[{doseID: UUID, medicationName: String, scheduledTime: Date}]`
- Remove pending entry when follow-up is completed, skipped, or stale (>2 hours)

## New Files

| File | Responsibility |
|------|---------------|
| `AnxietyWatch/Views/Medications/DoseAnxietyPromptView.swift` | Sheet with PRN toggle, severity slider, notes field, Log/Skip/Cancel |
| `AnxietyWatch/Utilities/DoseFollowUpManager.swift` | Notification scheduling, pending follow-up tracking (UserDefaults), foreground check, stale cleanup |

## Modified Files

| File | Change |
|------|--------|
| `AnxietyWatch/Models/MedicationDefinition.swift` | Add `promptAnxietyOnLog: Bool` |
| `AnxietyWatch/Models/MedicationDose.swift` | Add `isPRN: Bool` |
| `AnxietyWatch/Models/AnxietyEntry.swift` | Add `triggerDose: MedicationDose?`, `isFollowUp: Bool` |
| `AnxietyWatch/Views/Medications/AddMedicationView.swift` | Add toggle for `promptAnxietyOnLog`, default based on category |
| `AnxietyWatch/Views/Medications/MedicationsHubView.swift` | Change `logDose()` to present `DoseAnxietyPromptView` when `promptAnxietyOnLog` is true |
| `AnxietyWatch/Views/Medications/MedicationListView.swift` | Same change as MedicationsHubView |
| `AnxietyWatch/App/AnxietyWatchApp.swift` | Add `scenePhase` observer for foreground follow-up check, set `UNUserNotificationCenter.delegate` |

## Testing Strategy

- `DoseFollowUpManager`: unit tests for pending follow-up CRUD, stale cleanup logic, scheduling/cancellation
- Model changes: unit tests for AnxietyEntry ↔ MedicationDose relationship, `isFollowUp` pairing
- `promptAnxietyOnLog` defaults: test that "Benzodiazepine" and "Stimulant" categories default to true
- UI: manual testing on device — verify notification fires, Watch buzzes, foreground fallback works
