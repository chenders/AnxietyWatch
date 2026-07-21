import UIKit
import os

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let centrals = launchOptions?[.bluetoothCentrals] {
            Log.health.notice("App launched in background via CoreBluetooth state restoration: \(String(describing: centrals), privacy: .private)")
        }
        // Request an APNs device token so the redundant server alert channel
        // (sub-project C) can push. The token is forwarded to the server below;
        // if the push entitlement isn't provisioned this fails harmlessly.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Register with the server's alert channel (best-effort; no-ops until the
        // user has configured sync). The token itself is never logged.
        Log.health.notice("APNs device token received (len=\(deviceToken.count, privacy: .public))")
        AlertChannelUploader().registerPushToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Log.health.warning("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }
}
