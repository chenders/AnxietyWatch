# Remove Pharmacy Prescription Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all pharmacy prescription-import functionality (Walgreens scraping, Capital Rx claims sync, iOS server-fetch) from app, server, and docs; medications are entered manually from now on.

**Architecture:** The pharmacy connectors live server-side (`server/walgreens_*.py`, `server/caprx_*.py` + admin routes + cron); the iOS side is one fetch endpoint (`SyncService.fetchPrescriptions`) plus a JSON→SwiftData mapper (`PrescriptionImporter`) and 12 import-only model fields. Manual entry (`AddPrescriptionView`, OCR label scanner, pharmacy CRUD, supply alerts) already exists and stays. Generic device↔server backup/restore of user-entered prescriptions stays; only the pharmacy→server import path and its schema baggage are removed.

**Tech Stack:** Swift 5.9+/SwiftUI/SwiftData (iOS), Swift Testing, Flask + SQLAlchemy + Alembic + pytest (server).

## Decisions (confirmed with the project maintainer, 2026-07-11)

1. **Keep the OCR label scanner** (`PrescriptionLabelScanner`, `PrescriptionScannerView`, "Scan Label" button) — it is a manual-entry aid, untouched by this plan.
2. **Full field cleanup** — drop the 12 import-only fields from the SwiftData model AND the server table: `prescriberName`, `ndcCode`, `rxStatus`, `lastFillDate`, `importSource`, `walgreensRxId`, `directions`, `daysSupply`, `patientPay`, `planPay`, `dosageForm`, `drugType`.
3. **Existing imported rows are kept, not deleted** — dropping the `import_source` column (server) and `importSource` attribute (iOS lightweight migration) makes every surviving row an ordinary manual-style prescription. No prescription data is purged; only stored Walgreens/CapRx **credentials** are purged from the server `settings` table.

## Global Constraints

- **Swift Testing only** (`import Testing`, `@Test`, `#expect`) — never XCTest.
- **SwiftLint:** 150-char warn / 200 error; zero warnings (CI runs `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`).
- **Public repo:** no personal medical assertions, no PII. Fixture rules from repo CLAUDE.md: Rx numbers like `9999999-00001`, pharmacy store numbers `#12345`, prescriber `Jane Smith MD`.
- **New/deleted Swift files auto-register** with the target (synchronized pbxproj groups) — do NOT edit `project.pbxproj`.
- **Branch:** all work on `feat/remove-pharmacy-import` off `main`. Never commit to `main`.
- **iOS test command (per-suite):** `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/<SuiteName>` (or XcodeBuildMCP `test_sim` with the same `-only-testing` arg).
- **Server test command:** `cd server && python -m pytest tests/ -v` (same as CI).
- **Do NOT touch:** `server/resmed_*` (CPAP — separate feature sharing `crypto.py`/`settings`), `server/genius.py` (uses bs4/lxml — keep those deps), `crypto.py`, `log_sanitize.py`, admin helpers `_upsert_setting`/`_upgrade_legacy_plaintext_setting` (`server/admin.py:274-307`, used by ResMed), the `pharmacies`/`pharmacy_call_logs` tables and all Pharmacy/CallLog Swift code (manual features), `medication_definitions`/`medication_doses` (manual dose logging).
- **Historical docs are records, not ads:** `docs/DEVELOPMENT_TIMELINE.md`, `docs/plans/*` (incl. `fable5-reevaluation/`), and `docs/superpowers/plans|specs/*` describe what WAS built — leave every pharmacy mention there untouched. Only living docs (README, docs/FEATURES.md, PROJECT_FUTURE_PLAN.md, repo CLAUDE.md) get edited.

---

## File Inventory

**Delete (iOS):**
- `AnxietyWatch/Services/PrescriptionImporter.swift`
- `AnxietyWatchTests/PrescriptionImporterTests.swift`
- `AnxietyWatchTests/PrescriptionDaysSupplyTests.swift` (tests the PBM `daysSupply` priority path only)

**Modify (iOS):**
- `AnxietyWatch/Services/SyncService.swift:538-619` — delete `fetchPrescriptions`; inline `findOrCreateMedication`; keep `backfillMedicationLinks`
- `AnxietyWatch/Services/RestoreFromServer.swift:301-321,537-553` — self-contained insert-only prescription importer
- `AnxietyWatch/Views/Prescriptions/PrescriptionListView.swift:14-16,27-75,159-171` — remove fetch button + sync hint + fetch state
- `AnxietyWatch/Models/Prescription.swift` — drop 12 fields
- `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift` — drop `daysSupply`/`lastFillDate` branches
- `AnxietyWatch/Views/Prescriptions/PrescriptionDetailView.swift:75` — drop caprx special-case
- `AnxietyWatch/Services/DataExporter.swift:321-334,433-441` — trim `PrescriptionDTO`
- `AnxietyWatch/Utilities/DemoSeeder.swift:82-85`, `AnxietyWatch/Utilities/PreviewHelpers.swift:107-115` — drop `prescriberName:` args
- Tests: `Helpers/ModelFactory.swift`, `ModelEnumTests.swift`, `ModelNormalizationTests.swift`, `DashboardViewModelTests.swift`, `DataExporterTests.swift`, `ReconcileFromServerTests.swift`, `RestoreFromServerTests.swift`, `SyncServiceTests.swift` — compile-fix removed fields/APIs

**Delete (server):**
- `server/walgreens_client.py`, `server/walgreens_sync.py`, `server/caprx_client.py`, `server/caprx_sync.py`, `server/test_walgreens_login.py`
- `server/tests/test_walgreens_client.py`, `server/tests/test_walgreens_sync.py`, `server/tests/test_caprx_sync.py`
- `server/walgreens-cron`, `server/caprx-cron`
- `server/templates/walgreens_settings.html`, `server/templates/caprx_settings.html`

**Modify (server):**
- `server/admin.py` — remove `walgreens_settings()` (~L397-483), `caprx_settings()` (~L491-556), `clear_prescriptions()` (~L629-644)
- `server/templates/base.html:126-127` — remove nav links
- `server/Dockerfile` — remove playwright install, caprx-cron copy, xvfb/xauth
- `server/requirements.txt` — remove `playwright` (KEEP bs4/lxml — genius.py)
- `server/.env.example` — reword credential comment to ResMed-only
- `server/server.py:968-1006` — trim `_upsert_prescriptions` columns
- `server/schema.sql:172-196` — trim `prescriptions` table
- `server/alembic/versions/0011_remove_pharmacy_import.py` (create)
- `server/tests/test_server.py` — remove Walgreens-settings tests (~L1643-1690); trim prescription sync tests (~L1708-1764)
- `server/tests/test_alembic.py:130-…` — remove the Walgreens/CapRx-columns assertion block

**Docs:**
- `README.md:23,76,83,165,192`, `docs/FEATURES.md:73`, `PROJECT_FUTURE_PLAN.md:15,29,125`
- Delete `docs/caprx-api-fields.md`

---

### Task 1: iOS — remove the server-fetch import pipeline

**Files:**
- Modify: `AnxietyWatch/Services/RestoreFromServer.swift`
- Modify: `AnxietyWatch/Services/SyncService.swift:538-619`
- Modify: `AnxietyWatch/Views/Prescriptions/PrescriptionListView.swift`
- Delete: `AnxietyWatch/Services/PrescriptionImporter.swift`
- Delete: `AnxietyWatchTests/PrescriptionImporterTests.swift`
- Test: `AnxietyWatchTests/ReconcileFromServerTests.swift`, `AnxietyWatchTests/RestoreFromServerTests.swift`, `AnxietyWatchTests/SyncServiceTests.swift`

**Interfaces:**
- Consumes: existing `RestoreFromServer.prescriptionRowsNotAlreadyPresent(_:in:)` and its `existingKeys` helper (RestoreFromServer.swift:531-553) — both stay.
- Produces: `RestoreFromServer.importPrescriptions(_ rows: [[String: Any]], into: ModelContext) throws -> Int` (insert-only); `SyncService.findOrCreateMedication(name:doseMg:in:) throws -> MedicationDefinition?` keeps its exact current signature (SyncServiceTests and Task 2 depend on it).

- [ ] **Step 1: Inline `findOrCreateMedication` into SyncService**

In `AnxietyWatch/Services/SyncService.swift`, replace the delegating body (lines 594-601) with the implementation moved verbatim from `PrescriptionImporter.findOrCreateMedication` (PrescriptionImporter.swift:117-146). Keep the existing doc comment and signature:

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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try exact match first (fast, predicate-based)
        var descriptor = FetchDescriptor<MedicationDefinition>(
            predicate: #Predicate { $0.name == trimmed }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            if !existing.isActive { existing.isActive = true }
            return existing
        }

        // Fallback: case-insensitive match (SwiftData predicates don't support lowercased())
        let allMeds = try modelContext.fetch(FetchDescriptor<MedicationDefinition>())
        let lowered = trimmed.lowercased()
        if let existing = allMeds.first(where: { $0.name.lowercased() == lowered }) {
            if !existing.isActive { existing.isActive = true }
            return existing
        }

        let newMed = MedicationDefinition(name: trimmed, defaultDoseMg: doseMg)
        modelContext.insert(newMed)
        return newMed
    }
```

- [ ] **Step 2: Delete `SyncService.fetchPrescriptions`**

Remove SyncService.swift lines 538-579 (the `// MARK: - Fetch prescriptions from server` section through the end of `fetchPrescriptions`). Keep `fetchSongs` (581-589) and `backfillMedicationLinks` (603-619) — `backfillMedicationLinks` still repairs manually-entered/restored prescriptions with no `medication` link (called from `AnxietyWatchApp.swift:180`).

- [ ] **Step 3: Give RestoreFromServer its own insert-only prescription importer**

In `RestoreFromServer.swift`, next to the sibling importers (e.g. `importPharmacies`), add. For date parsing, reuse the file's existing ISO-8601 date-parsing helper that `importPharmacies`/`importPharmacyCallLogs` use (grep `ISO8601` / `parseDate` in this file and match the sibling call style exactly — do not add a second formatter if one exists):

```swift
    /// Insert prescriptions from restore/reconcile JSON rows. Insert-only by
    /// design: callers filter to genuinely-new rx numbers via
    /// `prescriptionRowsNotAlreadyPresent`, so no update branch exists and a
    /// locally-edited prescription can never be reverted to the server's copy.
    static func importPrescriptions(
        _ rows: [[String: Any]], into modelContext: ModelContext
    ) throws -> Int {
        var count = 0
        for row in rows {
            guard let rxNumber = row["rx_number"] as? String, !rxNumber.isEmpty else { continue }
            let rx = Prescription(
                rxNumber: rxNumber,
                medicationName: row["medication_name"] as? String ?? "",
                doseMg: row["dose_mg"] as? Double ?? 0,
                doseDescription: row["dose_description"] as? String ?? "",
                quantity: row["quantity"] as? Int ?? 0,
                refillsRemaining: row["refills_remaining"] as? Int ?? 0,
                dateFilled: parseDate(row["date_filled"]) ?? .now,
                estimatedRunOutDate: parseDate(row["estimated_run_out_date"]),
                pharmacyName: row["pharmacy_name"] as? String ?? "",
                notes: row["notes"] as? String ?? "",
                dailyDoseCount: row["daily_dose_count"] as? Double
            )
            modelContext.insert(rx)
            rx.medication = try SyncService.findOrCreateMedication(
                name: rx.medicationName, doseMg: rx.doseMg, in: modelContext
            )
            count += 1
        }
        return count
    }
```

(If Task 2 has not run yet, the extra `Prescription` init parameters still exist with defaults — this compiles both before and after Task 2.)

- [ ] **Step 4: Rewire the reconcile call site**

At `RestoreFromServer.swift:301-321`, replace the block comment + call. The long comment about `PrescriptionImporter`'s upsert is now stale; the new block reads:

```swift
        if let rows = json["prescriptions"] as? [[String: Any]] {
            // Insert-only: filter to genuinely-new rx numbers first so a
            // reconcile can never overwrite a locally-edited prescription
            // with the server's older copy.
            let newRows = try Self.prescriptionRowsNotAlreadyPresent(rows, in: modelContext)
            // NOT `try?`. Swallowing the error would report `prescriptions: 0` and let
            // the reconcile finish "successfully" having imported none of them —
            // indistinguishable, in the report the user actually reads, from "nothing
            // was missing". Every other importer here fails closed; this one too.
            report["prescriptions"] = try Self.importPrescriptions(newRows, into: modelContext)
        }
```

Also update the doc comment on `prescriptionRowsNotAlreadyPresent` (lines 537-544) — it references `PrescriptionImporter.importRecords`; reword to reference `importPrescriptions` being insert-only.

- [ ] **Step 5: Delete the importer and its tests**

```bash
git rm AnxietyWatch/Services/PrescriptionImporter.swift AnxietyWatchTests/PrescriptionImporterTests.swift
```

- [ ] **Step 6: Remove the fetch UI from PrescriptionListView**

In `AnxietyWatch/Views/Prescriptions/PrescriptionListView.swift`:
- Delete state vars at lines 14-16 (`isFetching`, `fetchResult`, `dismissedSyncHint`).
- Delete the entire `if SyncService.shared.isConfigured { … } else if … !dismissedSyncHint { … }` block (lines 27-75) — both the "Fetch from Server" section and the "Sync Not Configured" hint. The existing `Text("No prescriptions yet. Tap + to add one.")` empty state (line 78) already covers the empty case.
- Delete the `fetchFromServer()` function (lines ~159-171).
- The body-top comment (lines 19-22) mentions "the sync-hint gate" — reword to "the empty-state gate and its own Section".

- [ ] **Step 7: Fix test references**

`ReconcileFromServerTests.swift` (prescription cases at ~341, ~381) and `RestoreFromServerTests.swift` may reference `PrescriptionImporter`. Point them at `RestoreFromServer.importPrescriptions` / the reconcile entry point they already exercise; behavior under test (local edit survives; missing prescription is added) is unchanged. `SyncServiceTests.swift:266-343` (`findOrCreateMedication`) should pass unmodified.

- [ ] **Step 8: Build and run affected suites**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/SyncServiceTests -only-testing:AnxietyWatchTests/ReconcileFromServerTests -only-testing:AnxietyWatchTests/RestoreFromServerTests`
Expected: PASS, zero warnings.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: remove server prescription fetch; restore path now self-contained"
```

---

### Task 2: iOS — drop the 12 import-only Prescription fields

**Files:**
- Modify: `AnxietyWatch/Models/Prescription.swift`
- Modify: `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift`
- Modify: `AnxietyWatch/Views/Prescriptions/PrescriptionDetailView.swift:75`
- Modify: `AnxietyWatch/Services/DataExporter.swift:321-334,433-441`
- Modify: `AnxietyWatch/Utilities/DemoSeeder.swift:82-85`, `AnxietyWatch/Utilities/PreviewHelpers.swift:107-115`
- Delete: `AnxietyWatchTests/PrescriptionDaysSupplyTests.swift`
- Test: `AnxietyWatchTests/PrescriptionSupplyCalculatorTests.swift`, `Helpers/ModelFactory.swift`, `ModelEnumTests.swift`, `ModelNormalizationTests.swift`, `DashboardViewModelTests.swift`, `DataExporterTests.swift`

**Interfaces:**
- Consumes: `RestoreFromServer.importPrescriptions` from Task 1 (already core-fields-only).
- Produces: `Prescription` with exactly these stored properties: `id, rxNumber, medicationName, doseMg, doseDescription, quantity, refillsRemaining, dateFilled, estimatedRunOutDate, pharmacyName, notes, dailyDoseCount, medication, pharmacy`. Task 4's server payload mirrors this list.

**SwiftData migration note:** removing attributes is a lightweight migration — existing local rows (including ones originally imported from CapRx) survive with the removed attributes dropped. This is the on-device half of decision 3 ("convert to manual").

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
    /// Total pills/units dispensed
    var quantity: Int
    var refillsRemaining: Int
    var dateFilled: Date
    /// Computed from quantity and daily dose frequency; nil if unknown
    var estimatedRunOutDate: Date?
    /// Denormalized — preserves the name even if the pharmacy is later deleted
    var pharmacyName: String
    var notes: String
    /// User-provided daily dose count when no logging history is available
    var dailyDoseCount: Double?
    var medication: MedicationDefinition?
    var pharmacy: Pharmacy?

    init(
        rxNumber: String,
        medicationName: String,
        doseMg: Double,
        doseDescription: String = "",
        quantity: Int,
        refillsRemaining: Int = 0,
        dateFilled: Date = .now,
        estimatedRunOutDate: Date? = nil,
        pharmacyName: String = "",
        notes: String = "",
        dailyDoseCount: Double? = nil,
        medication: MedicationDefinition? = nil,
        pharmacy: Pharmacy? = nil
    ) {
        self.id = UUID()
        self.rxNumber = rxNumber
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.doseDescription = doseDescription
        self.quantity = quantity
        self.refillsRemaining = refillsRemaining
        self.dateFilled = dateFilled
        self.estimatedRunOutDate = estimatedRunOutDate
        self.pharmacyName = pharmacyName
        self.notes = notes
        self.dailyDoseCount = dailyDoseCount
        self.medication = medication
        self.pharmacy = pharmacy
    }
}
```

- [ ] **Step 2: Simplify the supply calculator**

In `PrescriptionSupplyCalculator.swift`:

`alertStalenessLimitDays` (lines 12-22) — remove the `daysSupply` branch:

```swift
    static func alertStalenessLimitDays(for prescription: Prescription) -> Int {
        if let daily = prescription.dailyDoseCount, daily > 0 {
            let supplyDays = Int(ceil(Double(prescription.quantity) / daily))
            return max(supplyDays * 2, defaultStalenessLimitDays)
        }
        return defaultStalenessLimitDays
    }
```

`alertPrescriptions` (line 126) — replace `let fillDate = rx.lastFillDate ?? rx.dateFilled` with `let fillDate = rx.dateFilled`.

`latestPrescriptionPerMedication` (lines 137-151) — replace both `lastFillDate ?? dateFilled` resolutions with `dateFilled`:

```swift
    static func latestPrescriptionPerMedication(from prescriptions: [Prescription]) -> [Prescription] {
        var latest: [String: Prescription] = [:]
        for rx in prescriptions {
            if let existing = latest[rx.medicationName] {
                if rx.dateFilled > existing.dateFilled {
                    latest[rx.medicationName] = rx
                }
            } else {
                latest[rx.medicationName] = rx
            }
        }
        return Array(latest.values)
    }
```

`effectiveRunOutDate` (lines 155-176) — remove the `daysSupply` branch and its comment:

```swift
    /// Resolves the best available run-out date: stored estimatedRunOutDate,
    /// then quantity-based estimate.
    private static func effectiveRunOutDate(for prescription: Prescription) -> Date? {
        if let stored = prescription.estimatedRunOutDate {
            return stored
        }
        guard let daily = prescription.dailyDoseCount else { return nil }
        return estimateRunOutDate(
            dateFilled: prescription.dateFilled,
            quantity: prescription.quantity,
            dailyDoseCount: daily
        )
    }
```

- [ ] **Step 3: Remove the caprx special-case in PrescriptionDetailView**

Line 75 area — replace

```swift
                LabeledContent("Refills Remaining") {
                    if prescription.importSource == "caprx" && prescription.refillsRemaining == 0 {
                        Text("Unknown").foregroundStyle(.secondary)
                    } else {
                        Text("\(prescription.refillsRemaining)")
                    }
                }
```

with

```swift
                LabeledContent("Refills Remaining", value: "\(prescription.refillsRemaining)")
```

Then grep the rest of the file (and `EditableSupplyFields`) for any display/edit of removed fields (`directions`, `prescriberName`, `ndcCode`, `rxStatus`, `daysSupply`, `patientPay`, `planPay`, `dosageForm`, `drugType`, `lastFillDate`) and delete those rows.

- [ ] **Step 4: Trim DataExporter**

`PrescriptionDTO` (lines 433-441) becomes:

```swift
    struct PrescriptionDTO: Codable {
        let rxNumber: String; let medicationName: String; let doseMg: Double
        let doseDescription: String; let quantity: Int; let refillsRemaining: Int
        let dateFilled: String; let estimatedRunOutDate: String?
        let pharmacyName: String; let notes: String; let dailyDoseCount: Double?
    }
```

and the mapping (lines 321-334) becomes:

```swift
            prescriptions: prescriptionsAll.filter { inRange($0.dateFilled) }.map { rx in
                PrescriptionDTO(rxNumber: rx.rxNumber, medicationName: rx.medicationName,
                                doseMg: rx.doseMg, doseDescription: rx.doseDescription,
                                quantity: rx.quantity, refillsRemaining: rx.refillsRemaining,
                                dateFilled: isoFormatter.string(from: rx.dateFilled),
                                estimatedRunOutDate: rx.estimatedRunOutDate.map { isoFormatter.string(from: $0) },
                                pharmacyName: rx.pharmacyName, notes: rx.notes,
                                dailyDoseCount: rx.dailyDoseCount)
            },
```

The prescriptions CSV block (lines 140-149) already emits only core fields — unchanged.

- [ ] **Step 5: Fix seeds and previews**

`DemoSeeder.swift:82-85` and `PreviewHelpers.swift:107-115`: delete the `prescriberName: "Jane Smith MD",` argument from each `Prescription(` call (compile error will point at them).

- [ ] **Step 6: Delete the daysSupply test suite; compile-fix the rest**

```bash
git rm AnxietyWatchTests/PrescriptionDaysSupplyTests.swift
```

Then build and fix remaining test compile errors by deleting references to removed fields (do not weaken assertions about surviving fields): `Helpers/ModelFactory.swift` (drop removed params from the prescription factory), `ModelEnumTests.swift`, `ModelNormalizationTests.swift`, `DashboardViewModelTests.swift` (uses `lastFillDate`), `DataExporterTests.swift`, `PrescriptionSupplyCalculatorTests.swift` (any `daysSupply`/`lastFillDate` cases — delete those specific tests; the quantity/`dailyDoseCount` cases are the ones that matter now and must still pass).

- [ ] **Step 7: Run the full iOS test suite**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS, zero warnings.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: drop 12 pharmacy-import-only fields from Prescription"
```

---

### Task 3: Server — delete importers, admin UI, cron, and deps

**Files:**
- Delete: `server/walgreens_client.py`, `server/walgreens_sync.py`, `server/caprx_client.py`, `server/caprx_sync.py`, `server/test_walgreens_login.py`, `server/tests/test_walgreens_client.py`, `server/tests/test_walgreens_sync.py`, `server/tests/test_caprx_sync.py`, `server/walgreens-cron`, `server/caprx-cron`, `server/templates/walgreens_settings.html`, `server/templates/caprx_settings.html`
- Modify: `server/admin.py`, `server/templates/base.html:126-127`, `server/Dockerfile`, `server/requirements.txt:13`, `server/.env.example:26`, `server/tests/test_server.py`

**Interfaces:**
- Consumes: nothing from earlier tasks (independent of Tasks 1-2).
- Produces: a server with no pharmacy-import code paths; Task 4 assumes these modules are gone.

- [ ] **Step 1: Delete the importer modules, cron files, templates, and their tests**

```bash
cd server
git rm walgreens_client.py walgreens_sync.py caprx_client.py caprx_sync.py \
       test_walgreens_login.py walgreens-cron caprx-cron \
       templates/walgreens_settings.html templates/caprx_settings.html \
       tests/test_walgreens_client.py tests/test_walgreens_sync.py tests/test_caprx_sync.py
```

- [ ] **Step 2: Remove the admin routes**

In `server/admin.py` delete three complete route functions (decorator through final `return`): `walgreens_settings()` (~L397-483), `caprx_settings()` (~L491-556), and `clear_prescriptions()` (~L629-644 — it exists to reset imported data and redirects to the caprx page). KEEP `_upsert_setting` (L274-279), `_upgrade_legacy_plaintext_setting` (L282-307), and `resmed_settings()` (L310-390). Update the section-header comment at L270-271 to mention only ResMed. KEEP the `DATA_BROWSER` entries for `prescriptions`/`pharmacy_call_logs` (~L1491-1492) — manual data stays browsable.

- [ ] **Step 3: Remove nav links**

`server/templates/base.html` — delete lines 126-127:

```html
            <a href="{{ url_for('admin.walgreens_settings') }}">Walgreens</a>
            <a href="{{ url_for('admin.caprx_settings') }}">CapRx</a>
```

(A stale `url_for` in a template is a runtime 500 — grep templates for `walgreens\|caprx` afterward and expect zero hits.)

- [ ] **Step 4: Trim Dockerfile and requirements**

`server/Dockerfile`:
- Delete: `RUN playwright install --with-deps chromium && playwright install --with-deps chrome`
- Delete: `COPY caprx-cron /etc/cron.d/caprx-sync` and its `RUN chmod 0644 /etc/cron.d/caprx-sync`
- Change the apt line to drop the Walgreens-only headed-Chrome shims (`xvfb`, `xauth`), keeping cron for ResMed:
  `RUN apt-get update && apt-get install -y --no-install-recommends cron && rm -rf /var/lib/apt/lists/*`
- Update the comment above it to `# cron for the scheduled ResMed sync`.
- KEEP the `resmed-cron` COPY/chmod and the CMD (cron still starts).

`server/requirements.txt`: delete the `playwright>=1.61.0` line. KEEP `beautifulsoup4` and `lxml` (used by `genius.py`), `requests`, `cryptography`.

`server/.env.example` line 26: change `(e.g., Walgreens/ResMed passwords configured via the admin UI)` to `(e.g., the ResMed password configured via the admin UI)`.

- [ ] **Step 5: Remove Walgreens-settings tests from test_server.py**

Delete the Walgreens admin-settings encryption tests at ~L1643-1690 (locate by `grep -n -i walgreens server/tests/test_server.py`). Leave the prescription sync tests (~L1708-1764) for Task 4, which changes the payload shape.

- [ ] **Step 6: Run the server suite**

Run: `cd server && python -m pytest tests/ -v`
Expected: PASS (prescription sync tests still pass — the schema/payload hasn't changed yet).

- [ ] **Step 7: Verify no dangling references**

Run: `grep -rn -i 'walgreens\|caprx' server/ --include='*.py' --include='*.html' --include='Dockerfile' --include='*.txt'`
Expected: only `server/alembic/versions/0001_baseline_schema.py` comment/column mentions (handled in Task 4) and possibly `crypto.py`/docstring mentions — reword those docstrings to ResMed-only while here.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat!: remove Walgreens and CapRx prescription importers from server"
```

---

### Task 4: Server — drop import-only columns, purge stored pharmacy credentials

**Files:**
- Create: `server/alembic/versions/0011_remove_pharmacy_import.py`
- Modify: `server/schema.sql:172-196`, `server/server.py:968-1006`, `server/tests/test_server.py`, `server/tests/test_alembic.py:130-…`

**Interfaces:**
- Consumes: Task 3 (importer modules gone — nothing else writes these columns).
- Produces: `prescriptions` table with columns exactly matching the Task 2 Swift model: `rx_number, medication_name, dose_mg, dose_description, quantity, refills_remaining, date_filled, estimated_run_out_date, pharmacy_name, notes, daily_dose_count`; `_upsert_prescriptions` accepting the trimmed camelCase payload from `DataExporter.PrescriptionDTO`.

**Data-safety note (decision 3):** the migration drops columns but deletes NO prescription rows — previously imported prescriptions survive as ordinary rows. The only row deletions are `settings` keys `walgreens_%`/`caprx_%` (encrypted pharmacy credentials, now unreadable dead weight and a credential-retention liability).

- [ ] **Step 1: Write the migration**

Check the current head first: `cd server && alembic heads` → expected `0010` (from `0010_cpap_by_session_fields.py`; if different, adjust `down_revision`). Create `server/alembic/versions/0011_remove_pharmacy_import.py`:

```python
"""Remove pharmacy-import columns and stored pharmacy credentials.

Prescription IMPORT (Walgreens scrape, CapRx claims) is removed; medications
are entered manually. Rows are kept — dropping import_source makes every
surviving prescription an ordinary manual record. Only stored Walgreens/CapRx
credentials are deleted from settings.

Revision ID: 0011
Revises: 0010
"""
from alembic import op

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None

IMPORT_COLUMNS = (
    "prescriber_name", "ndc_code", "rx_status", "last_fill_date",
    "import_source", "walgreens_rx_id", "directions", "days_supply",
    "patient_pay", "plan_pay", "dosage_form", "drug_type",
)


def upgrade():
    op.execute(
        "DELETE FROM settings WHERE key LIKE 'walgreens\\_%' OR key LIKE 'caprx\\_%'"
    )
    for col in IMPORT_COLUMNS:
        op.execute(f"ALTER TABLE prescriptions DROP COLUMN IF EXISTS {col}")


def downgrade():
    # Data is not restorable; recreate the columns empty so old code can run.
    op.execute("""
        ALTER TABLE prescriptions
            ADD COLUMN IF NOT EXISTS prescriber_name TEXT DEFAULT '',
            ADD COLUMN IF NOT EXISTS ndc_code TEXT DEFAULT '',
            ADD COLUMN IF NOT EXISTS rx_status TEXT DEFAULT '',
            ADD COLUMN IF NOT EXISTS last_fill_date TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS import_source TEXT DEFAULT 'manual',
            ADD COLUMN IF NOT EXISTS walgreens_rx_id TEXT,
            ADD COLUMN IF NOT EXISTS directions TEXT DEFAULT '',
            ADD COLUMN IF NOT EXISTS days_supply INTEGER,
            ADD COLUMN IF NOT EXISTS patient_pay DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS plan_pay DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS dosage_form TEXT DEFAULT '',
            ADD COLUMN IF NOT EXISTS drug_type TEXT DEFAULT ''
    """)
```

Before finalizing, compare each recreated column's type/default against the baseline (`server/alembic/versions/0001_baseline_schema.py` and `server/schema.sql:172-196`) and correct any mismatch — the downgrade must recreate exactly what the baseline created.

- [ ] **Step 2: Trim schema.sql**

In `server/schema.sql:172-196`, delete the 12 import-only column definitions from `CREATE TABLE prescriptions`, leaving: `rx_number` (PK), `medication_name`, `dose_mg`, `dose_description`, `quantity`, `refills_remaining`, `date_filled`, `estimated_run_out_date`, `pharmacy_name`, `notes`, `daily_dose_count`.

- [ ] **Step 3: Trim `_upsert_prescriptions` in server.py**

Replace the function at lines 968-1006 with:

```python
    def _upsert_prescriptions(cur, prescriptions):
        for rx in prescriptions:
            cur.execute(
                """INSERT INTO prescriptions (rx_number, medication_name, dose_mg, dose_description,
                       quantity, refills_remaining, date_filled, estimated_run_out_date,
                       pharmacy_name, notes, daily_dose_count)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (rx_number) DO UPDATE SET
                       medication_name = EXCLUDED.medication_name,
                       dose_mg = EXCLUDED.dose_mg,
                       dose_description = EXCLUDED.dose_description,
                       quantity = EXCLUDED.quantity,
                       refills_remaining = EXCLUDED.refills_remaining,
                       date_filled = EXCLUDED.date_filled,
                       estimated_run_out_date = EXCLUDED.estimated_run_out_date,
                       pharmacy_name = EXCLUDED.pharmacy_name,
                       notes = EXCLUDED.notes,
                       daily_dose_count = EXCLUDED.daily_dose_count""",
                (rx["rxNumber"], rx["medicationName"], rx["doseMg"],
                 rx.get("doseDescription", ""), rx["quantity"],
                 rx.get("refillsRemaining", 0), rx["dateFilled"],
                 rx.get("estimatedRunOutDate"), rx.get("pharmacyName", ""),
                 rx.get("notes", ""), rx.get("dailyDoseCount")),
            )
        return len(prescriptions)
```

(Unknown keys in an incoming payload are simply ignored by `.get`-style access — an older app build sending `importSource` etc. still syncs cleanly.)

- [ ] **Step 4: Update server tests**

- `server/tests/test_server.py` (~L1708-1764): trim prescription sync test payloads/assertions to the 11 core fields; keep `test_sync_prescriptions` and `test_sync_prescriptions_idempotent` semantics.
- `server/tests/test_alembic.py:130-…`: delete the `# Walgreens/CapRx columns on prescriptions` assertion block; if the file asserts full column lists, update them to the trimmed set.

- [ ] **Step 5: Run migration + suite**

Run: `cd server && python -m pytest tests/ -v` (the alembic test exercises upgrade-to-head against a scratch DB).
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat!: drop pharmacy-import columns; purge stored pharmacy credentials (0011)"
```

---

### Task 5: Documentation sweep

**Files:**
- Modify: `README.md:23,76,83,165-166,192`, `docs/FEATURES.md:73`, `PROJECT_FUTURE_PLAN.md:15,29,125`
- Delete: `docs/caprx-api-fields.md`

**Interfaces:** none — pure docs.

Living docs only; per Global Constraints, historical plans/timeline keep their pharmacy mentions. Repo `CLAUDE.md` needs no edit (its pharmacy/prescription mentions are all manual features that stay: OCR, MapKit search, models, fixture rules).

- [ ] **Step 1: README.md**

- Line 23: delete `pharmacy benefit (CapRx) integration, ` from the feature run-on sentence.
- Line 76: change the Prescription-management row to
  `| **Prescription management** | Manual entry with supply tracking, refill alerts, OCR label scanning, pharmacy search with call logging |`
- Line 83: delete the clause `, and CapRx pharmacy-benefit sync needs a Walgreens account plus the headless-browser scrape path on the server` (adjust the sentence to end after the watch clause; keep "The simulator covers everything else.").
- Lines 165-166 (architecture diagram): change
  `│   Alembic migrations · EDF leak parser · CapRx /      │` and
  `│   ResMed myAir clients · optional Claude analysis     │` to
  `│   Alembic migrations · EDF leak parser · ResMed       │` and
  `│   myAir client · optional Claude analysis             │`
  (keep the box width — pad with spaces to the same column).
- Line 192: change `and CapRx/Walgreens/ResMed myAir import pipelines.` to `and the ResMed myAir import pipeline.`

- [ ] **Step 2: docs/FEATURES.md**

Delete line 73: `- **CapRx claims import** -- automated prescription sync from pharmacy benefit data via the sync server`. If an adjacent bullet describes manual prescription entry, no replacement is needed; otherwise add `- **Manual prescription entry** -- with OCR label-scan prefill, supply tracking, and refill alerts`.

- [ ] **Step 3: PROJECT_FUTURE_PLAN.md**

- Line 15: delete `, and integration with pharmacy prescription data via CapRx` from the medication-tracking bullet.
- Line 29: change `a Flask/PostgreSQL sync server with prescription import from CapRx, providing a web-accessible data mirror` to `a Flask/PostgreSQL sync server providing a web-accessible data mirror`.
- Line 125: delete the bullet `Store patientPay, planPay, dosageForm, and drugType from CapRx claims (currently extracted and discarded).`

- [ ] **Step 4: Delete the CapRx field reference doc**

```bash
git rm docs/caprx-api-fields.md
```

- [ ] **Step 5: Sweep for stragglers in living docs**

Run: `grep -rn -i 'walgreens\|caprx\|pharmacy benefit\|pbm' README.md REQUIREMENTS.md CLAUDE.md PROJECT_FUTURE_PLAN.md AGENTS.md docs/FEATURES.md .github/copilot-instructions.md`
Expected: zero hits (fix any found; `AGENTS.md`/`copilot-instructions.md` mirror CLAUDE.md — apply the same treatment if they mention importers).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: remove pharmacy prescription import from living docs"
```

---

### Task 6: Final verification

**Files:** none new — whole-repo checks.

- [ ] **Step 1: Full iOS suite + lint**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS, zero warnings (warnings are errors in CI).

- [ ] **Step 2: Full server suite**

Run: `cd server && python -m pytest tests/ -v`
Expected: PASS.

- [ ] **Step 3: Repo-wide grep audit**

Run: `grep -rn -i 'walgreens\|caprx' --include='*.swift' --include='*.py' --include='*.html' --include='*.yml' --include='*.txt' --include='Dockerfile' . | grep -v -E '_work/|\.build/|alembic/versions/0001|alembic/versions/0011'`
Expected: zero hits. (`PrescriptionLabelScanner.swift` matches `WALGREENS` in its `knownPharmacyNames` OCR list — that is a pharmacy *name* for label parsing, not import; it stays. If it appears in the grep, it is the one allowed exception.)

- [ ] **Step 4: Manual smoke (simulator)**

Launch the app: Medications → Prescriptions shows existing rows with no "Fetch from Server" button and no sync hint; + → Add Prescription (with Scan Label) works; Dashboard supply alerts render.

- [ ] **Step 5: Commit any test-only stragglers, then hand off**

Use the superpowers:finishing-a-development-branch skill: merge/PR decision, and note the deploy step — the server needs an image rebuild + restart; `alembic upgrade head` runs automatically in the container CMD and will purge the stored pharmacy credentials on first boot.

---

## Self-Review Notes

- **Spec coverage:** importers (server) ✔ Task 3; iOS fetch pipeline ✔ Task 1; full field cleanup ✔ Tasks 2+4; existing rows kept / credentials purged ✔ Task 4; docs ✔ Task 5; manual entry preserved ✔ untouched (verified: AddPrescriptionView/scanner have zero references to removed fields).
- **Type consistency:** `Prescription` init in Task 2 matches the call in Task 1's `importPrescriptions` (core-fields subset with defaults) and Task 4's server column list; `SyncService.findOrCreateMedication(name:doseMg:in:)` signature unchanged for SyncServiceTests.
- **Ordering:** Tasks 1→2 must run in order (importer deletion before field drop keeps every intermediate state compiling); Tasks 3→4 in order; Task 5 anytime after 4; each task leaves both suites green.
