import SwiftUI
import SwiftData
import UIKit

/// Apple Health settings: a live read-access diagnostic plus the re-request and
/// iOS-Settings deep-link recovery paths. Replaces the old blind "Request
/// Access" button, which gave no signal about whether reads actually worked —
/// the gap that let the silent authorization freeze run for days.
struct AppleHealthSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @State private var result: HealthKitAccessDiagnostic.Result?
    @State private var checking = false
    @State private var requesting = false

    var body: some View {
        Form {
            Section("Status") {
                statusRow
                if let result {
                    probeRow("Steps", present: result.stepsPresent)
                    probeRow("Resting Heart Rate", present: result.restingHRPresent)
                    probeRow("Sleep", present: result.sleepPresent)
                }
            }

            Section {
                Button {
                    Task { await requestAccess() }
                } label: {
                    Label("Request HealthKit Access", systemImage: "heart.fill")
                }
                .disabled(requesting)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("Open iOS Settings", systemImage: "gear")
                }
            } footer: {
                Text("HealthKit does not reveal which permissions were granted. If data "
                     + "isn't arriving even though access looks on, toggle the types off and "
                     + "back on in iOS Settings → Privacy & Security → Health → Anxiety Watch, "
                     + "then rebuild history.")
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    // MARK: - Rows

    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.subheadline.bold())
                Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if checking { ProgressView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusTitle). \(statusDetail)")
    }

    private func probeRow(_ name: String, present: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            Image(systemName: present ? "checkmark" : "minus")
                .foregroundStyle(present ? Color.green : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(present ? "recent data present" : "no recent data")")
    }

    // MARK: - Status presentation

    private var statusIcon: String {
        switch result?.state {
        case .receiving: "checkmark.circle.fill"
        case .notRequested, .likelyRevoked: "exclamationmark.triangle.fill"
        case .noDataYet: "circle.dashed"
        case nil: "hourglass"
        }
    }

    private var statusColor: Color {
        switch result?.state {
        case .receiving: .green
        case .notRequested, .likelyRevoked: .orange
        case .noDataYet, nil: .secondary
        }
    }

    private var statusTitle: String {
        switch result?.state {
        case .receiving: "Receiving data"
        case .notRequested: "Access not granted"
        case .likelyRevoked: "Not receiving data"
        case .noDataYet: "No data yet"
        case nil: "Checking…"
        }
    }

    private var statusDetail: String {
        switch result?.state {
        case .receiving:
            "HealthKit reads are working."
        case .notRequested:
            "The authorization prompt hasn't been answered. Tap Request HealthKit Access below."
        case .likelyRevoked:
            "Access may have been revoked. Re-enable the types in iOS Settings, then rebuild history."
        case .noDataYet:
            "No recent health data to read yet."
        case nil:
            "Checking HealthKit access…"
        }
    }

    // MARK: - Actions

    private func refresh() async {
        checking = true
        defer { checking = false }
        let now = Date()
        // Single-clause, date-bounded fetch (avoids the unbounded-@Query and
        // compound-#Predicate pitfalls). Calendar-based cutoff is DST-safe.
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -HealthKitHistoryProbe.defaultWindowDays, to: now
        ) ?? now
        let descriptor = FetchDescriptor<HealthSnapshot>(
            predicate: #Predicate { $0.date >= cutoff }
        )
        let snapshots = (try? modelContext.fetch(descriptor)) ?? []
        let hadHistory = HealthKitHistoryProbe.hadRecentHealthKitData(in: snapshots, now: now)
        let diagnostic = HealthKitAccessDiagnostic(source: HealthKitManager.shared)
        result = await diagnostic.run(now: now, hadRecentHistory: hadHistory)
    }

    private func requestAccess() async {
        requesting = true
        try? await HealthKitManager.shared.requestAuthorization()
        requesting = false
        await refresh()
    }
}

#if DEBUG
#Preview {
    NavigationStack { AppleHealthSettingsView() }
}
#endif
