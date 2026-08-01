import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isRebuilding = false
    @State private var rebuildProgress = 0
    @State private var rebuildTotal = 0
    @State private var showRebuildConfirmation = false
#if DEBUG
    @State private var demoOuraPresented = false
    @State private var ouraBLEDemoPresented = false
    @State private var demoCNSPresented = false
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AppleHealthSettingsView()
                    } label: {
                        Label("Apple Health", systemImage: "heart.fill")
                    }
                    NavigationLink {
                        HealthRecordsSettingsView()
                    } label: {
                        Label("Health Records", systemImage: "cross.case.fill")
                    }
                    NavigationLink {
                        DevicesSettingsView()
                    } label: {
                        Label("Devices", systemImage: "dot.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        CNSMonitoringView()
                    } label: {
                        Label("CNS Monitoring", systemImage: "waveform.path.ecg.rectangle")
                    }
                } header: {
                    Text("Data Sources")
                } footer: {
                    Text(
                        "Anxiety Watch reads from these sources to correlate symptoms with physiological signals. "
                            + "It never writes back. CNS Monitoring arms an overnight respiratory-depression watch "
                            + "after a benzodiazepine/opioid dose or on demand; arming it auto-starts the EMAY "
                            + "oximeter session without touching your EMAY continuous-streaming toggle above. "
                            + "Phase 2 detects and discloses; loud alerting (klaxon/haptics) lands in Phase 3."
                    )
                }

                Section {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        Label("Server Sync", systemImage: "icloud.and.arrow.up")
                    }
                    Button {
                        Task { await refreshRecentSnapshots() }
                    } label: {
                        Label("Refresh Recent Snapshots", systemImage: "arrow.clockwise")
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
                            Label("Rebuild All History…", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
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
                } header: {
                    Text("Sync & Data")
                } footer: {
                    Text("Daily snapshots aggregate HealthKit values for the Trends tab. Rebuild only if values look stale.")
                }

                Section {
                    NavigationLink {
                        CheckInSettingsView()
                    } label: {
                        Label("Random Check-Ins", systemImage: "bell.badge")
                    }
                } header: {
                    Text("Notifications & Check-Ins")
                } footer: {
                    Text("Random check-ins capture your state at unpredictable moments so trends aren't biased toward bad days.")
                }

                Section {
                    NavigationLink {
                        ExportView().equatable()
                    } label: {
                        Label("Export Data", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Reports & Export")
                } footer: {
                    Text("Export to JSON, CSV, or PDF for sharing with your therapist or doctor.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
                    Link(destination: URL(string: "https://github.com/chenders/AnxietyWatch")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
#if DEBUG
                    NavigationLink {
                        EnergyMetricsDebugView().equatable()
                    } label: {
                        Label("Debug: Energy Metrics", systemImage: "bolt.fill")
                    }
#endif
                } header: {
                    Text("About")
                } footer: {
                    Text("Open-source. No telemetry. No accounts. No ads.")
                }
            }
            .navigationTitle("Settings")
#if DEBUG
            .navigationDestination(isPresented: $demoOuraPresented) {
                OuraSettingsView()
            }
            .navigationDestination(isPresented: $ouraBLEDemoPresented) {
                OuraBLEDemoView()
            }
            .navigationDestination(isPresented: $demoCNSPresented) {
                CNSMonitoringDemoView()
            }
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                guard arguments.contains("-demoOuraSequence")
                        || arguments.contains("-ouraBLEDemoAutoOpen")
                        || arguments.contains("-demoCNSSequence") else { return }
                // Let Settings remain visible long enough to establish where
                // the feature lives before following the matching visible row.
                try? await Task.sleep(for: .seconds(3))
                if arguments.contains("-demoCNSSequence") {
                    demoCNSPresented = true
                } else if arguments.contains("-ouraBLEDemoAutoOpen") {
                    ouraBLEDemoPresented = true
                } else {
                    demoOuraPresented = true
                }
            }
#endif
        }
    }

    private func refreshRecentSnapshots() async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: modelContext
        )
        try? await aggregator.aggregateRecentDays(endingAt: .now)
    }

    private func rebuildAllSnapshots() async {
        let calendar = Calendar.current
        let oldestDate = try? await HealthKitManager.shared.oldestSampleDate()
        let startDate = oldestDate ?? calendar.date(byAdding: .day, value: -90, to: .now)!
        let totalDays = max(1, (calendar.dateComponents([.day], from: startDate, to: .now).day ?? 90) + 1)

        isRebuilding = true
        rebuildTotal = totalDays
        rebuildProgress = 0

        // Run the HealthKit→SwiftData mirror before re-aggregating so the SpO2
        // precedence override has the source-tagged rows it needs in
        // `QuantityHealthSample` for the most recent ~9 days. The mirror's
        // initial lookback is bounded by `HealthDataCoordinator.initialMirrorLookbackDays`
        // (currently 7) + a 48h rolling correction window — by design, so a
        // first launch doesn't pull years of data — which means the rebuild
        // loop iterating over older days still won't have SwiftData-mirrored
        // rows there. For SpO2 the source-aware HK fallback in
        // `applyOvernightSpO2Precedence` covers older days regardless. For
        // HR/HRV (`applyDailyHeartMetricsPrecedence` still reads only
        // SwiftData) older-day Polar precedence requires that the row
        // already exists in `QuantityHealthSample`, e.g. from prior
        // incremental sync passes that mirrored it at the time. A future
        // "rebuild also extends the mirror anchor" change could close that
        // gap, but is out of scope here. Anchor + 48h look-back means a
        // fully-synced device no-ops in under a second.
        //
        // Constructing a fresh coordinator (rather than reusing the app-level
        // one via Environment plumbing) is fine here: the cross-instance race
        // with the app's own coordinator is recoverable via `@Attribute(.unique)`
        // on `QuantityHealthSample.id` — see the `isMirroring` docstring.
        let coordinator = HealthDataCoordinator(modelContainer: modelContext.container)
        await coordinator.mirrorHealthKitSamples()

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
        .environment(PolarHRMService(modelContext: ModelContext(container)))
        .environment(RecordingPresentationCoordinator())
}
#endif
