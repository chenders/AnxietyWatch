import SwiftUI

struct AppleHealthSettingsView: View {
    @State private var healthKitRequested = false

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        try? await HealthKitManager.shared.requestAuthorization()
                        healthKitRequested = true
                    }
                } label: {
                    Label("Request HealthKit Access", systemImage: "heart.fill")
                }
                if healthKitRequested {
                    Label("HealthKit access requested", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } footer: {
                Text("HealthKit does not reveal which permissions were granted. The app gracefully handles missing data.")
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack { AppleHealthSettingsView() }
}
#endif
