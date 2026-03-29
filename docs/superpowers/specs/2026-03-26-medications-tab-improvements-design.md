# Medications Tab Improvements — Design Spec

## Problem

The Medications tab has three usability issues:

1. **Supply Alerts are noisy** — old prescriptions that were filled months ago still show alerts, making the section long and overwhelming
2. **Medications require manual entry** — users must manually create `MedicationDefinition` records even though prescriptions (which contain medication names) are already imported from the pharmacy
3. **No way to dismiss medications you've stopped taking** — inactive medications still appear in active contexts like Quick Log and Supply Alerts

## Changes

### 1. Supply Alerts: 60-Day Staleness Filter

**What:** Filter supply alerts in `MedicationsHubView` to exclude prescriptions whose most recent fill date is more than 60 days ago.

**Logic:** For each prescription, use `lastFillDate ?? dateFilled` as the reference date. If that date is more than 60 days before today, exclude it from the alerts list. Also exclude prescriptions whose linked `medication?.isActive == false`.

**Where:** `MedicationsHubView.swift` — the computed `alertPrescriptions` filtering logic.

**No model changes required.** This is a view-layer filter only.

### 2. Auto-Create MedicationDefinition from Prescription Imports

**What:** When prescriptions are fetched from the server (or created manually), automatically find-or-create a `MedicationDefinition` and link it to the prescription.

**Logic (in `SyncService.fetchPrescriptions()`):**
1. After creating or upserting a `Prescription`, extract `medicationName` from the prescription
2. Query `MedicationDefinition` for a case-insensitive name match
3. If found: set `prescription.medication = existingDefinition`
4. If not found: create a new `MedicationDefinition` with:
   - `name`: from `medicationName`
   - `defaultDoseMg`: from `dose_mg` (or 0 if unavailable)
   - `category`: `""` (empty — user can categorize later)
   - `isActive`: `true`
5. Link the new definition to the prescription

**Where:** `SyncService.fetchPrescriptions()` — after the existing upsert logic.

**`AddPrescriptionView` already supports creating a `MedicationDefinition` inline**, so no changes needed there. The existing "select existing or add new" picker covers the manual case.

**Keep the manual "Add Medication" button** in `MedicationsHubView` for the rare case where a user needs to add a medication that doesn't come from a prescription.

### 3. "Not Currently Taking" — Honor `isActive` Flag

**What:** Medications with `isActive == false` should be excluded from all active/trackable contexts but remain in historical views.

**Excluded from (when `isActive == false`):**
- Quick Log section in `MedicationsHubView`
- Supply Alerts section in `MedicationsHubView` (prescriptions linked to inactive medications)
- Quick Log section in `MedicationListView`

**Still visible in:**
- Recent Doses section (historical — shows what was actually taken)
- Any future reporting/export views
- The medication list itself (so users can toggle `isActive` back on)

**Toggle UX:** Add a way to toggle `isActive` from the medications list. Options:
- Swipe action on a medication row ("Deactivate" / "Reactivate")
- Toggle in a medication detail/edit view

**Recommended:** Swipe action is the most discoverable and quickest interaction. Use a swipe action labeled "Deactivate" (when active) or "Reactivate" (when inactive). Show inactive medications in a separate "Not Currently Taking" section at the bottom of the medication list, visually distinguished (e.g., dimmed text).

**Where:** `MedicationsHubView.swift`, `MedicationListView.swift`

## Files to Modify

| File | Change |
|------|--------|
| `Views/Medications/MedicationsHubView.swift` | Filter supply alerts by 60-day staleness + `isActive`; filter Quick Log by `isActive` |
| `Views/Medications/MedicationListView.swift` | Add swipe actions for activate/deactivate; separate inactive section; filter Quick Log |
| `Services/SyncService.swift` | Find-or-create `MedicationDefinition` when upserting prescriptions |
| `Services/PrescriptionSupplyCalculator.swift` | No changes needed — filtering happens at the view layer |

## No New Models or Fields

All changes use existing model fields (`isActive`, `dateFilled`, `lastFillDate`, `medication` relationship). No schema migrations required.

## Edge Cases

- **Prescription with no linked medication and no `medicationName`:** Skip auto-creation (shouldn't happen in practice since `medicationName` is required)
- **Multiple prescriptions for the same medication name:** All link to the same `MedicationDefinition` — this is correct behavior
- **Case sensitivity in medication name matching:** Use case-insensitive comparison to avoid duplicates like "Lorazepam" vs "lorazepam"
- **User deactivates a medication then gets a new prescription for it:** The new prescription import should reactivate the medication (set `isActive = true`) since a new fill implies the user is taking it again
