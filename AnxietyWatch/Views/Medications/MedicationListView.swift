import SwiftUI
import SwiftData

struct MedicationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<MedicationDefinition> { $0.isActive },
        sort: \MedicationDefinition.name
    )
    private var activeMeds: [MedicationDefinition]
    @Query(
        filter: #Predicate<MedicationDefinition> { !$0.isActive },
        sort: \MedicationDefinition.name
    )
    private var inactiveMeds: [MedicationDefinition]
    @Query(sort: \MedicationDose.timestamp, order: .reverse)
    private var recentDoses: [MedicationDose]
    @State private var showingAddMed = false

    @Query(sort: \Prescription.dateFilled, order: .reverse)
    private var prescriptions: [Prescription]

    /// Active medications filtered to hide those whose ALL prescriptions are stale (>60 days).
    /// Keeps medications with no prescriptions (manually added).
    private var currentMeds: [MedicationDefinition] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -PrescriptionSupplyCalculator.alertStalenessLimitDays,
            to: .now
        )
        return activeMeds.filter { med in
            guard !med.prescriptions.isEmpty else { return true }
            guard let cutoff else { return true }
            return med.prescriptions.contains { rx in
                let fillDate = rx.lastFillDate ?? rx.dateFilled
                return fillDate >= cutoff
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Quick Log") {
                    if currentMeds.isEmpty {
                        Text("No medications defined. Tap + to add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(currentMeds) { med in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(med.name).font(.headline)
                                Text("\(med.defaultDoseMg, specifier: "%.1f") mg · \(med.category)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Log Dose") {
                                logDose(for: med)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Deactivate") {
                                med.isActive = false
                            }
                            .tint(.orange)
                        }
                    }
                }

                if !recentDoses.isEmpty {
                    Section("Recent Doses") {
                        ForEach(recentDoses.prefix(15)) { dose in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(dose.medicationName).font(.subheadline)
                                    Text(dose.timestamp, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(dose.doseMg, specifier: "%.1f") mg")
                                    .font(.subheadline.monospacedDigit())
                            }
                        }
                        .onDelete(perform: deleteDoses)
                    }
                }

                if !inactiveMeds.isEmpty {
                    Section("Not Currently Taking") {
                        ForEach(inactiveMeds) { med in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(med.name).font(.subheadline)
                                    if !med.category.isEmpty {
                                        Text(med.category)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                            .swipeActions(edge: .trailing) {
                                Button("Reactivate") {
                                    med.isActive = true
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Medications")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddMed = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddMed) {
                AddMedicationView()
            }
        }
    }

    private func logDose(for med: MedicationDefinition) {
        let dose = MedicationDose(
            medicationName: med.name,
            doseMg: med.defaultDoseMg,
            medication: med
        )
        modelContext.insert(dose)
    }

    private func deleteDoses(offsets: IndexSet) {
        let allDoses = Array(recentDoses.prefix(15))
        for index in offsets {
            modelContext.delete(allDoses[index])
        }
    }
}
