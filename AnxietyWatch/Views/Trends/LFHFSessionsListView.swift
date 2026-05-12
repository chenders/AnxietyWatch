import SwiftData
import SwiftUI

/// Newest-first list of overnight Polar H10 sessions, the drill-down
/// destination from the LF/HF trend card. Manual short sessions are
/// excluded for the same reason they're excluded from the trend chart:
/// they're not comparable to overnight captures.
struct LFHFSessionsListView: View {
    // Source-filtered at the SwiftData layer — the per-minute HRVReading
    // table grows unboundedly over time, and loading non-Polar rows here
    // (or any non-Polar SensorSession) is pure waste for this view.
    @Query(
        filter: #Predicate<SensorSession> { $0.source == "polar_h10" },
        sort: \SensorSession.startTime,
        order: .reverse
    )
    private var allSessions: [SensorSession]
    @Query(
        filter: #Predicate<HRVReading> { $0.source == "polar_h10" },
        sort: \HRVReading.timestamp
    )
    private var allReadings: [HRVReading]

    private var overnightSessions: [SensorSession] {
        allSessions.filter { session in
            guard let end = session.endTime else { return false }
            return end.timeIntervalSince(session.startTime) >= LFHFAggregator.overnightThresholdSeconds
        }
    }

    /// Accepts the already-filtered sessions array rather than re-filtering
    /// `allSessions` itself — `body` computes `overnightSessions` once and
    /// hands it in, so this helper costs one map+filter, not two.
    private func meansBySessionID(
        for sessions: [SensorSession]
    ) -> [UUID: LFHFAggregator.NightlyMean] {
        let overnightIDs = Set(sessions.map(\.id))
        let sessionStartTimes = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.startTime) })
        let overnightReadings = allReadings.filter {
            guard let sid = $0.sensorSessionID else { return false }
            return overnightIDs.contains(sid)
        }
        let means = LFHFAggregator.nightlyMeans(
            from: overnightReadings,
            sessionStartTimes: sessionStartTimes
        )
        return Dictionary(uniqueKeysWithValues: means.map { ($0.id, $0) })
    }

    var body: some View {
        let sessions = overnightSessions
        // Short-circuit the means computation entirely when there are no
        // sessions — no point scanning `allReadings` to render the empty
        // state.
        let means: [UUID: LFHFAggregator.NightlyMean] = sessions.isEmpty ? [:] : meansBySessionID(for: sessions)
        List {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Overnight Sessions",
                    systemImage: "moon.zzz",
                    description: Text("Sessions of 3 hours or longer will appear here.")
                )
            } else {
                ForEach(sessions) { session in
                    // `.equatable()` lets SwiftUI use the destination's
                    // sessionID-only `==` to dedupe rebuilds when this
                    // view's body re-runs. Without it, the destination's
                    // @Query state defeats SwiftUI's default memberwise
                    // comparison and a parent re-render storm cascades
                    // into a CA::Layer use-after-free on iOS 26.
                    NavigationLink {
                        LFHFSessionDetailView(sessionID: session.id).equatable()
                    } label: {
                        LFHFSessionRow(session: session, mean: means[session.id])
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("HRV Sessions")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        LFHFSessionsListView()
            .modelContainer(try! PreviewHelpers.makeSeededContainer())
    }
}
#endif

private struct LFHFSessionRow: View {
    let session: SensorSession
    let mean: LFHFAggregator.NightlyMean?

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f
    }()

    private var durationLabel: String {
        guard let end = session.endTime else { return "—" }
        let interval = end.timeIntervalSince(session.startTime)
        return Self.durationFormatter.string(from: interval) ?? "—"
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.body)
                Text(durationLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let hf = mean?.hfMean {
                    Text(String(format: "%.0f ms²", hf))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.teal)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
                if let ratio = mean?.lfHfMean {
                    Text(String(format: "LF/HF %.2f", ratio))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let count = mean?.validWindowCount {
                    Text("\(count) windows")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
