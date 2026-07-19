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
    @Environment(\.scenePhase) private var scenePhase

    @State private var result: HealthKitAccessDiagnostic.Result?
    @State private var checking = false
    @State private var requesting = false

    var body: some View {
        Form {
            Section("Status") {
                statusRow
                // Probe rows are shown only when the probes actually ran. For
                // `.notRequested` (reads would error code 5) and `.unavailable`
                // (no store to read) they are skipped, so rendering "—" here
                // would imply "checked, nothing there" rather than "not checked."
                if let result, result.state != .notRequested, result.state != .unavailable {
                    probeRow("Steps", present: result.stepsPresent)
                    probeRow("Resting Heart Rate", present: result.restingHRPresent)
                    probeRow("Heart Rate", present: result.heartRatePresent)
                    probeRow("Sleep", present: result.sleepPresent)
                }
            }

            Section {
                Button {
                    Task { await requestAccess() }
                } label: {
                    Label("Request HealthKit Access", systemImage: "heart.fill")
                }
                // Requesting access is a no-op when HealthKit is unavailable.
                .disabled(requesting || result?.state == .unavailable)

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
        .onChange(of: scenePhase) { _, phase in
            // Re-run the diagnostic when returning to the app — e.g. after the
            // user toggled access in iOS Settings via the deep link below, which
            // would otherwise leave the panel showing stale results.
            if phase == .active { Task { await refresh() } }
        }
    }

    // MARK: - Rows

    private var statusRow: some View {
        let state = result?.state
        return HStack(spacing: 12) {
            Image(systemName: state?.statusSymbolName ?? "hourglass")
                .foregroundStyle(tintColor(state))
            VStack(alignment: .leading, spacing: 2) {
                Text(state?.statusTitle ?? "Checking…").font(.subheadline.bold())
                Text(state?.statusDetail ?? "Checking HealthKit access…")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if checking { ProgressView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state?.statusTitle ?? "Checking"). \(state?.statusDetail ?? "")")
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

    private func tintColor(_ state: HealthKitAccessState?) -> Color {
        switch state?.statusTint {
        case .positive: .green
        case .warning: .orange
        case .neutral, nil: .secondary
        }
    }

    // MARK: - Actions

    private func refresh() async {
        checking = true
        defer { checking = false }
        result = await HealthKitAccessProbe.currentResult(modelContext: modelContext)
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
