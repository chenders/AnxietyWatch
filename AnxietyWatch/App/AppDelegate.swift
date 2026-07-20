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
        return true
    }
}
