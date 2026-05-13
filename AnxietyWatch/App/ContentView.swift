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
        // The pill is rendered as a free-floating overlay rather than
        // a safe-area inset because iOS 18+'s `Tab { ... }` TabView
        // ships a floating "liquid glass" tab bar that does NOT
        // contribute to the safe-area inset — so `.safeAreaInset(edge:
        // .bottom)` ends up placing the pill on top of the tab bar
        // visually. An overlay with the pill's own draggable position
        // sidesteps that entirely. The pill manages its own visibility
        // (returns no content when not recording) so the overlay is
        // effectively a no-op in idle states; observation of
        // polarService.state is scoped inside the pill view, not here.
        .overlay(alignment: .topLeading) {
            RecordingStatusPill()
        }
        .sheet(isPresented: $presentation.showingLiveView) {
            HRVSessionLiveView(service: polarService)
        }
    }
}
