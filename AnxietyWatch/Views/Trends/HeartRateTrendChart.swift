import Charts
import SwiftUI

/// Combined chart datum for the resting HR trend. HealthKit `restingHR`
/// (`.snapshot`) and Polar overnight session means (`.polar`) render as
/// separate visually-distinct series so users can see which source a given
/// mark came from. Anxiety entries render as background rule marks for
/// visual context.
enum HeartRateTrendDatum: Identifiable {
    case snapshot(HealthSnapshot)
    case entry(AnxietyEntry)
    case polar(LFHFAggregator.NightlyValue)

    var id: String {
        switch self {
        case .snapshot(let s): "snapshot-\(s.id)"
        case .entry(let e): "entry-\(e.id)"
        case .polar(let p): "polar-\(p.id)"
        }
    }

    /// Build the combined datum array from the three data sources. Snapshots
    /// without `restingHR` and Polar points whose `value` is nil are filtered
    /// out so the view body can render directly without nil-checks.
    static func from(
        snapshots: [HealthSnapshot],
        entries: [AnxietyEntry],
        polarSeries: [LFHFAggregator.NightlyValue]
    ) -> [HeartRateTrendDatum] {
        let hkDatums = snapshots
            .filter { $0.restingHR != nil }
            .map(HeartRateTrendDatum.snapshot)
        let entryDatums = entries.map(HeartRateTrendDatum.entry)
        let polarDatums = polarSeries
            .filter { $0.value != nil }
            .map(HeartRateTrendDatum.polar)
        return hkDatums + entryDatums + polarDatums
    }

    /// True when the chart has anything HR-related to plot from either source.
    /// Entries alone aren't enough — they're context, not data.
    static func hasAnyData(
        snapshots: [HealthSnapshot],
        polarSeries: [LFHFAggregator.NightlyValue]
    ) -> Bool {
        snapshots.contains { $0.restingHR != nil }
            || polarSeries.contains { $0.value != nil }
    }
}

struct HeartRateTrendChart: View {
    let snapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let polarSeries: [LFHFAggregator.NightlyValue]
    let dateRange: ClosedRange<Date>

    init(
        snapshots: [HealthSnapshot],
        entries: [AnxietyEntry],
        polarSeries: [LFHFAggregator.NightlyValue] = [],
        dateRange: ClosedRange<Date>
    ) {
        self.snapshots = snapshots
        self.entries = entries
        self.polarSeries = polarSeries
        self.dateRange = dateRange
    }

    var body: some View {
        let datums = HeartRateTrendDatum.from(
            snapshots: snapshots,
            entries: entries,
            polarSeries: polarSeries
        )
        let hasData = HeartRateTrendDatum.hasAnyData(
            snapshots: snapshots,
            polarSeries: polarSeries
        )
        ChartCard(title: "Resting Heart Rate", isEmpty: !hasData) {
            Chart(datums) { datum in
                switch datum {
                case .snapshot(let snapshot):
                    LineMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("BPM", snapshot.restingHR ?? 0),
                        series: .value("Source", "HealthKit")
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("BPM", snapshot.restingHR ?? 0)
                    )
                    .foregroundStyle(.red)
                    .symbolSize(30)
                case .entry(let entry):
                    RuleMark(x: .value("Date", entry.timestamp, unit: .day))
                        .foregroundStyle(Color.severity(entry.severity).opacity(0.2))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                case .polar(let point):
                    // Polar overnight-session mean HR. Drawn as a separate
                    // series so it doesn't connect to the HK line — they
                    // measure different things (sliding-window resting HR
                    // vs. overnight-session aggregate).
                    LineMark(
                        x: .value("Date", point.night, unit: .day),
                        y: .value("BPM", point.value ?? 0),
                        series: .value("Source", "Polar")
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", point.night, unit: .day),
                        y: .value("BPM", point.value ?? 0)
                    )
                    .foregroundStyle(.blue)
                    .symbol(.diamond)
                    .symbolSize(40)
                }
            }
            .chartXScale(domain: dateRange)
            .frame(height: 200)
        }
    }
}
