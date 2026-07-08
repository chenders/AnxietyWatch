// AnxietyWatch/Views/Trends/PolarSessionHRDetailView.swift
import Charts
import HealthKit
import SwiftData
import SwiftUI
import os

/// Navigation transport for a coalesced overnight Polar session. Carries
/// everything `PolarSessionHRDetailView` needs to render without re-running
/// `LFHFAggregator.coalesce` inside the destination. Hashable + Codable so
/// it's a valid `.navigationDestination(item:)` payload. Equatable on all
/// stored properties — the view itself is the one that scopes equality down
/// to identity props via its own `Equatable` conformance.
nonisolated struct CoalescedNightRef: Hashable, Codable, Sendable {
    /// Matches `LFHFAggregator.CoalescedNight.id` (first member's UUID).
    let id: UUID
    let startTime: Date
    let endTime: Date
    let memberSessionIDs: [UUID]

    init(id: UUID, startTime: Date, endTime: Date, memberSessionIDs: [UUID]) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.memberSessionIDs = memberSessionIDs
    }

    init(from night: LFHFAggregator.CoalescedNight) {
        self.init(
            id: night.id,
            startTime: night.startTime,
            endTime: night.endTime,
            memberSessionIDs: night.memberSessionIDs
        )
    }
}

/// Per-minute HR detail for one coalesced overnight Polar session, with HK
/// sleep-stage bands and anxiety-entry rules overlaid. The blue diamond on
/// `HeartRateTrendChart` is the only entry point.
struct PolarSessionHRDetailView: View, Equatable {
    let night: CoalescedNightRef

    @Query private var anxietyEntries: [AnxietyEntry]

    @State private var minutePoints: [RRArchiveAggregator.HRMinutePoint] = []
    @State private var awakeIntervals: [(start: Date, end: Date)] = []
    @State private var sleepStages: [SourcedSleepStageEvent] = []
    @State private var isLoading = true

    // Equatable on `night` only: paired with `.equatable()` at the
    // navigationDestination call site so SwiftUI dedupes rebuilds when
    // TrendsView's body re-runs. The default memberwise comparison can't
    // dedupe because @Query state is part of the struct. See
    // `LFHFSessionDetailView` for the canonical pattern and CLAUDE.md
    // "Closure-based NavigationLink destinations that contain @Query".
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.night == rhs.night
    }

    init(night: CoalescedNightRef) {
        self.night = night
        // Two-clause date-window predicate on AnxietyEntry.timestamp. Safe
        // because both captured locals are `Date` (a primitive value type) —
        // the iOS 26 SwiftData hang documented in CLAUDE.md targets compound
        // ANDs of captured non-primitive locals (UUID, String), not Date.
        let lower = night.startTime
        let upper = night.endTime
        _anxietyEntries = Query(
            filter: #Predicate<AnxietyEntry> {
                $0.timestamp >= lower && $0.timestamp <= upper
            },
            sort: \.timestamp
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                chartCard
            }
            .padding(.vertical)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: night.id) {
            await loadData()
        }
    }

    private static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    // MARK: - Header

    /// True iff HK returned at least one sleep-stage event that produces a
    /// renderable band — i.e., a non-`.inBed`/non-`@unknown` event whose
    /// clip to the session window is non-empty. Matches the predicate that
    /// `sleepStageBands` uses internally, so the chart caption and the
    /// Awakenings stat stay coupled: if the chart shows no bands, both
    /// fall back; if any band renders, both surface data.
    private var hasRenderableStageData: Bool {
        let windowRange = night.startTime...night.endTime
        return sleepStages.contains { event in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: event.stage),
                  value != .inBed else { return false }
            let s = max(event.start, windowRange.lowerBound)
            let e = min(event.end, windowRange.upperBound)
            return s < e
        }
    }

    private var navigationTitle: String {
        "Night of \(Self.titleDateFormatter.string(from: night.startTime))"
    }

    private var headerCard: some View {
        let startStr = Self.timeFormatter.string(from: night.startTime)
        let endStr = Self.timeFormatter.string(from: night.endTime)
        let wear = formattedWear(seconds: night.endTime.timeIntervalSince(night.startTime))
        let memberCount = night.memberSessionIDs.count
        let memberSuffix = memberCount > 1 ? " · \(memberCount) sessions" : ""

        let validBPM = minutePoints.compactMap(\.bpm)
        let meanBPM = validBPM.isEmpty ? nil : validBPM.reduce(0, +) / Double(validBPM.count)
        let minBPM = validBPM.min()
        let maxBPM = validBPM.max()
        let awakeCount = RRArchiveAggregator.awakeIntervalCount(
            intervals: awakeIntervals,
            in: night.startTime...night.endTime
        )

        return VStack(alignment: .leading, spacing: 8) {
            Text("\(startStr) – \(endStr) · \(wear) wear\(memberSuffix)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                statColumn(label: "Mean", value: meanBPM.map { String(format: "%.0f", $0) } ?? "—", unit: "BPM")
                statColumn(label: "Min", value: minBPM.map { String(format: "%.0f", $0) } ?? "—", unit: "BPM")
                statColumn(label: "Max", value: maxBPM.map { String(format: "%.0f", $0) } ?? "—", unit: "BPM")
                statColumn(label: "Awakenings", value: hasRenderableStageData ? "\(awakeCount)" : "—", unit: "")
            }
        }
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func statColumn(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.monospacedDigit().weight(.semibold))
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formattedWear(seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return "\(h)h \(m)m"
    }

    // MARK: - Chart

    private var chartCard: some View {
        let windowRange = night.startTime...night.endTime
        let stageBands = sleepStageBands(events: sleepStages, window: windowRange)
        // Drive the "no stages" caption off the renderable bands, not the
        // raw HK events — `sleepStageBands` drops `.inBed`/`@unknown`, so an
        // in-bed-only night should still surface the caption (otherwise the
        // chart background is silently blank with no explanation).
        let hasStageData = !stageBands.isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Per-minute HR")
                    .font(.headline)
                Spacer()
            }
            if !hasStageData && !isLoading {
                Text("No sleep stages for this night")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if minutePoints.isEmpty || minutePoints.allSatisfy({ $0.bpm == nil }) {
                ContentUnavailableView(
                    "No raw HR archive for this session",
                    systemImage: "waveform.path.ecg"
                )
                .frame(minHeight: 240)
            } else {
                Chart {
                    ForEach(stageBands) { band in
                        // RectangleMark with only xStart/xEnd spans the full
                        // y-axis (Swift Charts uses the chart's plot bounds
                        // when y is omitted), which is exactly the band
                        // behavior we want overlaid behind the HR line.
                        RectangleMark(
                            xStart: .value("Start", band.start),
                            xEnd: .value("End", band.end)
                        )
                        .foregroundStyle(band.color.opacity(0.12))
                    }
                    ForEach(minutePoints) { point in
                        // nil bpm renders as a line break — the documented
                        // Swift Charts gap pattern. We DO NOT set
                        // chartYScale(domain:) so iOS 26's NaN-vs-finite-domain
                        // layout pathology doesn't fire (CLAUDE.md pitfall).
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("BPM", point.bpm ?? .nan)
                        )
                        .foregroundStyle(ChartPalette.polarHeartRate)
                        .interpolationMethod(.monotone)
                    }
                    ForEach(anxietyEntries) { entry in
                        RuleMark(x: .value("Anxiety entry", entry.timestamp))
                            .foregroundStyle(Color.severity(entry.severity).opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartXScale(domain: windowRange)
                .frame(height: 240)
            }
        }
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }

    private struct StageBand: Identifiable {
        let id: UUID
        let start: Date
        let end: Date
        let color: Color
    }

    private func sleepStageBands(
        events: [SourcedSleepStageEvent],
        window: ClosedRange<Date>
    ) -> [StageBand] {
        events.compactMap { event in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: event.stage) else { return nil }
            let color: Color
            switch value {
            case .asleepDeep: color = .indigo
            case .asleepREM:  color = .purple
            case .asleepCore, .asleepUnspecified: color = .blue
            case .awake:      color = .orange
            case .inBed:      return nil
            @unknown default: return nil
            }
            // Clip the band to the window so a sample that spills past
            // the edge doesn't extend the chart's effective x-domain.
            let s = max(event.start, window.lowerBound)
            let e = min(event.end, window.upperBound)
            guard s < e else { return nil }
            return StageBand(id: event.hkUUID, start: s, end: e, color: color)
        }
    }

    // MARK: - Data loading

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        // Clear prior-night state so a re-navigation doesn't briefly show
        // the previous night's stats while this load is in flight.
        self.minutePoints = []
        self.awakeIntervals = []
        self.sleepStages = []

        // Resolve member session IDs → .rr archive URLs (pure path derivation,
        // no I/O — `archiveURL(for:)` is just appendingPathComponent).
        let urls = night.memberSessionIDs.map(RRArchiveWriter.archiveURL(for:))
        let window = night.startTime...night.endTime
        // File I/O — run off-main so the UI stays responsive during the
        // ~100 ms archive read for a full overnight session.
        self.minutePoints = await Task.detached(priority: .userInitiated) {
            RRArchiveAggregator.perMinuteHR(rrFiles: urls, window: window)
        }.value
        guard !Task.isCancelled else { return }

        // Pad ±30 min to catch lying-down-before-falling-asleep edges.
        let hkStart = night.startTime.addingTimeInterval(-30 * 60)
        let hkEnd = night.endTime.addingTimeInterval(30 * 60)
        do {
            let events = try await HealthKitManager.shared.sleepStageEvents(
                start: hkStart, end: hkEnd
            )
            guard !Task.isCancelled else { return }
            self.sleepStages = events
            self.awakeIntervals = events
                .filter { $0.stage == HKCategoryValueSleepAnalysis.awake.rawValue }
                .map { ($0.start, $0.end) }
        } catch {
            Log.health.warning("Polar session HR detail: sleep-stage query failed: \(error.localizedDescription, privacy: .public)")
            self.sleepStages = []
            self.awakeIntervals = []
        }
    }
}

#if DEBUG
#Preview("Mock — full data") {
    let t0 = Calendar.current.date(from: DateComponents(
        year: 2026, month: 5, day: 11, hour: 23, minute: 42
    ))!
    let endT = t0.addingTimeInterval(7 * 3600 + 36 * 60)
    let ref = CoalescedNightRef(
        id: UUID(),
        startTime: t0,
        endTime: endT,
        memberSessionIDs: [UUID(), UUID()]
    )
    return NavigationStack {
        PolarSessionHRDetailView(night: ref)
    }
}
#endif
