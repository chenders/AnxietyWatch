import Foundation
import Testing

@testable import AnxietyWatch

/// Covers the pure error-message mapping extracted from HealthRecordsSettingsView
/// (F-082). The SwiftUI view wiring itself — the `@State` inline banner and the
/// `Task`/`do-catch` in the button — is not unit-testable without a UI host, so
/// only the message-mapping helper is exercised here.
struct HealthRecordsSettingsViewTests {

    private struct DescribedError: LocalizedError {
        let errorDescription: String?
    }

    private struct BareError: Error {}

    @Test("Uses a LocalizedError's description when present")
    func usesLocalizedDescription() {
        let error = DescribedError(errorDescription: "Health Records is unavailable in your region.")
        let message = HealthRecordsSettingsView.authorizationErrorMessage(for: error)
        #expect(message.contains("Health Records is unavailable in your region."))
        #expect(message.contains("Couldn't connect Health Records."))
    }

    @Test("Falls back to a generic hint when no description is available")
    func fallsBackToGenericHint() {
        let message = HealthRecordsSettingsView.authorizationErrorMessage(for: BareError())
        #expect(message.contains("Make sure a hospital is linked in the Health app"))
        // Never leak a raw NSError/debug string to the user.
        #expect(!message.contains("BareError"))
    }
}
