import SwiftData
import SwiftUI

struct AddMedicationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var defaultDoseMg: Double = 0
    @State private var category = ""

    private let categories = ["SSRI", "SNRI", "Benzodiazepine", "Beta Blocker", "Z-Drug", "Supplement", "Other"]

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
        }
    }

    private func save() {
        let med = MedicationDefinition(
            name: name.trimmingCharacters(in: .whitespaces),
            defaultDoseMg: defaultDoseMg,
            category: category
        )
        modelContext.insert(med)
        dismiss()
    }
}
