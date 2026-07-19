import SwiftUI
import SwiftData
import UIKit

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
/// Self-contained: it owns the one-shot `needsRequest` probe and runs it in its
/// own `.task` (plus a `scenePhase`-active refresh — the reliable "user granted
/// access in Settings and came back" signal). Scoping the state here, rather
/// than in `DashboardView`, keeps a probe result from invalidating the entire
/// dashboard body. The `Group` wrapper always exists so the `.task` fires, and
/// its conditional content collapses to nothing when hidden, so the banner
/// reserves no `VStack` spacing while access is fine.
struct HealthKitAccessBanner: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var state: HealthKitAccessState = .receiving
    @State private var requesting = false

    var body: some View {
        Group {
            if state.showsDashboardBanner {
                bannerButton
            }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private var bannerButton: some View {
        Button {
            Task { await handleTap() }
        } label: {
            bannerLabel
        }
        .buttonStyle(.plain)
        .disabled(requesting)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private var title: String {
        state == .notRequested ? "Apple Health isn't connected" : "We're not seeing your health data"
    }

    private var detail: String {
        state == .notRequested
            ? "Anxiety Watch hasn't been granted access to your health data, so Trends and Dashboard stay empty. Tap to grant access."
            : "Trends and Dashboard look empty. Health access may have been turned off. Tap to check your permissions."
    }

    private var bannerLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.slash.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            if requesting { ProgressView() } else {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    private func refresh() async {
        state = await HealthKitAccessProbe.currentResult(modelContext: modelContext).state
    }

    private func handleTap() async {
        // First-ever ask (`.notRequested` and we've never presented the sheet):
        // request in place — one-tap recovery for a genuinely fresh install.
        // Every other case routes to iOS Settings: re-invoking
        // `requestAuthorization` can't change a decision the user already made
        // and only re-presents the slow, black `HealthPrivacyService` host
        // (measured 2026-07-19). A partial grant that left the ask-status stuck
        // at `.shouldRequest` is fixed by toggling types in Settings, not by
        // re-asking. `.likelyRevoked` is likewise a Settings fix.
        if state == .notRequested && !HealthKitManager.hasEverRequestedAuthorization {
            requesting = true
            try? await HealthKitManager.shared.requestAuthorization()
            await refresh()
            requesting = false
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}
