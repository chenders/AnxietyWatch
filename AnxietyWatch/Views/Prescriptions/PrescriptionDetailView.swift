import SwiftUI
import SwiftData

struct PrescriptionDetailView: View {
    @Bindable var prescription: Prescription
    @State private var isEditing = false

    var body: some View {
        List {
            prescriptionSection
            medicationSection
            supplySection
            pharmacySection
            notesSection
        }
        .navigationTitle(prescription.medicationName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Done" : "Edit") {
                    isEditing.toggle()
                }
            }
        }
    }

    // MARK: - Sections

    private var prescriptionSection: some View {
        Section("Prescription") {
            if isEditing {
                // Rx number is immutable once set — it's the sync primary key
                if prescription.rxNumber.isEmpty {
                    TextField("Rx Number", text: $prescription.rxNumber)
                } else {
                    LabeledContent("Rx Number", value: prescription.rxNumber)
                }
                DatePicker(
                    "Date Filled",
                    selection: $prescription.dateFilled,
                    displayedComponents: .date
                )
            } else {
                LabeledContent("Rx Number", value: prescription.rxNumber.isEmpty ? "—" : prescription.rxNumber)
                LabeledContent("Date Filled") {
                    Text(prescription.dateFilled, format: .dateTime.month().day().year())
                }
            }
        }
    }

    private var medicationSection: some View {
        Section("Medication") {
            if isEditing {
                TextField("Medication Name", text: $prescription.medicationName)
                TextField("Dose (mg)", value: $prescription.doseMg, format: .number)
                    .keyboardType(.decimalPad)
                TextField("Dose Description", text: $prescription.doseDescription)
            } else {
                LabeledContent("Medication", value: prescription.medicationName)
                LabeledContent("Dose") {
                    Text(doseDisplay)
                }
            }
        }
    }

    private var supplySection: some View {
        Section("Supply") {
            if isEditing {
                EditableSupplyFields(prescription: prescription)
            } else {
                LabeledContent("Quantity", value: "\(prescription.quantity)")
                LabeledContent("Refills Remaining", value: "\(prescription.refillsRemaining)")
                LabeledContent("Daily Doses") {
                    if let count = prescription.dailyDoseCount {
                        Text(String(format: "%.1f", count))
                    } else {
                        Text("Unknown").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Supply Status") {
                    SupplyBadge(prescription: prescription)
                }
                LabeledContent("Run-out Date") {
                    if let date = prescription.estimatedRunOutDate {
                        Text(date, format: .dateTime.month().day().year())
                    } else {
                        Text("Unknown").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var pharmacySection: some View {
        Section("Pharmacy") {
            if isEditing {
                TextField("Pharmacy Name", text: $prescription.pharmacyName)
            } else if prescription.pharmacyName.isEmpty {
                Text("No pharmacy").foregroundStyle(.secondary)
            } else {
                if let pharmacy = prescription.pharmacy {
                    NavigationLink {
                        PharmacyDetailFromPrescription(pharmacy: pharmacy)
                    } label: {
                        Text(pharmacy.name)
                    }
                } else {
                    Text(prescription.pharmacyName)
                }
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            if isEditing {
                TextField("Notes", text: $prescription.notes, axis: .vertical)
                    .lineLimit(3...6)
            } else if prescription.notes.isEmpty {
                Text("No notes").foregroundStyle(.secondary)
            } else {
                Text(prescription.notes)
            }
        }
    }

    // MARK: - Helpers

    private var doseDisplay: String {
        let mgString = String(format: "%.1f mg", prescription.doseMg)
        if prescription.doseDescription.isEmpty {
            return mgString
        }
        return "\(mgString) — \(prescription.doseDescription)"
    }
}

// MARK: - Editable Supply Fields (extracted to keep parent under ~100 lines)

private struct EditableSupplyFields: View {
    @Bindable var prescription: Prescription
    @State private var quantityText: String = ""
    @State private var dailyDoseText: String = ""

    var body: some View {
        TextField("Quantity", text: $quantityText)
            .keyboardType(.numberPad)
            .onAppear {
                quantityText = "\(prescription.quantity)"
                if let d = prescription.dailyDoseCount {
                    dailyDoseText = String(format: "%.1f", d)
                }
            }
            .onChange(of: quantityText) { _, newValue in
                if let q = Int(newValue) { prescription.quantity = q }
                recomputeRunOut()
            }

        Stepper(
            "Refills: \(prescription.refillsRemaining)",
            value: $prescription.refillsRemaining,
            in: 0...99
        )

        TextField("Daily Dose Count", text: $dailyDoseText)
            .keyboardType(.decimalPad)
            .onChange(of: dailyDoseText) { _, newValue in
                prescription.dailyDoseCount = Double(newValue)
                recomputeRunOut()
            }
    }

    private func recomputeRunOut() {
        guard let daily = prescription.dailyDoseCount, daily > 0 else {
            prescription.estimatedRunOutDate = nil
            return
        }
        prescription.estimatedRunOutDate = PrescriptionSupplyCalculator.estimateRunOutDate(
            dateFilled: prescription.dateFilled,
            quantity: prescription.quantity,
            dailyDoseCount: daily
        )
    }
}

// MARK: - Minimal pharmacy detail shown when tapping pharmacy from prescription

/// A lightweight pharmacy view reachable from the prescription detail.
/// Avoids a dependency on the full Pharmacy views module.
private struct PharmacyDetailFromPrescription: View {
    let pharmacy: Pharmacy

    var body: some View {
        List {
            Section("Contact") {
                LabeledContent("Phone", value: pharmacy.phoneNumber.isEmpty ? "—" : pharmacy.phoneNumber)
                if !pharmacy.address.isEmpty {
                    LabeledContent("Address", value: pharmacy.address)
                }
            }
            if !pharmacy.notes.isEmpty {
                Section("Notes") {
                    Text(pharmacy.notes)
                }
            }
        }
        .navigationTitle(pharmacy.name)
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    let context = ModelContext(container)
    let rx = try! context.fetch(FetchDescriptor<Prescription>()).first!
    NavigationStack {
        PrescriptionDetailView(prescription: rx)
    }
    .modelContainer(container)
}
#endif
