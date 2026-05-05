import Charts
import SwiftData
import SwiftUI

/// Combined overnight respiratory chart: AHI bars + SpO₂ nadir line + T90 bars
/// + CPAP usage hours, with a desat-count mini-row in the subtitle.
struct SleepRespiratoryTrendChart: View {
    let sessions: [CPAPSession]
    let snapshots: [HealthSnapshot]
    /// Full history needed for baseline calculation
    let allSnapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    private var ahiBaseline: BaselineCalculator.BaselineResult? {
        BaselineCalculator.cpapAHIBaseline(from: allSnapshots)
    }

    /// Unified data point for the AHI chart — avoids ForEach/MapContentBuilder
    /// ambiguity that occurs on some Xcode versions when Charts and MapKit
    /// cross-import overlays are both active.
    private struct AHIDatum: Identifiable {
        let id: UUID
        let date: Date
        let ahi: Double
        let color: Color
    }

    private var ahiData: [AHIDatum] {
        sessions.map {
            AHIDatum(id: $0.id, date: $0.date, ahi: $0.ahi, color: ahiColor($0.ahi))
        }
    }

    /// Date doubles as the stable identity — one snapshot per calendar day.
    private struct NadirDatum: Identifiable {
        var id: Date { date }
        let date: Date
        let value: Double
    }

    private var nadirData: [NadirDatum] {
        snapshots.compactMap { snap in
            snap.spo2NadirOvernight.map { NadirDatum(date: snap.date, value: $0) }
        }
    }

    private struct T90Datum: Identifiable {
        var id: Date { date }
        let date: Date
        let minutes: Int
        let color: Color
    }

    private var t90Data: [T90Datum] {
        snapshots.compactMap { snap in
            snap.spo2TimeBelow90Min.map {
                T90Datum(date: snap.date, minutes: $0,
                         color: ClinicalSeverity.t90Severity($0).color)
            }
        }
    }

    private var desatSparkline: String? {
        // Aggregate summary rather than a per-night dot string. A 90-night
        // window would otherwise produce an unreadable paragraph in the
        // ChartCard subtitle (which doesn't line-limit).
        let ds = snapshots.compactMap(\.spo2DesatsCount)
        guard !ds.isEmpty else { return nil }
        let avg = Double(ds.reduce(0, +)) / Double(ds.count)
        return String(format: "avg %.1f desats/night across %d night%@",
                      avg, ds.count, ds.count == 1 ? "" : "s")
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let baseline = ahiBaseline {
            parts.append(String(format: "30-day AHI avg: %.1f events/hr", baseline.mean))
        }
        if let desats = desatSparkline {
            parts.append(desats)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var hasAnyData: Bool {
        !sessions.isEmpty || !nadirData.isEmpty || !t90Data.isEmpty
    }

    var body: some View {
        ChartCard(
            title: "Sleep Respiratory",
            subtitle: subtitle,
            isEmpty: !hasAnyData
        ) {
            // AHI bars (typical 0–30 range). Kept as its own chart so the
            // SpO₂ nadir line — which lives at 75–100% — doesn't squash the
            // AHI bars into the bottom 30% of a shared y-axis.
            if !ahiData.isEmpty {
                Chart(ahiData) { d in
                    BarMark(
                        x: .value("Date", d.date, unit: .day),
                        y: .value("AHI", d.ahi)
                    )
                    .foregroundStyle(d.color.gradient)
                }
                .chartOverlay(content: ahiBaselineOverlay)
                .chartOverlay(content: anxietyEntriesOverlay)
                .chartXScale(domain: dateRange)
                .chartYAxisLabel("AHI (events/hr)")
                .frame(height: 160)
            }

            // SpO₂ nadir line. Domain floor adapts to the actual data so a
            // severe night (e.g., nadir 65%) isn't clipped at the chart
            // floor; default cap is 75 so day-to-day variation in the
            // common 85–99 range stays legible.
            if !nadirData.isEmpty {
                let observedMin = nadirData.map(\.value).min() ?? 75
                let domainFloor = min(75, observedMin - 2)
                Chart(nadirData) { n in
                    LineMark(
                        x: .value("Date", n.date, unit: .day),
                        y: .value("Nadir %", n.value)
                    )
                    .foregroundStyle(.green)
                    .symbol(.circle)
                    .symbolSize(30)
                }
                .chartXScale(domain: dateRange)
                .chartYScale(domain: domainFloor...100)
                .chartYAxisLabel("SpO₂ nadir (%)")
                .frame(height: 110)
            }

            // T90 bars
            if !t90Data.isEmpty {
                Chart(t90Data) { d in
                    BarMark(
                        x: .value("Date", d.date, unit: .day),
                        y: .value("Minutes", d.minutes)
                    )
                    .foregroundStyle(d.color.gradient)
                }
                .chartXScale(domain: dateRange)
                .chartYAxisLabel("T90 (min <90% SpO₂)")
                .frame(height: 100)
            }

            // CPAP usage hours
            if !sessions.isEmpty {
                Chart(sessions) { session in
                    let hours = Double(session.totalUsageMinutes) / 60.0
                    BarMark(
                        x: .value("Date", session.date, unit: .day),
                        y: .value("Hours", hours)
                    )
                    .foregroundStyle(.teal.gradient)
                }
                .chartXScale(domain: dateRange)
                .chartYAxisLabel("Usage (hours)")
                .frame(height: 100)
            }
        }
    }

    private func ahiBaselineOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let baseline = ahiBaseline,
               let meanY = proxy.position(forY: baseline.mean) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: meanY))
                    path.addLine(to: CGPoint(x: geo.size.width, y: meanY))
                }
                .stroke(.green.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))

                Text("avg")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .position(x: geo.size.width - 12, y: meanY - 8)

                if let upperY = proxy.position(forY: baseline.upperBound) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: upperY))
                        path.addLine(to: CGPoint(x: geo.size.width, y: upperY))
                    }
                    .stroke(.red.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
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

    private func ahiColor(_ ahi: Double) -> Color {
        ClinicalSeverity.ahiSeverity(ahi).color
    }
}
