import Testing
import UIKit
@testable import AnxietyWatch

@MainActor
struct AppDelegateTests {
    private final class UploaderSpy: AlertChannelUploading {
        var tokens: [Data] = []
        func sessionStarted(_ sessionID: UUID) {}
        func uploadSamples(sessionID: UUID, samples: [CNSSignalSample]) {}
        func sessionEnded(_ sessionID: UUID) {}
        func registerPushToken(_ deviceToken: Data) { tokens.append(deviceToken) }
    }

    @Test func forwardsAPNsDeviceTokenToUploader() {
        let delegate = AppDelegate()
        let spy = UploaderSpy()
        delegate.alertChannelUploader = spy
        let token = Data([0x01, 0x02, 0x03, 0x04])

        delegate.application(UIApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: token)

        #expect(spy.tokens == [token])
    }
}
