import SwiftUI

/// Proactive Dashboard banner that surfaces the silent HealthKit
/// read-authorization freeze. It appears **only** when authorization has never
/// resolved (`.notRequested`) — the state in which every ingestion path
/// (aggregate, backfill, Rebuild All History) reads nothing while iOS Settings
/// still shows "Health Data — On." That is the exact state both prior
/// production incidents were in (2026-07-13, 2026-07-18), and the only state
/// with zero false-positive risk: a prompt is always correct when the sheet has
/// never resolved. `.likelyRevoked` is deliberately left to Settings → Apple
/// Health — see `HealthKitAccessState.showsDashboardBanner` and the design doc.
///
/// Pure presentational view: `DashboardView` owns the one-shot `needsRequest`
/// probe (its `.task` runs on appear and refreshes on `scenePhase` becoming
/// active — the reliable "user granted access in Settings and came back"
/// signal). When access is fine this returns `EmptyView`, so it reserves no
/// `VStack` spacing.
struct HealthKitAccessBanner: View {
    @Binding var needsRequest: Bool
    @State private var requesting = false

    var body: some View {
        // Route through the tested scope property rather than an inline check,
        // so the "banner on .notRequested only" decision has one enforced home.
        let state: HealthKitAccessState = needsRequest ? .notRequested : .receiving
        if state.showsDashboardBanner {
            Button {
                Task { await grantAccess() }
            } label: {
                bannerLabel
            }
            .buttonStyle(.plain)
            .disabled(requesting)
            .accessibilityLabel("Apple Health isn't connected")
            .accessibilityHint("Anxiety Watch hasn't been granted access to your health "
                               + "data. Activate to grant access.")
        }
    }

    private var bannerLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.slash.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Health isn't connected")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text("Anxiety Watch hasn't been granted access to your health data, so "
                     + "Trends and Dashboard stay empty. Tap to grant access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            if requesting {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    private func grantAccess() async {
        requesting = true
        // For `.notRequested` this presents the system sheet directly; a granted
        // response flips the gate to `.unnecessary` and the banner disappears.
        try? await HealthKitManager.shared.requestAuthorization()
        needsRequest = await HealthKitManager.shared.authorizationNeedsRequest()
        requesting = false
    }
}
