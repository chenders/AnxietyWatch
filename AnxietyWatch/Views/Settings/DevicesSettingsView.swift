import SwiftUI

struct DevicesSettingsView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    CPAPListView().equatable()
                } label: {
                    Label("CPAP", systemImage: "bed.double.fill")
                }
                NavigationLink {
                    PolarSettingsView()
                } label: {
                    Label("Polar H10", systemImage: "heart.text.square")
                }
                NavigationLink {
                    EMAYLiveView()
                } label: {
                    Label("EMAY Oximeter (Live)", systemImage: "lungs.fill")
                }
                NavigationLink {
                    OuraSettingsView()
                } label: {
                    Label("Oura Ring", systemImage: "circle.hexagongrid.fill")
                }
            } footer: {
                Text("Manage your connected hardware devices and their settings.")
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    DevicesSettingsView()
}
#endif