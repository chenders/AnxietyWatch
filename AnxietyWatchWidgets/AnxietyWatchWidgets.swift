import SwiftUI
import WidgetKit

// MARK: - Shared Constants

enum SharedData {
    static let appGroup = "group.org.waitingforthefuture.AnxietyWatch.watch"

    static var shared: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    enum Key {
        static let lastAnxiety = "lastAnxiety"
        static let hrvAvg = "hrvAvg"
        static let restingHR = "restingHR"
        static let lastUpdate = "lastUpdate"
    }
}

// MARK: - Timeline Entry

struct StatsEntry: TimelineEntry {
    let date: Date
    let lastAnxiety: Int?
    let hrvAvg: Double?
    let restingHR: Double?
    let lastUpdate: Date?
}

// MARK: - Timeline Provider

struct StatsTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: .now, lastAnxiety: 5, hrvAvg: 42, restingHR: 62, lastUpdate: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        let entry = readEntry()
        // Refresh every 15 minutes; the watch app also triggers reloads when new data arrives
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)
            ?? Date.now.addingTimeInterval(15 * 60)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func readEntry() -> StatsEntry {
        let defaults = SharedData.shared
        let anxiety = defaults?.object(forKey: SharedData.Key.lastAnxiety) as? Int
        let hrv = defaults?.object(forKey: SharedData.Key.hrvAvg) as? Double
        let hr = defaults?.object(forKey: SharedData.Key.restingHR) as? Double
        let lastUpdate = (defaults?.object(forKey: SharedData.Key.lastUpdate) as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        return StatsEntry(date: .now, lastAnxiety: anxiety, hrvAvg: hrv, restingHR: hr, lastUpdate: lastUpdate)
    }
}

// MARK: - Widget Views

struct CircularView: View {
    let entry: StatsEntry

    var body: some View {
        if let hrv = entry.hrvAvg {
            Gauge(value: hrv, in: 10...120) {
                Text("HRV")
            } currentValueLabel: {
                Text(String(format: "%.0f", hrv))
                    .font(.system(.title3, design: .rounded, weight: .bold))
            }
            .gaugeStyle(.accessoryCircular)
        } else if let anxiety = entry.lastAnxiety {
            Gauge(value: Double(anxiety), in: 1...10) {
                Text("ANX")
            } currentValueLabel: {
                Text("\(anxiety)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
            }
            .gaugeStyle(.accessoryCircular)
        } else {
            Text("--")
                .font(.title3)
        }
    }
}

struct RectangularView: View {
    let entry: StatsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                if let hrv = entry.hrvAvg {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HRV")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f ms", hrv))
                            .font(.headline)
                            .foregroundStyle(.blue)
                    }
                }
                if let anxiety = entry.lastAnxiety {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Anxiety")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(anxiety)/10")
                            .font(.headline)
                            .foregroundStyle(severityColor(anxiety))
                    }
                }
                if let hr = entry.restingHR {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("RHR")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f", hr))
                            .font(.headline)
                            .foregroundStyle(.red)
                    }
                }
            }
            if let lastUpdate = entry.lastUpdate {
                Text(lastUpdate, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func severityColor(_ severity: Int) -> Color {
        switch severity {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}

struct InlineView: View {
    let entry: StatsEntry

    var body: some View {
        if let hrv = entry.hrvAvg, let anxiety = entry.lastAnxiety {
            Text("HRV \(String(format: "%.0f", hrv))ms · Anxiety \(anxiety)/10")
        } else if let hrv = entry.hrvAvg {
            Text("HRV \(String(format: "%.0f", hrv))ms")
        } else if let anxiety = entry.lastAnxiety {
            Text("Anxiety \(anxiety)/10")
        } else {
            Text("Anxiety Watch")
        }
    }
}

// MARK: - Widget

struct AnxietyWatchWidgets: Widget {
    let kind = "AnxietyWatchWidgets"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatsTimelineProvider()) { entry in
            WidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Anxiety Watch")
        .description("Current HRV and last anxiety rating")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct WidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: StatsEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularView(entry: entry)
        case .accessoryRectangular:
            RectangularView(entry: entry)
        case .accessoryInline:
            InlineView(entry: entry)
        default:
            RectangularView(entry: entry)
        }
    }
}

#Preview(as: .accessoryRectangular) {
    AnxietyWatchWidgets()
} timeline: {
    StatsEntry(date: .now, lastAnxiety: 6, hrvAvg: 42, restingHR: 62, lastUpdate: .now)
}
