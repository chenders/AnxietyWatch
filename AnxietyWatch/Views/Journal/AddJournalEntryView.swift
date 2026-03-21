import SwiftData
import SwiftUI

struct AddJournalEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var severity = Constants.defaultSeverity
    @State private var notes = ""
    @State private var tagText = ""
    @State private var tags: [String] = []
    @State private var timestamp = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section("Severity") {
                    VStack {
                        Text("\(severity)")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(severityColor)
                        Slider(
                            value: Binding(
                                get: { Double(severity) },
                                set: { severity = Int($0.rounded()) }
                            ),
                            in: 1...10,
                            step: 1
                        )
                        .tint(severityColor)
                        HStack {
                            Text("Calm").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("Severe").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 100)
                }

                Section("Tags") {
                    ForEach(tags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                            Spacer()
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    HStack {
                        TextField("Add tag...", text: $tagText)
                            .onSubmit { addTag() }
                        Button("Add") { addTag() }
                            .disabled(tagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("When") {
                    DatePicker("Time", selection: $timestamp)
                }
            }
            .navigationTitle("New Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private var severityColor: Color {
        switch severity {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespaces).lowercased()
        if !tag.isEmpty && !tags.contains(tag) {
            tags.append(tag)
        }
        tagText = ""
    }

    private func save() {
        let entry = AnxietyEntry(
            timestamp: timestamp,
            severity: severity,
            notes: notes,
            tags: tags
        )
        modelContext.insert(entry)
        dismiss()
    }
}
