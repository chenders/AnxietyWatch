import Foundation
import SwiftUI
import SwiftData
import Testing
import UIKit

@testable import AnxietyWatch

@MainActor
@Suite
struct SettingsViewSmokeTests {

    /// Force SwiftUI body evaluation by hosting in a UIHostingController and
    /// laying out its view. Pure construction doesn't catch environment
    /// dependency or initializer crashes — only realizing the view hierarchy
    /// does. We size the host to an iPhone-ish viewport so any inner
    /// LayoutSubviews work resolves.
    private func realize<V: View>(_ view: V) {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.layoutIfNeeded()
    }

    @Test("SettingsView renders without crashing")
    func settingsViewRenders() throws {
        let container = try TestHelpers.makeFullContainer()
        let polar = PolarHRMService(modelContext: ModelContext(container))
        let recordingPresentation = RecordingPresentationCoordinator()
        realize(
            SettingsView()
                .modelContainer(container)
                .environment(polar)
                .environment(recordingPresentation)
        )
    }

    @Test("CheckInSettingsView renders without crashing")
    func checkInSettingsViewRenders() {
        realize(NavigationStack { CheckInSettingsView() })
    }

    @Test("PolarSettingsView renders without crashing")
    func polarSettingsViewRenders() throws {
        let container = try TestHelpers.makeFullContainer()
        let polar = PolarHRMService(modelContext: ModelContext(container))
        let recordingPresentation = RecordingPresentationCoordinator()
        realize(
            NavigationStack { PolarSettingsView() }
                .environment(polar)
                .environment(recordingPresentation)
        )
    }

    @Test("AppleHealthSettingsView renders without crashing")
    func appleHealthSettingsViewRenders() {
        realize(NavigationStack { AppleHealthSettingsView() })
    }

    @Test("HealthRecordsSettingsView renders without crashing")
    func healthRecordsSettingsViewRenders() throws {
        let container = try TestHelpers.makeFullContainer()
        realize(
            NavigationStack { HealthRecordsSettingsView() }
                .modelContainer(container)
        )
    }
}
