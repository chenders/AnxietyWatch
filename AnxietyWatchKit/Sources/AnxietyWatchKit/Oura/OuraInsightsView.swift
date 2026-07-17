import Foundation
import SwiftUI

// MARK: - OuraInsightsSnapshot

/// Immutable snapshot of Oura Ring daily metrics for a date range.
/// The app layer fetches data from `OuraService` and hands this to the view.
public struct OuraInsightsSnapshot: Sendable, Equatable {
    public var days: [Day]
    public var dateRange: String

    public struct Day: Sendable, Equatable, Identifiable {
        public var id: String { date }
        public var date: String

        // Stress
        public var stressHigh: Int?
        public var recoveryHigh: Int?
        public var stressSummary: String?

        // Resilience
        public var resilienceLevel: String?
        public var resilienceSleepRecovery: Int?
        public var resilienceDaytimeRecovery: Int?
        public var resilienceStress: Int?

        public init(date: String,
                    stressHigh: Int? = nil,
                    recoveryHigh: Int? = nil,
                    stressSummary: String? = nil,
                    resilienceLevel: String? = nil,
                    resilienceSleepRecovery: Int? = nil,
                    resilienceDaytimeRecovery: Int? = nil,
                    resilienceStress: Int? = nil) {
            self.date = date
            self.stressHigh = stressHigh
            self.recoveryHigh = recoveryHigh
            self.stressSummary = stressSummary
            self.resilienceLevel = resilienceLevel
            self.resilienceSleepRecovery = resilienceSleepRecovery
            self.resilienceDaytimeRecovery = resilienceDaytimeRecovery
            self.resilienceStress = resilienceStress
        }
    }

    public init(days: [Day] = [], dateRange: String = "") {
        self.days = days
        self.dateRange = dateRange
    }

    /// Build a snapshot from Oura API responses.
    public static func build(
        stress: [OuraStressData],
        resilience: [OuraResilienceData],
        dateRange: String
    ) -> OuraInsightsSnapshot {
        var allDates = Set<String>()
        var stressMap: [String: OuraStressData] = [:]
        var resilienceMap: [String: OuraResilienceData] = [:]

        for s in stress {
            allDates.insert(s.day)
            stressMap[s.day] = s
        }
        for r in resilience {
            allDates.insert(r.day)
            resilienceMap[r.day] = r
        }

        let sorted = allDates.sorted()
        let days: [Day] = sorted.map { date in
            let s = stressMap[date]
            let r = resilienceMap[date]
            return Day(
                date: date,
                stressHigh: s?.stressHigh,
                recoveryHigh: s?.recoveryHigh,
                stressSummary: s?.daySummary,
                resilienceLevel: r?.level,
                resilienceSleepRecovery: r?.contributors?.sleepRecovery,
                resilienceDaytimeRecovery: r?.contributors?.daytimeRecovery,
                resilienceStress: r?.contributors?.stress
            )
        }

        return OuraInsightsSnapshot(days: days, dateRange: dateRange)
    }
}

// MARK: - OuraInsightsView

/// SwiftUI view displaying Oura Ring daily stress and resilience metrics.
///
/// Takes an `OuraInsightsSnapshot` — the app is responsible for fetching
/// data from `OuraService` and building the snapshot. The view never
/// touches any actor directly.
public struct OuraInsightsView: View {
    public let snapshot: OuraInsightsSnapshot

    public init(snapshot: OuraInsightsSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider().padding(.vertical, 4)

                if snapshot.days.isEmpty {
                    emptyState
                } else {
                    ForEach(snapshot.days.reversed()) { day in
                        dayCard(day)
                        Divider().padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Oura Insights")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daily Stress & Resilience")
                .font(.headline)
            Text(snapshot.dateRange)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.dashed")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No Oura data available")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Connect your Oura Ring and pull to refresh.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Day card

    @ViewBuilder
    private func dayCard(_ day: OuraInsightsSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date header
            Text(formatDate(day.date))
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack(alignment: .top, spacing: 16) {
                // Stress column
                stressColumn(day)
                    .frame(maxWidth: .infinity)

                Divider()

                // Resilience column
                resilienceColumn(day)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Stress column

    @ViewBuilder
    private func stressColumn(_ day: OuraInsightsSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stress")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.orange)

            if let stressHigh = day.stressHigh {
                HStack(spacing: 4) {
                    Text("High:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(stressHigh) min")
                        .font(.caption)
                        .monospacedDigit()
                }
            }

            if let recoveryHigh = day.recoveryHigh {
                HStack(spacing: 4) {
                    Text("Recovery:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(recoveryHigh) min")
                        .font(.caption)
                        .monospacedDigit()
                }
            }

            // Stress bar
            if let stressHigh = day.stressHigh, let recoveryHigh = day.recoveryHigh {
                let total = stressHigh + recoveryHigh
                if total > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: max(2, geo.size.width * CGFloat(stressHigh) / CGFloat(total)))
                            Rectangle()
                                .fill(Color.green.opacity(0.7))
                                .frame(width: max(2, geo.size.width * CGFloat(recoveryHigh) / CGFloat(total)))
                        }
                        .frame(height: 6)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .frame(height: 6)
                }
            }

            if let summary = day.stressSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            if day.stressHigh == nil && day.recoveryHigh == nil && day.stressSummary == nil {
                Text("—")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Resilience column

    @ViewBuilder
    private func resilienceColumn(_ day: OuraInsightsSnapshot.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Resilience")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.blue)

            if let level = day.resilienceLevel {
                HStack(spacing: 4) {
                    Circle()
                        .fill(resilienceColor(level))
                        .frame(width: 8, height: 8)
                    Text(level.capitalized)
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }

            if let sleep = day.resilienceSleepRecovery {
                HStack(spacing: 4) {
                    Text("Sleep:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(sleep)%")
                        .font(.caption)
                        .monospacedDigit()
                }
            }

            if let daytime = day.resilienceDaytimeRecovery {
                HStack(spacing: 4) {
                    Text("Daytime:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(daytime)%")
                        .font(.caption)
                        .monospacedDigit()
                }
            }

            if day.resilienceLevel == nil
                && day.resilienceSleepRecovery == nil
                && day.resilienceDaytimeRecovery == nil {
                Text("—")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ iso: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "EEEE, MMM d"
        return out.string(from: date)
    }

    private func resilienceColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "exceptional": return .purple
        case "strong":      return .blue
        case "solid":       return .green
        case "adequate":    return .yellow
        case "limited":     return .orange
        default:            return .gray
        }
    }
}
