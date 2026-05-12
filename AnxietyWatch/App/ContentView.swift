import SwiftUI

struct ContentView: View {
    /// Held just to forward to the live session sheet — its `.state`
    /// properties are intentionally NOT read inside this body so the
    /// per-second HR / elapsed updates don't invalidate the entire tab
    /// tree at WindowGroup scope (iOS 26 pitfall documented in
    /// CLAUDE.md). `RecordingStatusPill` scopes its own observation.
    @Environment(PolarHRMService.self) private var polarService
    @Environment(RecordingPresentationCoordinator.self) private var presentation

    var body: some View {
        @Bindable var presentation = presentation
        TabView {
            Tab("Dashboard", systemImage: "heart.text.square") {
                DashboardView()
            }
            Tab("Journal", systemImage: "book") {
                JournalListView()
            }
            Tab("Medications", systemImage: "pills") {
                MedicationsHubView()
            }
            Tab("Trends", systemImage: "chart.xyaxis.line") {
                TrendsView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
        }
        // `.safeAreaInset` reserves a strip ABOVE the tab bar for the
        // pill rather than overlaying on top of it. An overlay-style
        // placement (ZStack alignment .bottom) sits *on* the tab bar,
        // which would intercept taps in the pill's hit-test region and
        // make tab switching unreliable during recording — the worst
        // possible time for it. With `.safeAreaInset` the pill gets its
        // own non-overlapping zone, and when it renders `EmptyView`
        // (the non-recording state) the inset height collapses to zero
        // so the tab content reclaims the space.
        //
        // RecordingStatusPill is rendered unconditionally; the pill's
        // own body decides whether to draw content. Keeping the
        // visibility branch inside that child view scopes
        // polarService.state observation to the pill only — otherwise
        // every HR tick would re-render the tab tree (iOS 26 pitfall).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // No padding applied here — RecordingStatusPill applies its
            // own padding INSIDE the `if let content` conditional so
            // that when the pill is hidden no inset is contributed at
            // all. Wrapping with .padding(...) here would leave a
            // permanent gap above the tab bar in idle states.
            RecordingStatusPill()
        }
        .sheet(isPresented: $presentation.showingLiveView) {
            HRVSessionLiveView(service: polarService)
        }
    }
}
