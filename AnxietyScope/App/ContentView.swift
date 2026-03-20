import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Dashboard", systemImage: "heart.text.square") {
                DashboardView()
            }
            Tab("Journal", systemImage: "book") {
                JournalListView()
            }
            Tab("Medications", systemImage: "pills") {
                MedicationListView()
            }
            Tab("Trends", systemImage: "chart.xyaxis.line") {
                TrendsView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
        }
    }
}

