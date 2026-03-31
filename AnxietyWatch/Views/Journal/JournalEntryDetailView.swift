import SwiftData
import SwiftUI

struct JournalEntryDetailView: View {
    @Bindable var entry: AnxietyEntry
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("Severity") {
                if isEditing {
                    VStack {
                        Text("\(entry.severity)")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(Color.severity(entry.severity))
                        Slider(
                            value: Binding(
                                get: { Double(entry.severity) },
                                set: { entry.severity = Int($0.rounded()) }
                            ),
                            in: 1...10,
                            step: 1
                        )
                        .tint(Color.severity(entry.severity))
                    }
                } else {
                    HStack {
                        SeverityBadge(severity: entry.severity)
                        Text("\(entry.severity) / 10")
                            .font(.title3)
                    }
                }
            }

            Section("Notes") {
                if isEditing {
                    TextEditor(text: $entry.notes)
                        .frame(minHeight: 100)
                } else if entry.notes.isEmpty {
                    Text("No notes")
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.notes)
                }
            }

            if !entry.tags.isEmpty {
                Section("Tags") {
                    ForEach(entry.tags, id: \.self) { tag in
                        Text(tag)
                    }
                }
            }

            Section("Logged") {
                if isEditing {
                    DatePicker("Time", selection: $entry.timestamp)
                } else {
                    Text(entry.timestamp, format: .dateTime)
                }
            }
        }
        .navigationTitle("Entry Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Done" : "Edit") {
                    isEditing.toggle()
                }
            }
        }
    }

}
