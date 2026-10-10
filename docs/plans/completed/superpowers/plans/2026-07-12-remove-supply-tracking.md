# Remove Prescription Supply Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all prescription supply/expiration tracking (run-out math, supply alerts, badges, and the `quantity`/`refillsRemaining`/`estimatedRunOutDate`/`dailyDoseCount` fields), leaving prescriptions as simple descriptive manual records.

**Architecture:** Supply tracking is a thin layer over four Prescription fields: `PrescriptionSupplyCalculator` (pure math) feeds Supply Alerts on the Dashboard (`DashboardViewModel.lowSupplyCount` → `AlertsSectionView`) and Medications hub (`supplyAlertSection`), the `SupplyBadge`, and the Prescriptions list's active/expired partitioning (whose fill-date-window filters caused the "No prescriptions yet" lie that motivated this removal). Deleting the fields removes the entire layer. Dose logging (`MedicationDose`, Log Dose, follow-ups) is a separate subsystem and is untouched.

**Tech Stack:** Swift 5.9+/SwiftUI/SwiftData (iOS), Swift Testing, Flask + SQLAlchemy + Alembic + pytest (server).

## Decisions (confirmed with the project maintainer, 2026-07-12)

1. Remove supply tracking entirely — nothing computes expiration or remaining supply anywhere.
2. `quantity` and `refillsRemaining` are dropped too (not kept as informational fields). The OCR label scanner stops parsing them.
3. Prescription's final shape: `id, rxNumber, medicationName, doseMg, doseDescription, dateFilled, pharmacyName, notes` + `medication`/`pharmacy` relationships.
4. The Prescriptions list becomes one flat list (newest fill first) — no partitions, no windows, nothing filtered out of view.

## Global Constraints

- **Swift Testing only** (`import Testing`, `@Test`, `#expect`) — never XCTest.
- **SwiftLint:** 150-char warn / 200 error; zero warnings (CI runs `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`).
- **Public repo:** no PII; fixture Rx numbers like `9999999-00001`.
- **Deleted Swift files auto-register** (synchronized pbxproj groups) — do NOT edit `project.pbxproj`.
- **Branch:** all work on `feat/remove-supply-tracking` off `main`. Never commit to `main`.
- **iOS test command (per-suite):** `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/<SuiteName>`; full suite = same without `-only-testing`.
- **Server test command:** `cd server && uv run python -m pytest tests/ -v` (a hook rejects bare `python`).
- **Untouched subsystems:** `MedicationDefinition`/`MedicationDose`/dose logging/DoseFollowUpManager; pharmacy CRUD + call logs; the OCR scanner's OTHER fields (rx number, medication name, dose, date filled, pharmacy name); all CPAP/HealthKit/HRV code; historical docs (`docs/DEVELOPMENT_TIMELINE.md`, `docs/plans/*`, `docs/superpowers/plans|specs/*`).
- **Line numbers below are approximate** — locate edits by symbol/quoted text, not line number.

---

## File Inventory

**Delete (iOS):**
- `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift`
- `AnxietyWatchTests/PrescriptionSupplyCalculatorTests.swift`

**Modify (iOS):**
- `AnxietyWatch/Models/Prescription.swift` — drop 4 fields
- `AnxietyWatch/Views/Prescriptions/PrescriptionListView.swift` — flat list, no `SupplyBadge`, no partitions
- `AnxietyWatch/Views/Prescriptions/PrescriptionDetailView.swift` — remove `supplySection`, `EditableSupplyFields`, `SupplyBadge` use
- `AnxietyWatch/Views/Prescriptions/AddPrescriptionView.swift` — remove Supply section + qty/refills/dailyDose state + run-out computation
- `AnxietyWatch/Views/Prescriptions/PrescriptionScannerView.swift` — remove qty/refills prefill plumbing
- `AnxietyWatch/Services/PrescriptionLabelScanner.swift` — remove `quantity`/`refillsRemaining` parsing + `Field` cases
- `AnxietyWatch/Views/Medications/MedicationsHubView.swift` — remove `supplyAlertSection` (mind the `.navigationDestination` currently scoped inside it — PROJECT_FUTURE_PLAN.md:198 documents this trap; hoist it if other rows need it, else delete)
- `AnxietyWatch/Views/Dashboard/DashboardView.swift` — remove `prescriptions` @Query + `computeSupplyAlerts` calls + `lowSupplyCount`-based `activeAlerts`
- `AnxietyWatch/Views/Dashboard/DashboardViewModel.swift` — remove `lowSupplyCount` + `computeSupplyAlerts`
- `AnxietyWatch/Views/Dashboard/Sections/AlertsSectionView.swift` — remove the "N Prescriptions Running Low" block (HRV/baseline alerts stay)
- `AnxietyWatch/Services/DataExporter.swift` — `PrescriptionDTO` + mapping + CSV to 8 core keys
- `AnxietyWatch/Services/RestoreFromServer.swift` — `importPrescriptions` to core keys
- `AnxietyWatch/Utilities/DemoSeeder.swift`, `AnxietyWatch/Utilities/PreviewHelpers.swift` — drop removed args
- Tests: `Helpers/ModelFactory.swift`, `ReconcileFromServerTests.swift` (round-trip test shrinks to 7 JSON keys; dedupe/skip fixtures drop `quantity`), `PrescriptionLabelScannerTests.swift` (delete qty/refills cases), `DashboardViewModelTests.swift` (delete supply-alert cases), `DashboardPerfTests.swift` (delete only the supply-alert perf test), `RestoreFromServerTests.swift` (compile-fix if needed)

**Modify (server):**
- `server/alembic/versions/0012_remove_supply_tracking.py` (create)
- `server/schema.sql` — prescriptions to 8 columns
- `server/server.py` — `_upsert_prescriptions` to 8 columns
- `server/tests/test_alembic.py`, `server/tests/test_server.py` — fixtures/assertions

**Docs (living only):**
- `docs/FEATURES.md:70,72,73`, `README.md:76,188,190`, `CLAUDE.md:143`, `PROJECT_FUTURE_PLAN.md:17,86-87,123,198,269`

---

### Task 1: iOS — remove supply tracking UI and calculator

**Files:**
- Delete: `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift`, `AnxietyWatchTests/PrescriptionSupplyCalculatorTests.swift`
- Modify: `PrescriptionListView.swift`, `PrescriptionDetailView.swift`, `AddPrescriptionView.swift`, `PrescriptionScannerView.swift`, `PrescriptionLabelScanner.swift`, `MedicationsHubView.swift`, `DashboardView.swift`, `DashboardViewModel.swift`, `Sections/AlertsSectionView.swift`
- Test: `PrescriptionLabelScannerTests.swift`, `DashboardViewModelTests.swift`, `DashboardPerfTests.swift`

**Interfaces:**
- Consumes: current `Prescription` model (fields still present in this task — views simply stop reading the doomed ones, so every intermediate state compiles; Task 2 drops the fields).
- Produces: no view or service references `PrescriptionSupplyCalculator`, `SupplyBadge`, `lowSupplyCount`, `computeSupplyAlerts`, or scanner `quantity`/`refillsRemaining` after this task.

- [ ] **Step 1: Flatten PrescriptionListView**

Replace the body's partitioned sections with one flat list. The `@Query(sort: \Prescription.dateFilled, order: .reverse)` already orders newest-first. Delete `activePrescriptions`, `expiredPrescriptions`, the body-top partition caching and its comment, and the `SupplyBadge` struct at the bottom of the file. The new body:

```swift
    var body: some View {
        NavigationStack {
            List {
                if prescriptions.isEmpty {
                    Text("No prescriptions yet. Tap + to add one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prescriptions) { rx in
                        NavigationLink {
                            PrescriptionDetailView(prescription: rx)
                        } label: {
                            PrescriptionRow(prescription: rx)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
            .navigationTitle("Prescriptions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddPrescriptionView()
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(prescriptions[index])
        }
    }
```

(`deleteFromFiltered` is replaced by `delete` since there is no filtering left; `Equatable`/`static ==` conformance and `showingAdd` stay as they are.) In `PrescriptionRow`, delete the `Text("qty \(prescription.quantity)")` line and the `SupplyBadge(prescription: prescription)` + surrounding `Spacer()` if it becomes trailing-empty.

- [ ] **Step 2: PrescriptionDetailView**

Delete the whole `supplySection` computed property and its call in `body`; delete the `EditableSupplyFields` private struct. If `EditableSupplyFields` was the only editing surface for `dateFilled`/`notes` etc., check the remaining editable sections still cover the surviving fields (medication name, dose, rx number, pharmacy, date filled, notes) — if a surviving field loses its only editor, move that one row into the adjacent section rather than keeping the Supply section shell.

- [ ] **Step 3: AddPrescriptionView**

Delete: `quantityText`/`refillsRemaining`/`dailyDoseCountText` @State vars and their `init` seeding (including the `prefillQuantity`/`prefillRefills` init parameters), the `supplySection` property and its call in `body`, the scanner-prefill lines `if let qty = scannedData.quantity { … }` / `if let refills = scannedData.refillsRemaining { … }`, and the run-out computation block (`let runOut: Date? = dailyDose.flatMap { PrescriptionSupplyCalculator.estimateRunOutDate(…) }`). The save gate becomes:

```swift
    private var canSave: Bool {
        !medicationName.isEmpty
    }
```

and the `Prescription(...)` construction passes only the surviving fields (in this task the removed params still exist with defaults — just stop passing them).

- [ ] **Step 4: PrescriptionScannerView**

Remove whatever plumbing forwards `quantity`/`refillsRemaining` from scan results toward AddPrescriptionView (locate with `grep -n 'quantity\|refills' PrescriptionScannerView.swift`). Scanned rx number, medication name, dose, date, pharmacy keep flowing.

- [ ] **Step 5: PrescriptionLabelScanner**

Delete the `quantity` and `refillsRemaining` vars from the result struct, the two `Field` enum cases, and the two regex-parse blocks (`/[Qq](?:ty|uantity)\s*:?\s*#?\s*(\d+)/` and `/[Rr]efills?\s*:?\s*(\d+)/`). Check the comment at ~line 246 ("look like an Rx number, quantity, or date") — reword to drop "quantity" if that heuristic no longer considers it, or leave if the heuristic genuinely still matches digit-runs.

- [ ] **Step 6: MedicationsHubView**

Delete `supplyAlertSection` (property + call). CAUTION (documented at PROJECT_FUTURE_PLAN.md:198): a `.navigationDestination` is currently scoped inside/conditional on the supply-alert section — if any other row in the hub navigates through it, hoist the modifier to the `List` before deleting the section; verify hub navigation still works by checking what uses that destination type.

- [ ] **Step 7: Dashboard**

- `DashboardViewModel.swift`: delete `lowSupplyCount` and `computeSupplyAlerts(from:)`.
- `DashboardView.swift`: delete the `prescriptions` `@Query` (verify nothing else in the file reads it — `LastMedicationRowView` uses doses, not prescriptions), both `vm.computeSupplyAlerts(from: prescriptions)` calls and the `.onChange(of: prescriptions.count)` wrapper, and update the `activeAlerts: vm.lowSupplyCount > 0 ? 1 : 0` argument (~line 81) to `activeAlerts: 0` — then look at that parameter: if supply was the ONLY contributor, remove the parameter from the called view instead of passing a constant.
- `Sections/AlertsSectionView.swift`: delete the `if vm.lowSupplyCount > 0 { … }` block ("N Prescriptions Running Low"). The HRV-below-baseline alert and the section's other content stay. Update the doc comment mentioning `lowSupplyCount`.

- [ ] **Step 8: Delete the calculator and its tests**

```bash
git rm AnxietyWatch/Services/PrescriptionSupplyCalculator.swift AnxietyWatchTests/PrescriptionSupplyCalculatorTests.swift
```

- [ ] **Step 9: Fix remaining tests**

- `PrescriptionLabelScannerTests.swift`: delete the test cases asserting quantity/refills extraction (locate with `grep -n -i 'quantity\|refill' …`); other scanner tests (rx number, pharmacy name incl. the WALGREENS fixture, dose, date, confidence gating) must still pass unmodified.
- `DashboardViewModelTests.swift`: delete supply-alert test cases; baseline/trend/sample-loading tests stay.
- `DashboardPerfTests.swift`: delete only the supply-alert perf test (the one inserting 200 prescriptions, "bulk fixture" comment); the 365-snapshot baseline perf test stays.

- [ ] **Step 10: Run affected suites**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/PrescriptionLabelScannerTests -only-testing:AnxietyWatchTests/DashboardViewModelTests -only-testing:AnxietyWatchTests/DashboardPerfTests`
Expected: PASS, zero warnings. Also verify: `grep -rn 'PrescriptionSupplyCalculator\|SupplyBadge\|lowSupplyCount\|computeSupplyAlerts' AnxietyWatch/ AnxietyWatchTests/ --include='*.swift'` → zero hits.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat!: remove prescription supply tracking UI and calculator"
```

---

### Task 2: iOS — drop the 4 supply fields from the model

**Files:**
- Modify: `AnxietyWatch/Models/Prescription.swift`, `AnxietyWatch/Services/DataExporter.swift`, `AnxietyWatch/Services/RestoreFromServer.swift`, `AnxietyWatch/Utilities/DemoSeeder.swift`, `AnxietyWatch/Utilities/PreviewHelpers.swift`
- Test: `AnxietyWatchTests/Helpers/ModelFactory.swift`, `AnxietyWatchTests/ReconcileFromServerTests.swift`, `AnxietyWatchTests/RestoreFromServerTests.swift`

**Interfaces:**
- Consumes: Task 1 (no view reads the doomed fields anymore).
- Produces: `Prescription` with stored properties exactly `id, rxNumber, medicationName, doseMg, doseDescription, dateFilled, pharmacyName, notes, medication, pharmacy`; `importPrescriptions` reading exactly 7 snake_case keys (`rx_number, medication_name, dose_mg, dose_description, date_filled, pharmacy_name, notes`); `PrescriptionDTO` with exactly the camelCase twins. Task 3 mirrors this on the server. SwiftData lightweight migration drops the attributes from existing stores.

- [ ] **Step 1: Trim the model**

Replace `AnxietyWatch/Models/Prescription.swift` in full:

```swift
import Foundation
import SwiftData

@Model
final class Prescription {
    var id: UUID
    var rxNumber: String
    /// Denormalized — preserves the name even if the definition is later deleted
    var medicationName: String
    var doseMg: Double
    /// Human-readable dose description, e.g. "10mg tablet", "0.5mg/mL"
    var doseDescription: String
    var dateFilled: Date
    /// Denormalized — preserves the name even if the pharmacy is later deleted
    var pharmacyName: String
    var notes: String
    var medication: MedicationDefinition?
    var pharmacy: Pharmacy?

    init(
        rxNumber: String,
        medicationName: String,
        doseMg: Double,
        doseDescription: String = "",
        dateFilled: Date = .now,
        pharmacyName: String = "",
        notes: String = "",
        medication: MedicationDefinition? = nil,
        pharmacy: Pharmacy? = nil
    ) {
        self.id = UUID()
        self.rxNumber = rxNumber
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.doseDescription = doseDescription
        self.dateFilled = dateFilled
        self.pharmacyName = pharmacyName
        self.notes = notes
        self.medication = medication
        self.pharmacy = pharmacy
    }
}
```

- [ ] **Step 2: RestoreFromServer.importPrescriptions**

Trim the `Prescription(` construction to the surviving keys (keep the rx_number guard, the date_filled fail-closed guard with its comment, the seen-set, and the medication link exactly as they are):

```swift
            let rx = Prescription(
                rxNumber: rxNumber,
                medicationName: row["medication_name"] as? String ?? "",
                doseMg: row["dose_mg"] as? Double ?? 0,
                doseDescription: row["dose_description"] as? String ?? "",
                dateFilled: dateFilled,
                pharmacyName: row["pharmacy_name"] as? String ?? "",
                notes: row["notes"] as? String ?? ""
            )
```

- [ ] **Step 3: DataExporter**

`PrescriptionDTO` becomes:

```swift
    struct PrescriptionDTO: Codable {
        let rxNumber: String; let medicationName: String; let doseMg: Double
        let doseDescription: String; let dateFilled: String
        let pharmacyName: String; let notes: String
    }
```

Mapping closure:

```swift
            prescriptions: prescriptionsAll.filter { inRange($0.dateFilled) }.map { rx in
                PrescriptionDTO(rxNumber: rx.rxNumber, medicationName: rx.medicationName,
                                doseMg: rx.doseMg, doseDescription: rx.doseDescription,
                                dateFilled: isoFormatter.string(from: rx.dateFilled),
                                pharmacyName: rx.pharmacyName, notes: rx.notes)
            },
```

CSV block header/rows: drop `quantity`, `refills_remaining`, `estimated_run_out_date`, `daily_dose_count` columns:

```swift
        csv = "rx_number,medication_name,dose_mg,dose_description,date_filled,pharmacy_name,notes\n"
        for rx in bundle.prescriptions {
            csv += "\"\(escapeCsv(rx.rxNumber))\",\"\(escapeCsv(rx.medicationName))\",\(rx.doseMg),"
            csv += "\"\(escapeCsv(rx.doseDescription))\",\(rx.dateFilled),"
            csv += "\"\(escapeCsv(rx.pharmacyName))\",\"\(escapeCsv(rx.notes))\"\n"
        }
```

- [ ] **Step 4: Seeds, previews, factory, fixtures**

Delete the removed arguments everywhere the compiler flags: `DemoSeeder.swift` / `PreviewHelpers.swift` `Prescription(` calls (`quantity:`, `refillsRemaining:`), `ModelFactory.swift` prescription factory params, `ReconcileFromServerTests.swift` fixtures (`quantity` keys in row dicts) and the round-trip test — it shrinks to the 7 surviving keys and their `#expect`s (delete the `quantity`/`refillsRemaining`/`dailyDoseCount`/`estimatedRunOutDate` assertions and fixture keys; keep the medication-link assertion and the date assertions for `dateFilled`).

- [ ] **Step 5: Full iOS suite**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS, zero warnings. Verify: `grep -rn 'estimatedRunOutDate\|dailyDoseCount\|refillsRemaining' AnxietyWatch/ AnxietyWatchTests/ --include='*.swift'` → zero hits, and `grep -rn '\.quantity\|quantity:' … | grep -v -i 'cpap\|healthkit\|hk\|sample'` → only non-Prescription hits.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: drop quantity/refills/run-out/dailyDose fields from Prescription"
```

---

### Task 3: Server — migration 0012 + schema + upsert

**Files:**
- Create: `server/alembic/versions/0012_remove_supply_tracking.py`
- Modify: `server/schema.sql` (prescriptions table), `server/server.py` (`_upsert_prescriptions`), `server/tests/test_alembic.py`, `server/tests/test_server.py`

**Interfaces:**
- Consumes: Task 2's payload shape (7 camelCase keys up, 7 snake_case columns down).
- Produces: `prescriptions` table with columns exactly `rx_number` (PK), `medication_name`, `dose_mg`, `dose_description`, `date_filled`, `pharmacy_name`, `notes`.

- [ ] **Step 1: Migration**

Verify head first: `cd server && uv run alembic heads` → expected `0011` (adjust `down_revision` if different). Create `server/alembic/versions/0012_remove_supply_tracking.py`:

```python
"""Remove prescription supply-tracking columns.

Supply/expiration tracking is removed from the app (no run-out math, no
supply alerts); prescriptions are simple descriptive records. Drops the four
columns that only existed to feed that math. No rows are deleted.

Revision ID: 0012
Revises: 0011
"""
from alembic import op

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None

SUPPLY_COLUMNS = (
    "quantity", "refills_remaining", "estimated_run_out_date", "daily_dose_count",
)


def upgrade():
    for col in SUPPLY_COLUMNS:
        op.execute(f"ALTER TABLE prescriptions DROP COLUMN IF EXISTS {col}")


def downgrade():
    # Data is not restorable; recreate the columns to baseline shape so old
    # code can run. quantity was NOT NULL with no default in the baseline —
    # backfill existing rows with 0 via a temporary default, then drop the
    # default to match the baseline definition exactly.
    op.execute("""
        ALTER TABLE prescriptions
            ADD COLUMN IF NOT EXISTS quantity INTEGER NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS refills_remaining INTEGER NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS estimated_run_out_date TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS daily_dose_count DOUBLE PRECISION
    """)
    op.execute("ALTER TABLE prescriptions ALTER COLUMN quantity DROP DEFAULT")
```

Cross-check each recreated column against `server/schema.sql` as of the parent commit (`git show HEAD~1:server/schema.sql` once Step 2 lands, or the current file before editing): `quantity INTEGER NOT NULL` (no default), `refills_remaining INTEGER NOT NULL DEFAULT 0`, `estimated_run_out_date TIMESTAMPTZ` (nullable), `daily_dose_count DOUBLE PRECISION` (nullable).

- [ ] **Step 2: schema.sql**

The prescriptions table becomes:

```sql
CREATE TABLE IF NOT EXISTS prescriptions (
    rx_number               TEXT NOT NULL PRIMARY KEY,
    medication_name         TEXT NOT NULL,
    dose_mg                 DOUBLE PRECISION NOT NULL,
    dose_description        TEXT NOT NULL DEFAULT '',
    date_filled             TIMESTAMPTZ NOT NULL,
    pharmacy_name           TEXT NOT NULL DEFAULT '',
    notes                   TEXT NOT NULL DEFAULT ''
);
```

- [ ] **Step 3: `_upsert_prescriptions`**

```python
    def _upsert_prescriptions(cur, prescriptions):
        for rx in prescriptions:
            cur.execute(
                """INSERT INTO prescriptions (rx_number, medication_name, dose_mg, dose_description,
                       date_filled, pharmacy_name, notes)
                   VALUES (%s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (rx_number) DO UPDATE SET
                       medication_name = EXCLUDED.medication_name,
                       dose_mg = EXCLUDED.dose_mg,
                       dose_description = EXCLUDED.dose_description,
                       date_filled = EXCLUDED.date_filled,
                       pharmacy_name = EXCLUDED.pharmacy_name,
                       notes = EXCLUDED.notes""",
                (rx["rxNumber"], rx["medicationName"], rx["doseMg"],
                 rx.get("doseDescription", ""), rx["dateFilled"],
                 rx.get("pharmacyName", ""), rx.get("notes", "")),
            )
        return len(prescriptions)
```

(Old app builds still sending `quantity` etc. are unaffected — unknown keys are simply never read.)

- [ ] **Step 4: Server tests**

- `test_server.py`: trim prescription sync payloads/assertions to the 7 core fields (`test_sync_prescriptions`, `test_sync_prescriptions_idempotent` semantics unchanged). NOTE: `rx["quantity"]` was previously a required key — removing it from payloads must not break other assertions.
- `test_alembic.py`: update the exact-column-set assertion for prescriptions to the 7 columns; extend or mirror the existing 0011-style tests for 0012 — an upgrade test that (a) re-adds the four columns to a scratch DB (simulating pre-0012 prod), (b) inserts a row, (c) runs 0012, (d) asserts the row survives and columns are gone; and a downgrade test asserting the recreated `quantity` column enforces NOT NULL and has no default (`SELECT column_default, is_nullable FROM information_schema.columns WHERE table_name='prescriptions' AND column_name='quantity'` → `(None, 'NO')`).

- [ ] **Step 5: Run suite + commit**

Run: `cd server && uv run python -m pytest tests/ -q`
Expected: only the known pre-existing barometric-timezone flake may fail; everything else passes.

```bash
git add -A
git commit -m "feat!: drop prescription supply-tracking columns (0012)"
```

---

### Task 4: Docs sweep + final verification

**Files:**
- Modify: `docs/FEATURES.md:70,72,73`, `README.md:76,188,190`, `CLAUDE.md:143`, `PROJECT_FUTURE_PLAN.md:17,86-87,123,198,269`

**Interfaces:** none — docs + whole-repo checks. Historical docs keep every supply mention.

- [ ] **Step 1: docs/FEATURES.md**

- Line 70 (`- **Prescription management** -- supply tracking with days-remaining calculations, refill alerts, expiration monitoring`) → `- **Prescription management** -- manual prescription records (medication, dose, Rx number, pharmacy, fill date, notes)`
- Line 72 (OCR bullet) → drop `, quantity, and refill count`; ends `extracts Rx number, medication name, and dosage`
- Line 73 (`- **Manual prescription entry** -- with OCR label-scan prefill, supply tracking, and refill alerts`) → `- **Manual prescription entry** -- with OCR label-scan prefill`

- [ ] **Step 2: README.md**

- Line 76 → `| **Prescription management** | Manual prescription records with OCR label scanning, pharmacy search with call logging |`
- Line 188 → drop `, quantity, and refills`; ends `extracts Rx number, medication name, and dosage from photographed pill bottles using regex patterns against VNRecognizeTextRequest output.`
- Line 190 → drop `supply alerts, ` from the DashboardViewModel test-suite enumeration.

- [ ] **Step 3: CLAUDE.md**

Delete the file-tree line 143 (`│   │   ├── PrescriptionSupplyCalculator.swift # Supply estimation + status`).

- [ ] **Step 4: PROJECT_FUTURE_PLAN.md**

Read each site in context; trim only removed functionality:
- Line 17: drop `supply calculations, refill alerts, ` from the bullet; also soften `A full medication lifecycle system.` to `Medication and pharmacy record-keeping.` since lifecycle tracking is gone.
- Lines 86-87: line 86 — drop `supply alert filtering, ` from the DashboardViewModel enumeration; line 87 (consolidate triplicated supply alert filtering) — delete the whole bullet.
- Line 123 (staleness filter fix) — delete the whole bullet.
- Line 198 (`.navigationDestination` scoping conditional on supply alerts) — delete or reword to match what Task 1 Step 6 actually did (if the destination was hoisted, the bullet is fixed — say so or delete it).
- Line 269 (refill eligibility date alongside supply run-out) — delete the whole bullet.

- [ ] **Step 5: Straggler grep + full suites**

Run: `grep -rn -iE 'supply (track|alert|status|estimat)|run.?out|refill' README.md CLAUDE.md AGENTS.md REQUIREMENTS.md docs/FEATURES.md PROJECT_FUTURE_PLAN.md .github/copilot-instructions.md` — fix hits describing removed functionality (leave hits about dose logging or unrelated features).
Run both full suites one last time (`xcodebuild test …` full, `cd server && uv run python -m pytest tests/ -q`).
Expected: green (modulo the known barometric flake).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: remove supply tracking from living docs"
```

---

## Self-Review Notes

- **Spec coverage:** calculator + alerts + badges + list partitioning ✔ Task 1; four fields off model/exporter/restore ✔ Task 2; server columns/payload ✔ Task 3; docs ✔ Task 4. Decision 4 (flat list, nothing hidden) ✔ Task 1 Step 1 — the misleading empty state ceases to exist structurally.
- **Type consistency:** `Prescription` init in Task 2 Step 1 matches Task 2 Step 2's construction and Task 3's column list (7 data columns = 7 DTO keys = 8 Swift stored props incl. `id`, which never syncs — consistent with the existing design where `id` is local-only).
- **Ordering:** Task 1 must precede Task 2 (views stop reading fields before fields vanish); Task 3 independent of 1-2 but sequenced after for one deploy story; Task 4 last.
