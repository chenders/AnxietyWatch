import SwiftUI
import SwiftData

/// Sheet presented when logging a dose for a medication with `promptAnxietyOnLog`.
/// Captures anxiety severity, optional notes, and PRN/scheduled status.
/// Also used for the 30-minute follow-up (with `isFollowUp: true`).
struct DoseAnxietyPromptView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let medication: MedicationDefinition
    /// If non-nil, this is a follow-up for an existing dose (no PRN toggle, no dose creation).
    let existingDose: MedicationDose?

    @State private var severity: Double = 5
    @State private var notes = ""
    @State private var isPRN = true

    private var isFollowUp: Bool { existingDose != nil }

    var body: some View {
        NavigationStack {
            Form {
                if !isFollowUp {
                    Section {
                        Toggle("Taken as needed (PRN)", isOn: $isPRN)
                    } footer: {
                        Text(isPRN ? "As-needed / situational use" : "Scheduled / routine dose")
                    }
                }

                Section("Anxiety Level") {
                    VStack(spacing: 8) {
                        Text("\(Int(severity))")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(severityColor)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: Int(severity))

                        Slider(value: $severity, in: 1...10, step: 1)
                            .tint(severityColor)

                        HStack {
                            Text("Minimal").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("Severe").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Notes (optional)") {
                    TextField("How are you feeling?", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(isFollowUp ? "30-Min Follow-Up" : "Log \(medication.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isFollowUp ? "Log" : "Log Dose") {
                        save()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !isFollowUp {
                    Button("Skip — just log the dose") {
                        skipAndLogDose()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Actions

    private func save() {
        let dose: MedicationDose
        if let existingDose {
            dose = existingDose
        } else {
            dose = MedicationDose(
                medicationName: medication.name,
                doseMg: medication.defaultDoseMg,
                isPRN: isPRN,
                medication: medication
            )
            modelContext.insert(dose)
        }

        let entry = AnxietyEntry(
            severity: Int(severity),
            notes: notes,
            triggerDose: dose,
            isFollowUp: isFollowUp
        )
        modelContext.insert(entry)

        if !isFollowUp {
            // Schedule 30-min follow-up notification
            DoseFollowUpManager.ensureAuthorization()
            DoseFollowUpManager.scheduleFollowUp(
                doseID: dose.id,
                medicationName: medication.name
            )
        } else {
            // Mark follow-up as completed
            DoseFollowUpManager.completeFollowUp(doseID: dose.id)
        }

        dismiss()
    }

    private func skipAndLogDose() {
        let dose = MedicationDose(
            medicationName: medication.name,
            doseMg: medication.defaultDoseMg,
            isPRN: isPRN,
            medication: medication
        )
        modelContext.insert(dose)
        dismiss()
    }

    private var severityColor: Color {
        switch Int(severity) {
        case 1...3: .green
        case 4...6: .yellow
        case 7...8: .orange
        default: .red
        }
    }
}
