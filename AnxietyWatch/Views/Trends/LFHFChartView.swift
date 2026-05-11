import Charts
import SwiftUI

/// HF-power trend across overnight Polar H10 sessions, with a personal
/// 30-day baseline rule and a headline number for the most recent session.
struct LFHFChartView: View {
    let windowMeans: [LFHFAggregator.NightlyMean]
    /// Full-history overnight means used to compute the 30-day baseline.
    let allOvernightMeans: [LFHFAggregator.NightlyMean]
    let dateRange: ClosedRange<Date>
    /// Right edge of the *unpadded* window. `dateRange.upperBound` carries
    /// a +12h padding for chart axis breathing room — using that for the
    /// baseline cutoff would exclude legitimate late-evening sessions on
    /// the last day of a past period.
    let baselineAnchor: Date

    @State private var showExplainer = false

    private var validWindowMeans: [LFHFAggregator.NightlyMean] {
        windowMeans.filter { $0.hfMean != nil }
    }

    /// Most recent overnight session in the window, valid or not. Headline +
    /// accessibility describe this session honestly — if its `hfMean` is nil,
    /// the UI shows "—" instead of falling back to an older session and
    /// misleadingly calling it "latest."
    private var latestSession: LFHFAggregator.NightlyMean? {
        windowMeans.max { $0.night < $1.night }
    }

    private var hfBaseline: Double? {
        LFHFAggregator.hfBaseline(from: allOvernightMeans, anchor: baselineAnchor)
    }

    private var delta: Double? {
        guard let latestHF = latestSession?.hfMean, let baseline = hfBaseline else { return nil }
        return LFHFAggregator.relativeDelta(value: latestHF, baseline: baseline)
    }

    private var baselineSubtitle: String? {
        guard let baseline = hfBaseline else {
            if windowMeans.isEmpty { return nil }
            if validWindowMeans.isEmpty {
                return "No valid frequency-domain windows in this period"
            }
            return "Baseline needs 3+ overnight sessions in the last 30 days"
        }
        let status: String
        if let d = delta {
            status = d < LFHFAggregator.belowBaselineThreshold ? "⚠ Below baseline" : "Within normal range"
        } else {
            // Baseline exists, but the latest session in this window has no
            // valid HF — say so explicitly instead of rendering an em-dash.
            status = "Last session has no valid data"
        }
        return String(format: "30-day avg: %.0f ms² · %@", baseline, status)
    }

    var body: some View {
        // isEmpty branches off `windowMeans` (sessions in window), not
        // `validWindowMeans` (sessions with plottable HF), so a window
        // full of all-sentinel sessions still renders the card shell --
        // info button stays reachable and the drill-down still works.
        ChartCard(
            title: "HRV Frequency Power",
            subtitle: baselineSubtitle,
            isEmpty: windowMeans.isEmpty
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    headline
                    Spacer()
                    Button {
                        showExplainer = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About LF/HF")
                }
                // NavigationLink wraps the charts only so the info button
                // above stays independently hittable. The accessibility
                // summary lives here, not on the whole card, so VoiceOver
                // doesn't collapse the info button and the drill-down into
                // a single element.
                NavigationLink {
                    LFHFSessionsListView()
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        hfChart
                        lfChart
                        ratioChart
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilitySummary)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showExplainer) {
            LFHFExplainerSheet()
        }
    }

    private var accessibilitySummary: String {
        if windowMeans.isEmpty {
            return "LF/HF heart rate variability card. No overnight sessions yet."
        }
        let plural = windowMeans.count == 1 ? "session" : "sessions"
        guard let session = latestSession, let hf = session.hfMean else {
            return "LF/HF heart rate variability card. " +
                "\(windowMeans.count) \(plural) in window. " +
                "Last session has no valid frequency-domain data."
        }
        var parts: [String] = []
        parts.append("LF/HF heart rate variability card.")
        // Round before truncating so the spoken value matches the on-screen
        // `%.0f` rounding instead of always rounding down.
        parts.append("Latest overnight HF mean \(Int(hf.rounded())) milliseconds squared.")
        if let ratio = session.lfHfMean {
            parts.append(String(format: "Ratio %.2f.", ratio))
        }
        if let d = delta {
            let sign = d >= 0 ? "above" : "below"
            parts.append("\(Int(abs(d * 100).rounded())) percent \(sign) 30-day average.")
        }
        parts.append("\(windowMeans.count) sessions in current window.")
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HF Power · last overnight")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let hf = latestSession?.hfMean {
                    Text(String(format: "%.0f", hf))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle((delta ?? 0) < LFHFAggregator.belowBaselineThreshold ? .orange : .primary)
                    Text("ms²")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let ratio = latestSession?.lfHfMean {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.2f", ratio))
                            .font(.system(.title3, design: .rounded).weight(.medium))
                            .foregroundStyle(.primary.opacity(0.85))
                        Text("LF/HF")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let d = delta {
                Text(String(format: "%+.0f%% vs 30-day avg", d * 100))
                    .font(.caption)
                    .foregroundStyle(d < LFHFAggregator.belowBaselineThreshold ? .orange : .secondary)
            }
        }
    }

    @ViewBuilder
    private var hfChart: some View {
        Chart {
            ForEach(validWindowMeans) { mean in
                LineMark(
                    x: .value("Date", mean.night, unit: .day),
                    y: .value("HF (ms²)", mean.hfMean!)
                )
                .foregroundStyle(.teal)
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", mean.night, unit: .day),
                    y: .value("HF (ms²)", mean.hfMean!)
                )
                .foregroundStyle(.teal)
                .symbolSize(30)
            }
            if let baseline = hfBaseline {
                RuleMark(y: .value("Baseline", baseline))
                    .foregroundStyle(.green.opacity(0.6))
                    .lineStyle(StrokeStyle(dash: [5, 3]))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("avg")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
            }
        }
        .chartXScale(domain: dateRange)
        .frame(height: 180)
    }

    private var lfWindowMeans: [LFHFAggregator.NightlyMean] {
        windowMeans.filter { $0.lfMean != nil }
    }

    @ViewBuilder
    private var lfChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LF Power")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Chart {
                ForEach(lfWindowMeans) { mean in
                    LineMark(
                        x: .value("Date", mean.night, unit: .day),
                        y: .value("LF (ms²)", mean.lfMean!)
                    )
                    .foregroundStyle(.indigo)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", mean.night, unit: .day),
                        y: .value("LF (ms²)", mean.lfMean!)
                    )
                    .foregroundStyle(.indigo)
                    .symbolSize(24)
                }
            }
            .chartXScale(domain: dateRange)
            .frame(height: 100)
        }
    }

    private var ratioWindowMeans: [LFHFAggregator.NightlyMean] {
        windowMeans.filter { $0.lfHfMean != nil }
    }

    @ViewBuilder
    private var ratioChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LF/HF Ratio")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Chart {
                ForEach(ratioWindowMeans) { mean in
                    LineMark(
                        x: .value("Date", mean.night, unit: .day),
                        y: .value("LF/HF", mean.lfHfMean!)
                    )
                    .foregroundStyle(.primary.opacity(0.85))
                    .interpolationMethod(.catmullRom)
                }
                RuleMark(y: .value("Balance", 1.0))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(dash: [3, 3]))
            }
            .chartXScale(domain: dateRange)
            .frame(height: 60)
        }
    }
}

#if DEBUG
#Preview("With data") {
    let now = Date(timeIntervalSince1970: 1_711_929_600)
    let calendar = Calendar.current
    var readings: [HRVReading] = []
    for nightIdx in 0..<4 {
        let start = calendar.date(byAdding: .day, value: -(nightIdx * 2 + 1), to: now)!
        let sessionID = UUID()
        for minute in 0..<300 {
            readings.append(HRVReading(
                timestamp: start.addingTimeInterval(Double(minute) * 60),
                rmssd: 40, sdnn: 50, pnn50: 10,
                lfPower: 90 + Double(nightIdx) * 5 + sin(Double(minute) / 30) * 15,
                hfPower: 50 + Double(nightIdx) * 4 + cos(Double(minute) / 30) * 10,
                lfHfRatio: 1.8 + Double(nightIdx) * 0.1,
                sensorSessionID: sessionID,
                source: PolarHRMService.sourceLabel
            ))
        }
    }
    let means = LFHFAggregator.nightlyMeans(from: readings)
    let weekAgo = calendar.date(byAdding: .day, value: -10, to: now)!
    return LFHFChartView(
        windowMeans: means,
        allOvernightMeans: means,
        dateRange: weekAgo...now.addingTimeInterval(12 * 3600),
        baselineAnchor: now
    )
    .padding()
}

#Preview("Empty") {
    let now = Date(timeIntervalSince1970: 1_711_929_600)
    let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!
    return LFHFChartView(
        windowMeans: [],
        allOvernightMeans: [],
        dateRange: weekAgo...now,
        baselineAnchor: now
    )
    .padding()
}
#endif
