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
    /// Identity payloads for each Polar diamond, in display order. Used by
    /// the chart overlay to resolve a tap x-position back to a navigable
    /// `CoalescedNightRef`. Empty → no tap regions (chart still renders).
    let coalescedNights: [CoalescedNightRef]
    /// Set by the overlay when the user taps a diamond. The parent uses
    /// this to drive `.navigationDestination(item:)`.
    @Binding var tappedNight: CoalescedNightRef?

    init(
        snapshots: [HealthSnapshot],
        entries: [AnxietyEntry],
        polarSeries: [LFHFAggregator.NightlyValue] = [],
        dateRange: ClosedRange<Date>,
        coalescedNights: [CoalescedNightRef] = [],
        tappedNight: Binding<CoalescedNightRef?> = .constant(nil)
    ) {
        self.snapshots = snapshots
        self.entries = entries
        self.polarSeries = polarSeries
        self.dateRange = dateRange
        self.coalescedNights = coalescedNights
        self._tappedNight = tappedNight
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
                    .foregroundStyle(ChartPalette.hkHeartRate)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("BPM", snapshot.restingHR ?? 0)
                    )
                    .foregroundStyle(ChartPalette.hkHeartRate)
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
                    .foregroundStyle(ChartPalette.polarHeartRate)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", point.night, unit: .day),
                        y: .value("BPM", point.value ?? 0)
                    )
                    .foregroundStyle(ChartPalette.polarHeartRate)
                    .symbol(.diamond)
                    .symbolSize(40)
                }
            }
            .chartXScale(domain: dateRange)
            .frame(height: 200)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            handleTap(at: location, proxy: proxy, geo: geo)
                        }
                }
            }
        }
    }

    /// Maps a tap location in the chart overlay to the nearest
    /// `CoalescedNightRef` (Polar diamond) and writes it through the
    /// binding. Snap tolerance is ±0.4 day so a user tapping between two
    /// closely-spaced diamonds gets the nearer one rather than no-op.
    private func handleTap(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard !coalescedNights.isEmpty else { return }
        // No fallback if the chart hasn't laid out yet — `geo.frame(in: .local)`
        // would include the y-axis label region and produce a wrong x-origin.
        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        let xInPlot = location.x - plotFrame.origin.x
        guard let tapDate: Date = proxy.value(atX: xInPlot) else { return }

        // Find the night whose anchor date is closest to the tap.
        let nearest = coalescedNights.min { lhs, rhs in
            abs(lhs.startTime.timeIntervalSince(tapDate))
                < abs(rhs.startTime.timeIntervalSince(tapDate))
        }
        guard let nearest else { return }
        // ±0.4 day = ±9.6h. Tighter than half the typical inter-night spacing
        // (24h) so a tap halfway between two nights doesn't accidentally
        // snap to one of them.
        let toleranceSeconds: TimeInterval = 0.4 * 86_400
        if abs(nearest.startTime.timeIntervalSince(tapDate)) <= toleranceSeconds {
            tappedNight = nearest
        }
    }
}
