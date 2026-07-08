import os
import SwiftUI

struct HealthRecordsSettingsView: View {
    @State private var clinicalRecordsRequested = false
    @State private var authErrorMessage: String?

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await requestClinicalAuthorization() }
                } label: {
                    Label("Connect Health Records", systemImage: "cross.case.fill")
                }
                if clinicalRecordsRequested {
                    Label("Clinical records access requested", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if let authErrorMessage {
                    Label(authErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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

    private func requestClinicalAuthorization() async {
        authErrorMessage = nil
        do {
            try await HealthKitManager.shared.requestClinicalAuthorization()
            clinicalRecordsRequested = true
        } catch {
            // Previously an empty catch: a failed request left the button looking
            // dead. Surface an inline message and log the failure type (no PII —
            // never the error's user-facing text or any record contents).
            Log.health.error("Clinical records authorization failed: \(String(describing: type(of: error)), privacy: .public)")
            clinicalRecordsRequested = false
            authErrorMessage = Self.authorizationErrorMessage(for: error)
        }
    }

    /// Maps an authorization error to a user-facing message. Pure and static so
    /// it can be unit-tested without instantiating the view.
    static func authorizationErrorMessage(for error: Error) -> String {
        let base = "Couldn't connect Health Records."
        // flatMap (not `?.`) so a LocalizedError with a nil errorDescription
        // flattens String?? → String? and falls through to the generic hint,
        // rather than interpolating a literal "nil" (Copilot review of #164).
        let detail = (error as? LocalizedError).flatMap { $0.errorDescription }
        // Fall back to a generic hint when the error has no useful description,
        // rather than leaking a raw NSError debug string to the user.
        let hint = detail ?? "Make sure a hospital is linked in the Health app, then try again."
        return "\(base) \(hint)"
    }
}

#if DEBUG
#Preview {
    NavigationStack { HealthRecordsSettingsView() }
}
#endif
