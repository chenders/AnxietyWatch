import SwiftUI

/// Floating "recording in progress" pill rendered above the tab bar at
/// the root of ContentView. Visible only while a Polar H10 session is
/// connecting or actively recording; tapping reopens the live session
/// sheet via `RecordingPresentationCoordinator`.
///
/// **Critical observation-scoping**: this view reads
/// `polarService.state` directly via `@Environment`. Because the read
/// happens inside *this* view's body — not ContentView's, and not the
/// App's `WindowGroup` — every state update (HR ticking every ~1s) only
/// invalidates this view, not the entire tab tree. PR #135 fixed the
/// equivalent bug for the backfill overlay; the same pattern applies
/// here. ContentView intentionally renders `RecordingStatusPill()`
/// unconditionally so the visibility decision lives inside the pill,
/// not at the App/WindowGroup root.
struct RecordingStatusPill: View {
    @Environment(PolarHRMService.self) private var polarService
    @Environment(RecordingPresentationCoordinator.self) private var presentation

    var body: some View {
        let content = RecordingPillContent.from(state: polarService.state)
        Group {
            if let content {
                Button {
                    presentation.showingLiveView = true
                } label: {
                    pillLabel(content)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(content))
                .accessibilityHint("Opens the live session view")
                // Padding lives INSIDE the `if let` so it disappears
                // entirely when the pill is hidden — applying padding
                // at the call site (or after this `Group`) would leave
                // a permanent 8pt bottom inset above the tab bar even
                // in idle / non-recording states.
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Animation must key on a stable signal — `content` itself changes
        // every second during a session (elapsedText reformats, hrText
        // updates) so animating on the whole struct would open a fresh
        // 0.25s transaction every tick. `content != nil` flips only at
        // the show/hide boundary, which is what we actually want to
        // animate.
        .animation(.smooth(duration: 0.25), value: content != nil)
    }

    private func pillLabel(_ content: RecordingPillContent) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(content.isLive ? Color.red : Color.orange)
                .frame(width: 8, height: 8)
            Text(content.statusText)
                .font(.caption.weight(.semibold))
            if let elapsed = content.elapsedText {
                Text("·").foregroundStyle(.secondary)
                Text(elapsed).font(.caption).monospacedDigit()
            }
            if let hr = content.hrText {
                Text("·").foregroundStyle(.secondary)
                Text(hr).font(.caption).monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private func accessibilityLabel(_ content: RecordingPillContent) -> String {
        var parts: [String] = [content.statusText]
        if let elapsed = content.elapsedText {
            parts.append(elapsed + " elapsed")
        }
        if let hr = content.hrText {
            parts.append(hr)
        }
        return parts.joined(separator: ", ")
    }
}
