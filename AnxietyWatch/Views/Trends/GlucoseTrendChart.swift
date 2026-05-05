import Charts
import SwiftUI

/// Daily glucose chart: range band (min↔max), avg line, and CV% on a
/// secondary axis. Mirrors the anxiety overlay pattern of other Trends charts.
struct GlucoseTrendChart: View {
    let snapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    /// Daily snapshot of glucose stats. Typed (rather than tuple) and
    /// Identifiable so the Chart content builder can disambiguate against
    /// MapKit's MapContentBuilder cross-import overlay on watchOS — the
    /// same trick the AHIDatum struct uses in SleepRespiratoryTrendChart.
    private struct GlucoseDatum: Identifiable {
        var id: Date { date }
        let date: Date
        let avg: Double?
        let min: Double?
        let max: Double?
        let cv: Double?
    }

    /// Derived from GlucoseDatum, but only for days with both min and max
    /// — keeps the AreaMark ForEach unconditional so the result builder
    /// has a single content shape rather than a conditional inside it.
    private struct GlucoseRangeDatum: Identifiable {
        var id: Date { date }
        let date: Date
        let min: Double
        let max: Double
    }

    private struct GlucoseAvgDatum: Identifiable {
        var id: Date { date }
        let date: Date
        let avg: Double
    }

    private struct GlucoseCVDatum: Identifiable {
        var id: Date { date }
        let date: Date
        let cv: Double
    }

    private var data: [GlucoseDatum] {
        // Include a snapshot if any glucose stat is populated, even if some
        // fields are nil — the CV-only secondary chart still renders for
        // sparse-day rows that lack a primary-chart band/avg.
        snapshots.compactMap { snap in
            let hasAny = snap.bloodGlucoseAvg != nil
                || snap.glucoseMin != nil
                || snap.glucoseMax != nil
                || snap.glucoseCV != nil
            return hasAny
                ? GlucoseDatum(date: snap.date,
                               avg: snap.bloodGlucoseAvg,
                               min: snap.glucoseMin,
                               max: snap.glucoseMax,
                               cv: snap.glucoseCV)
                : nil
        }
    }

    private var rangeData: [GlucoseRangeDatum] {
        data.compactMap { d in
            guard let mn = d.min, let mx = d.max else { return nil }
            return GlucoseRangeDatum(date: d.date, min: mn, max: mx)
        }
    }

    private var avgData: [GlucoseAvgDatum] {
        data.compactMap { d in d.avg.map { GlucoseAvgDatum(date: d.date, avg: $0) } }
    }

    private var cvData: [GlucoseCVDatum] {
        data.compactMap { d in d.cv.map { GlucoseCVDatum(date: d.date, cv: $0) } }
    }

    var body: some View {
        ChartCard(
            title: "Glucose",
            subtitle: "Daily avg with min/max range and variability",
            isEmpty: data.isEmpty
        ) {
            Chart {
                ForEach(rangeData) { r in
                    AreaMark(
                        x: .value("Date", r.date, unit: .day),
                        yStart: .value("Min", r.min),
                        yEnd: .value("Max", r.max)
                    )
                    .foregroundStyle(Color.purple.opacity(0.18))
                }
                ForEach(avgData) { a in
                    LineMark(
                        x: .value("Date", a.date, unit: .day),
                        y: .value("Avg", a.avg)
                    )
                    .foregroundStyle(.purple)
                    .symbol(.circle)
                    .symbolSize(20)
                }
            }
            .chartOverlay(content: anxietyEntriesOverlay)
            .chartXScale(domain: dateRange)
            .chartYAxisLabel("mg/dL")
            .frame(height: 180)

            // CV% as a secondary chart row.
            if !cvData.isEmpty {
                Chart(cvData) { entry in
                    BarMark(
                        x: .value("Date", entry.date, unit: .day),
                        y: .value("CV%", entry.cv)
                    )
                    .foregroundStyle(ClinicalSeverity.glucoseCVSeverity(entry.cv).color.gradient)
                }
                .chartXScale(domain: dateRange)
                .chartYAxisLabel("CV (%)")
                .frame(height: 90)
            }
        }
    }

    private func anxietyEntriesOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            ForEach(entries) { entry in
                if let xPos = proxy.position(forX: entry.timestamp) {
                    Path { path in
                        path.move(to: CGPoint(x: xPos, y: 0))
                        path.addLine(to: CGPoint(x: xPos, y: geo.size.height))
                    }
                    .stroke(Color.severity(entry.severity).opacity(0.25), lineWidth: 2)

                    Text("\(entry.severity)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.severity(entry.severity))
                        .position(x: xPos, y: 4)
                }
            }
        }
    }
}
