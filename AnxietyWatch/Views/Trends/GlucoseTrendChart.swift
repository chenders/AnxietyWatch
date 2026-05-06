import Charts
import Foundation
import SwiftUI

/// Daily glucose chart styled to mirror `HRVTrendChart` / `HeartRateTrendChart`:
/// a smooth LineMark + PointMark of `bloodGlucoseAvg`, a dashed RuleMark at the
/// rolling mean labelled `avg`, anxiety-entry vertical markers, and a small
/// CV% bar row beneath. Days whose `dataQuality.glucose.reliability == "low"`
/// render with a muted point + asterisk so the user can see the average is
/// built on sparse data.
struct GlucoseTrendChart: View {
    let snapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    private var datums: [GlucoseTrendDatum] {
        GlucoseTrendDatum.from(snapshots: snapshots)
    }

    private var rollingMean: Double? {
        GlucoseTrendDatum.rollingMean(datums)
    }

    /// Mean CV% across the visible window. nil when no day has CV.
    private var meanCV: Double? {
        let cvs = datums.compactMap { $0.cv }
        guard !cvs.isEmpty else { return nil }
        return cvs.reduce(0, +) / Double(cvs.count)
    }

    private var subtitle: String {
        let avgDayCount = datums.count
        let cvDayCount = datums.compactMap { $0.cv }.count
        return GlucoseTrendDatum.subtitle(
            meanCV: meanCV,
            avgDayCount: avgDayCount,
            cvDayCount: cvDayCount
        )
    }

    var body: some View {
        ChartCard(
            title: "Glucose",
            subtitle: subtitle,
            isEmpty: datums.isEmpty
        ) {
            Chart {
                ForEach(datums) { d in
                    LineMark(
                        x: .value("Date", d.date, unit: .day),
                        y: .value("mg/dL", d.avg)
                    )
                    .foregroundStyle(.purple)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", d.date, unit: .day),
                        y: .value("mg/dL", d.avg)
                    )
                    .foregroundStyle(.purple.opacity(d.isLowReliability ? 0.4 : 1.0))
                    .symbolSize(30)
                    .annotation(position: .top, spacing: 1) {
                        if d.isLowReliability {
                            Text("*")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let mean = rollingMean {
                    RuleMark(y: .value("Avg", mean))
                        .foregroundStyle(.green.opacity(0.6))
                        .lineStyle(StrokeStyle(dash: [5, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("avg")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                }

                ForEach(entries) { entry in
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
            .chartYAxisLabel("mg/dL")
            .frame(height: 220)

            // CV% mini-bar row beneath. Same color ladder as the
            // glucose tile's CV badge to keep the visual story consistent.
            let cvData = datums.compactMap { d -> GlucoseCVDatum? in
                guard let cv = d.cv else { return nil }
                return GlucoseCVDatum(date: d.date, cv: cv)
            }
            if !cvData.isEmpty {
                Chart(cvData) { c in
                    BarMark(
                        x: .value("Date", c.date, unit: .day),
                        y: .value("CV%", c.cv)
                    )
                    .foregroundStyle(ClinicalSeverity.glucoseCVSeverity(c.cv).color.gradient)
                }
                .chartXScale(domain: dateRange)
                .chartYAxisLabel("CV (%)")
                .frame(height: 70)
            }
        }
    }
}

// MARK: - Pure-function data prep (testable)

/// Per-day chart point. Pure value type so the data-prep can be unit tested
/// without touching SwiftUI view bodies.
struct GlucoseTrendDatum: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let avg: Double
    let cv: Double?
    /// True when this day's `dataQuality.glucose.reliability == "low"`.
    /// Used to mute the point and add an asterisk in the chart annotation.
    let isLowReliability: Bool
}

extension GlucoseTrendDatum {
    /// Build chart datums from snapshots. Drops snapshots with no
    /// `bloodGlucoseAvg` (the chart has nothing to plot for them) and parses
    /// the `dataQuality` JSON to flag low-reliability days. Robust against a
    /// nil or malformed `dataQuality` blob — those days simply default to
    /// `isLowReliability = false`.
    static func from(snapshots: [HealthSnapshot]) -> [GlucoseTrendDatum] {
        snapshots.compactMap { snap in
            guard let avg = snap.bloodGlucoseAvg else { return nil }
            return GlucoseTrendDatum(
                date: snap.date,
                avg: avg,
                cv: snap.glucoseCV,
                isLowReliability: parseGlucoseLowReliability(snap.dataQuality)
            )
        }
    }

    /// Simple arithmetic mean across the visible window. The plan calls this
    /// the "7-day rolling mean" — for the typical 7-day Trends view, the
    /// visible window already is 7 days, so the visible-window mean is the
    /// rolling mean. Returns nil when the array is empty.
    static func rollingMean(_ datums: [GlucoseTrendDatum]) -> Double? {
        guard !datums.isEmpty else { return nil }
        let total = datums.reduce(0.0) { $0 + $1.avg }
        return total / Double(datums.count)
    }

    /// Build the chart subtitle so the user knows what window the average and
    /// CV summarize. Disambiguates the avg-day count from the cv-day count when
    /// they differ (most days will have both, but recent low-data days may have
    /// only the avg). When they match, collapses to a single "over N days" for
    /// cleanliness. When `meanCV` is nil, no CV phrase is included.
    static func subtitle(meanCV: Double?, avgDayCount: Int, cvDayCount: Int) -> String {
        guard let cv = meanCV else {
            return "Daily avg over \(avgDayCount) days"
        }
        if cvDayCount == avgDayCount {
            return String(format: "Daily avg · CV %.0f%% over %d days", cv, avgDayCount)
        }
        return String(
            format: "Daily avg · CV %.0f%% over %d of %d days",
            cv, cvDayCount, avgDayCount
        )
    }

    /// Parse the `dataQuality` JSON blob and return whether the
    /// `glucose.reliability` field equals `"low"`. Defaults to false on any
    /// failure so a missing or mangled JSON blob never breaks the chart.
    private static func parseGlucoseLowReliability(_ json: String?) -> Bool {
        guard
            let json,
            let data = json.data(using: .utf8),
            let any = try? JSONSerialization.jsonObject(with: data, options: []),
            let top = any as? [String: Any],
            let glucose = top["glucose"] as? [String: Any],
            let reliability = glucose["reliability"] as? String
        else {
            return false
        }
        return reliability == "low"
    }
}

/// CV%-per-day point for the secondary mini-bar chart row. Identifiable so the
/// Chart content builder has a single concrete shape (same trick as
/// `SleepRespiratoryTrendChart`).
private struct GlucoseCVDatum: Identifiable {
    var id: Date { date }
    let date: Date
    let cv: Double
}
