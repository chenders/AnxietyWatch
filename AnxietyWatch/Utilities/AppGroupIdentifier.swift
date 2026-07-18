import Foundation

/// The single source of truth for the App Group identifier.
///
/// Compiled into the iOS app, Watch app, and Widgets extension targets (added
/// to the latter two via the project's synchronized-group membership
/// exceptions). Every target-local constant — `AppGroup.identifier`,
/// `WatchAppGroup.identifier`, and both `SharedData.appGroup` enums — references
/// this value, so the identifier can never drift between targets again. That
/// drift is exactly what the `fix/app-group-identifier-mismatch` work exists to
/// prevent.
///
/// Must match the `com.apple.security.application-groups` entitlement in all
/// three targets.
enum AppGroupIdentifier {
    static let value = "group.com.groundeffectsoftware.AnxietyWatch.watch"
}
