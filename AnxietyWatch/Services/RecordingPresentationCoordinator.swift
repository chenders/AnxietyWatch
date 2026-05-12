import Foundation
import Observation

/// Shared sheet-presentation state for the in-progress recording UI.
/// Injected at App scope so any view (the in-app pill, the dashboard
/// card, the Settings polar section) can flip `showingLiveView` from
/// outside its own subtree and have ContentView's root-level sheet
/// react to it.
///
/// Lives separately from `PolarHRMService` so the model layer doesn't
/// own UI state — the service publishes "is this session running"; this
/// coordinator publishes "is the user looking at it right now". The two
/// can diverge intentionally: the user dismisses the sheet but
/// recording continues (the pill stays visible); the user taps the
/// pill and the sheet reopens.
///
/// **Reset contract**: this coordinator does NOT clear `showingLiveView`
/// when a session ends. SwiftUI resets the binding to `false` on any
/// sheet dismissal (swipe-down, the Close toolbar button, or
/// programmatic `dismiss()`). If a session is stopped externally
/// (Bluetooth disconnect, reconnect-grace expiry) while the sheet is
/// open, the sheet stays mounted and shows the idle / error state until
/// the user closes it — which is the intentional UX, matching the
/// existing Close-button affordance in `HRVSessionLiveView`. A future
/// contributor should not patch `PolarHRMService.stopSession()` to set
/// `showingLiveView = false`; that would race with the user-driven
/// dismissal and produce a sheet that disappears mid-read.
@MainActor
@Observable
final class RecordingPresentationCoordinator {
    var showingLiveView: Bool = false
}
