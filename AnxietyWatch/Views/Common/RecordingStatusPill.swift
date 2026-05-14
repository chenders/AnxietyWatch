import SwiftUI

/// Floating "recording in progress" pill rendered as an overlay on top
/// of ContentView's TabView. Visible only while a Polar H10 session is
/// connecting or actively recording; tapping reopens the live session
/// sheet via `RecordingPresentationCoordinator`. The pill is
/// **draggable** — the user can move it anywhere on screen, and the
/// position survives app launches via `PillPositionStore`.
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
///
/// **Why an overlay rather than `.safeAreaInset`**: iOS 18+'s new
/// `Tab { ... }` TabView renders a floating "liquid glass" tab bar
/// that does not contribute to the safe area inset the way the old
/// tab-bar chrome did. `.safeAreaInset(edge: .bottom)` ended up
/// placing the pill on top of the tab bar visually. An overlay with
/// explicit positioning + drag gesture sidesteps that entirely.
struct RecordingStatusPill: View {
    #if DEBUG
    /// Stable accessibility identifier consumed by DEBUG-build screen
    /// capture (see DebugScreenCapture.swift) to find and hide this
    /// pill during full-screen capture. Fenced so it adds no Release
    /// binary symbol; the consumer (`DebugScreenCapture.swift`) is also
    /// DEBUG-only.
    static let debugAccessibilityIdentifier = "debug-recording-pill"
    #endif

    @Environment(PolarHRMService.self) private var polarService
    @Environment(RecordingPresentationCoordinator.self) private var presentation

    /// Last persisted position from disk. Loaded once at init; nil
    /// until the user first drags the pill, in which case the view
    /// uses the default-anchor placement below.
    @State private var persistedPosition: CGPoint?
    /// In-flight drag offset. Reset to .zero on gesture end and added
    /// into `persistedPosition` instead.
    @State private var dragOffset: CGSize = .zero
    /// Measured natural size of the pill content — needed to clamp
    /// drag targets so the pill can't be pushed off-screen.
    @State private var pillSize: CGSize = .zero

    private let store = PillPositionStore()

    /// Default top-center placement, just below the safe-area top
    /// edge so the pill clears the notch / Dynamic Island / status
    /// bar instead of sitting under them.
    private func defaultPosition(in container: CGSize, pill: CGSize, safeArea: EdgeInsets) -> CGPoint {
        let x = max(0, (container.width - pill.width) / 2)
        let y: CGFloat = safeArea.top + 8
        return CGPoint(x: x, y: y)
    }

    /// Pick the anchor for this render: saved position (clamped to
    /// current bounds, safe-area-aware) if we have one and have
    /// measured the pill, otherwise the default top-center placement.
    /// Extracted from body so the conditional doesn't tangle SwiftUI's
    /// ViewBuilder (which doesn't allow imperative if/else value
    /// assignment).
    private func resolvedAnchor(
        saved: CGPoint?,
        container: CGSize,
        safeArea: EdgeInsets
    ) -> CGPoint {
        if let saved, pillSize != .zero {
            return PillPositionStore.clamp(
                position: saved,
                screen: container,
                pillSize: pillSize,
                safeArea: safeArea
            )
        }
        return defaultPosition(in: container, pill: pillSize, safeArea: safeArea)
    }

    var body: some View {
        let content = RecordingPillContent.from(state: polarService.state)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let content {
                    // Clamp the loaded position against the current
                    // container size every render — handles cases the
                    // saved coordinates never anticipated: rotation
                    // shrinks the screen, iPad multitasking resizes
                    // the window, or the user moved between devices
                    // with different screen sizes (iCloud-synced
                    // UserDefaults could surface a position from a
                    // larger device). Without this re-clamp on every
                    // body, the pill could start off-screen and be
                    // unreachable until the user clears defaults.
                    let anchor = resolvedAnchor(
                        saved: persistedPosition,
                        container: proxy.size,
                        safeArea: proxy.safeAreaInsets
                    )
                    Button {
                        presentation.showingLiveView = true
                    } label: {
                        pillLabel(content)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(content))
                    .accessibilityHint("Opens the live session view. Drag to move the pill.")
                    #if DEBUG
                    .accessibilityIdentifier(Self.debugAccessibilityIdentifier)
                    #endif
                    .background(
                        // Measure the pill's natural size once so drag
                        // clamping has accurate bounds. Reads only on
                        // appear / size changes, not every render.
                        GeometryReader { pillProxy in
                            Color.clear.preference(
                                key: PillSizePreferenceKey.self,
                                value: pillProxy.size
                            )
                        }
                    )
                    .offset(
                        x: anchor.x + dragOffset.width,
                        y: anchor.y + dragOffset.height
                    )
                    // Hide the pill until its natural size has been
                    // measured. On first render `pillSize` is .zero, so
                    // `defaultPosition` would center using width=0 —
                    // placing the leading edge at container.width / 2
                    // and producing a visible jump-left once the
                    // PreferenceKey delivers the real size on the next
                    // pass. Keeping the pill invisible during that
                    // measurement frame eliminates the flash. The
                    // measurement still runs (the .background
                    // GeometryReader fires regardless of opacity).
                    //
                    // `.allowsHitTesting(false)` paired with the
                    // opacity gate — an invisible Button still
                    // receives taps unless hit-testing is explicitly
                    // disabled, so without this a tap in the first
                    // render frame could open the live view from an
                    // unmeasured pill location.
                    .opacity(pillSize == .zero ? 0 : 1)
                    .allowsHitTesting(pillSize != .zero)
                    // `.highPriorityGesture` (not `.gesture`) so the
                    // drag takes precedence over the Button's tap
                    // when both could match — without this, small or
                    // pure-horizontal movements fall under SwiftUI's
                    // default 10pt drag threshold and the Button tap
                    // wins, opening the modal instead of moving the
                    // pill. The smaller `minimumDistance: 3` gives
                    // the drag a hair-trigger so even a careful slow
                    // slide registers immediately; a genuine tap (no
                    // movement at all) still opens the live view.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .local)
                            .onChanged { value in
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                let raw = CGPoint(
                                    x: anchor.x + value.translation.width,
                                    y: anchor.y + value.translation.height
                                )
                                let clamped = PillPositionStore.clamp(
                                    position: raw,
                                    screen: proxy.size,
                                    pillSize: pillSize,
                                    safeArea: proxy.safeAreaInsets
                                )
                                persistedPosition = clamped
                                dragOffset = .zero
                                store.save(clamped)
                            }
                    )
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onPreferenceChange(PillSizePreferenceKey.self) { newSize in
                pillSize = newSize
            }
            .onAppear {
                if persistedPosition == nil, let saved = store.load() {
                    persistedPosition = saved
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: content != nil)
        // The overlay GeometryReader fills the parent. Tap-through is
        // automatic — the pill button is the only opaque region; the
        // rest of the ZStack is transparent and doesn't intercept.
        .allowsHitTesting(content != nil)
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

/// Tunnels the pill's measured natural size up so the parent's drag
/// clamping has accurate bounds. Lives in this file because nothing
/// else needs it.
private struct PillSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
