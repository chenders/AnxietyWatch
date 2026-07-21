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

    /// Two-tone klaxon shape. Named so the pure buffer builder and its tests
    /// share one source of truth.
    static let pulseDuration: Float = 0.25
    static let gapDuration: Float = 0.15
    static let highFrequency: Float = 1500
    static let lowFrequency: Float = 900
    static let amplitude: Float = 0.6

    func playKlaxon() {
        guard Self.engine == nil else { return }  // already playing

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = Self.makeKlaxonBuffer(format: format) else {
            // Fail closed: skip foreground audio but keep the app (and the
            // monitor) running — watch haptic + notifications still fire. A
            // force-unwrap crash here would take the whole monitor down.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)

        do {
            try engine.start()
        } catch {
            // Start failed: tear down and DON'T cache the engine, so the next
            // playKlaxon() retries. Caching a non-started engine would trip the
            // `engine == nil` guard above and turn one transient failure into
            // permanent silence — the wrong direction for a fail-safe alarm.
            engine.detach(player)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        player.play()

        Self.engine = engine
        Self.playerNode = player
    }

    /// Builds one looping klaxon cycle — high pulse, gap, low pulse, gap. Pure
    /// and deterministic (no engine/session) so tests can verify pulse timing
    /// and the hi/lo alternation. Frequency alternates per PULSE, never per
    /// sample: a per-sample switch produces broadband noise, not a tone.
    static func makeKlaxonBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = Float(format.sampleRate)
        let pulseFrames = Int(pulseDuration * sampleRate)
        let gapFrames = Int(gapDuration * sampleRate)
        let segments: [(frequency: Float, frames: Int)] = [
            (highFrequency, pulseFrames), (0, gapFrames),
            (lowFrequency, pulseFrames), (0, gapFrames)
        ]
        let totalFrames = segments.reduce(0) { $0 + $1.frames }
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)
              ),
              let channelData = buffer.floatChannelData
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        let channels = UnsafeBufferPointer(start: channelData, count: Int(format.channelCount))

        var frame = 0
        for segment in segments {
            for i in 0..<segment.frames {
                // Time resets per segment so each pulse is a clean, continuous
                // tone instead of switching frequency mid-waveform.
                let t = Float(i) / sampleRate
                let sample = segment.frequency > 0
                    ? sin(2.0 * .pi * segment.frequency * t) * amplitude
                    : 0
                for channel in 0..<Int(format.channelCount) {
                    channels[channel][frame] = sample
                }
                frame += 1
            }
        }
        return buffer
    }

    static func stopKlaxon() {
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
        // Release the session so other audio isn't left ducked/interrupted
        // after the alarm stops.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
