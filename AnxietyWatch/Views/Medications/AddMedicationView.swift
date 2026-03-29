import SwiftData
import SwiftUI

struct AddMedicationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var defaultDoseMg: Double = 0
    @State private var category = ""
    @State private var promptAnxietyOnLog = false
    @State private var userToggledPrompt = false

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
                    Toggle("Prompt anxiety rating on dose", isOn: Binding(
                        get: { promptAnxietyOnLog },
                        set: { promptAnxietyOnLog = $0; userToggledPrompt = true }
                    ))
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
                if !userToggledPrompt {
                    promptAnxietyOnLog = Self.promptCategories.contains(newValue)
                }
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
