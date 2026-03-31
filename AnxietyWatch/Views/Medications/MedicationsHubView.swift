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
    @Query(sort: \MedicationDose.timestamp, order: .reverse)
    private var recentDoses: [MedicationDose]
    @Query(sort: \Prescription.dateFilled, order: .reverse)
    private var prescriptions: [Prescription]
    @State private var showingAddMed = false
    @State private var promptMedication: MedicationDefinition?

    var body: some View {
        NavigationStack {
            List {
                quickLogSection
                supplyAlertSection
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
    private var supplyAlertSection: some View {
        let alerts = PrescriptionSupplyCalculator.alertPrescriptions(from: prescriptions)
        if !alerts.isEmpty {
            Section("Supply Alerts") {
                ForEach(alerts) { rx in
                    NavigationLink(value: rx.id) {
                        SupplyAlertRow(prescription: rx)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let rx = prescriptions.first(where: { $0.id == id }) {
                    PrescriptionDetailView(prescription: rx)
                }
            }
        }
    }

    @ViewBuilder
    private var navigationSection: some View {
        Section {
            NavigationLink {
                PrescriptionListView()
            } label: {
                Label("Prescriptions", systemImage: "list.clipboard")
            }
            NavigationLink {
                PharmacyListView()
            } label: {
                Label("Pharmacies", systemImage: "cross.case")
            }
        }
    }

    @ViewBuilder
    private var recentDosesSection: some View {
        if !recentDoses.isEmpty {
            Section("Recent Doses") {
                ForEach(recentDoses.prefix(10)) { dose in
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
        let allDoses = Array(recentDoses.prefix(10))
        for index in offsets {
            modelContext.delete(allDoses[index])
        }
    }
}

// MARK: - Supply Alert Row

private struct SupplyAlertRow: View {
    let prescription: Prescription

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(prescription.medicationName).font(.subheadline)
                if let days = PrescriptionSupplyCalculator.daysRemaining(for: prescription) {
                    let label = days < 0 ? "Supply expired" : days == 0 ? "Runs out today" : "\(days) days remaining"
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Rx \(prescription.rxNumber)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch PrescriptionSupplyCalculator.supplyStatus(for: prescription) {
        case .good: .green
        case .warning: .yellow
        case .low: .red
        case .expired: .gray
        case .unknown: .secondary
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
