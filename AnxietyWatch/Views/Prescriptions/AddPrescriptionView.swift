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
    @State private var quantityText: String
    @State private var refillsRemaining: Int
    @State private var dailyDoseCountText: String
    @State private var selectedPharmacyID: UUID?
    @State private var notes: String

    // Inline "Add New" medication fields
    @State private var addingNewMed = false
    @State private var newMedName: String
    @State private var newMedDose: Double = 0
    @State private var newMedCategory = ""

    private let categories = [
        "SSRI", "SNRI", "Benzodiazepine", "Beta Blocker",
        "Z-Drug", "Supplement", "Other"
    ]

    // MARK: - Pre-fill init

    init(
        prefillRxNumber: String? = nil,
        prefillMedicationName: String? = nil,
        prefillDose: Double? = nil,
        prefillQuantity: Int? = nil,
        prefillRefills: Int? = nil,
        prefillPharmacyName: String? = nil,
        prefillDateFilled: Date? = nil
    ) {
        _rxNumber = State(initialValue: prefillRxNumber ?? "")
        _dateFilled = State(initialValue: prefillDateFilled ?? .now)
        _doseMg = State(initialValue: prefillDose ?? 0)
        _doseDescription = State(initialValue: "")
        _quantityText = State(
            initialValue: prefillQuantity.map(String.init) ?? ""
        )
        _refillsRemaining = State(initialValue: prefillRefills ?? 0)
        _dailyDoseCountText = State(initialValue: "")
        _notes = State(initialValue: "")
        _newMedName = State(initialValue: prefillMedicationName ?? "")

        // selectedMedID and selectedPharmacyID are resolved in onAppear
        // because @Query results aren't available during init
        _selectedMedID = State(initialValue: nil)
        _selectedPharmacyID = State(initialValue: nil)

        // If a medication name was prefilled but won't match an existing med,
        // start in "add new" mode
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
                supplySection
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
        }
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
        TextField("Dose (mg)", value: $doseMg, format: .number)
            .keyboardType(.decimalPad)
        Picker("Category", selection: $newMedCategory) {
            Text("None").tag("")
            ForEach(categories, id: \.self) { cat in
                Text(cat).tag(cat)
            }
        }
    }

    private var supplySection: some View {
        Section("Supply") {
            TextField("Quantity Dispensed", text: $quantityText)
                .keyboardType(.numberPad)
            Stepper("Refills Remaining: \(refillsRemaining)", value: $refillsRemaining, in: 0...99)
            TextField("Daily Dose Count", text: $dailyDoseCountText)
                .keyboardType(.decimalPad)
                .textContentType(.none)
                .overlay(alignment: .trailing) {
                    if dailyDoseCountText.isEmpty {
                        Text("e.g. 2 for twice daily")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
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

    private var scanPlaceholderSection: some View {
        Section {
            Button {
                // Phase 4 will wire this up
            } label: {
                Label("Scan Label", systemImage: "camera")
            }
            .disabled(true)
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
        !medicationName.isEmpty && (Int(quantityText) ?? 0) > 0
    }

    private func save() {
        let quantity = Int(quantityText) ?? 0
        let dailyDose = Double(dailyDoseCountText)

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

        // Compute run-out date
        let runOut: Date? = dailyDose.flatMap {
            PrescriptionSupplyCalculator.estimateRunOutDate(
                dateFilled: dateFilled,
                quantity: quantity,
                dailyDoseCount: $0
            )
        }

        let rx = Prescription(
            rxNumber: rxNumber.trimmingCharacters(in: .whitespaces),
            medicationName: medicationName,
            doseMg: doseMg,
            doseDescription: doseDescription.trimmingCharacters(in: .whitespaces),
            quantity: quantity,
            refillsRemaining: refillsRemaining,
            dateFilled: dateFilled,
            estimatedRunOutDate: runOut,
            pharmacyName: pharm?.name ?? "",
            notes: notes.trimmingCharacters(in: .whitespaces),
            dailyDoseCount: dailyDose,
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
