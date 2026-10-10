# Random Mood Check-Ins

**Date:** 2026-04-03
**Status:** Approved

## Problem

The journal data has selection bias — entries are only logged when the user feels anxious, making it look like they're anxious all the time. There's no baseline record of calm or neutral states. Without prompted check-ins at random times, the data can't distinguish "usually anxious" from "only logs when anxious."

## Solution

Schedule local notifications at random times during waking hours that prompt a one-tap severity rating. Entries are tagged with their source so Trends can separate prompted baselines from self-initiated spikes.

This feature also lays the groundwork for a future "smart prompting" feature where the app detects physiological patterns (elevated HR, low HRV) and prompts the user to confirm or deny its prediction, building a personalized correlation model over time.

## Data Model

Add a `source` field to `AnxietyEntry`:

```swift
/// Origin of this entry: nil/"user" (manual), "dose_followup", or "random_checkin"
var source: String?
```

Optional for migration — existing entries get `nil`, treated as `"user"`. Values:
- `nil` / `"user"` — self-initiated from journal or Watch
- `"dose_followup"` — from the existing medication dose prompt
- `"random_checkin"` — from a random check-in notification

## RandomCheckInManager

New `enum RandomCheckInManager` in `AnxietyWatch/Utilities/`, following the `DoseFollowUpManager` pattern.

### Settings (UserDefaults)

- `isEnabled: Bool` — default `false`
- `frequencyPerDay: Int` — default `2`, range 1-4
- `quietHoursStart: Int` — hour (0-23), default `22` (10 PM)
- `quietHoursEnd: Int` — hour (0-23), default `8` (8 AM)

### State (UserDefaults, Codable)

```swift
struct PendingCheckIn: Codable {
    let notificationId: String
    let scheduledTime: Date
}
```

Stored as a single optional pending check-in. Only one check-in is pending at a time — after it fires (or is dismissed/stale), the next one is scheduled.

### Methods

- `scheduleNextCheckIn()` — picks a random time within the next waking window, schedules a `UNTimeIntervalNotificationTrigger`, stores the pending check-in. Called after each check-in is completed or dismissed, and on app launch if enabled with no pending check-in.
- `pendingCheckInIfDue() -> Bool` — called on app foreground. Returns true if there's a pending check-in whose scheduled time has passed.
- `completeCheckIn()` — clears the pending check-in, schedules the next one.
- `dismissCheckIn()` — same as complete (user swiped away the sheet). Still schedules the next one.
- `cancelAll()` — removes pending notifications and clears state. Called when user disables the feature.
- `cleanupStale()` — removes check-ins older than 24 hours. Reschedules.

### Randomization Logic

Divide the waking window (e.g., 8 AM - 10 PM = 14 hours) by frequency (e.g., 2), giving time slots of 7 hours each. Pick a random minute within the next upcoming slot. After it fires, schedule the next slot.

Example with frequency=2, quiet hours 10 PM - 8 AM:
- Slot 1: 8:00 AM - 3:00 PM → random time picked, e.g., 10:47 AM
- Slot 2: 3:00 PM - 10:00 PM → random time picked, e.g., 6:23 PM

If the current time is past all slots for today, schedule for the first slot tomorrow.

### DND Handling

No special code needed. The system suppresses notification delivery when Focus/DND is active. We schedule normally. If the notification is suppressed, it becomes stale and `cleanupStale()` reschedules on next app launch.

## Notification

```swift
let content = UNMutableNotificationContent()
content.title = "How are you feeling?"
content.body = "Quick check-in — tap to log"
content.sound = .default
content.categoryIdentifier = "RANDOM_CHECKIN"
```

Scheduled via `UNTimeIntervalNotificationTrigger` with the computed delay from now until the random target time.

## UI

### iPhone: Check-in prompt sheet

Presented on app foreground when `pendingCheckInIfDue()` returns true. Matches the dose follow-up pattern:
- Title: "How are you feeling?"
- 1-10 severity grid (same component as `AddJournalEntryView` / dose prompt)
- Tapping a number saves an `AnxietyEntry` with `source: "random_checkin"` and dismisses
- No notes field — one tap only

If both a dose follow-up and a random check-in are pending, dose follow-up takes priority (time-sensitive medication tracking).

### Watch: QuickLogView modification

When a check-in notification arrives on the Watch (automatic when iPhone is locked), tapping it opens the Watch app. The flow:

1. iPhone sets `applicationContext["pendingRandomCheckIn": true]` via WatchConnectivity when a check-in notification is scheduled
2. iPhone clears it when the check-in is completed on iPhone
3. Watch's `QuickLogView` checks this flag on appear
4. If set, entries created from QuickLogView get `source: "random_checkin"` sent in the WatchConnectivity message
5. iPhone's `PhoneConnectivityManager` reads the source field and applies it to the created `AnxietyEntry`
6. After the Watch entry is sent, the Watch clears the flag locally

If the user opens QuickLogView manually (not from a notification), the flag may still be set. This is acceptable — the timing window is small, and a slightly over-tagged entry is better than missing the tag.

### Journal list indicator

Entries with `source == "random_checkin"` show a small icon (e.g., SF Symbol `bell.fill` or `clock.fill`) next to the severity circle in `JournalListView`. Subtle, not prominent.

### Trends filtering

A picker in `TrendsView` with three options:
- **All** — every entry (default)
- **Self-reported** — `source == nil` or `source == "user"`
- **Check-ins** — `source == "random_checkin"`

Filters the `AnxietyEntry` array before passing to chart views. The "dose_followup" entries are included in "Self-reported" since they're user-initiated (the dose was intentional).

### Settings

New section in `SettingsView` titled "Random Check-Ins":
- **Toggle:** "Enable Check-Ins" — enables/disables. Toggling off calls `cancelAll()`.
- **Stepper:** "Times per day" — range 1-4, default 2. Only shown when enabled.
- **Time pickers:** "Active hours: Start / End" — default 8:00 AM / 10:00 PM. Only shown when enabled.

Changing any setting while enabled calls `cancelAll()` then `scheduleNextCheckIn()` to apply immediately.

## Files

### New
- `AnxietyWatch/Utilities/RandomCheckInManager.swift` — scheduling, state, UserDefaults persistence
- `AnxietyWatch/Views/Journal/RandomCheckInPromptView.swift` — one-tap severity sheet
- `AnxietyWatchTests/RandomCheckInManagerTests.swift` — unit tests for scheduling logic, randomization, stale cleanup

### Modified
- `AnxietyWatch/Models/AnxietyEntry.swift` — add `source: String?` field
- `AnxietyWatch/App/AnxietyWatchApp.swift` — add foreground check for pending check-ins
- `AnxietyWatch/Views/Settings/SettingsView.swift` — add check-in settings section
- `AnxietyWatch/Views/Journal/JournalListView.swift` — add source indicator icon
- `AnxietyWatch/Views/Trends/TrendsView.swift` — add source filter picker
- `AnxietyWatch Watch App/QuickLogView.swift` — read pendingRandomCheckIn flag, pass source
- `AnxietyWatch Watch App/WatchConnectivityManager.swift` — include source in entry message
- `AnxietyWatch/Services/PhoneConnectivityManager.swift` — read source from Watch message
- `AnxietyWatchTests/Helpers/ModelFactory.swift` — add source parameter to `anxietyEntry()`

## Out of Scope

- Smart prompting (physiological-triggered check-ins) — future feature that builds on this data
- Watch-initiated scheduling (Watch doesn't schedule its own notifications)
- Rich notification actions (inline severity buttons on the notification itself)
- Notes field on the check-in prompt
