import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var healthKitRequested = false
    @State private var clinicalRecordsRequested = false
    @State private var isRebuilding = false
    @State private var rebuildProgress = 0
    @State private var rebuildTotal = 0
    @State private var showRebuildConfirmation = false
    @Query private var allMeds: [MedicationDefinition]
    @State private var checkInsEnabled = RandomCheckInManager.isEnabled
    @State private var checkInFrequency = RandomCheckInManager.frequencyPerDay
    // Active hours are the inverse of quiet hours: active starts when quiet ends
    @State private var activeHoursStart = RandomCheckInManager.activeHoursStart
    @State private var activeHoursEnd = RandomCheckInManager.activeHoursEnd

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

                Section("Clinical Records") {
                    Button {
                        Task {
                            do {
                                try await HealthKitManager.shared.requestClinicalAuthorization()
                                clinicalRecordsRequested = true
                            } catch {
                                // Authorization failed or was cancelled — don't show checkmark
                            }
                        }
                    } label: {
                        Label("Connect Health Records", systemImage: "cross.case.fill")
                    }
                    if clinicalRecordsRequested {
                        Label("Clinical records access requested", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    NavigationLink {
                        LabResultsView()
                    } label: {
                        Label("Lab Results", systemImage: "flask.fill")
                    }
                    Text("Requires a linked hospital in Apple Health. Go to Health app → Browse → Health Records to connect your provider.")
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

                Section("Server Sync") {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        Label("Server Sync", systemImage: "icloud.and.arrow.up")
                    }
                }

                Section("Data") {
                    Button {
                        Task { await refreshTodaySnapshot() }
                    } label: {
                        Label("Refresh Today's Snapshot", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRebuilding)

                    Button {
                        showRebuildConfirmation = true
                    } label: {
                        if isRebuilding {
                            HStack {
                                ProgressView()
                                Text("Rebuilding… \(rebuildProgress)/\(rebuildTotal) days")
                                    .monospacedDigit()
                            }
                        } else {
                            Label("Rebuild All History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        }
                    }
                    .disabled(isRebuilding)
                    .confirmationDialog(
                        "Rebuild all health snapshots from your full HealthKit history? This may take a few minutes.",
                        isPresented: $showRebuildConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Rebuild All") {
                            Task { await rebuildAllSnapshots() }
                        }
                    }
                }

                Section("Random Check-Ins") {
                    Toggle("Enable Check-Ins", isOn: $checkInsEnabled)
                        .onChange(of: checkInsEnabled) { _, newValue in
                            RandomCheckInManager.isEnabled = newValue
                            if newValue {
                                RandomCheckInManager.ensureAuthorization()
                                RandomCheckInManager.scheduleNextCheckIn()
                            } else {
                                RandomCheckInManager.cancelAll()
                            }
                        }

                    if checkInsEnabled {
                        Stepper("Times per day: \(checkInFrequency)", value: $checkInFrequency, in: 1...4)
                            .onChange(of: checkInFrequency) { _, newValue in
                                RandomCheckInManager.frequencyPerDay = newValue
                                RandomCheckInManager.cancelAll()
                                RandomCheckInManager.isEnabled = true
                                RandomCheckInManager.scheduleNextCheckIn()
                            }

                        HStack {
                            Text("Active hours")
                            Spacer()
                            Picker("Start", selection: $activeHoursStart) {
                                ForEach(5..<13, id: \.self) { hour in
                                    Text("\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")")
                                        .tag(hour)
                                }
                            }
                            .labelsHidden()
                            Text("–")
                            Picker("End", selection: $activeHoursEnd) {
                                ForEach(18..<24, id: \.self) { hour in
                                    Text("\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")")
                                        .tag(hour)
                                }
                            }
                            .labelsHidden()
                        }
                        .onChange(of: activeHoursStart) { _, newValue in
                            RandomCheckInManager.activeHoursStart = newValue
                            RandomCheckInManager.cancelAll()
                            RandomCheckInManager.isEnabled = true
                            RandomCheckInManager.scheduleNextCheckIn()
                        }
                        .onChange(of: activeHoursEnd) { _, newValue in
                            RandomCheckInManager.activeHoursEnd = newValue
                            RandomCheckInManager.cancelAll()
                            RandomCheckInManager.isEnabled = true
                            RandomCheckInManager.scheduleNextCheckIn()
                        }

                        Text("You'll get \(checkInFrequency) random check-in\(checkInFrequency == 1 ? "" : "s") between \(activeHoursStart % 12 == 0 ? 12 : activeHoursStart % 12) \(activeHoursStart < 12 ? "AM" : "PM") and \(activeHoursEnd % 12 == 0 ? 12 : activeHoursEnd % 12) \(activeHoursEnd < 12 ? "AM" : "PM").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: BuildVersion.commitHash)
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

    private func refreshTodaySnapshot() async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: modelContext
        )
        try? await aggregator.aggregateDay(.now)
    }

    private func rebuildAllSnapshots() async {
        let calendar = Calendar.current
        let oldestDate = try? await HealthKitManager.shared.oldestSampleDate()
        let startDate = oldestDate ?? calendar.date(byAdding: .day, value: -90, to: .now)!
        let totalDays = max(1, (calendar.dateComponents([.day], from: startDate, to: .now).day ?? 90) + 1)

        isRebuilding = true
        rebuildTotal = totalDays
        rebuildProgress = 0

        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: modelContext
        )
        for offset in 0..<totalDays {
            let date = calendar.date(byAdding: .day, value: offset, to: startDate)!
            try? await aggregator.aggregateDay(date)
            rebuildProgress = offset + 1
        }
        isRebuilding = false
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    SettingsView()
        .modelContainer(container)
}
#endif
