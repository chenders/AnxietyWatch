import SwiftUI
import SwiftData

struct PharmacyDetailView: View {
    @Bindable var pharmacy: Pharmacy
    @Environment(\.modelContext) private var modelContext
    @State private var showingLogCall = false

    var body: some View {
        Form {
            infoSection
            prescriptionsSection
            callLogSection
            actionsSection
        }
        .navigationTitle(pharmacy.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingLogCall) {
            LogCallSheet(pharmacy: pharmacy)
        }
    }

    // MARK: - Sections

    private var infoSection: some View {
        Section("Info") {
            EditableField("Name", text: $pharmacy.name)
            EditableField("Address", text: $pharmacy.address)
            EditableField("Phone", text: $pharmacy.phoneNumber)
            TextField("Notes", text: $pharmacy.notes, axis: .vertical)
                .lineLimit(3...6)
        }
    }

    private var prescriptionsSection: some View {
        Section("Prescriptions") {
            let prescriptions = pharmacy.prescriptions
            if prescriptions.isEmpty {
                Text("No prescriptions linked.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(prescriptions) { rx in
                    NavigationLink(value: rx) {
                        VStack(alignment: .leading) {
                            Text(rx.medicationName).font(.subheadline)
                            Text("Rx #\(rx.rxNumber)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var callLogSection: some View {
        Section("Call Log") {
            let logs = pharmacy.callLogs.sorted { $0.timestamp > $1.timestamp }
            if logs.isEmpty {
                Text("No calls logged.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logs.prefix(20)) { log in
                    CallLogRow(log: log)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                PharmacyCallService.shared.initiateCall(
                    to: pharmacy,
                    modelContext: modelContext
                )
            } label: {
                Label("Call Pharmacy", systemImage: "phone.fill")
            }
            .disabled(pharmacy.phoneNumber.isEmpty)

            Button {
                showingLogCall = true
            } label: {
                Label("Log a Call", systemImage: "note.text")
            }
        }
    }
}

// MARK: - Editable Field Helper

private struct EditableField: View {
    let label: String
    @Binding var text: String

    init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    var body: some View {
        TextField(label, text: $text)
    }
}

// MARK: - Call Log Row

private struct CallLogRow: View {
    let log: PharmacyCallLog

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(log.direction.capitalized)
                    .font(.subheadline)
                Text(log.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !log.notes.isEmpty {
                    Text(log.notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let seconds = log.durationSeconds {
                Text(formattedDuration(seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconName: String {
        switch log.direction {
        case "incoming": return "phone.arrow.down.left"
        case "outgoing", "connected", "completed": return "phone.arrow.up.right"
        case "attempted": return "phone.badge.waveform"
        default: return "phone"
        }
    }

    private var iconColor: Color {
        switch log.direction {
        case "completed": return .green
        case "attempted": return .orange
        default: return .blue
        }
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Log Call Sheet

private struct LogCallSheet: View {
    let pharmacy: Pharmacy
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var direction = "outgoing"
    @State private var notes = ""

    private let directions = ["incoming", "outgoing"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Call Details") {
                    Picker("Direction", selection: $direction) {
                        ForEach(directions, id: \.self) { dir in
                            Text(dir.capitalized).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Log Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        PharmacyCallService.shared.logManualCall(
                            pharmacy: pharmacy,
                            direction: direction,
                            notes: notes.trimmingCharacters(in: .whitespaces),
                            modelContext: modelContext
                        )
                        dismiss()
                    }
                }
            }
        }
    }
}
