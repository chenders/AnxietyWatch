import Charts
import SwiftUI

/// Combined chart datum for the RMSSD trend. Polar-only — HealthKit does
/// not surface RMSSD as a quantity type. Anxiety entries render as
/// background rule marks for context, matching the rest of the trend stack.
enum RMSSDTrendDatum: Identifiable {
    case polar(LFHFAggregator.NightlyValue)
    case entry(AnxietyEntry)

    var id: String {
        switch self {
        case .polar(let p): "polar-\(p.id)"
        case .entry(let e): "entry-\(e.id)"
        }
    }

    /// Builds the combined datum array. Polar points with nil values are
    /// filtered out so the view body can render without nil-checks. The
    /// upstream aggregator (`LFHFAggregator.nightlyRMSSD`) already filters,
    /// but the defensive filter here means the view contract holds even if
    /// the data shape changes.
    static func from(
        polarSeries: [LFHFAggregator.NightlyValue],
        entries: [AnxietyEntry]
    ) -> [RMSSDTrendDatum] {
        let polarDatums = polarSeries
            .filter { $0.value != nil }
            .map(RMSSDTrendDatum.polar)
        let entryDatums = entries.map(RMSSDTrendDatum.entry)
        return polarDatums + entryDatums
    }

    /// True when at least one Polar point has a value. Entries alone aren't
    /// enough — they're context, not the metric.
    static func hasAnyData(polarSeries: [LFHFAggregator.NightlyValue]) -> Bool {
        polarSeries.contains { $0.value != nil }
    }
}

/// Trend card for overnight RMSSD (root-mean-square of successive RR
/// differences, in ms) from Polar sessions. Modelled on the existing HRV
/// (SDNN) chart's vocabulary so the new card reads as part of the same
/// trend stack rather than a separate visual idiom.
struct RMSSDTrendChart: View {
    let polarSeries: [LFHFAggregator.NightlyValue]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    var body: some View {
        let hasData = RMSSDTrendDatum.hasAnyData(polarSeries: polarSeries)
        let datums = RMSSDTrendDatum.from(polarSeries: polarSeries, entries: entries)
        ChartCard(
            title: "Heart Rate Variability (RMSSD)",
            subtitle: "Polar overnight · parasympathetic index",
            isEmpty: !hasData
        ) {
            Chart(datums) { datum in
                switch datum {
                case .polar(let point):
                    LineMark(
                        x: .value("Date", point.night, unit: .day),
                        y: .value("RMSSD (ms)", point.value ?? 0)
                    )
                    .foregroundStyle(ChartPalette.polarRMSSD)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", point.night, unit: .day),
                        y: .value("RMSSD (ms)", point.value ?? 0)
                    )
                    .foregroundStyle(ChartPalette.polarRMSSD)
                    .symbol(.diamond)
                    .symbolSize(40)
                case .entry(let entry):
                    RuleMark(x: .value("Date", entry.timestamp, unit: .day))
                        .foregroundStyle(Color.severity(entry.severity).opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .annotation(position: .top, spacing: 0) {
                            Text("\(entry.severity)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.severity(entry.severity))
                        }
                }
            }
            .chartXScale(domain: dateRange)
            .frame(height: 220)
        }
    }
}
