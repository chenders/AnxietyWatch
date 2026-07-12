import SwiftUI
import SwiftData

struct MedicationsHubView: View {
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
    // Capped at the 10 rows the "Recent Doses" section actually renders. The
    // MedicationDose table grows unboundedly (multiple doses/day), and this
    // view only ever shows/deletes the first 10 — a fetchLimit bounds the
    // fetch in SQLite instead of materializing the whole table to truncate it
    // in memory each body (F-072).
    @Query private var recentDoses: [MedicationDose]
    @State private var showingAddMed = false
    @State private var promptMedication: MedicationDefinition?

    private static let recentDosesLimit = 10

    init() {
        var descriptor = FetchDescriptor<MedicationDose>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.recentDosesLimit
        _recentDoses = Query(descriptor)
    }

    var body: some View {
        NavigationStack {
            List {
                quickLogSection
                navigationSection
                recentDosesSection
                notCurrentlyTakingSection
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
            .sheet(item: $promptMedication) { med in
                DoseAnxietyPromptView(medication: med, existingDose: nil)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var quickLogSection: some View {
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
                .swipeActions(edge: .trailing) {
                    Button("Deactivate") {
                        med.isActive = false
                    }
                    .tint(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var navigationSection: some View {
        Section {
            NavigationLink {
                PrescriptionListView().equatable()
            } label: {
                Label("Prescriptions", systemImage: "list.clipboard")
            }
            NavigationLink {
                PharmacyListView().equatable()
            } label: {
                Label("Pharmacies", systemImage: "cross.case")
            }
        }
    }

    @ViewBuilder
    private var recentDosesSection: some View {
        if !recentDoses.isEmpty {
            Section("Recent Doses") {
                // Already capped at `recentDosesLimit` by the @Query fetchLimit.
                ForEach(recentDoses) { dose in
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

    @ViewBuilder
    private var notCurrentlyTakingSection: some View {
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

    // MARK: - Actions

    private func logDose(for med: MedicationDefinition) {
        if med.promptAnxietyOnLog == true {
            promptMedication = med
        } else {
            let dose = MedicationDose(
                medicationName: med.name,
                doseMg: med.defaultDoseMg,
                medication: med
            )
            modelContext.insert(dose)
        }
    }

    private func deleteDoses(offsets: IndexSet) {
        // Snapshot the target objects BEFORE mutating the context: deleting by
        // live index would shift subsequent offsets as the @Query collection
        // updates (Copilot review of #165). `recentDoses` is already the
        // capped, newest-first set the section renders.
        let toDelete = offsets.map { recentDoses[$0] }
        for dose in toDelete {
            modelContext.delete(dose)
        }
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    NavigationStack {
        MedicationsHubView()
    }
    .modelContainer(container)
}
#endif
