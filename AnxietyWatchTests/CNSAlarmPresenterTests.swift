import Testing
import UserNotifications
@testable import AnxietyWatch

@MainActor
struct CNSAlarmPresenterTests {
    @Test("Critical permission posts one critical notification and one watch haptic")
    func criticalPresentation() {
        let notification = NotificationPostingSpy()
        let haptic = WatchHapticSpy()
        let audio = AlarmAudioSpy()
        let presenter = CNSAlarmPresenter(notify: notification, haptic: haptic, audio: audio)

        presenter.present(tier: .klaxon, permission: .criticalGranted, appActive: false)

        #expect(notification.contents.count == 1)
        #expect(notification.contents[0].interruptionLevel == .critical)
        #expect(notification.contents[0].sound != nil)
        #expect(haptic.sendCount == 1)
        #expect(audio.playCount == 0)
    }

    @Test("Time-Sensitive permission uses fallback notification")
    func timeSensitivePresentation() {
        let notification = NotificationPostingSpy()
        let haptic = WatchHapticSpy()
        let presenter = CNSAlarmPresenter(notify: notification, haptic: haptic, audio: AlarmAudioSpy())

        presenter.present(tier: .klaxon, permission: .timeSensitiveOnly, appActive: false)

        #expect(notification.contents.count == 1)
        #expect(notification.contents[0].interruptionLevel == .timeSensitive)
        #expect(haptic.sendCount == 1)
    }

    @Test("Denied notification permission remains watch-first and plays foreground audio")
    func deniedForegroundPresentation() {
        let notification = NotificationPostingSpy()
        let haptic = WatchHapticSpy()
        let audio = AlarmAudioSpy()
        let presenter = CNSAlarmPresenter(notify: notification, haptic: haptic, audio: audio)

        presenter.present(tier: .klaxon, permission: .denied, appActive: true)

        #expect(notification.contents.isEmpty)
        #expect(haptic.sendCount == 1)
        #expect(audio.playCount == 1)
    }
}

@MainActor
private final class NotificationPostingSpy: NotificationPosting {
    private(set) var contents: [UNNotificationContent] = []
    func post(_ content: UNNotificationContent) { contents.append(content) }
}

@MainActor
private final class WatchHapticSpy: WatchHapticSending {
    private(set) var sendCount = 0
    func sendKlaxonHaptic() { sendCount += 1 }
}

@MainActor
private final class AlarmAudioSpy: AlarmAudioPlaying {
    private(set) var playCount = 0
    func playKlaxon() { playCount += 1 }
}
