import Charts
import SwiftUI

/// Combined chart datum for the HF Power trend. Polar-only — HealthKit
/// does not surface frequency-domain HRV at this resolution. The chart
/// keeps the baseline rule mark and anxiety-entry context rules that
/// matched the original LF/HF card style.
enum HFPowerTrendDatum: Identifiable {
    case polar(LFHFAggregator.NightlyMean)
    case baselineMean(Double)
    case entry(AnxietyEntry)

    var id: String {
        switch self {
        case .polar(let p): "polar-\(p.id)"
        case .baselineMean: "baseline-mean"
        case .entry(let e): "entry-\(e.id)"
        }
    }

    /// Builds the combined datum array. Means with nil `hfMean` (all-sentinel
    /// sessions) are skipped so the view body can render directly.
    static func from(
        windowMeans: [LFHFAggregator.NightlyMean],
        entries: [AnxietyEntry],
        baseline: Double?
    ) -> [HFPowerTrendDatum] {
        var data: [HFPowerTrendDatum] = windowMeans
            .filter { $0.hfMean != nil }
            .map(HFPowerTrendDatum.polar)
        if let baseline {
            data.append(.baselineMean(baseline))
        }
        data += entries.map(HFPowerTrendDatum.entry)
        return data
    }

    /// True when at least one mean has a plottable HF value. Entries and
    /// baseline are context, not the metric.
    static func hasAnyData(windowMeans: [LFHFAggregator.NightlyMean]) -> Bool {
        windowMeans.contains { $0.hfMean != nil }
    }
}

/// Overnight HF Power trend from Polar sessions, in the same vocabulary
/// as the rest of the trend stack. The info button surfaces
/// `LFHFExplainerSheet` for the methodology / interpretation note. The
/// LF/HF *ratio* is intentionally not surfaced from the Trends tab —
/// kept only in the per-session detail view.
struct HFPowerTrendChart: View {
    let windowMeans: [LFHFAggregator.NightlyMean]
    /// Full-history overnight means used to compute the 30-day baseline.
    let allOvernightMeans: [LFHFAggregator.NightlyMean]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>
    /// Right edge of the *unpadded* window. `dateRange.upperBound` carries
    /// a +12h padding for chart axis breathing room — using that for the
    /// baseline cutoff would exclude legitimate late-evening sessions on
    /// the last day of a past period.
    let baselineAnchor: Date

    init(
        windowMeans: [LFHFAggregator.NightlyMean],
        allOvernightMeans: [LFHFAggregator.NightlyMean],
        entries: [AnxietyEntry] = [],
        dateRange: ClosedRange<Date>,
        baselineAnchor: Date
    ) {
        self.windowMeans = windowMeans
        self.allOvernightMeans = allOvernightMeans
        self.entries = entries
        self.dateRange = dateRange
        self.baselineAnchor = baselineAnchor
    }

    @State private var showExplainer = false

    private func subtitle(baseline: Double?) -> String? {
        guard let baseline else {
            if windowMeans.isEmpty { return nil }
            if !HFPowerTrendDatum.hasAnyData(windowMeans: windowMeans) {
                return "No valid frequency-domain windows in this period"
            }
            return "Baseline needs 3+ overnight sessions in the last 30 days"
        }
        return String(format: "30-day avg: %.0f ms²", baseline)
    }

    var body: some View {
        // Compute the baseline once per body evaluation; both the subtitle
        // and the data builder need it, and the helper does a linear scan
        // over the full-history nightly means.
        let baseline = LFHFAggregator.hfBaseline(
            from: allOvernightMeans,
            anchor: baselineAnchor
        )
        let datums = HFPowerTrendDatum.from(
            windowMeans: windowMeans,
            entries: entries,
            baseline: baseline
        )
        // Branch off `windowMeans.isEmpty`, not the stricter "has any valid
        // hfMean" predicate, so a window full of all-sentinel sessions
        // still renders the card shell. The info button into
        // LFHFExplainerSheet must stay reachable in that state — the
        // subtitle already names "No valid frequency-domain windows in
        // this period" so the user has somewhere to go for context.
        ChartCard(
            title: "HRV (HF Power)",
            subtitle: subtitle(baseline: baseline),
            isEmpty: windowMeans.isEmpty
        ) {
            HStack(alignment: .top) {
                Text("Polar overnight · parasympathetic power")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showExplainer = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About HF Power")
            }

            Chart(datums) { datum in
                switch datum {
                case .polar(let mean):
                    LineMark(
                        x: .value("Date", mean.night, unit: .day),
                        y: .value("HF (ms²)", mean.hfMean ?? 0)
                    )
                    .foregroundStyle(.purple)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", mean.night, unit: .day),
                        y: .value("HF (ms²)", mean.hfMean ?? 0)
                    )
                    .foregroundStyle(.purple)
                    .symbol(.diamond)
                    .symbolSize(40)
                case .baselineMean(let value):
                    RuleMark(y: .value("Baseline", value))
                        .foregroundStyle(.green.opacity(0.6))
                        .lineStyle(StrokeStyle(dash: [5, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("avg")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                case .entry(let entry):
                    RuleMark(x: .value("Date", entry.timestamp, unit: .day))
                        .foregroundStyle(Color.severity(entry.severity).opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartXScale(domain: dateRange)
            .frame(height: 220)
        }
        .sheet(isPresented: $showExplainer) {
            LFHFExplainerSheet()
        }
    }
}
