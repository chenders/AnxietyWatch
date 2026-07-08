import SwiftData
import SwiftUI

struct CPAPDetailView: View, Equatable {
    let session: CPAPSession

    // Previously the parent list handed in two whole-table arrays just so this
    // view could read one day's snapshot/entries and a 30-day SpO₂ baseline
    // (F-074). This view now owns date-scoped @Querys instead, so the parent
    // (CPAPListView / DashboardView) no longer fetches those tables at all.
    //
    // Both predicates are two-clause Date-only windows, fully bounded on both
    // edges (so viewing an OLD session fetches a fixed window, not everything
    // up to now). Two-clause Date compounds are safe from the iOS 26 SwiftData
    // ORDER BY hang — that path targets captured non-primitive locals (UUID,
    // String), not Date; see PolarSessionHRDetailView for the same documented
    // pattern. The snapshot window [sessionDay-30d, sessionDay] exactly matches
    // BaselineCalculator's window anchored at the session date and includes the
    // exact session-day snapshot; the entry window is the session's single day.
    @Query private var snapshots: [HealthSnapshot]
    @Query private var entries: [AnxietyEntry]

    init(session: CPAPSession) {
        self.session = session
        let calendar = Calendar.current
        let sessionDayStart = calendar.startOfDay(for: session.date)
        let snapshotLowerCutoff = calendar.date(
            byAdding: .day, value: -Constants.baselineWindowDays, to: sessionDayStart
        ) ?? sessionDayStart
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: sessionDayStart) ?? sessionDayStart
        _snapshots = Query(
            filter: #Predicate<HealthSnapshot> {
                $0.date >= snapshotLowerCutoff && $0.date <= sessionDayStart
            },
            sort: \HealthSnapshot.date, order: .reverse
        )
        _entries = Query(
            filter: #Predicate<AnxietyEntry> {
                $0.timestamp >= sessionDayStart && $0.timestamp < nextDayStart
            },
            sort: \AnxietyEntry.timestamp, order: .reverse
        )
    }

    // Equatable on the session's stable identity only; paired with
    // `.equatable()` at the NavigationLink call sites so SwiftUI dedupes
    // rebuilds. @Query state otherwise defeats memberwise comparison and a
    // parent re-render storm can cascade into a CA::Layer use-after-free on
    // iOS 26. See CLAUDE.md render-pitfall #2.
    static func == (lhs: CPAPDetailView, rhs: CPAPDetailView) -> Bool {
        lhs.session.persistentModelID == rhs.session.persistentModelID
    }

    private var daySnapshot: HealthSnapshot? {
        let sessionDate = Calendar.current.startOfDay(for: session.date)
        return snapshots.first { $0.date == sessionDate }
    }

    /// The `entries` @Query is already bounded to the session's single day, so
    /// this is a plain passthrough (the day filter now lives in the predicate).
    private var dayEntries: [AnxietyEntry] { entries }

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Date", value: session.date.formatted(.dateTime.weekday(.wide).month().day().year()))
                LabeledContent("Source", value: session.importSource)
            }

            Section("Key Metrics") {
                HStack {
                    Text("AHI")
                    Spacer()
                    Text(String(format: "%.1f events/hr", session.ahi))
                        .foregroundStyle(ahiColor)
                        .fontWeight(.semibold)
                }
                LabeledContent("Usage", value: usageString)
                if let leak = session.leakRate95th {
                    LabeledContent("Leak (95th %ile)", value: String(format: "%.1f L/min", leak))
                }
            }

            Section("Events") {
                LabeledContent("Obstructive", value: "\(session.obstructiveEvents)")
                LabeledContent("Central", value: "\(session.centralEvents)")
                LabeledContent("Hypopnea", value: "\(session.hypopneaEvents)")
            }

            Section("Pressure (cmH\u{2082}O)") {
                // OSCAR Summary exports carry no minimum-pressure column, so
                // those imports store CPAPImporter.oscarPressureMinUnavailable
                // (0). A CPAP never delivers 0 cmH₂O, so render the sentinel
                // as "not recorded" rather than a measured value.
                LabeledContent(
                    "Min",
                    value: session.pressureMin == CPAPImporter.oscarPressureMinUnavailable
                        ? "—"
                        : String(format: "%.1f", session.pressureMin)
                )
                LabeledContent("Mean", value: String(format: "%.1f", session.pressureMean))
                LabeledContent("Max", value: String(format: "%.1f", session.pressureMax))
            }

            if let snap = daySnapshot,
               snap.spo2NadirOvernight != nil
                || snap.spo2TimeBelow90Min != nil
                || snap.spo2DesatsCount != nil {
                Section("Overnight SpO\u{2082}") {
                    if let nadir = snap.spo2NadirOvernight {
                        HStack {
                            Text("Nadir")
                            Spacer()
                            Text(String(format: "%.0f%%", nadir))
                                .foregroundStyle(ClinicalSeverity.spo2NadirSeverity(nadir).color)
                                .fontWeight(.semibold)
                        }
                    }
                    if let t90 = snap.spo2TimeBelow90Min {
                        HStack {
                            Text("Time <90% (T90)")
                            Spacer()
                            Text("\(t90) min")
                                .foregroundStyle(ClinicalSeverity.t90Severity(t90).color)
                                .fontWeight(.semibold)
                        }
                    }
                    if let desats = snap.spo2DesatsCount {
                        HStack {
                            Text("Desats")
                            Spacer()
                            Text("\(desats)")
                                .foregroundStyle(ClinicalSeverity.desatCountSeverity(desats).color)
                                .fontWeight(.semibold)
                        }
                    }
                    if let nadir = snap.spo2NadirOvernight,
                       let baseline = BaselineCalculator.spo2NadirBaseline(
                            from: snapshots,
                            anchorDate: session.date
                       ) {
                        HStack {
                            Text("vs. 30-day avg")
                            Spacer()
                            Text(String(format: "nadir %.0f%%", baseline.mean))
                                .foregroundStyle(.secondary)
                            Text(comparisonLabel(nadir: nadir, mean: baseline.mean))
                                .font(.caption)
                                .foregroundStyle(nadir < baseline.lowerBound ? .red : .secondary)
                        }
                    }
                }
            }

            if daySnapshot != nil || !dayEntries.isEmpty {
                Section("That Day's Context") {
                    if let snap = daySnapshot {
                        if let hrv = snap.hrvAvg {
                            LabeledContent("HRV", value: String(format: "%.0f ms", hrv))
                        }
                        if let rhr = snap.restingHR {
                            LabeledContent("Resting HR", value: String(format: "%.0f bpm", rhr))
                        }
                        if let sleep = snap.sleepDurationMin {
                            LabeledContent("Sleep", value: "\(sleep / 60)h \(sleep % 60)m")
                        }
                    }
                    ForEach(dayEntries) { entry in
                        LabeledContent(
                            "Anxiety @ \(entry.timestamp.formatted(.dateTime.hour().minute()))",
                            value: "\(entry.severity)/10"
                        )
                    }
                }
            }
        }
        .navigationTitle("CPAP Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var usageString: String {
        let h = session.totalUsageMinutes / 60
        let m = session.totalUsageMinutes % 60
        return "\(h)h \(m)m"
    }

    private func comparisonLabel(nadir: Double, mean: Double) -> String {
        if nadir < mean { return "(lower)" }
        if nadir > mean { return "(higher)" }
        return "(equal)"
    }

    private var ahiColor: Color {
        ClinicalSeverity.ahiSeverity(session.ahi).color
    }
}
