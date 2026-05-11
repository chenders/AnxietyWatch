import Charts
import SwiftData
import SwiftUI

/// Per-minute LF/HF detail for a single Polar H10 session. The trend card
/// shows nightly means; this view shows the full ~300-point trajectory of
/// an overnight session with true gaps where the recorder couldn't compute
/// frequency-domain values (windows of <30 RR intervals).
struct LFHFSessionDetailView: View {
    let sessionID: UUID

    @Query private var readings: [HRVReading]

    init(sessionID: UUID) {
        self.sessionID = sessionID
        // Capture the shared constant into a local so the macro picks it up
        // — keeps the source label in one place if it ever changes.
        let polarSource = PolarHRMService.sourceLabel
        _readings = Query(
            filter: #Predicate<HRVReading> {
                $0.sensorSessionID == sessionID && $0.source == polarSource
            },
            sort: \.timestamp
        )
    }

    private func sessionRange(for points: [LFHFAggregator.LFHFPoint]) -> ClosedRange<Date>? {
        guard let first = points.first?.timestamp, let last = points.last?.timestamp else { return nil }
        return first...last
    }

    var body: some View {
        // Compute once per render — `gappedPerMinutePoints` does a sort + map
        // of the full readings array, and it used to fan out to ~5 callsites
        // (empty check, title, summary, sessionRange, each sub-chart).
        let points = LFHFAggregator.gappedPerMinutePoints(from: readings)
        let title = points.first?.timestamp.formatted(date: .abbreviated, time: .shortened) ?? "Session"
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if points.isEmpty {
                    ContentUnavailableView(
                        "No Readings",
                        systemImage: "waveform.path.ecg",
                        description: Text("This session didn't produce any HRV windows.")
                    )
                    .padding(.top, 60)
                } else {
                    summaryCard(points: points)
                    if let range = sessionRange(for: points) {
                        hfChart(points: points, range: range)
                        lfChart(points: points, range: range)
                        ratioChart(points: points, range: range)
                        legend
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func summaryCard(points: [LFHFAggregator.LFHFPoint]) -> some View {
        let validCount = points.compactMap(\.hfPower).count
        let totalCount = points.count
        let hfMean = LFHFAggregator.outlierTrimmedMean(of: points.compactMap(\.hfPower))
        let ratioMean = LFHFAggregator.outlierTrimmedMean(of: points.compactMap(\.lfHfRatio))
        HStack(spacing: 24) {
            metricColumn(label: "Windows", value: "\(validCount)/\(totalCount)")
            if let mean = hfMean {
                metricColumn(label: "HF mean", value: String(format: "%.0f ms²", mean))
            }
            if let ratio = ratioMean {
                metricColumn(label: "LF/HF mean", value: String(format: "%.2f", ratio))
            }
        }
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func metricColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
    }

    @ViewBuilder
    private func hfChart(points: [LFHFAggregator.LFHFPoint], range: ClosedRange<Date>) -> some View {
        // Passing .nan when a window has no frequency data tells Swift Charts
        // to break the line at that x — the visual gap the clinical lens asked
        // for, instead of silently connecting across missing minutes.
        let upper = LFHFAggregator.robustUpperBound(of: points.compactMap(\.hfPower))
        sectionedChart(title: "HF Power (ms²)", range: range, yMax: upper) {
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("HF", point.hfPower ?? .nan)
                )
                .foregroundStyle(.teal)
            }
        }
    }

    @ViewBuilder
    private func lfChart(points: [LFHFAggregator.LFHFPoint], range: ClosedRange<Date>) -> some View {
        let upper = LFHFAggregator.robustUpperBound(of: points.compactMap(\.lfPower))
        sectionedChart(title: "LF Power (ms²)", range: range, yMax: upper) {
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("LF", point.lfPower ?? .nan)
                )
                .foregroundStyle(.indigo)
            }
        }
    }

    @ViewBuilder
    private func ratioChart(points: [LFHFAggregator.LFHFPoint], range: ClosedRange<Date>) -> some View {
        // Ratio doesn't get y-clipping — it's already bounded in practice and
        // the balance reference line at 1.0 needs the natural scale to read.
        sectionedChart(title: "LF/HF Ratio", range: range, yMax: nil) {
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("LF/HF", point.lfHfRatio ?? .nan)
                )
                .foregroundStyle(.primary.opacity(0.85))
            }
            RuleMark(y: .value("Balance", 1.0))
                .foregroundStyle(.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(dash: [3, 3]))
        }
    }

    @ViewBuilder
    private func sectionedChart<Marks: ChartContent>(
        title: String,
        range: ClosedRange<Date>,
        yMax: Double?,
        @ChartContentBuilder content: () -> Marks
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if let yMax {
                Chart { content() }
                    .chartXScale(domain: range)
                    .chartYScale(domain: 0...yMax)
                    .frame(height: 140)
                    .padding(.horizontal)
            } else {
                Chart { content() }
                    .chartXScale(domain: range)
                    .frame(height: 140)
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Gaps = minutes with fewer than 30 RR intervals (not low autonomic activity).")
            Text(
                "HF and LF y-axes are clipped at the 95th percentile so an artifact " +
                "window (motion, ectopic beat) can't compress the rest of the trace. " +
                "The summary mean above is similarly outlier-trimmed."
            )
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
    }
}

#if DEBUG
private struct LFHFSessionDetailPreviewWrapper: View {
    @Query(sort: \SensorSession.startTime, order: .reverse) private var sessions: [SensorSession]

    var body: some View {
        if let session = sessions.first(where: { session in
            guard let end = session.endTime else { return false }
            return end.timeIntervalSince(session.startTime) >= LFHFAggregator.overnightThresholdSeconds
        }) {
            LFHFSessionDetailView(sessionID: session.id)
        } else {
            ContentUnavailableView("No seeded overnight session", systemImage: "moon.zzz")
        }
    }
}

#Preview {
    NavigationStack {
        LFHFSessionDetailPreviewWrapper()
            .modelContainer(try! PreviewHelpers.makeSeededContainer())
    }
}
#endif
