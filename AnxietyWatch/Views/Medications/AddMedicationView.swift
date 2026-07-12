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
    @State private var cnsDepressantClass: CNSDepressantClass?
    @State private var userToggledCNSDepressantClass = false

    private let categories = [
        "SSRI", "SNRI", "Benzodiazepine", "Opioid", "Stimulant",
        "Beta Blocker", "Z-Drug", "Supplement", "Other",
    ]

    /// Categories that default to prompting for anxiety on dose log.
    private static let promptCategories: Set<String> = ["Benzodiazepine", "Stimulant"]

    /// Display names for the CNS-depressant class picker (spec §14.1 classes).
    private static let cnsDepressantClassLabels: [CNSDepressantClass: String] = [
        .benzodiazepine: "Benzodiazepine / Z-drug",
        .opioidIR: "Opioid (immediate release)",
        .opioidER: "Opioid (extended release)",
        .methadoneOrUnknownLongActing: "Methadone / long-acting",
    ]

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

                Section {
                    Picker("CNS depressant class", selection: cnsDepressantClassBinding) {
                        Text("None").tag(CNSDepressantClass?.none)
                        ForEach(CNSDepressantClass.allCases, id: \.self) { depressantClass in
                            Text(Self.cnsDepressantClassLabels[depressantClass] ?? depressantClass.rawValue)
                                .tag(CNSDepressantClass?.some(depressantClass))
                        }
                    }
                } header: {
                    Text("CNS Depressant Class")
                } footer: {
                    Text("Determines the overnight respiratory-depression monitoring window. "
                        + "Defaults from the name and category — override if the default is wrong.")
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
                updateCNSDepressantClassDefault()
            }
            .onChange(of: name) { _, _ in
                updateCNSDepressantClassDefault()
            }
        }
    }

    /// Tracks whether the user has explicitly touched the picker, so a later
    /// name/category edit never silently overwrites their explicit choice
    /// (mirrors `userToggledPrompt` above). `AddMedicationView` only ever
    /// creates new medications today (no edit mode exists), so this guards
    /// within a single creation session; it's the same guard an eventual
    /// edit flow would need against overwriting a persisted explicit value.
    private var cnsDepressantClassBinding: Binding<CNSDepressantClass?> {
        Binding(
            get: { cnsDepressantClass },
            set: { cnsDepressantClass = $0; userToggledCNSDepressantClass = true }
        )
    }

    private func updateCNSDepressantClassDefault() {
        guard !userToggledCNSDepressantClass else { return }
        cnsDepressantClass = CNSDepressantClassifier.classify(name: name, category: category)
    }

    private func save() {
        let med = MedicationDefinition(
            name: name.trimmingCharacters(in: .whitespaces),
            defaultDoseMg: defaultDoseMg,
            category: category,
            promptAnxietyOnLog: promptAnxietyOnLog,
            cnsDepressantClass: cnsDepressantClass?.rawValue
        )
        modelContext.insert(med)
        dismiss()
    }
}
