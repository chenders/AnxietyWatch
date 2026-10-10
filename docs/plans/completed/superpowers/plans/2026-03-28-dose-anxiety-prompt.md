# Dose-Triggered Anxiety Prompt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When logging a benzo or stimulant dose, prompt for anxiety rating with PRN/scheduled toggle, then follow up via local notification 30 minutes later.

**Architecture:** Three model field additions (no new models), a `DoseFollowUpManager` utility for notification scheduling and pending follow-up tracking, a `DoseAnxietyPromptView` sheet, and foreground-check wiring in the app delegate. Local notifications mirror to Apple Watch automatically.

**Tech Stack:** Swift/SwiftUI, SwiftData, UserNotifications

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `AnxietyWatch/Utilities/DoseFollowUpManager.swift` | Schedule/cancel local notifications, track pending follow-ups in UserDefaults, stale cleanup |
| `AnxietyWatch/Views/Medications/DoseAnxietyPromptView.swift` | Sheet with PRN toggle, severity slider, notes field, Log/Skip/Cancel actions |
| `AnxietyWatchTests/DoseFollowUpManagerTests.swift` | Unit tests for pending follow-up CRUD and stale cleanup |

### Modified Files

| File | Changes |
|------|---------|
| `AnxietyWatch/Models/MedicationDefinition.swift` | Add `promptAnxietyOnLog: Bool` field |
| `AnxietyWatch/Models/MedicationDose.swift` | Add `isPRN: Bool` field |
| `AnxietyWatch/Models/AnxietyEntry.swift` | Add `triggerDose: MedicationDose?` relationship, `isFollowUp: Bool` field |
| `AnxietyWatch/Views/Medications/AddMedicationView.swift` | Add "Stimulant" category, add `promptAnxietyOnLog` toggle with category-based default |
| `AnxietyWatch/Views/Medications/MedicationsHubView.swift` | Present `DoseAnxietyPromptView` sheet when `promptAnxietyOnLog` is true |
| `AnxietyWatch/Views/Medications/MedicationListView.swift` | Same change as MedicationsHubView |
| `AnxietyWatch/App/AnxietyWatchApp.swift` | Add `scenePhase` observer for foreground follow-up check, set notification delegate |

---

### Task 1: Model Changes

**Files:**
- Modify: `AnxietyWatch/Models/MedicationDefinition.swift`
- Modify: `AnxietyWatch/Models/MedicationDose.swift`
- Modify: `AnxietyWatch/Models/AnxietyEntry.swift`

- [ ] **Step 1: Add `promptAnxietyOnLog` to MedicationDefinition**

In `AnxietyWatch/Models/MedicationDefinition.swift`, add the field after `isActive` (line 11) and update the init:

```swift
import Foundation
import SwiftData

@Model
final class MedicationDefinition {
    var id: UUID
    var name: String
    var defaultDoseMg: Double
    /// e.g. "benzodiazepine", "SSRI", "supplement"
    var category: String
    var isActive: Bool
    /// When true, logging a dose opens an anxiety rating prompt + schedules a 30-min follow-up
    var promptAnxietyOnLog: Bool
    @Relationship(deleteRule: .nullify, inverse: \MedicationDose.medication)
    var doses: [MedicationDose]
    @Relationship(deleteRule: .nullify, inverse: \Prescription.medication)
    var prescriptions: [Prescription]

    init(
        name: String,
        defaultDoseMg: Double,
        category: String = "",
        isActive: Bool = true,
        promptAnxietyOnLog: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.defaultDoseMg = defaultDoseMg
        self.category = category
        self.isActive = isActive
        self.promptAnxietyOnLog = promptAnxietyOnLog
        self.doses = []
        self.prescriptions = []
    }
}
```

- [ ] **Step 2: Add `isPRN` to MedicationDose**

Replace the full file `AnxietyWatch/Models/MedicationDose.swift`:

```swift
import Foundation
import SwiftData

@Model
final class MedicationDose {
    var id: UUID
    var timestamp: Date
    /// Denormalized — preserves the name even if the definition is later deleted
    var medicationName: String
    var doseMg: Double
    var notes: String?
    /// True if taken as-needed (PRN), false if on a timed schedule
    var isPRN: Bool
    var medication: MedicationDefinition?

    init(
        timestamp: Date = .now,
        medicationName: String,
        doseMg: Double,
        notes: String? = nil,
        isPRN: Bool = true,
        medication: MedicationDefinition? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.notes = notes
        self.isPRN = isPRN
        self.medication = medication
    }
}
```

- [ ] **Step 3: Add `triggerDose` and `isFollowUp` to AnxietyEntry**

Replace the full file `AnxietyWatch/Models/AnxietyEntry.swift`:

```swift
import Foundation
import SwiftData

@Model
final class AnxietyEntry {
    var id: UUID
    var timestamp: Date
    /// Subjective anxiety severity, 1 (minimal) to 10 (severe)
    var severity: Int
    var notes: String
    /// Freeform tags for categorization (e.g. "work", "social", "trigger:caffeine")
    var tags: [String]
    var locationLatitude: Double?
    var locationLongitude: Double?
    /// The medication dose that triggered this anxiety entry (nil for manual entries)
    var triggerDose: MedicationDose?
    /// True if this is a 30-minute follow-up entry (vs the initial at-dosing entry)
    var isFollowUp: Bool

    init(
        timestamp: Date = .now,
        severity: Int = 5,
        notes: String = "",
        tags: [String] = [],
        triggerDose: MedicationDose? = nil,
        isFollowUp: Bool = false
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.severity = severity
        self.notes = notes
        self.tags = tags
        self.isFollowUp = isFollowUp
        self.triggerDose = triggerDose
    }
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Models/MedicationDefinition.swift AnxietyWatch/Models/MedicationDose.swift AnxietyWatch/Models/AnxietyEntry.swift
git commit -m "feat: add promptAnxietyOnLog, isPRN, and triggerDose model fields"
```

---

### Task 2: DoseFollowUpManager + Tests

**Files:**
- Create: `AnxietyWatch/Utilities/DoseFollowUpManager.swift`
- Create: `AnxietyWatchTests/DoseFollowUpManagerTests.swift`

- [ ] **Step 1: Create DoseFollowUpManager**

Create `AnxietyWatch/Utilities/DoseFollowUpManager.swift`:

```swift
import Foundation
import UserNotifications

/// Manages 30-minute follow-up notifications after dose-triggered anxiety entries.
/// Tracks pending follow-ups in UserDefaults so they survive app termination.
enum DoseFollowUpManager {

    private static let pendingKey = "pendingDoseFollowUps"
    static let followUpDelay: TimeInterval = 30 * 60 // 30 minutes
    private static let staleThreshold: TimeInterval = 2 * 60 * 60 // 2 hours

    struct PendingFollowUp: Codable, Equatable {
        let doseID: UUID
        let medicationName: String
        let scheduledTime: Date
    }

    // MARK: - Notification Authorization

    /// Request notification permission if not already granted.
    /// Call this the first time a prompted dose is logged.
    static func ensureAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Schedule / Cancel

    /// Schedule a 30-minute follow-up notification for a dose.
    static func scheduleFollowUp(doseID: UUID, medicationName: String) {
        let scheduledTime = Date.now.addingTimeInterval(followUpDelay)

        // Save to UserDefaults
        var pending = loadPending()
        pending.append(PendingFollowUp(
            doseID: doseID,
            medicationName: medicationName,
            scheduledTime: scheduledTime
        ))
        savePending(pending)

        // Schedule local notification
        let content = UNMutableNotificationContent()
        content.title = "How's your anxiety?"
        content.body = "You took \(medicationName) 30 minutes ago"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: followUpDelay,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: notificationID(for: doseID),
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Cancel a pending follow-up (e.g., if the dose is deleted).
    static func cancelFollowUp(doseID: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID(for: doseID)])
        var pending = loadPending()
        pending.removeAll { $0.doseID == doseID }
        savePending(pending)
    }

    // MARK: - Foreground Check

    /// Returns the first pending follow-up that is due (past scheduled time)
    /// and not yet stale (within 2 hours). Call on app foreground.
    static func pendingFollowUpIfDue() -> PendingFollowUp? {
        let now = Date.now
        let pending = loadPending()
        return pending.first { followUp in
            followUp.scheduledTime <= now &&
            now.timeIntervalSince(followUp.scheduledTime) < staleThreshold
        }
    }

    /// Mark a follow-up as completed or dismissed. Removes it from pending.
    static func completeFollowUp(doseID: UUID) {
        var pending = loadPending()
        pending.removeAll { $0.doseID == doseID }
        savePending(pending)
    }

    /// Remove follow-ups older than 2 hours. Call on app foreground.
    static func cleanupStale() {
        let now = Date.now
        var pending = loadPending()
        pending.removeAll { now.timeIntervalSince($0.scheduledTime) >= staleThreshold }
        savePending(pending)
    }

    // MARK: - Persistence

    static func loadPending() -> [PendingFollowUp] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([PendingFollowUp].self, from: data)) ?? []
    }

    private static func savePending(_ pending: [PendingFollowUp]) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    static func notificationID(for doseID: UUID) -> String {
        "dose-followup-\(doseID.uuidString)"
    }
}
```

- [ ] **Step 2: Create tests**

Create `AnxietyWatchTests/DoseFollowUpManagerTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

struct DoseFollowUpManagerTests {

    /// Clear pending follow-ups before each test.
    private func clearPending() {
        UserDefaults.standard.removeObject(forKey: "pendingDoseFollowUps")
    }

    @Test("Schedule adds a pending follow-up")
    func scheduleAddsPending() {
        clearPending()
        let doseID = UUID()
        DoseFollowUpManager.scheduleFollowUp(doseID: doseID, medicationName: "Clonazepam")

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.count == 1)
        #expect(pending[0].doseID == doseID)
        #expect(pending[0].medicationName == "Clonazepam")

        // Cleanup
        DoseFollowUpManager.cancelFollowUp(doseID: doseID)
    }

    @Test("Cancel removes the pending follow-up")
    func cancelRemovesPending() {
        clearPending()
        let doseID = UUID()
        DoseFollowUpManager.scheduleFollowUp(doseID: doseID, medicationName: "Adderall")

        DoseFollowUpManager.cancelFollowUp(doseID: doseID)

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.isEmpty)
    }

    @Test("Complete removes the pending follow-up")
    func completeRemovesPending() {
        clearPending()
        let doseID = UUID()
        DoseFollowUpManager.scheduleFollowUp(doseID: doseID, medicationName: "Clonazepam")

        DoseFollowUpManager.completeFollowUp(doseID: doseID)

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.isEmpty)
    }

    @Test("pendingFollowUpIfDue returns nil when nothing is scheduled")
    func noPendingReturnsNil() {
        clearPending()
        #expect(DoseFollowUpManager.pendingFollowUpIfDue() == nil)
    }

    @Test("pendingFollowUpIfDue returns nil for future follow-ups")
    func futureFollowUpReturnsNil() {
        clearPending()
        // Manually insert a follow-up scheduled 30 min from now
        let followUp = DoseFollowUpManager.PendingFollowUp(
            doseID: UUID(),
            medicationName: "Clonazepam",
            scheduledTime: Date.now.addingTimeInterval(1800)
        )
        let data = try! JSONEncoder().encode([followUp])
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        #expect(DoseFollowUpManager.pendingFollowUpIfDue() == nil)

        clearPending()
    }

    @Test("pendingFollowUpIfDue returns due follow-up")
    func dueFollowUpReturned() {
        clearPending()
        let doseID = UUID()
        // Manually insert a follow-up that was due 5 minutes ago
        let followUp = DoseFollowUpManager.PendingFollowUp(
            doseID: doseID,
            medicationName: "Adderall",
            scheduledTime: Date.now.addingTimeInterval(-300)
        )
        let data = try! JSONEncoder().encode([followUp])
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        let result = DoseFollowUpManager.pendingFollowUpIfDue()
        #expect(result != nil)
        #expect(result?.doseID == doseID)

        clearPending()
    }

    @Test("cleanupStale removes old follow-ups")
    func staleCleanup() {
        clearPending()
        // Insert one stale (3 hours ago) and one recent (5 min ago)
        let stale = DoseFollowUpManager.PendingFollowUp(
            doseID: UUID(),
            medicationName: "Old",
            scheduledTime: Date.now.addingTimeInterval(-3 * 3600)
        )
        let recent = DoseFollowUpManager.PendingFollowUp(
            doseID: UUID(),
            medicationName: "Recent",
            scheduledTime: Date.now.addingTimeInterval(-300)
        )
        let data = try! JSONEncoder().encode([stale, recent])
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        DoseFollowUpManager.cleanupStale()

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.count == 1)
        #expect(pending[0].medicationName == "Recent")

        clearPending()
    }

    @Test("Notification ID is deterministic for a dose")
    func notificationIDDeterministic() {
        let doseID = UUID()
        let id1 = DoseFollowUpManager.notificationID(for: doseID)
        let id2 = DoseFollowUpManager.notificationID(for: doseID)
        #expect(id1 == id2)
        #expect(id1.contains(doseID.uuidString))
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Utilities/DoseFollowUpManager.swift AnxietyWatchTests/DoseFollowUpManagerTests.swift
git commit -m "feat: add DoseFollowUpManager for follow-up notification scheduling"
```

---

### Task 3: DoseAnxietyPromptView

**Files:**
- Create: `AnxietyWatch/Views/Medications/DoseAnxietyPromptView.swift`

- [ ] **Step 1: Create the prompt sheet view**

Create `AnxietyWatch/Views/Medications/DoseAnxietyPromptView.swift`:

```swift
import SwiftUI
import SwiftData

/// Sheet presented when logging a dose for a medication with `promptAnxietyOnLog`.
/// Captures anxiety severity, optional notes, and PRN/scheduled status.
/// Also used for the 30-minute follow-up (with `isFollowUp: true`).
struct DoseAnxietyPromptView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let medication: MedicationDefinition
    /// If non-nil, this is a follow-up for an existing dose (no PRN toggle, no dose creation).
    let existingDose: MedicationDose?

    @State private var severity: Double = 5
    @State private var notes = ""
    @State private var isPRN = true

    private var isFollowUp: Bool { existingDose != nil }

    var body: some View {
        NavigationStack {
            Form {
                if !isFollowUp {
                    Section {
                        Toggle("Taken as needed (PRN)", isOn: $isPRN)
                    } footer: {
                        Text(isPRN ? "As-needed / situational use" : "Scheduled / routine dose")
                    }
                }

                Section("Anxiety Level") {
                    VStack(spacing: 8) {
                        Text("\(Int(severity))")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(severityColor)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: Int(severity))

                        Slider(value: $severity, in: 1...10, step: 1)
                            .tint(severityColor)

                        HStack {
                            Text("Minimal").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("Severe").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Notes (optional)") {
                    TextField("How are you feeling?", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(isFollowUp ? "30-Min Follow-Up" : "Log \(medication.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isFollowUp ? "Log" : "Log Dose") {
                        save()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !isFollowUp {
                    Button("Skip — just log the dose") {
                        skipAndLogDose()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Actions

    private func save() {
        let dose: MedicationDose
        if let existingDose {
            dose = existingDose
        } else {
            dose = MedicationDose(
                medicationName: medication.name,
                doseMg: medication.defaultDoseMg,
                isPRN: isPRN,
                medication: medication
            )
            modelContext.insert(dose)
        }

        let entry = AnxietyEntry(
            severity: Int(severity),
            notes: notes,
            triggerDose: dose,
            isFollowUp: isFollowUp
        )
        modelContext.insert(entry)

        if !isFollowUp {
            // Schedule 30-min follow-up notification
            DoseFollowUpManager.ensureAuthorization()
            DoseFollowUpManager.scheduleFollowUp(
                doseID: dose.id,
                medicationName: medication.name
            )
        } else {
            // Mark follow-up as completed
            DoseFollowUpManager.completeFollowUp(doseID: dose.id)
        }

        dismiss()
    }

    private func skipAndLogDose() {
        let dose = MedicationDose(
            medicationName: medication.name,
            doseMg: medication.defaultDoseMg,
            isPRN: isPRN,
            medication: medication
        )
        modelContext.insert(dose)
        dismiss()
    }

    private var severityColor: Color {
        switch Int(severity) {
        case 1...3: .green
        case 4...6: .yellow
        case 7...8: .orange
        default: .red
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Views/Medications/DoseAnxietyPromptView.swift
git commit -m "feat: add DoseAnxietyPromptView for dose-triggered anxiety rating"
```

---

### Task 4: Wire Up MedicationsHubView and MedicationListView

**Files:**
- Modify: `AnxietyWatch/Views/Medications/MedicationsHubView.swift`
- Modify: `AnxietyWatch/Views/Medications/MedicationListView.swift`

- [ ] **Step 1: Update MedicationsHubView**

In `AnxietyWatch/Views/Medications/MedicationsHubView.swift`:

Add state for the sheet after the existing `@State` (after line 20):

```swift
    @State private var promptMedication: MedicationDefinition?
```

Replace the `logDose(for:)` method (lines 185-192) with:

```swift
    private func logDose(for med: MedicationDefinition) {
        if med.promptAnxietyOnLog {
            promptMedication = med
        } else {
            let dose = MedicationDose(
                medicationName: med.name,
                doseMg: med.defaultDoseMg,
                medication: med
            )
            modelContext.insert(dose)
        }
    }
```

Add a `.sheet` modifier to the `NavigationStack` (after the existing `.sheet(isPresented: $showingAddMed)` block, after line 43):

```swift
            .sheet(item: $promptMedication) { med in
                DoseAnxietyPromptView(medication: med, existingDose: nil)
            }
```

- [ ] **Step 2: Update MedicationListView**

In `AnxietyWatch/Views/Medications/MedicationListView.swift`:

Add state after existing `@State` (after line 18):

```swift
    @State private var promptMedication: MedicationDefinition?
```

Replace the `logDose(for:)` method (lines 112-119) with:

```swift
    private func logDose(for med: MedicationDefinition) {
        if med.promptAnxietyOnLog {
            promptMedication = med
        } else {
            let dose = MedicationDose(
                medicationName: med.name,
                doseMg: med.defaultDoseMg,
                medication: med
            )
            modelContext.insert(dose)
        }
    }
```

Add a `.sheet` modifier to the `NavigationStack` (after the existing `.sheet(isPresented: $showingAddMed)` block, after line 108):

```swift
            .sheet(item: $promptMedication) { med in
                DoseAnxietyPromptView(medication: med, existingDose: nil)
            }
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Views/Medications/MedicationsHubView.swift AnxietyWatch/Views/Medications/MedicationListView.swift
git commit -m "feat: present anxiety prompt sheet when logging prompted medications"
```

---

### Task 5: AddMedicationView — Toggle + Stimulant Category

**Files:**
- Modify: `AnxietyWatch/Views/Medications/AddMedicationView.swift`

- [ ] **Step 1: Add Stimulant category and promptAnxietyOnLog toggle**

Replace the full file `AnxietyWatch/Views/Medications/AddMedicationView.swift`:

```swift
import SwiftData
import SwiftUI

struct AddMedicationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var defaultDoseMg: Double = 0
    @State private var category = ""
    @State private var promptAnxietyOnLog = false

    private let categories = [
        "SSRI", "SNRI", "Benzodiazepine", "Stimulant",
        "Beta Blocker", "Z-Drug", "Supplement", "Other",
    ]

    /// Categories that default to prompting for anxiety on dose log.
    private static let promptCategories: Set<String> = ["Benzodiazepine", "Stimulant"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Medication") {
                    TextField("Name", text: $name)
                    TextField("Default Dose (mg)", value: $defaultDoseMg, format: .number)
                        .keyboardType(.decimalPad)
                }

                Section("Category") {
                    Picker("Category", selection: $category) {
                        Text("None").tag("")
                        ForEach(categories, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                    }
                }

                Section {
                    Toggle("Prompt anxiety rating on dose", isOn: $promptAnxietyOnLog)
                } footer: {
                    Text("When enabled, logging a dose will ask for your current anxiety level and follow up 30 minutes later.")
                }
            }
            .navigationTitle("Add Medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: category) { _, newValue in
                promptAnxietyOnLog = Self.promptCategories.contains(newValue)
            }
        }
    }

    private func save() {
        let med = MedicationDefinition(
            name: name.trimmingCharacters(in: .whitespaces),
            defaultDoseMg: defaultDoseMg,
            category: category,
            promptAnxietyOnLog: promptAnxietyOnLog
        )
        modelContext.insert(med)
        dismiss()
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Views/Medications/AddMedicationView.swift
git commit -m "feat: add Stimulant category and anxiety prompt toggle to AddMedicationView"
```

---

### Task 6: App Foreground Follow-Up Check

**Files:**
- Modify: `AnxietyWatch/App/AnxietyWatchApp.swift`

- [ ] **Step 1: Add scenePhase observer and follow-up sheet**

In `AnxietyWatch/App/AnxietyWatchApp.swift`, add these state properties after the existing `@State private var coordinator` (after line 29):

```swift
    @Environment(\.scenePhase) private var scenePhase
    @State private var followUpDose: MedicationDose?
    @State private var followUpMedication: MedicationDefinition?
```

Add a `.onChange(of: scenePhase)` modifier and a `.sheet` to the `WindowGroup`, after the existing `.task` block (after line 57):

```swift
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        checkPendingFollowUp()
                    }
                }
                .sheet(item: $followUpMedication) { med in
                    if let dose = followUpDose {
                        DoseAnxietyPromptView(medication: med, existingDose: dose)
                    }
                }
```

Add the `checkPendingFollowUp` method to the struct (before the `backfillOverlay` method):

```swift
    private func checkPendingFollowUp() {
        DoseFollowUpManager.cleanupStale()

        guard let pending = DoseFollowUpManager.pendingFollowUpIfDue() else { return }

        // Look up the dose and its medication
        let context = ModelContext(sharedModelContainer)
        let doseID = pending.doseID
        let descriptor = FetchDescriptor<MedicationDose>(
            predicate: #Predicate<MedicationDose> { $0.id == doseID }
        )
        guard let dose = try? context.fetch(descriptor).first,
              let medication = dose.medication else {
            // Dose was deleted or medication unlinked — clean up
            DoseFollowUpManager.completeFollowUp(doseID: pending.doseID)
            return
        }

        // Check if a follow-up entry already exists for this dose
        let entryDescriptor = FetchDescriptor<AnxietyEntry>(
            predicate: #Predicate<AnxietyEntry> { $0.isFollowUp == true }
        )
        let followUpEntries = (try? context.fetch(entryDescriptor)) ?? []
        let alreadyCompleted = followUpEntries.contains { $0.triggerDose?.id == doseID }

        if alreadyCompleted {
            DoseFollowUpManager.completeFollowUp(doseID: pending.doseID)
            return
        }

        followUpDose = dose
        followUpMedication = medication
    }
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/App/AnxietyWatchApp.swift
git commit -m "feat: add foreground follow-up check for pending dose anxiety prompts"
```

---

### Task 7: Enable Prompt for Existing Medications + Final Verification

- [ ] **Step 1: Run full test suite**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests`
Expected: All tests PASS

- [ ] **Step 2: Run watchOS build**

Run: `xcodebuild build -scheme "AnxietyWatch Watch App" -destination 'generic/platform=watchOS Simulator' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Manual testing checklist**

- Open the app, go to Medications tab
- Tap "Log Dose" on a benzo → verify anxiety prompt sheet appears
- Fill in severity + notes, tap "Log Dose" → verify dose + anxiety entry created
- Wait 30 minutes (or use `simctl push` to test notification) → verify notification fires
- Tap notification → verify follow-up sheet appears
- Log follow-up → verify second AnxietyEntry linked to same dose with `isFollowUp: true`
- Tap "Skip" on the prompt → verify only dose is logged, no anxiety entry, no follow-up
- Tap "Cancel" on the prompt → verify nothing is logged
- Log a non-prompted medication → verify one-tap behavior unchanged
- Add a new medication as "Stimulant" → verify prompt toggle defaults to on
- Add a new medication as "SSRI" → verify prompt toggle defaults to off
- Kill and reopen app after scheduling a follow-up → verify foreground check presents the sheet
