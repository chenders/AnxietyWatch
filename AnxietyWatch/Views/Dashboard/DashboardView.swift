import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PolarHRMService.self) private var polarService
    @Environment(EMAYRealtimeService.self) private var emayService
    @EnvironmentObject private var pipelineService: KitPipelineService
    // All six of these queries are bounded to a 30-day window in init() below
    // (AnxietyEntry, MedicationDose, HealthSnapshot, CPAPSession,
    // ClinicalLabResult, SleepStageEvent) — each can grow unbounded, and the
    // dashboard only reads recent values (mostly `.first`, plus the 30-day
    // baselines from recentSnapshots). The cutoff is captured once at view init
    // via a `let`-bound constant because SwiftData's #Predicate macro can't
    // reference a runtime-evaluated Date.now directly.
    @Query private var recentEntries: [AnxietyEntry]
    @Query private var recentDoses: [MedicationDose]
    @Query private var recentSnapshots: [HealthSnapshot]
    @Query private var recentCPAP: [CPAPSession]
    @Query private var recentLabResults: [ClinicalLabResult]
    @Query private var recentSleepEvents: [SleepStageEvent]

    @State private var vm = DashboardViewModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Drives the HealthKit-access banner. One-shot bool (flips at most once or
    /// twice per session), owned here so its `.task`/`scenePhase` probe is
    /// reliable and the banner itself stays a pure `EmptyView`-when-fine view.
    @State private var healthKitNeedsRequest = false
#if DEBUG
    @State private var demoLabsPresented = false
    @State private var demoSequence = DemoVideoSequence.shared
#endif
    private let barometer = BarometerService.shared

    init() {
        // Day-aligned, calendar-based cutoff (DST-safe) matching
        // BaselineCalculator's own `Calendar.date(byAdding:.day, value:-30)`
        // window exactly. The previous `addingTimeInterval(-30 * 24 * 3600)`
        // form could land a full calendar day off across a DST transition,
        // which was harmless when these queries only read `.first` but now
        // matters because `recentSnapshots` feeds the statistical baselines.
        let cal = Calendar.current
        let recentCutoff = cal.date(
            byAdding: .day, value: -Constants.baselineWindowDays, to: cal.startOfDay(for: .now)
        ) ?? cal.startOfDay(for: .now)

        _recentEntries = Query(
            filter: #Predicate<AnxietyEntry> { $0.timestamp >= recentCutoff },
            sort: \AnxietyEntry.timestamp, order: .reverse
        )
        _recentDoses = Query(
            filter: #Predicate<MedicationDose> { $0.timestamp >= recentCutoff },
            sort: \MedicationDose.timestamp, order: .reverse
        )
        // Previously the ONE query in this init with no predicate — it fetched
        // the entire ever-growing HealthSnapshot table on every render (F-071).
        // Bounded to the same 30-day cutoff as its siblings; this exactly
        // matches BaselineCalculator's window (Constants.baselineWindowDays =
        // 30), so the dashboard baselines see the same data they did before.
        _recentSnapshots = Query(
            filter: #Predicate<HealthSnapshot> { $0.date >= recentCutoff },
            sort: \HealthSnapshot.date, order: .reverse
        )
        _recentCPAP = Query(
            filter: #Predicate<CPAPSession> { $0.date >= recentCutoff },
            sort: \CPAPSession.date, order: .reverse
        )
        _recentLabResults = Query(
            filter: #Predicate<ClinicalLabResult> { $0.effectiveDate >= recentCutoff },
            sort: \ClinicalLabResult.effectiveDate, order: .reverse
        )
        _recentSleepEvents = Query(
            filter: #Predicate<SleepStageEvent> { $0.startTime >= recentCutoff },
            sort: \SleepStageEvent.startTime, order: .reverse
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 0. HealthKit access banner — only shows when authorization
                    // has never resolved, i.e. every read is silently failing.
                    HealthKitAccessBanner(needsRequest: $healthKitNeedsRequest)

                    // 1. Alerts strip
                    AlertsSectionView(snapshots: recentSnapshots, vm: vm)

                    // 1.5 v3 Pipeline monitoring card (BLE live vitals)
                    if let monitor = pipelineService.monitoring {
                        DashboardMonitoringCard(monitor: monitor)
                    }

                    // 2. Smart Summary "What changed today"
                    SmartSummaryCard(summary: vm.smartSummary(
                        snapshots: recentSnapshots,
                        sleepEvents: recentSleepEvents,
                        lastAnxiety: recentEntries.first
                    ))

                    // Oura Cloud daily context is distinct from HealthKit and BLE.
                    OuraDailyContextCard()

                    // 3. Polar HRV start-session (always visible when paired per Q4)
                    if polarService.isPaired {
                        HRVSessionCardView(service: polarService)
                    }
                    if emayService.isFullAppDemoSimulated {
                        EMAYLiveCardView()
                    }

                    // 4. Last Anxiety (spine signal)
                    anxietySection

                    // 5. Last Night merged hero (sleep efficiency + AHI + nadir + WASO)
                    lastNightSection

                    // 6+7. Vitals hero (HR + HRV) — wraps the two highest-priority autonomic signals
                    VitalsHeroSectionView(vm: vm)

                    // 8. Vitals 2-col grid (RHR, SpO2, RR, VO2, Walking HR, Steadiness, AFib, BP, Glucose)
                    VitalsGridSectionView(vm: vm)

                    // 9. Activity row (Steps + Cal + Exercise)
                    ActivityRowSectionView(vm: vm, snapshots: recentSnapshots)

                    // 10. Environment & background disclosure (default collapsed)
                    EnvironmentDisclosureSectionView(
                        vm: vm, snapshots: recentSnapshots, barometer: barometer
                    )

                    // 11. Last Medication compact row
                    LastMedicationRowView(lastDose: recentDoses.first)

                    // 12. Care section row (Lab Results entry)
                    CareSectionRowView(
                        recentLabResultsCount: vm.latestLabResultPerTest(from: recentLabResults).count
                    )
                }
                .padding()
            }
#if DEBUG
            .demoAutoScroll("dashboard", stops: 4, step: 500)
#endif
            .navigationTitle("Dashboard")
            .task {
                // Surface the access banner if HealthKit authorization has never
                // resolved. Cheap status call; its own task so it never delays
                // the synchronous baseline compute below.
                healthKitNeedsRequest = await HealthKitManager.shared.authorizationNeedsRequest()
            }
            .onChange(of: scenePhase) { _, phase in
                // Re-probe on foreground: if the user granted access in iOS
                // Settings and returned, the banner clears itself.
                if phase == .active {
                    Task { healthKitNeedsRequest = await HealthKitManager.shared.authorizationNeedsRequest() }
                }
            }
#if DEBUG
            .navigationDestination(isPresented: $demoLabsPresented) {
                LabResultsView().equatable()
            }
            .task(id: demoSequence.completedProfiles) {
                guard ProcessInfo.processInfo.arguments.contains("-demoLabsAndSongs"),
                      demoSequence.completedProfiles.contains("dashboard") else { return }
                // The Dashboard has programmatically scrolled to its Care row;
                // now follow the same navigation destination as that row.
                try? await Task.sleep(for: .seconds(2))
                demoLabsPresented = true
                try? await Task.sleep(for: .seconds(6))
                demoLabsPresented = false
                demoSequence.labsViewed = true
            }
#endif
            .task {
                // Compute immediately from cached @Query data — no async, no blocking
                vm.computeBaselines(from: recentSnapshots)
                vm.sendStatsToWatch(
                    lastAnxiety: recentEntries.first?.severity,
                    todaySnapshot: vm.todaySnapshot(from: recentSnapshots)
                )

                // Load samples and refresh in background — these are slow
                Task { @MainActor in
                    vm.loadSamples(from: modelContext)
                }
                Task {
                    await vm.refreshSnapshot(context: modelContext)
                    // Recompute baselines from fresh data after refresh
                    let descriptor = FetchDescriptor<HealthSnapshot>(
                        sortBy: [SortDescriptor(\.date, order: .reverse)]
                    )
                    if let updated = try? modelContext.fetch(descriptor) {
                        vm.computeBaselines(from: updated)
                    }
                }
                Task { await vm.autoSync(context: modelContext) }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var anxietySection: some View {
        if let latest = recentEntries.first {
            MetricCard(
                title: "Last Anxiety",
                value: "\(latest.severity)/10",
                subtitle: latest.timestamp.formatted(.relative(presentation: .named)),
                color: Color.severity(latest.severity)
            )
        } else {
            MetricCard(
                title: "Anxiety",
                value: "—",
                subtitle: "No entries yet",
                color: .secondary
            )
        }
    }

    @ViewBuilder
    private var lastNightSection: some View {
        if let snapshot = recentSnapshots.first(where: {
            $0.spo2NadirOvernight != nil
                || $0.sleepDurationMin != nil
                || $0.cpapAHI != nil
                // cpapAHI can be nil for an EDF-only night that still has real
                // CPAP usage (F-094); usage is the reliable "CPAP happened"
                // proxy now that AHI is optional.
                || $0.cpapUsageMinutes != nil
        }) {
            // Noon-to-noon window for the snapshot's night — the previous
            // same-calendar-day filter spanned 48 hours and could dilute
            // SleepEfficiencyCalculator with an adjacent night's events
            // (the F-011 defect class, in this sibling consumer).
            let nightEvents = DashboardViewModel.nightEvents(
                from: recentSleepEvents, forMorning: snapshot.date
            )
            // Date-matched to the snapshot's night — `recentCPAP.first` could
            // be up to 30 days old when the SD card hasn't been imported
            // recently, silently presenting a stale AHI as last night's
            // (F-036). No matching session → the nil branch renders the card
            // without an AHI clause.
            if let cpap = vm.cpapSession(for: snapshot, in: recentCPAP) {
                let efficiency = SleepEfficiencyCalculator.compute(from: nightEvents)
                let headline = LastNightHeadline.compose(
                    efficiencyPct: efficiency.efficiencyPct,
                    efficiencyEstimated: efficiency.isBedTimeEstimated,
                    ahi: cpap.ahi,
                    nadirPct: snapshot.spo2NadirOvernight
                )
                NavigationLink {
                    CPAPDetailView(session: cpap).equatable()
                } label: {
                    LastNightCard(
                        snapshot: snapshot,
                        sleepEvents: nightEvents,
                        lastCPAP: cpap,
                        cpapAHIBaseline: vm.cpapAHIBaseline,
                        wrappedInLink: true
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .accessibilityLabel("Last Night. \(headline.text).\(spo2SourceDisclosure(for: snapshot))")
                .accessibilityHint("Tap to view CPAP detail")
            } else {
                LastNightCard(
                    snapshot: snapshot,
                    sleepEvents: nightEvents,
                    lastCPAP: nil,
                    cpapAHIBaseline: vm.cpapAHIBaseline
                )
                .padding(.horizontal)
            }
        }
    }

    /// Spoken SpO₂ mixed-provenance disclosure for the Last-Night link's
    /// accessibilityLabel (F-092). In `wrappedInLink` mode LastNightCard sets
    /// `.accessibilityElement(children: .ignore)`, so its visual divergence
    /// footnote isn't read by VoiceOver — this folds the same disclosure into
    /// the link's label. Empty (no suffix) when the sources don't diverge.
    private func spo2SourceDisclosure(for snapshot: HealthSnapshot) -> String {
        guard snapshot.spo2SourcesDiverge,
              let agg = snapshot.spo2AggregateBasis,
              let burden = snapshot.spo2BurdenBasis else { return "" }
        return " SpO2 sources differ: nadir from \(agg.label); "
            + "time below 90 percent and desaturations from \(burden.label)."
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    DashboardView()
        .modelContainer(container)
        .environment(PolarHRMService(modelContext: ModelContext(container)))
        .environment(EMAYRealtimeService(modelContext: ModelContext(container)))
        .environment(RecordingPresentationCoordinator())
}
#endif
