import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PolarHRMService.self) private var polarService
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
    @Query(sort: \Prescription.dateFilled, order: .reverse)
    private var prescriptions: [Prescription]
    @Query private var recentSleepEvents: [SleepStageEvent]

    @State private var vm = DashboardViewModel()
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
                    // 1. Alerts strip
                    AlertsSectionView(snapshots: recentSnapshots, vm: vm)

                    // 2. Smart Summary "What changed today"
                    SmartSummaryCard(summary: vm.smartSummary(
                        snapshots: recentSnapshots,
                        sleepEvents: recentSleepEvents,
                        lastAnxiety: recentEntries.first,
                        activeAlerts: vm.lowSupplyCount > 0 ? 1 : 0
                    ))

                    // 3. Polar HRV start-session (always visible when paired per Q4)
                    if polarService.isPaired {
                        HRVSessionCardView(service: polarService)
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
            .navigationTitle("Dashboard")
            .task {
                // Compute immediately from cached @Query data — no async, no blocking
                vm.computeSupplyAlerts(from: prescriptions)
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
            .onChange(of: prescriptions.count) {
                vm.computeSupplyAlerts(from: prescriptions)
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
                .accessibilityLabel("Last Night. \(headline.text).")
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
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    DashboardView()
        .modelContainer(container)
        .environment(PolarHRMService(modelContext: ModelContext(container)))
        .environment(RecordingPresentationCoordinator())
}
#endif
