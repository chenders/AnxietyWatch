import AVFAudio
import UserNotifications

@MainActor
protocol NotificationPosting {
    func post(_ content: UNNotificationContent)
    func schedule(_ content: UNNotificationContent, at fireDate: Date)
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
        } else if channels.contains(.standardNotification) {
            notify.post(Self.notificationContent(interruptionLevel: .active, criticalSound: false))
        }
        if channels.contains(.foregroundAudio) {
            audio.playKlaxon()
        }
    }

    /// Arms the dead-man's switch with the loudest notification level the
    /// user granted. When denied, the OS blocks notification delivery entirely;
    /// the existing watch-first klaxon path remains independent.
    func scheduleMonitoringStopped(permission: CNSNotifyPermission, at fireDate: Date) {
        let level: UNNotificationInterruptionLevel
        let criticalSound: Bool
        switch permission {
        case .criticalGranted:
            level = .critical
            criticalSound = true
        case .timeSensitiveOnly:
            level = .timeSensitive
            criticalSound = false
        case .standardOnly, .notDetermined, .denied:
            level = .active
            criticalSound = false
        }
        notify.schedule(Self.monitoringStoppedContent(
            interruptionLevel: level, criticalSound: criticalSound
        ), at: fireDate)
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

    private static func monitoringStoppedContent(
        interruptionLevel: UNNotificationInterruptionLevel,
        criticalSound: Bool
    ) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "CNS monitoring may have stopped"
        content.body = "Monitoring may have been interrupted. Reopen AnxietyWatch to check its status."
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

    func schedule(_ content: UNNotificationContent, at fireDate: Date) {
        let interval = max(fireDate.timeIntervalSinceNow, CNSMonitoringConstants.minimumNotificationDelay)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: CNSMonitoringConstants.deadMansSwitchNotificationID,
            content: content,
            trigger: trigger
        )
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
final class ForegroundAlarmAudioPlayer: AlarmAudioPlaying {
    private static var engine: AVAudioEngine?
    private static var playerNode: AVAudioPlayerNode?

    func playKlaxon() {
        guard Self.engine == nil else { return }  // already playing

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

        let toneDuration: Float = 0.25
        let silenceDuration: Float = 0.15
        let frameCount = AVAudioFrameCount((toneDuration + silenceDuration) * Float(format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channels = UnsafeBufferPointer(start: buffer.floatChannelData, count: Int(format.channelCount))
        let toneFrames = Int(toneDuration * Float(format.sampleRate))
        let totalFrames = Int(frameCount)
        let highFreq: Float = 1500
        let lowFreq: Float = 900
        let amplitude: Float = 0.6

        for frame in 0..<totalFrames {
            let t = Float(frame) / Float(format.sampleRate)
            let freq = frame < toneFrames ? (frame % 2 == 0 ? highFreq : lowFreq) : 0
            let sample = sin(2.0 * .pi * freq * t) * amplitude
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)

        try? engine.start()
        player.play()

        Self.engine = engine
        Self.playerNode = player
    }

    static func stopKlaxon() {
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
    }
}
