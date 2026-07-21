import AVFAudio
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

    @Test("Klaxon buffer is a hi-pulse / gap / lo-pulse / gap cycle that alternates per pulse, not per sample")
    func klaxonBufferHasTwoToneStructure() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try #require(ForegroundAlarmAudioPlayer.makeKlaxonBuffer(format: format))
        let sr = Float(format.sampleRate)
        let pulse = Int(ForegroundAlarmAudioPlayer.pulseDuration * sr)
        let gap = Int(ForegroundAlarmAudioPlayer.gapDuration * sr)
        let amp = ForegroundAlarmAudioPlayer.amplitude

        #expect(Int(buffer.frameLength) == pulse * 2 + gap * 2)
        let samples = try #require(buffer.floatChannelData)[0]

        // High pulse: a mid-pulse sample matches sin(2π·1500·t)·amp — proving a
        // per-PULSE tone, not the per-sample-alternating noise the old code made.
        let hiIdx = pulse / 2
        let hiExpected = sin(2.0 * .pi * ForegroundAlarmAudioPlayer.highFrequency * (Float(hiIdx) / sr)) * amp
        #expect(abs(samples[hiIdx] - hiExpected) < 0.001)

        // First gap is silent.
        #expect(abs(samples[pulse + gap / 2]) < 0.001)

        // Low pulse matches sin(2π·900·t)·amp (time resets at the segment start).
        let loStart = pulse + gap
        let loIdx = loStart + pulse / 2
        let loExpected = sin(2.0 * .pi * ForegroundAlarmAudioPlayer.lowFrequency * (Float(loIdx - loStart) / sr)) * amp
        #expect(abs(samples[loIdx] - loExpected) < 0.001)

        // Second gap is silent.
        #expect(abs(samples[loStart + pulse + gap / 2]) < 0.001)
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

    @Test("Standard permission still posts an active fallback notification")
    func standardFallbackPresentation() {
        let notification = NotificationPostingSpy()
        let haptic = WatchHapticSpy()
        let presenter = CNSAlarmPresenter(
            notify: notification, haptic: haptic, audio: AlarmAudioSpy()
        )

        presenter.present(tier: .klaxon, permission: .standardOnly, appActive: false)

        #expect(notification.contents.count == 1)
        #expect(notification.contents[0].interruptionLevel == .active)
        #expect(notification.contents[0].sound != nil)
        #expect(haptic.sendCount == 1)
    }

    @Test("Watchdog uses the highest available scheduled interruption level")
    func watchdogPresentation() {
        let notification = NotificationPostingSpy()
        let presenter = CNSAlarmPresenter(
            notify: notification, haptic: WatchHapticSpy(), audio: AlarmAudioSpy()
        )
        let fireDate = Date(timeIntervalSince1970: 1_750_000_090)

        presenter.scheduleMonitoringStopped(permission: .criticalGranted, at: fireDate)

        #expect(notification.scheduled.count == 1)
        #expect(notification.scheduled[0].content.interruptionLevel == .critical)
        #expect(notification.scheduled[0].content.sound != nil)
        #expect(notification.scheduled[0].fireDate == fireDate)
    }

    @Test("Watchdog falls back to Time-Sensitive rather than stopping silently")
    func watchdogFallback() {
        let notification = NotificationPostingSpy()
        let presenter = CNSAlarmPresenter(
            notify: notification, haptic: WatchHapticSpy(), audio: AlarmAudioSpy()
        )

        presenter.scheduleMonitoringStopped(
            permission: .timeSensitiveOnly, at: Date(timeIntervalSince1970: 1_750_000_090)
        )

        #expect(notification.scheduled.count == 1)
        #expect(notification.scheduled[0].content.interruptionLevel == .timeSensitive)
    }

    @Test("Denied notification permission remains watch-first and plays foreground audio")
    func deniedForegroundPresentation() {
        let notification = NotificationPostingSpy()
        let haptic = WatchHapticSpy()
        let audio = AlarmAudioSpy()
        let presenter = CNSAlarmPresenter(notify: notification, haptic: haptic, audio: audio)

        presenter.present(tier: .klaxon, permission: .denied, appActive: true)

        #expect(notification.contents.count == 1)
        #expect(notification.contents[0].interruptionLevel == .active)
        #expect(haptic.sendCount == 1)
        #expect(audio.playCount == 1)
    }
}

@MainActor
private final class NotificationPostingSpy: NotificationPosting {
    struct Scheduled {
        let content: UNNotificationContent
        let fireDate: Date
    }

    private(set) var contents: [UNNotificationContent] = []
    private(set) var scheduled: [Scheduled] = []
    func post(_ content: UNNotificationContent) { contents.append(content) }
    func schedule(_ content: UNNotificationContent, at fireDate: Date) {
        scheduled.append(Scheduled(content: content, fireDate: fireDate))
    }
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
