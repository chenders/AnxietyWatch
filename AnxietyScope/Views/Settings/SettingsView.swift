import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var healthKitRequested = false
    @Query private var allMeds: [MedicationDefinition]

    var body: some View {
        NavigationStack {
            Form {
                Section("Health Data") {
                    Button {
                        Task {
                            try? await HealthKitManager.shared.requestAuthorization()
                            healthKitRequested = true
                        }
                    } label: {
                        Label("Request HealthKit Access", systemImage: "heart.fill")
                    }
                    if healthKitRequested {
                        Label("HealthKit access requested", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text("HealthKit does not reveal which permissions were granted. The app gracefully handles missing data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Manage Medications") {
                    ForEach(allMeds) { med in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(med.name)
                                Text("\(med.defaultDoseMg, specifier: "%.1f") mg · \(med.category)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Active", isOn: Bindable(med).isActive)
                                .labelsHidden()
                        }
                    }
                    .onDelete(perform: deleteMeds)
                    if allMeds.isEmpty {
                        Text("No medications defined yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("CPAP") {
                    NavigationLink {
                        CPAPListView()
                    } label: {
                        Label("CPAP Data", systemImage: "bed.double.fill")
                    }
                }

                Section("Reports & Export") {
                    NavigationLink {
                        ExportView()
                    } label: {
                        Label("Export & Reports", systemImage: "square.and.arrow.up")
                    }
                }

                Section("Data") {
                    Button {
                        Task { await refreshAllSnapshots() }
                    } label: {
                        Label("Rebuild Today's Health Snapshot", systemImage: "arrow.clockwise")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Phase", value: "5 — Reports & Export")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func deleteMeds(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(allMeds[index])
        }
    }

    private func refreshAllSnapshots() async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: modelContext
        )
        try? await aggregator.aggregateDay(.now)
    }
}
