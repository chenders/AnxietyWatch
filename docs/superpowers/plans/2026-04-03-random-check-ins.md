# Random Mood Check-Ins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add random mood check-in notifications at configurable intervals during waking hours, with one-tap severity logging, to collect baseline data and reduce selection bias in the journal.

**Architecture:** A `RandomCheckInManager` (following the `DoseFollowUpManager` pattern) schedules local notifications at random times within waking hours. Tapping a notification opens a one-tap severity sheet on iPhone or QuickLogView on Watch. Entries are tagged with `source: "random_checkin"` for filtering in Trends.

**Tech Stack:** UserNotifications, SwiftData, WatchConnectivity, Swift Testing

**Spec:** `docs/superpowers/specs/2026-04-03-random-check-ins-design.md`

---

## File Structure

### New files
- `AnxietyWatch/Utilities/RandomCheckInManager.swift` — scheduling, state, UserDefaults persistence
- `AnxietyWatch/Views/Journal/RandomCheckInPromptView.swift` — one-tap severity sheet (iPhone)
- `AnxietyWatchTests/RandomCheckInManagerTests.swift` — unit tests

### Modified files
- `AnxietyWatch/Models/AnxietyEntry.swift` — add `source: String?` field
- `AnxietyWatch/App/AnxietyWatchApp.swift` — add foreground check for pending check-ins
- `AnxietyWatch/Views/Settings/SettingsView.swift` — add check-in settings section
- `AnxietyWatch/Views/Journal/JournalListView.swift` — add source indicator icon on `JournalEntryRow`
- `AnxietyWatch/Views/Trends/TrendsView.swift` — add source filter picker
- `AnxietyWatch Watch App/QuickLogView.swift` — read pending check-in flag, pass source
- `AnxietyWatch Watch App/WatchConnectivityManager.swift` — include source in entry message
- `AnxietyWatch/Services/PhoneConnectivityManager.swift` — read source from Watch message
- `AnxietyWatchTests/Helpers/ModelFactory.swift` — add source parameter

---

### Task 1: Add `source` field to AnxietyEntry

**Files:**
- Modify: `AnxietyWatch/Models/AnxietyEntry.swift`
- Modify: `AnxietyWatchTests/Helpers/ModelFactory.swift`

- [ ] **Step 1: Add source property to AnxietyEntry**

In `AnxietyWatch/Models/AnxietyEntry.swift`, add the property after `isFollowUp`:

```swift
    /// Origin of this entry: nil/"user" (manual), "dose_followup", or "random_checkin".
    /// Optional for migration — nil treated as "user" for historical entries.
    var source: String?
```

And add it to the init with a default:

```swift
    init(
        timestamp: Date = .now,
        severity: Int = 5,
        notes: String = "",
        tags: [String] = [],
        triggerDose: MedicationDose? = nil,
        isFollowUp: Bool = false,
        source: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.severity = severity
        self.notes = notes
        self.tags = tags
        self.isFollowUp = isFollowUp
        self.triggerDose = triggerDose
        self.source = source
    }
```

- [ ] **Step 2: Update ModelFactory**

In `AnxietyWatchTests/Helpers/ModelFactory.swift`, update the `anxietyEntry` factory:

```swift
    static func anxietyEntry(
        timestamp: Date = referenceDate,
        severity: Int = 5,
        notes: String = "",
        tags: [String] = [],
        triggerDose: MedicationDose? = nil,
        isFollowUp: Bool = false,
        source: String? = nil
    ) -> AnxietyEntry {
        AnxietyEntry(
            timestamp: timestamp,
            severity: severity,
            notes: notes,
            tags: tags,
            triggerDose: triggerDose,
            isFollowUp: isFollowUp,
            source: source
        )
    }
```

- [ ] **Step 3: Build and test**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Models/AnxietyEntry.swift AnxietyWatchTests/Helpers/ModelFactory.swift
git commit -m "feat: add source field to AnxietyEntry for check-in tracking

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Create RandomCheckInManager

**Files:**
- Create: `AnxietyWatch/Utilities/RandomCheckInManager.swift`
- Create: `AnxietyWatchTests/RandomCheckInManagerTests.swift`

- [ ] **Step 1: Create RandomCheckInManager**

```swift
// AnxietyWatch/Utilities/RandomCheckInManager.swift
import Foundation
import UserNotifications

/// Schedules random mood check-in notifications during waking hours.
/// Follows the same persistence pattern as DoseFollowUpManager.
enum RandomCheckInManager {

    // MARK: - Keys

    private static let enabledKey = "randomCheckIn_enabled"
    private static let frequencyKey = "randomCheckIn_frequencyPerDay"
    private static let quietStartKey = "randomCheckIn_quietHoursStart"
    private static let quietEndKey = "randomCheckIn_quietHoursEnd"
    private static let pendingKey = "randomCheckIn_pending"
    private static let staleThreshold: TimeInterval = 24 * 60 * 60 // 24 hours

    struct PendingCheckIn: Codable, Equatable {
        let notificationId: String
        let scheduledTime: Date
    }

    // MARK: - Settings

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var frequencyPerDay: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: frequencyKey)
            return v > 0 ? v : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: frequencyKey) }
    }

    static var quietHoursStart: Int {
        get {
            let v = UserDefaults.standard.object(forKey: quietStartKey) as? Int
            return v ?? 22
        }
        set { UserDefaults.standard.set(newValue, forKey: quietStartKey) }
    }

    static var quietHoursEnd: Int {
        get {
            let v = UserDefaults.standard.object(forKey: quietEndKey) as? Int
            return v ?? 8
        }
        set { UserDefaults.standard.set(newValue, forKey: quietEndKey) }
    }

    // MARK: - Notification Authorization

    static func ensureAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Scheduling

    /// Schedule the next random check-in notification. Picks a random time
    /// in the next available waking slot and schedules a local notification.
    static func scheduleNextCheckIn(from now: Date = .now) {
        guard isEnabled else { return }

        let targetTime = nextRandomTime(from: now)
        let delay = targetTime.timeIntervalSince(now)
        guard delay > 0 else { return }

        let id = "random-checkin-\(UUID().uuidString)"
        let pending = PendingCheckIn(notificationId: id, scheduledTime: targetTime)
        savePending(pending)

        let content = UNMutableNotificationContent()
        content.title = "How are you feeling?"
        content.body = "Quick check-in — tap to log"
        content.sound = .default
        content.categoryIdentifier = "RANDOM_CHECKIN"

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: delay,
            repeats: false
        )

        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)

        // Update Watch applicationContext so it knows a check-in is pending
        updateWatchContext(pending: true)
    }

    // MARK: - Foreground Check

    /// Returns true if a pending check-in is due (past scheduled time and not stale).
    static func pendingCheckInIfDue(now: Date = .now) -> Bool {
        guard let pending = loadPending() else { return false }
        return pending.scheduledTime <= now &&
               now.timeIntervalSince(pending.scheduledTime) < staleThreshold
    }

    /// Mark the check-in as completed and schedule the next one.
    static func completeCheckIn() {
        if let pending = loadPending() {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [pending.notificationId])
            center.removeDeliveredNotifications(withIdentifiers: [pending.notificationId])
        }
        clearPending()
        updateWatchContext(pending: false)
        scheduleNextCheckIn()
    }

    /// User dismissed the sheet without logging. Still schedule next.
    static func dismissCheckIn() {
        completeCheckIn()
    }

    /// Cancel all pending check-ins. Called when feature is disabled.
    static func cancelAll() {
        if let pending = loadPending() {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [pending.notificationId])
            center.removeDeliveredNotifications(withIdentifiers: [pending.notificationId])
        }
        clearPending()
        updateWatchContext(pending: false)
    }

    /// Remove check-ins older than 24 hours and reschedule.
    static func cleanupStale(now: Date = .now) {
        guard let pending = loadPending() else { return }
        if now.timeIntervalSince(pending.scheduledTime) >= staleThreshold {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [pending.notificationId])
            center.removeDeliveredNotifications(withIdentifiers: [pending.notificationId])
            clearPending()
            scheduleNextCheckIn(from: now)
        }
    }

    // MARK: - Randomization

    /// Compute the next random check-in time within the waking window.
    /// Visible for testing.
    static func nextRandomTime(
        from now: Date = .now,
        frequency: Int? = nil,
        quietStart: Int? = nil,
        quietEnd: Int? = nil
    ) -> Date {
        let calendar = Calendar.current
        let freq = frequency ?? frequencyPerDay
        let qStart = quietStart ?? quietHoursStart
        let qEnd = quietEnd ?? quietHoursEnd

        // Waking hours in minutes from midnight
        let wakeStart = qEnd * 60          // e.g., 8*60 = 480
        let wakeEnd = qStart * 60          // e.g., 22*60 = 1320
        let wakingMinutes = wakeEnd - wakeStart
        guard wakingMinutes > 0, freq > 0 else {
            // Fallback: schedule for tomorrow at wake time
            return calendar.date(byAdding: .day, value: 1,
                to: calendar.date(bySettingHour: qEnd, minute: 0, second: 0, of: now)!)!
        }

        let slotSize = wakingMinutes / freq
        let todayStart = calendar.startOfDay(for: now)
        let minutesSinceMidnight = calendar.dateComponents([.hour, .minute], from: now)
        let currentMinute = (minutesSinceMidnight.hour ?? 0) * 60 + (minutesSinceMidnight.minute ?? 0)

        // Find the next slot that hasn't passed yet
        for slot in 0..<freq {
            let slotStart = wakeStart + slot * slotSize
            let slotEnd = slotStart + slotSize

            if currentMinute < slotEnd {
                // This slot is still available
                let effectiveStart = max(slotStart, currentMinute + 1) // at least 1 minute from now
                let randomMinute = Int.random(in: effectiveStart..<slotEnd)
                return calendar.date(byAdding: .minute, value: randomMinute, to: todayStart)!
            }
        }

        // All slots passed today — schedule for first slot tomorrow
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let randomMinute = Int.random(in: wakeStart..<(wakeStart + slotSize))
        return calendar.date(byAdding: .minute, value: randomMinute, to: tomorrow)!
    }

    // MARK: - Persistence

    static func loadPending() -> PendingCheckIn? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(PendingCheckIn.self, from: data)
    }

    private static func savePending(_ pending: PendingCheckIn) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    private static func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    // MARK: - Watch Context

    private static func updateWatchContext(pending: Bool) {
        PhoneConnectivityManager.shared.updateCheckInContext(pending: pending)
    }
}
```

- [ ] **Step 2: Write RandomCheckInManagerTests**

```swift
// AnxietyWatchTests/RandomCheckInManagerTests.swift
import Foundation
import Testing

@testable import AnxietyWatch

@Suite(.serialized)
struct RandomCheckInManagerTests {

    private func clearState() {
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_pending")
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_enabled")
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_frequencyPerDay")
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_quietHoursStart")
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_quietHoursEnd")
    }

    // MARK: - Settings defaults

    @Test("Default frequency is 2")
    func defaultFrequency() {
        clearState()
        #expect(RandomCheckInManager.frequencyPerDay == 2)
    }

    @Test("Default quiet hours are 22-8")
    func defaultQuietHours() {
        clearState()
        #expect(RandomCheckInManager.quietHoursStart == 22)
        #expect(RandomCheckInManager.quietHoursEnd == 8)
    }

    @Test("Default is disabled")
    func defaultDisabled() {
        clearState()
        #expect(RandomCheckInManager.isEnabled == false)
    }

    // MARK: - Persistence

    @Test("Pending check-in round-trips through UserDefaults")
    func pendingPersistence() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")

        let loaded = RandomCheckInManager.loadPending()
        #expect(loaded != nil)
        #expect(loaded?.notificationId == "test-id")

        clearState()
    }

    @Test("loadPending returns nil when no pending check-in")
    func noPending() {
        clearState()
        #expect(RandomCheckInManager.loadPending() == nil)
    }

    // MARK: - pendingCheckInIfDue

    @Test("pendingCheckInIfDue returns false when nothing pending")
    func noPendingNotDue() {
        clearState()
        #expect(RandomCheckInManager.pendingCheckInIfDue() == false)
    }

    @Test("pendingCheckInIfDue returns false for future check-in")
    func futurePendingNotDue() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(3600)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")

        #expect(RandomCheckInManager.pendingCheckInIfDue() == false)

        clearState()
    }

    @Test("pendingCheckInIfDue returns true for past check-in within 24h")
    func pastPendingIsDue() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(-300) // 5 minutes ago
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")

        #expect(RandomCheckInManager.pendingCheckInIfDue() == true)

        clearState()
    }

    @Test("pendingCheckInIfDue returns false for stale check-in (>24h)")
    func stalePendingNotDue() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(-25 * 3600) // 25 hours ago
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")

        #expect(RandomCheckInManager.pendingCheckInIfDue() == false)

        clearState()
    }

    // MARK: - cleanupStale

    @Test("cleanupStale removes stale check-in")
    func staleCleanup() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(-25 * 3600)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")

        RandomCheckInManager.cleanupStale()

        #expect(RandomCheckInManager.loadPending() == nil)

        clearState()
    }

    @Test("cleanupStale keeps recent check-in")
    func recentNotCleaned() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(-300)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")

        RandomCheckInManager.cleanupStale()

        #expect(RandomCheckInManager.loadPending() != nil)

        clearState()
    }

    // MARK: - Randomization

    @Test("nextRandomTime returns a time within waking hours")
    func randomTimeInWakingHours() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
        let target = RandomCheckInManager.nextRandomTime(
            from: now, frequency: 2, quietStart: 22, quietEnd: 8
        )
        let hour = calendar.component(.hour, from: target)
        #expect(hour >= 8 && hour < 22, "Target hour \(hour) should be in waking window")
    }

    @Test("nextRandomTime after all slots returns tomorrow")
    func allSlotsPassed() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23))!
        let target = RandomCheckInManager.nextRandomTime(
            from: now, frequency: 2, quietStart: 22, quietEnd: 8
        )
        let dayComponent = calendar.component(.day, from: target)
        #expect(dayComponent == 16, "Should schedule for next day")
        let hour = calendar.component(.hour, from: target)
        #expect(hour >= 8 && hour < 15, "Should be in first slot (8-15)")
    }

    @Test("nextRandomTime is always in the future")
    func randomTimeInFuture() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        for _ in 0..<20 {
            let target = RandomCheckInManager.nextRandomTime(
                from: now, frequency: 2, quietStart: 22, quietEnd: 8
            )
            #expect(target > now, "Target should be after now")
        }
    }

    @Test("nextRandomTime with frequency 4 stays in waking window")
    func highFrequencyInWindow() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 8))!
        for _ in 0..<20 {
            let target = RandomCheckInManager.nextRandomTime(
                from: now, frequency: 4, quietStart: 22, quietEnd: 8
            )
            let hour = calendar.component(.hour, from: target)
            #expect(hour >= 8 && hour < 22, "Target hour \(hour) should be in waking window")
        }
    }
}
```

- [ ] **Step 3: Build and run tests**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests/RandomCheckInManagerTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

Note: The `updateWatchContext` call in `RandomCheckInManager` references `PhoneConnectivityManager.shared.updateCheckInContext(pending:)` which doesn't exist yet. This will cause a build error. To fix, add a stub method to `PhoneConnectivityManager` first:

In `AnxietyWatch/Services/PhoneConnectivityManager.swift`, add before the `// MARK: - WCSessionDelegate` line:

```swift
    // MARK: - Check-In Context

    /// Update Watch applicationContext with pending check-in state.
    func updateCheckInContext(pending: Bool) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled
        else { return }

        var context = (try? WCSession.default.receivedApplicationContext) ?? [:]
        context["pendingRandomCheckIn"] = pending
        try? WCSession.default.updateApplicationContext(context)
    }
```

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Utilities/RandomCheckInManager.swift AnxietyWatchTests/RandomCheckInManagerTests.swift AnxietyWatch/Services/PhoneConnectivityManager.swift
git commit -m "feat: add RandomCheckInManager with scheduling and tests

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Create RandomCheckInPromptView (iPhone)

**Files:**
- Create: `AnxietyWatch/Views/Journal/RandomCheckInPromptView.swift`
- Modify: `AnxietyWatch/App/AnxietyWatchApp.swift`

- [ ] **Step 1: Create RandomCheckInPromptView**

```swift
// AnxietyWatch/Views/Journal/RandomCheckInPromptView.swift
import SwiftUI
import SwiftData

/// One-tap severity sheet shown when a random check-in notification is due.
struct RandomCheckInPromptView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("How are you feeling?")
                    .font(.title2.bold())
                    .padding(.top, 24)

                Text("Tap a number to log")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                    ForEach(1...10, id: \.self) { level in
                        Button {
                            logEntry(severity: level)
                        } label: {
                            Text("\(level)")
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(Color.severity(level), in: .circle)
                        }
                    }
                }
                .padding(.horizontal, 24)

                HStack {
                    ForEach(["Calm", "Mild", "Moderate", "High", "Crisis"], id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        RandomCheckInManager.dismissCheckIn()
                        dismiss()
                    }
                }
            }
        }
    }

    private func logEntry(severity: Int) {
        let entry = AnxietyEntry(
            severity: severity,
            source: "random_checkin"
        )
        modelContext.insert(entry)
        try? modelContext.save()
        RandomCheckInManager.completeCheckIn()
        dismiss()
    }
}
```

- [ ] **Step 2: Wire into AnxietyWatchApp**

In `AnxietyWatch/App/AnxietyWatchApp.swift`:

Add a state variable after `followUpMedication`:

```swift
    @State private var showingRandomCheckIn = false
```

In the `.onChange(of: scenePhase)` block, add the check-in check after `checkPendingFollowUp()`:

```swift
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        checkPendingFollowUp()
                        checkPendingRandomCheckIn()
                    }
                }
```

Add the sheet after the existing `.sheet(item: $followUpMedication)`:

```swift
                .sheet(isPresented: $showingRandomCheckIn) {
                    RandomCheckInPromptView()
                }
```

In the `.task` block, add after `coord.scheduleBackgroundRefresh()`:

```swift
                    // Schedule random check-in if enabled and none pending
                    if RandomCheckInManager.isEnabled && RandomCheckInManager.loadPending() == nil {
                        RandomCheckInManager.ensureAuthorization()
                        RandomCheckInManager.scheduleNextCheckIn()
                    }
```

Add the new method after `checkPendingFollowUp()`:

```swift
    private func checkPendingRandomCheckIn() {
        RandomCheckInManager.cleanupStale()

        // Don't show if a dose follow-up is already being shown
        guard followUpMedication == nil else { return }
        guard RandomCheckInManager.pendingCheckInIfDue() else { return }

        showingRandomCheckIn = true
    }
```

- [ ] **Step 3: Build and run**

Run:
```bash
xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Views/Journal/RandomCheckInPromptView.swift AnxietyWatch/App/AnxietyWatchApp.swift
git commit -m "feat: add RandomCheckInPromptView and wire into app lifecycle

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Add Settings UI

**Files:**
- Modify: `AnxietyWatch/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Add check-in settings section**

In `AnxietyWatch/Views/Settings/SettingsView.swift`, add these state variables at the top of the struct:

```swift
    @State private var checkInsEnabled = RandomCheckInManager.isEnabled
    @State private var checkInFrequency = RandomCheckInManager.frequencyPerDay
    @State private var activeHoursStart = RandomCheckInManager.quietHoursEnd   // wake time
    @State private var activeHoursEnd = RandomCheckInManager.quietHoursStart   // sleep time
```

Add a new `Section` in the `Form` (after the existing sections, before the closing of Form):

```swift
                Section("Random Check-Ins") {
                    Toggle("Enable Check-Ins", isOn: $checkInsEnabled)
                        .onChange(of: checkInsEnabled) { _, newValue in
                            RandomCheckInManager.isEnabled = newValue
                            if newValue {
                                RandomCheckInManager.ensureAuthorization()
                                RandomCheckInManager.scheduleNextCheckIn()
                            } else {
                                RandomCheckInManager.cancelAll()
                            }
                        }

                    if checkInsEnabled {
                        Stepper("Times per day: \(checkInFrequency)", value: $checkInFrequency, in: 1...4)
                            .onChange(of: checkInFrequency) { _, newValue in
                                RandomCheckInManager.frequencyPerDay = newValue
                                RandomCheckInManager.cancelAll()
                                RandomCheckInManager.isEnabled = true
                                RandomCheckInManager.scheduleNextCheckIn()
                            }

                        HStack {
                            Text("Active hours")
                            Spacer()
                            Picker("Start", selection: $activeHoursStart) {
                                ForEach(5..<13, id: \.self) { hour in
                                    Text("\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")")
                                        .tag(hour)
                                }
                            }
                            .labelsHidden()
                            Text("–")
                            Picker("End", selection: $activeHoursEnd) {
                                ForEach(18..<24, id: \.self) { hour in
                                    Text("\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")")
                                        .tag(hour)
                                }
                            }
                            .labelsHidden()
                        }
                        .onChange(of: activeHoursStart) { _, newValue in
                            RandomCheckInManager.quietHoursEnd = newValue
                            RandomCheckInManager.cancelAll()
                            RandomCheckInManager.isEnabled = true
                            RandomCheckInManager.scheduleNextCheckIn()
                        }
                        .onChange(of: activeHoursEnd) { _, newValue in
                            RandomCheckInManager.quietHoursStart = newValue
                            RandomCheckInManager.cancelAll()
                            RandomCheckInManager.isEnabled = true
                            RandomCheckInManager.scheduleNextCheckIn()
                        }

                        Text("You'll get \(checkInFrequency) random check-in\(checkInFrequency == 1 ? "" : "s") between \(activeHoursStart % 12 == 0 ? 12 : activeHoursStart % 12) \(activeHoursStart < 12 ? "AM" : "PM") and \(activeHoursEnd % 12 == 0 ? 12 : activeHoursEnd % 12) \(activeHoursEnd < 12 ? "AM" : "PM").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
```

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Views/Settings/SettingsView.swift
git commit -m "feat: add random check-in settings UI

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Journal indicator and Trends filter

**Files:**
- Modify: `AnxietyWatch/Views/Journal/JournalListView.swift`
- Modify: `AnxietyWatch/Views/Trends/TrendsView.swift`

- [ ] **Step 1: Add check-in indicator to JournalEntryRow**

In `AnxietyWatch/Views/Journal/JournalListView.swift`, update `JournalEntryRow.body`:

```swift
struct JournalEntryRow: View {
    let entry: AnxietyEntry

    var body: some View {
        HStack(spacing: 12) {
            SeverityBadge(severity: entry.severity)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline.bold())
                    if entry.source == "random_checkin" {
                        Image(systemName: "bell.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.notes.isEmpty {
                    Text(entry.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !entry.tags.isEmpty {
                    Text(entry.tags.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add source filter to TrendsView**

In `AnxietyWatch/Views/Trends/TrendsView.swift`, add an enum and state variable at the top of the struct (after `pageOffset`):

```swift
    @State private var sourceFilter: SourceFilter = .all

    enum SourceFilter: String, CaseIterable {
        case all = "All"
        case selfReported = "Self-Reported"
        case checkIns = "Check-Ins"
    }
```

Add a filter function:

```swift
    private func filterBySource(_ entries: [AnxietyEntry]) -> [AnxietyEntry] {
        switch sourceFilter {
        case .all: return entries
        case .selfReported: return entries.filter { $0.source == nil || $0.source == "user" || $0.source == "dose_followup" }
        case .checkIns: return entries.filter { $0.source == "random_checkin" }
        }
    }
```

In the body, add a picker after the time range picker (after the `.onChange(of: timeRange)` line):

```swift
                    Picker("Source", selection: $sourceFilter) {
                        ForEach(SourceFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
```

And update the entries filtering line to apply the source filter:

```swift
        let entries = filterBySource(allEntries.filter { inWindow($0.timestamp, start: ws.start, end: ws.end) })
```

- [ ] **Step 3: Build and run full tests**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Views/Journal/JournalListView.swift AnxietyWatch/Views/Trends/TrendsView.swift
git commit -m "feat: add check-in indicator in journal and source filter in trends

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Watch integration

**Files:**
- Modify: `AnxietyWatch Watch App/WatchConnectivityManager.swift`
- Modify: `AnxietyWatch Watch App/QuickLogView.swift`
- Modify: `AnxietyWatch/Services/PhoneConnectivityManager.swift`

- [ ] **Step 1: Add pendingRandomCheckIn to WatchConnectivityManager**

In `AnxietyWatch Watch App/WatchConnectivityManager.swift`, add a property after `lastSyncStatus`:

```swift
    var pendingRandomCheckIn = false
```

Update `loadContext()` to read the flag:

```swift
    private func loadContext() {
        let ctx = WCSession.default.receivedApplicationContext
        lastAnxiety = ctx["lastAnxiety"] as? Int
        hrvAvg = ctx["hrvAvg"] as? Double
        restingHR = ctx["restingHR"] as? Double
        pendingRandomCheckIn = ctx["pendingRandomCheckIn"] as? Bool ?? false
        pushToWidget()
    }
```

Update `session(_:didReceiveApplicationContext:)` to read the flag:

```swift
    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            self.lastAnxiety = applicationContext["lastAnxiety"] as? Int
            self.hrvAvg = applicationContext["hrvAvg"] as? Double
            self.restingHR = applicationContext["restingHR"] as? Double
            self.pendingRandomCheckIn = applicationContext["pendingRandomCheckIn"] as? Bool ?? false
            self.pushToWidget()
        }
    }
```

Add source to `sendAnxietyEntry`:

```swift
    func sendAnxietyEntry(severity: Int, notes: String = "", source: String? = nil) {
        var message: [String: Any] = [
            "type": "anxietyEntry",
            "severity": severity,
            "timestamp": Date().timeIntervalSince1970,
            "notes": notes,
        ]
        if let source {
            message["source"] = source
        }

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { [weak self] _ in
                WCSession.default.transferUserInfo(message)
                Task { @MainActor in
                    self?.lastSyncStatus = "Queued"
                }
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }
```

- [ ] **Step 2: Update QuickLogView to pass source**

In `AnxietyWatch Watch App/QuickLogView.swift`, update the button action:

```swift
                        Button {
                            selectedSeverity = level
                            let source: String? = connectivity.pendingRandomCheckIn ? "random_checkin" : nil
                            connectivity.sendAnxietyEntry(severity: level, source: source)
                            if connectivity.pendingRandomCheckIn {
                                connectivity.pendingRandomCheckIn = false
                            }
                            WKInterfaceDevice.current().play(.success)
                            showingConfirmation = true
                        } label: {
```

- [ ] **Step 3: Update PhoneConnectivityManager to read source**

In `AnxietyWatch/Services/PhoneConnectivityManager.swift`, update `handleIncoming`:

```swift
    nonisolated private func handleIncoming(_ message: [String: Any]) {
        guard message["type"] as? String == "anxietyEntry",
              let severity = message["severity"] as? Int,
              let ts = message["timestamp"] as? TimeInterval,
              let container = modelContainer
        else { return }

        let notes = message["notes"] as? String ?? ""
        let source = message["source"] as? String
        let timestamp = Date(timeIntervalSince1970: ts)

        Task { @MainActor in
            let context = ModelContext(container)
            let entry = AnxietyEntry(timestamp: timestamp, severity: severity, notes: notes, source: source)
            context.insert(entry)
            try? context.save()

            // If this was a check-in from the Watch, complete it on the iPhone side
            if source == "random_checkin" {
                RandomCheckInManager.completeCheckIn()
            }
        }
    }
```

Also update `sendStatsToWatch` to preserve the check-in context:

```swift
    func sendStatsToWatch(lastAnxiety: Int?, hrvAvg: Double?, restingHR: Double?) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled
        else { return }

        var context: [String: Any] = [:]
        if let v = lastAnxiety { context["lastAnxiety"] = v }
        if let v = hrvAvg { context["hrvAvg"] = v }
        if let v = restingHR { context["restingHR"] = v }

        // Preserve pending check-in state
        if let pending = RandomCheckInManager.loadPending() {
            context["pendingRandomCheckIn"] = pending.scheduledTime <= Date.now
        }

        try? WCSession.default.updateApplicationContext(context)
    }
```

- [ ] **Step 4: Build both targets**

Run:
```bash
xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -3
xcodebuild build -scheme "AnxietyWatch Watch App" -destination 'generic/platform=watchOS Simulator' 2>&1 | tail -3
```
Expected: Both `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add "AnxietyWatch Watch App/WatchConnectivityManager.swift" "AnxietyWatch Watch App/QuickLogView.swift" AnxietyWatch/Services/PhoneConnectivityManager.swift
git commit -m "feat: add Watch integration for random check-ins

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Final verification and PR

- [ ] **Step 1: Run full unit test suite**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Push and create PR**

```bash
git push -u origin feature/random-check-ins
```

Create PR targeting `main` with title: "feat: random mood check-ins with configurable scheduling"
