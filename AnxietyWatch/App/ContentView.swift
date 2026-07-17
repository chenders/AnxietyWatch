import SwiftUI
import AnxietyWatchKit

private enum AppTab: String, Hashable {
    case dashboard, journal, medications, trends, settings
}

struct ContentView: View {
    /// Held just to forward to the live session sheet — its `.state`
    /// properties are intentionally NOT read inside this body so the
    /// per-second HR / elapsed updates don't invalidate the entire tab
    /// tree at WindowGroup scope (iOS 26 pitfall documented in
    /// CLAUDE.md). `RecordingStatusPill` scopes its own observation.
    @Environment(PolarHRMService.self) private var polarService
    @Environment(RecordingPresentationCoordinator.self) private var presentation
    @State private var selectedTab: AppTab
#if DEBUG
    @State private var demoSequence = DemoVideoSequence.shared
#endif
    private let screenshotOuraService = OuraService()

    init() {
        let args = ProcessInfo.processInfo.arguments
        let requested = args.firstIndex(of: "-screenshotTab").flatMap { index in
            args.indices.contains(index + 1) ? AppTab(rawValue: args[index + 1]) : nil
        }
        _selectedTab = State(initialValue: requested ?? .dashboard)
    }

    @ViewBuilder
    var body: some View {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-screenshotOuraData") {
            NavigationStack {
                OuraDataDashboardView(service: screenshotOuraService)
            }
        } else if arguments.contains("-screenshotLabResults") {
            NavigationStack {
                LabResultsView()
            }
        } else if arguments.contains("-demoLabsAndSongs") {
            DemoLabsAndSongsSequenceView()
        } else if arguments.contains("-demoSongs") {
            DemoSongsWalkthroughView()
        } else {
            mainTabs
        }
    }

    private var mainTabs: some View {
        @Bindable var presentation = presentation
        return TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "heart.text.square", value: .dashboard) {
                DashboardView()
            }
            Tab("Journal", systemImage: "book", value: .journal) {
                JournalListView()
            }
            Tab("Medications", systemImage: "pills", value: .medications) {
                MedicationsHubView()
            }
            Tab("Trends", systemImage: "chart.xyaxis.line", value: .trends) {
                TrendsView()
            }
            Tab("Settings", systemImage: "gear", value: .settings) {
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
        #if DEBUG
        .task(id: demoSequence.completedProfiles) {
            guard ProcessInfo.processInfo.arguments.contains("-demoMainSequence") else { return }
            if demoSequence.completedProfiles.contains("dashboard"), selectedTab == .dashboard {
                try? await Task.sleep(for: .seconds(2)); selectedTab = .journal
            } else if demoSequence.completedProfiles.contains("journal"), selectedTab == .journal {
                try? await Task.sleep(for: .seconds(2)); selectedTab = .medications
            } else if demoSequence.completedProfiles.contains("medications"), selectedTab == .medications {
                try? await Task.sleep(for: .seconds(2)); selectedTab = .trends
            }
        }
        .modifier(DebugShakeCapture())
        #endif
    }
}
