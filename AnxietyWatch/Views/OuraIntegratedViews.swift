import Charts
import SwiftUI
import AnxietyWatchKit

/// Small, source-explicit projection shared by Dashboard and Trends. It keeps
/// Oura Cloud daily summaries separate from HealthKit and BLE observations.
private struct OuraDailyPoint: Identifiable, Sendable {
    let day: Date
    var readiness: Int?
    var sleep: Int?
    var resilience: String?
    var stressMinutes: Int?
    var restorativeMinutes: Int?
    var summary: String?
    var id: Date { day }

    init(day: Date, readiness: Int? = nil, sleep: Int? = nil, resilience: String? = nil,
         stressMinutes: Int? = nil, restorativeMinutes: Int? = nil, summary: String? = nil) {
        self.day = day
        self.readiness = readiness
        self.sleep = sleep
        self.resilience = resilience
        self.stressMinutes = stressMinutes
        self.restorativeMinutes = restorativeMinutes
        self.summary = summary
    }
}

private enum OuraPresentationData {
    static func load(service: OuraService, start: Date, end: Date) async -> [OuraDailyPoint] {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("-seedDemoData") else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (0..<90).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            // Intentional missing and partial cloud records exercise chart gaps.
            if [9, 26, 57].contains(offset) { return nil }
            let disruption = (10...12).contains(offset) ? 1.0 : 0
            let recovery = 0.65 * sin(Double(offset) * 0.47) + 0.3 * cos(Double(offset) * 0.19) - disruption * 0.7
            return OuraDailyPoint(
                day: date,
                readiness: offset == 34 ? nil : max(55, min(94, Int((82 + recovery * 9).rounded()))),
                sleep: max(58, min(95, Int((84 + recovery * 7 + 3 * sin(Double(offset) * 1.1)).rounded()))),
                resilience: recovery > 0.35 ? "Strong" : recovery < -0.45 ? "Adequate" : "Solid",
                stressMinutes: max(28, Int((78 - recovery * 24 + 8 * sin(Double(offset) * 0.8)).rounded())),
                restorativeMinutes: offset == 18 ? nil : max(35, Int((116 + recovery * 35 + 10 * cos(Double(offset) * 0.61)).rounded())),
                summary: offset == 0 ? "Restorative periods increased during the afternoon." : nil
            )
        }.filter { $0.day >= start && $0.day <= end }.sorted { $0.day < $1.day }
#else
        async let readiness = service.fetchReadiness(startDate: start, endDate: end)
        async let sleep = service.fetchSleepDetail(startDate: start, endDate: end)
        async let stress = service.fetchStress(startDate: start, endDate: end)
        async let resilience = service.fetchResilience(startDate: start, endDate: end)
        let values = await (readiness, sleep, stress, resilience)
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var points: [Date: OuraDailyPoint] = [:]
        func date(_ value: String) -> Date? { formatter.date(from: value) }
        for value in values.0 { if let day = date(value.day) { points[day] = OuraDailyPoint(day: day, readiness: value.score) } }
        for value in values.1 { if let day = date(value.day) { var p = points[day] ?? OuraDailyPoint(day: day); p.sleep = value.score; points[day] = p } }
        for value in values.2 { if let day = date(value.day) { var p = points[day] ?? OuraDailyPoint(day: day); p.stressMinutes = value.stressHigh; p.restorativeMinutes = value.recoveryHigh; p.summary = value.daySummary; points[day] = p } }
        for value in values.3 { if let day = date(value.day) { var p = points[day] ?? OuraDailyPoint(day: day); p.resilience = value.level; points[day] = p } }
        return points.values.sorted { $0.day < $1.day }
#endif
    }
}

struct OuraDailyContextCard: View {
    private let service = OuraService()
    @State private var latest: OuraDailyPoint?

    var body: some View {
        Group {
            if let latest {
                NavigationLink { OuraDataDashboardView(service: service) } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Oura Daily Context", systemImage: "circle.hexagongrid.fill")
                                .font(.headline).foregroundStyle(.teal)
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 8) {
                            value("Readiness", latest.readiness.map(String.init) ?? "—", .teal)
                            value("Sleep", latest.sleep.map(String.init) ?? "—", .indigo)
                            value("Resilience", latest.resilience ?? "—", .cyan)
                        }
                        HStack {
                            Label("High stress \(latest.stressMinutes.map { "\($0) min" } ?? "—")", systemImage: "bolt.fill").foregroundStyle(.orange)
                            Spacer()
                            Label("Restorative \(latest.restorativeMinutes.map { "\($0) min" } ?? "—")", systemImage: "leaf.fill").foregroundStyle(.teal)
                        }.font(.caption.weight(.semibold))
                        HStack {
                            Text("Oura Cloud • \(latest.day.formatted(.dateTime.month().day()))")
#if targetEnvironment(simulator)
                            Spacer(); Text("DEMO DATA").foregroundStyle(.yellow)
#endif
                        }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).stroke(.teal.opacity(0.25)) }
                }.buttonStyle(.plain)
            }
        }
        .task {
            let end = Date.now, start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
            latest = await OuraPresentationData.load(service: service, start: start, end: end).last
        }
    }

    private func value(_ title: String, _ text: String, _ color: Color) -> some View {
        VStack(spacing: 2) { Text(text).font(.title3.bold().monospacedDigit()).foregroundStyle(color); Text(title).font(.caption2).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
    }
}

struct OuraTrendsSection: View {
    let start: Date
    let end: Date
    private let service = OuraService()
    @State private var points: [OuraDailyPoint] = []
    @State private var expanded = false

    var body: some View {
        Group {
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Oura", systemImage: "circle.hexagongrid.fill").font(.title3.bold()).foregroundStyle(.teal)
                    Spacer()
                    Button(expanded ? "Show Less" : "Show All") { withAnimation { expanded.toggle() } }.font(.subheadline)
                }
                HStack {
                    Text("Oura Cloud daily summaries").font(.caption).foregroundStyle(.secondary)
                    Spacer()
#if targetEnvironment(simulator)
                    Text("DEMO DATA").font(.caption2.bold()).foregroundStyle(.yellow)
#endif
                }
                scoresChart
                if expanded { stressChart }
            }
            .padding()
            .background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(.teal.opacity(0.22)) }
                .padding(.horizontal)
            }
        }
#if DEBUG
        .task {
            guard DemoVideoScroll.shouldRun("trends") else { return }
            try? await Task.sleep(for: .seconds(3))
            expanded = true
        }
#endif
        .task(id: loadKey) {
            points = await OuraPresentationData.load(service: service, start: start, end: end)
        }
    }

    private var scoresChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Daily Scores").font(.headline)
            Chart(points) { point in
                if let value = point.readiness {
                    LineMark(x: .value("Day", point.day), y: .value("Score", value), series: .value("Series", "Readiness"))
                        .foregroundStyle(.teal).symbol(.circle)
                }
                if let value = point.sleep {
                    LineMark(x: .value("Day", point.day), y: .value("Score", value), series: .value("Series", "Sleep"))
                        .foregroundStyle(.indigo).symbol(.diamond)
                }
            }
            .chartYScale(domain: 0...100)
            .chartForegroundStyleScale(["Readiness": Color.teal, "Sleep": Color.indigo])
            .frame(height: 180)
            Text("Teal circles: Readiness • Indigo diamonds: Sleep").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var stressChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stress & Restorative Time").font(.headline)
            Chart(points) { point in
                if let value = point.stressMinutes {
                    BarMark(x: .value("Day", point.day), y: .value("Minutes", value))
                        .foregroundStyle(.orange).position(by: .value("Series", "High stress"))
                }
                if let value = point.restorativeMinutes {
                    BarMark(x: .value("Day", point.day), y: .value("Minutes", value))
                        .foregroundStyle(.teal).position(by: .value("Series", "Restorative"))
                }
            }.frame(height: 190)
            Text("Independent durations; missing records remain gaps.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var loadKey: String { "\(start.timeIntervalSinceReferenceDate)-\(end.timeIntervalSinceReferenceDate)" }

    init(start: Date, end: Date) { self.start = start; self.end = end }
}
