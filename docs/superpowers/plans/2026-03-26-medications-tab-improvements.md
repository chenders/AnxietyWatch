# Medications Tab Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce supply alert noise, auto-create medications from prescription imports, and let users mark medications as "not currently taking."

**Architecture:** Three independent changes touching views and SyncService. No model changes — uses existing `MedicationDefinition.isActive` and `Prescription.lastFillDate`/`dateFilled`. The find-or-create logic is a static method on SyncService for testability.

**Tech Stack:** SwiftUI, SwiftData, Swift Testing

**Spec:** `docs/superpowers/specs/2026-03-26-medications-tab-improvements-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `AnxietyWatch/Services/SyncService.swift` | Modify | Add `findOrCreateMedication` static method; call it from `fetchPrescriptions` |
| `AnxietyWatch/Views/Medications/MedicationsHubView.swift` | Modify | 60-day staleness filter on supply alerts; inactive medication filter; deactivate swipe; inactive section |
| `AnxietyWatch/Views/Medications/MedicationListView.swift` | Modify | Deactivate swipe on Quick Log; inactive section with reactivate swipe |
| `AnxietyWatchTests/SyncServiceTests.swift` | Modify | Add `makeContainer` models; add find-or-create tests |

---

### Task 1: Auto-link medications in SyncService

**Files:**
- Modify: `AnxietyWatch/Services/SyncService.swift:132-244`
- Modify: `AnxietyWatchTests/SyncServiceTests.swift`

- [ ] **Step 1: Update test `makeContainer` to include Prescription and Pharmacy models**

In `AnxietyWatchTests/SyncServiceTests.swift`, update the `makeContainer` method (lines 12-19):

```swift
private func makeContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: AnxietyEntry.self, MedicationDefinition.self, MedicationDose.self,
        CPAPSession.self, HealthSnapshot.self, BarometricReading.self,
        ClinicalLabResult.self, Prescription.self, Pharmacy.self,
        PharmacyCallLog.self,
        configurations: config
    )
}
```

- [ ] **Step 2: Write failing tests for `findOrCreateMedication`**

Add the following tests at the end of `SyncServiceTests` (before the closing `}`):

```swift
// MARK: - findOrCreateMedication

@Test("Creates new MedicationDefinition when none exists")
func findOrCreateNew() throws {
    let container = try makeContainer()
    let context = ModelContext(container)

    let med = try SyncService.findOrCreateMedication(
        name: "Lorazepam", doseMg: 0.5, in: context
    )

    #expect(med.name == "Lorazepam")
    #expect(med.defaultDoseMg == 0.5)
    #expect(med.isActive == true)

    let all = try context.fetch(FetchDescriptor<MedicationDefinition>())
    #expect(all.count == 1)
}

@Test("Finds existing MedicationDefinition by case-insensitive name")
func findOrCreateExisting() throws {
    let container = try makeContainer()
    let context = ModelContext(container)

    let existing = MedicationDefinition(name: "Lorazepam", defaultDoseMg: 0.5)
    context.insert(existing)
    try context.save()

    let found = try SyncService.findOrCreateMedication(
        name: "lorazepam", doseMg: 1.0, in: context
    )

    #expect(found.id == existing.id)
    // Should not overwrite existing dose
    #expect(found.defaultDoseMg == 0.5)

    let all = try context.fetch(FetchDescriptor<MedicationDefinition>())
    #expect(all.count == 1)
}

@Test("Reactivates inactive MedicationDefinition when found")
func findOrCreateReactivates() throws {
    let container = try makeContainer()
    let context = ModelContext(container)

    let inactive = MedicationDefinition(
        name: "Lorazepam", defaultDoseMg: 0.5, isActive: false
    )
    context.insert(inactive)
    try context.save()

    let found = try SyncService.findOrCreateMedication(
        name: "Lorazepam", doseMg: 0.5, in: context
    )

    #expect(found.id == inactive.id)
    #expect(found.isActive == true)
}

@Test("Skips medication creation when name is empty")
func findOrCreateEmptyName() throws {
    let container = try makeContainer()
    let context = ModelContext(container)

    let result = try SyncService.findOrCreateMedication(
        name: "", doseMg: 0, in: context
    )

    // Should return nil for empty names
    let all = try context.fetch(FetchDescriptor<MedicationDefinition>())
    #expect(all.count == 0)
    // We'll adjust this test once we decide the return type
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/SyncServiceTests 2>&1 | tail -20`

Expected: Compilation error — `findOrCreateMedication` does not exist yet.

- [ ] **Step 4: Implement `findOrCreateMedication` in SyncService**

In `AnxietyWatch/Services/SyncService.swift`, add this static method after the `fetchPrescriptions` method (after line 244, before `parseDate`):

```swift
/// Find existing MedicationDefinition by name (case-insensitive) or create a new one.
/// Reactivates inactive medications when a new prescription arrives.
/// Returns nil if the medication name is empty.
@discardableResult
static func findOrCreateMedication(
    name: String,
    doseMg: Double,
    in modelContext: ModelContext
) throws -> MedicationDefinition? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    let allMeds = try modelContext.fetch(FetchDescriptor<MedicationDefinition>())
    let lowered = trimmed.lowercased()

    if let existing = allMeds.first(where: { $0.name.lowercased() == lowered }) {
        if !existing.isActive {
            existing.isActive = true
        }
        return existing
    }

    let newMed = MedicationDefinition(name: trimmed, defaultDoseMg: doseMg)
    modelContext.insert(newMed)
    return newMed
}
```

- [ ] **Step 5: Update the empty-name test to match the optional return type**

Replace the `findOrCreateEmptyName` test:

```swift
@Test("Returns nil when medication name is empty")
func findOrCreateEmptyName() throws {
    let container = try makeContainer()
    let context = ModelContext(container)

    let result = try SyncService.findOrCreateMedication(
        name: "", doseMg: 0, in: context
    )

    #expect(result == nil)
    let all = try context.fetch(FetchDescriptor<MedicationDefinition>())
    #expect(all.count == 0)
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/SyncServiceTests 2>&1 | tail -20`

Expected: All SyncServiceTests pass.

- [ ] **Step 7: Wire `findOrCreateMedication` into `fetchPrescriptions`**

In `AnxietyWatch/Services/SyncService.swift`, update the `fetchPrescriptions` method. After the upsert logic for **new** prescriptions (after `modelContext.insert(rx)` on line 238, before `added += 1`), add:

```swift
rx.medication = try SyncService.findOrCreateMedication(
    name: rx.medicationName, doseMg: rx.doseMg, in: modelContext
)
```

And for **existing** prescriptions (after `updated += 1` on line 216), add the same linking if the prescription doesn't already have a medication:

```swift
if rx.medication == nil {
    rx.medication = try SyncService.findOrCreateMedication(
        name: rx.medicationName, doseMg: rx.doseMg, in: modelContext
    )
}
```

- [ ] **Step 8: Run full test suite to confirm no regressions**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add AnxietyWatch/Services/SyncService.swift AnxietyWatchTests/SyncServiceTests.swift
git commit -m "feat: auto-create MedicationDefinition from prescription imports

Find-or-create by case-insensitive name match when fetching prescriptions
from the server. Reactivates inactive medications when new prescriptions
arrive."
```

---

### Task 2: Filter supply alerts by staleness and active status

**Files:**
- Modify: `AnxietyWatch/Views/Medications/MedicationsHubView.swift:70-89`

- [ ] **Step 1: Update the supply alerts filter in MedicationsHubView**

In `AnxietyWatch/Views/Medications/MedicationsHubView.swift`, replace lines 71-74 (the `let alerts = prescriptions.filter` block):

```swift
let alerts = prescriptions.filter { rx in
    // Skip prescriptions filled more than 60 days ago
    let fillDate = rx.lastFillDate ?? rx.dateFilled
    let daysSinceFill = Calendar.current.dateComponents(
        [.day], from: fillDate, to: .now
    ).day ?? 0
    guard daysSinceFill <= 60 else { return false }

    // Skip prescriptions for inactive medications
    if rx.medication?.isActive == false { return false }

    let status = PrescriptionSupplyCalculator.supplyStatus(for: rx)
    return status == .low || status == .warning || status == .expired
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Views/Medications/MedicationsHubView.swift
git commit -m "fix: filter supply alerts older than 60 days and for inactive medications

Reduces noise in the Supply Alerts section by excluding prescriptions
filled more than 60 days ago, and prescriptions linked to medications
marked as not currently taking."
```

---

### Task 3: Add activate/deactivate UX to MedicationsHubView

**Files:**
- Modify: `AnxietyWatch/Views/Medications/MedicationsHubView.swift`

- [ ] **Step 1: Add a query for inactive medications**

In `AnxietyWatch/Views/Medications/MedicationsHubView.swift`, after the `activeMeds` query (after line 10), add:

```swift
@Query(
    filter: #Predicate<MedicationDefinition> { !$0.isActive },
    sort: \MedicationDefinition.name
)
private var inactiveMeds: [MedicationDefinition]
```

- [ ] **Step 2: Add swipe action to deactivate medications in Quick Log**

Replace the `ForEach(activeMeds)` block (lines 50-65) inside `quickLogSection` with:

```swift
ForEach(activeMeds) { med in
    HStack {
        VStack(alignment: .leading) {
            Text(med.name).font(.headline)
            Text("\(med.defaultDoseMg, specifier: "%.1f") mg · \(med.category)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Log Dose") {
            logDose(for: med)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }
    .swipeActions(edge: .trailing) {
        Button("Deactivate") {
            med.isActive = false
        }
        .tint(.orange)
    }
}
```

- [ ] **Step 3: Add "Not Currently Taking" section**

After the `recentDosesSection` in the `body` List (after line 23 — `recentDosesSection`), add:

```swift
notCurrentlyTakingSection
```

Then add the section computed property after the `recentDosesSection` property (after line 127):

```swift
@ViewBuilder
private var notCurrentlyTakingSection: some View {
    if !inactiveMeds.isEmpty {
        Section("Not Currently Taking") {
            ForEach(inactiveMeds) { med in
                HStack {
                    VStack(alignment: .leading) {
                        Text(med.name).font(.subheadline)
                        if !med.category.isEmpty {
                            Text(med.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .swipeActions(edge: .trailing) {
                    Button("Reactivate") {
                        med.isActive = true
                    }
                    .tint(.green)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Views/Medications/MedicationsHubView.swift
git commit -m "feat: add activate/deactivate swipe actions for medications

Swipe left on an active medication to deactivate it. Inactive medications
appear in a 'Not Currently Taking' section with a reactivate swipe action."
```

---

### Task 4: Add activate/deactivate UX to MedicationListView

**Files:**
- Modify: `AnxietyWatch/Views/Medications/MedicationListView.swift`

- [ ] **Step 1: Add inactive medications query**

In `AnxietyWatch/Views/Medications/MedicationListView.swift`, after the `activeMeds` query (after line 10), add:

```swift
@Query(
    filter: #Predicate<MedicationDefinition> { !$0.isActive },
    sort: \MedicationDefinition.name
)
private var inactiveMeds: [MedicationDefinition]
```

- [ ] **Step 2: Add swipe action to deactivate in Quick Log and add inactive section**

Replace the Quick Log `ForEach(activeMeds)` block (lines 23-38) with:

```swift
ForEach(activeMeds) { med in
    HStack {
        VStack(alignment: .leading) {
            Text(med.name).font(.headline)
            Text("\(med.defaultDoseMg, specifier: "%.1f") mg · \(med.category)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Log Dose") {
            logDose(for: med)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }
    .swipeActions(edge: .trailing) {
        Button("Deactivate") {
            med.isActive = false
        }
        .tint(.orange)
    }
}
```

Then after the Recent Doses section closing brace (after line 58), add inside the List:

```swift
if !inactiveMeds.isEmpty {
    Section("Not Currently Taking") {
        ForEach(inactiveMeds) { med in
            HStack {
                VStack(alignment: .leading) {
                    Text(med.name).font(.subheadline)
                    if !med.category.isEmpty {
                        Text(med.category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .swipeActions(edge: .trailing) {
                Button("Reactivate") {
                    med.isActive = true
                }
                .tint(.green)
            }
        }
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 4: Run full test suite**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Views/Medications/MedicationListView.swift
git commit -m "feat: add activate/deactivate swipe actions to MedicationListView

Mirrors the same UX from MedicationsHubView — swipe to deactivate active
medications, inactive section with reactivate swipe."
```
