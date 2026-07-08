import SwiftUI

struct HealthRecordsSettingsView: View {
    @State private var clinicalRecordsRequested = false

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        do {
                            try await HealthKitManager.shared.requestClinicalAuthorization()
                            clinicalRecordsRequested = true
                        } catch {
                            // Authorization failed or was cancelled — don't show checkmark
                        }
                    }
                } label: {
                    Label("Connect Health Records", systemImage: "cross.case.fill")
                }
                if clinicalRecordsRequested {
                    Label("Clinical records access requested", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                NavigationLink {
                    LabResultsView().equatable()
                } label: {
                    Label("Lab Results", systemImage: "flask.fill")
                }
            } footer: {
                Text("Requires a linked hospital in Apple Health. Go to Health app → Browse → Health Records to connect your provider.")
            }
        }
        .navigationTitle("Health Records")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack { HealthRecordsSettingsView() }
}
#endif
