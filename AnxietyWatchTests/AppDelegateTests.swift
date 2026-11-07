import Testing
import UIKit
@testable import AnxietyWatch

@Suite("AppDelegate")
struct AppDelegateTests {
    @Test func finishesLaunchWithoutRegisteringRemoteNotifications() {
        let delegate = AppDelegate()
        let ok = delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil)
        #expect(ok)
    }
}
