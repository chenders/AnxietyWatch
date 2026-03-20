import SwiftUI

@main
struct AnxietyScopeWatchApp: App {
    private let connectivity = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                QuickLogView()
                CurrentStatsView()
            }
            .onAppear {
                connectivity.activate()
            }
        }
    }
}
