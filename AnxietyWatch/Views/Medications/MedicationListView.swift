import SwiftUI
import SwiftData

struct MedicationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<MedicationDefinition> { $0.isActive },
        sort: \MedicationDefinition.name
    )
    private var activeMeds: [MedicationDefinition]
    @Query(sort: \MedicationDose.timestamp, order: .reverse)
    private var recentDoses: [MedicationDose]
    @State private var showingAddMed = false

    var body: some View {
        NavigationStack {
            List {
                Section("Quick Log") {
                    if activeMeds.isEmpty {
                        Text("No medications defined. Tap + to add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(activeMeds) { med in
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
