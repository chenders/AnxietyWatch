import SwiftUI
import SwiftData

struct AddPrescriptionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(
        filter: #Predicate<MedicationDefinition> { $0.isActive },
        sort: \MedicationDefinition.name
    )
    private var activeMeds: [MedicationDefinition]

    @Query(
        filter: #Predicate<Pharmacy> { $0.isActive },
        sort: \Pharmacy.name
    )
    private var pharmacies: [Pharmacy]

    // MARK: - Form state

    @State private var rxNumber: String
    @State private var dateFilled: Date
    @State private var selectedMedID: UUID?
    @State private var doseMg: Double
    @State private var doseDescription: String
    @State private var selectedPharmacyID: UUID?
    @State private var notes: String

    // Inline "Add New" medication fields
    @State private var addingNewMed = false
    @State private var newMedName: String
    @State private var newMedCategory = ""

    /// Fields that arrived from an OCR scan with low confidence — surfaced as
    /// an inline warning next to the field so a misread dose/Rx digit isn't
    /// silently accepted just because it pre-populated the form (F-042).
    @State private var lowConfidenceScannedFields: Set<PrescriptionLabelScanner.Field> = []

    private let categories = [
        "SSRI", "SNRI", "Benzodiazepine", "Beta Blocker",
        "Z-Drug", "Supplement", "Other"
    ]

    // MARK: - Pre-fill init

    init(
        prefillRxNumber: String? = nil,
        prefillMedicationName: String? = nil,
        prefillDose: Double? = nil,
        prefillDateFilled: Date? = nil
    ) {
        _rxNumber = State(initialValue: prefillRxNumber ?? "")
        _dateFilled = State(initialValue: prefillDateFilled ?? .now)
        _doseMg = State(initialValue: prefillDose ?? 0)
        _doseDescription = State(initialValue: "")
        _notes = State(initialValue: "")
        _newMedName = State(initialValue: prefillMedicationName ?? "")

        _selectedMedID = State(initialValue: nil)
        _selectedPharmacyID = State(initialValue: nil)

        // Prefilled medication names won't match an existing definition,
        // so start in "add new" mode to let the user create one
        if prefillMedicationName != nil {
            _addingNewMed = State(initialValue: true)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                prescriptionSection
                medicationSection
                pharmacySection
                notesSection
                scanPlaceholderSection
            }
            .navigationTitle("Add Prescription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    // MARK: - Sections

    private var prescriptionSection: some View {
        Section("Prescription") {
            TextField("Rx Number", text: $rxNumber)
                .onChange(of: rxNumber) { _, _ in lowConfidenceScannedFields.remove(.rxNumber) }
            if lowConfidenceScannedFields.contains(.rxNumber) {
                lowConfidenceWarning("Rx number was read with low confidence — verify against the label.")
            }
            DatePicker("Date Filled", selection: $dateFilled, displayedComponents: .date)
        }
    }

    private var medicationSection: some View {
        Section("Medication") {
            if addingNewMed {
                newMedicationFields
            } else {
                medicationPicker
            }

            TextField("Dose Description", text: $doseDescription)
                .textContentType(.none)
                // A manual edit means the user has taken ownership of the
                // value, so the low-confidence OCR warning no longer applies.
                .onChange(of: doseDescription) { _, _ in lowConfidenceScannedFields.remove(.dose) }
            if lowConfidenceScannedFields.contains(.dose) {
                lowConfidenceWarning("Dose was read with low confidence — verify against the label.")
            }
        }
    }

    /// Inline "verify this OCR reading" caption for a low-confidence scanned field.
    @ViewBuilder
    private func lowConfidenceWarning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityLabel("Warning. \(text)")
    }

    @ViewBuilder
    private var medicationPicker: some View {
        Picker("Medication", selection: $selectedMedID) {
            Text("Select...").tag(UUID?.none)
            ForEach(activeMeds) { med in
                Text(med.name).tag(Optional(med.id))
            }
            Text("Add New...").tag(UUID?(addNewSentinel))
        }
        .onChange(of: selectedMedID) { _, newValue in
            if newValue == addNewSentinel {
                addingNewMed = true
                selectedMedID = nil
            } else if let id = newValue,
                      let med = activeMeds.first(where: { $0.id == id }) {
                doseMg = med.defaultDoseMg
            }
        }

        TextField("Dose (mg)", value: $doseMg, format: .number)
            .keyboardType(.decimalPad)
    }

    @ViewBuilder
    private var newMedicationFields: some View {
        HStack {
            Text("New Medication")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Choose Existing") {
                addingNewMed = false
                selectedMedID = nil
            }
            .font(.caption)
        }

        TextField("Name", text: $newMedName)
            .onChange(of: newMedName) { _, _ in lowConfidenceScannedFields.remove(.medicationName) }
        if lowConfidenceScannedFields.contains(.medicationName) {
            lowConfidenceWarning("Medication name was read with low confidence — verify against the label.")
        }
        TextField("Dose (mg)", value: $doseMg, format: .number)
            .keyboardType(.decimalPad)
        Picker("Category", selection: $newMedCategory) {
            Text("None").tag("")
            ForEach(categories, id: \.self) { cat in
                Text(cat).tag(cat)
            }
        }
    }

    private var pharmacySection: some View {
        Section("Pharmacy") {
            Picker("Pharmacy", selection: $selectedPharmacyID) {
                Text("None").tag(UUID?.none)
                ForEach(pharmacies) { pharm in
                    Text(pharm.name).tag(Optional(pharm.id))
                }
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(3...6)
        }
    }

    @State private var showingScanner = false

    private var scanPlaceholderSection: some View {
        Section {
            Button {
                showingScanner = true
            } label: {
                Label("Scan Label", systemImage: "camera")
            }
            .sheet(isPresented: $showingScanner) {
                PrescriptionScannerView(onScanComplete: { scannedData in
                    // Carry each populated field's low-confidence flag through
                    // to the form so the pre-filled value is visibly marked
                    // "verify" rather than looking authoritative (F-042).
                    var flagged: Set<PrescriptionLabelScanner.Field> = []
                    if let rx = scannedData.rxNumber {
                        rxNumber = rx
                        if scannedData.isLowConfidence(.rxNumber) { flagged.insert(.rxNumber) }
                    }
                    if let name = scannedData.medicationName {
                        newMedName = name
                        addingNewMed = true
                        if scannedData.isLowConfidence(.medicationName) { flagged.insert(.medicationName) }
                    }
                    if let dose = scannedData.dose {
                        doseDescription = dose
                        if scannedData.isLowConfidence(.dose) { flagged.insert(.dose) }
                        let lower = dose.lowercased()
                        if let numeric = Double(dose.filter { $0.isNumber || $0 == "." }) {
                            if lower.contains("mcg") {
                                doseMg = numeric / 1000
                            } else if lower.contains("ml") {
                                doseMg = 0  // ml not convertible to mg
                            } else {
                                doseMg = numeric
                            }
                        }
                    }
                    if let date = scannedData.dateFilled { dateFilled = date }
                    lowConfidenceScannedFields = flagged
                })
            }
        }
    }

    // MARK: - Validation & Save

    private var medicationName: String {
        if addingNewMed {
            return newMedName.trimmingCharacters(in: .whitespaces)
        }
        if let id = selectedMedID,
           let med = activeMeds.first(where: { $0.id == id }) {
            return med.name
        }
        return ""
    }

    private var canSave: Bool {
        !medicationName.isEmpty
    }

    private func save() {
        // Resolve or create MedicationDefinition
        var medDef: MedicationDefinition?
        if addingNewMed {
            let newDef = MedicationDefinition(
                name: medicationName,
                defaultDoseMg: doseMg,
                category: newMedCategory
            )
            modelContext.insert(newDef)
            medDef = newDef
        } else if let id = selectedMedID {
            medDef = activeMeds.first { $0.id == id }
        }

        // Resolve pharmacy
        let pharm = pharmacies.first { $0.id == selectedPharmacyID }

        let rx = Prescription(
            rxNumber: rxNumber.trimmingCharacters(in: .whitespaces),
            medicationName: medicationName,
            doseMg: doseMg,
            doseDescription: doseDescription.trimmingCharacters(in: .whitespaces),
            dateFilled: dateFilled,
            pharmacyName: pharm?.name ?? "",
            notes: notes.trimmingCharacters(in: .whitespaces),
            medication: medDef,
            pharmacy: pharm
        )
        modelContext.insert(rx)
        dismiss()
    }

    /// Sentinel UUID used to detect "Add New..." selection in the Picker.
    private var addNewSentinel: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    }
}
