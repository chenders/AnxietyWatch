import AVFAudio
import UserNotifications

@MainActor
protocol NotificationPosting {
    func post(_ content: UNNotificationContent)
}

@MainActor
protocol WatchHapticSending {
    func sendKlaxonHaptic()
}

@MainActor
protocol AlarmAudioPlaying {
    func playKlaxon()
}

@MainActor
struct CNSAlarmPresenter {
    private let notify: any NotificationPosting
    private let haptic: any WatchHapticSending
    private let audio: any AlarmAudioPlaying

    init(notify: any NotificationPosting, haptic: any WatchHapticSending, audio: any AlarmAudioPlaying) {
        self.notify = notify
        self.haptic = haptic
        self.audio = audio
    }

    func present(tier: CNSAlertTier, permission: CNSNotifyPermission, appActive: Bool) {
        let channels = CNSAlarmChannelPolicy.channels(
            tier: tier,
            criticalGranted: permission == .criticalGranted,
            timeSensitiveGranted: permission == .timeSensitiveOnly,
            appActive: appActive
        )
        if channels.contains(.watchHaptic) {
            haptic.sendKlaxonHaptic()
        }
        if channels.contains(.criticalNotification) {
            notify.post(Self.notificationContent(interruptionLevel: .critical, criticalSound: true))
        } else if channels.contains(.timeSensitiveNotification) {
            notify.post(Self.notificationContent(interruptionLevel: .timeSensitive, criticalSound: false))
        }
        if channels.contains(.foregroundAudio) {
            audio.playKlaxon()
        }
    }

    private static func notificationContent(
        interruptionLevel: UNNotificationInterruptionLevel,
        criticalSound: Bool
    ) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "CNS Depression Warning"
        content.body = "Wake up and check your breathing and oxygen level now."
        content.interruptionLevel = interruptionLevel
        content.sound = criticalSound ? .defaultCritical : .default
        return content
    }
}

@MainActor
struct UserNotificationPoster: NotificationPosting {
    func post(_ content: UNNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
struct PhoneWatchHapticSender: WatchHapticSending {
    func sendKlaxonHaptic() {
        PhoneConnectivityManager.shared.sendKlaxonHaptic()
    }
}

@MainActor
struct ForegroundAlarmAudioPlayer: AlarmAudioPlaying {
    func playKlaxon() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        // Foreground audio asset playback is supplied by the app alarm UI;
        // activating `.playback` here ensures that audio bypasses silent mode.
    }
}
