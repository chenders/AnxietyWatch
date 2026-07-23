#if DEBUG
import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// DEBUG-only first cut of the tiered CNS alert engine (the spec's
/// `KlaxonAlarmService`, §5.3/§9). Maps the detection tier to an escalating
/// local alert — gentle heads-up → mild warning beep → loud klaxon + strong
/// haptics — on the phone only. Wired ONLY into the live-dongle self-test for
/// now (not the production coordinator paths).
///
/// Sounds are synthesized (no audio assets) and use the `.playback` session
/// category, so they play over the ring/silent switch while the app is in the
/// foreground. Deferred (per the design doc): background/locked survival,
/// DND/Critical-Alerts bypass, watch haptics, and the slide-to-dismiss +
/// "Are you OK?" confirmation interaction.
@MainActor
final class CNSAlertEngine {
    private let tone = CNSAlertTonePlayer()
    private var klaxonHapticTask: Task<Void, Never>?
    private var lastTier: CNSAlertTier = .clear

    // Retained + prepared so the Taptic Engine is warm; an inline, unretained,
    // un-prepared UINotificationFeedbackGenerator() is silently dropped by iOS
    // ("no engine to play feedback").
    private let notifier = UINotificationFeedbackGenerator()

    // Best-effort DEBUG loudness: force the media volume to max while the klaxon
    // sounds, restoring it after. iOS exposes no public output-volume setter, so
    // this drives a hidden MPVolumeView slider — fragile (private-view
    // introspection) and does NOT change the output ROUTE (headphones still win)
    // or bypass the mute switch. The robust answer is the Critical Alerts
    // entitlement (system volume, ignores mute + this slider); this is only a
    // louder foreground stopgap.
    private let volumeView = MPVolumeView(frame: .zero)
    private var priorSystemVolume: Float?

    /// Drive the alert for a new tier. Idempotent per tier (only acts on change).
    func update(for tier: CNSAlertTier) {
        guard tier != lastTier else { return }
        let rising = tier.rawValue > lastTier.rawValue
        lastTier = tier

        switch tier {
        case .clear:
            silence()
            lastTier = .clear   // silence() resets lastTier; keep it consistent

        case .watch:
            stopKlaxonHaptics()
            restoreSystemVolume()         // de-escalated below confirm/klaxon — un-pin the media volume
            if rising { notify(.warning) }
            tone.playSoftChirp()          // one gentle heads-up tone

        case .confirm:
            stopKlaxonHaptics()
            if rising { notify(.warning) }
            boostSystemVolume()           // pre-klaxon "confirm you're awake" is loud too
            tone.playWarningLoop()        // mild repeating pre-klaxon beep

        case .klaxon:
            if rising { notify(.error) }
            boostSystemVolume()           // best-effort: max the media volume
            tone.playKlaxonLoop()         // loud two-tone alarm, until dismissed
            startKlaxonHaptics()          // strong repeating buzz
        }
    }

    /// Stop all sound + haptics (used by the self-test's Stop / dismiss).
    func silence() {
        stopKlaxonHaptics()
        tone.stop()
        restoreSystemVolume()
        lastTier = .clear
    }

    private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notifier.prepare()   // warm the Taptic Engine right before firing
        notifier.notificationOccurred(type)
    }

    /// Force the system media volume to max for the klaxon (best-effort).
    private func boostSystemVolume() {
        guard priorSystemVolume == nil,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) else { return }
        priorSystemVolume = AVAudioSession.sharedInstance().outputVolume
        volumeView.alpha = 0.0001
        volumeView.isUserInteractionEnabled = false
        if volumeView.superview == nil { window.addSubview(volumeView) }
        // The slider subview only exists once the view is in the hierarchy.
        DispatchQueue.main.async { [weak self] in
            // If Stop / de-escalation already restored the volume before this
            // deferred boost runs, `priorSystemVolume` is nil — don't re-pin it.
            guard let self, self.priorSystemVolume != nil else { return }
            self.setVolumeSlider(1.0)
        }
    }

    private func restoreSystemVolume() {
        guard let prior = priorSystemVolume else { return }
        priorSystemVolume = nil
        setVolumeSlider(prior)
        volumeView.removeFromSuperview()
    }

    private func setVolumeSlider(_ value: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }

    private func startKlaxonHaptics() {
        klaxonHapticTask?.cancel()
        klaxonHapticTask = Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            while !Task.isCancelled {
                generator.impactOccurred(intensity: 1.0)
                try? await Task.sleep(for: .milliseconds(550))
            }
        }
    }

    private func stopKlaxonHaptics() {
        klaxonHapticTask?.cancel()
        klaxonHapticTask = nil
    }
}

/// Synthesized alert tones via `AVAudioEngine` + a looping `AVAudioPlayerNode`.
/// Buffers are generated once (no audio asset files). Control methods are
/// called only from the `@MainActor` `CNSAlertEngine`.
@MainActor
final class CNSAlertTonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    private lazy var softBuffer = makeBeep(freq: 523, onSeconds: 0.18, totalSeconds: 0.9, amp: 0.22)
    private lazy var warningBuffer = makeBeep(freq: 660, onSeconds: 0.16, totalSeconds: 1.1, amp: 0.32)
    private lazy var klaxonBuffer = makeKlaxon()

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func playSoftChirp() { play(softBuffer, loop: false) }
    func playWarningLoop() { play(warningBuffer, loop: true) }
    func playKlaxonLoop() { play(klaxonBuffer, loop: true) }

    func stop() {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func play(_ buffer: AVAudioPCMBuffer, loop: Bool) {
        activate()
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: loop ? .loops : [], completionHandler: nil)
        player.play()
    }

    private func activate() {
        // `.playback` plays over the silent switch (foreground). `.duckOthers`
        // lowers other audio while the alert sounds.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
    }

    /// A single `freq`-Hz beep of `onSeconds`, padded with silence to
    /// `totalSeconds` (so a looped buffer becomes a repeating beep). Short
    /// attack/release envelope avoids clicks.
    private func makeBeep(freq: Double, onSeconds: Double, totalSeconds: Double, amp: Float) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(totalSeconds * sr)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        let onFrames = Int(onSeconds * sr)
        let ramp = max(1, Int(0.005 * sr))
        for i in 0..<Int(frames) {
            if i < onFrames {
                let t = Double(i) / sr
                let env = Double(min(i, onFrames - i)) / Double(ramp)
                channel[i] = amp * Float(min(1.0, env) * sin(2 * .pi * freq * t))
            } else {
                channel[i] = 0
            }
        }
        return buffer
    }

    /// Loud two-tone alarm: 0.25 s @ 760 Hz + 0.25 s @ 1000 Hz; looped it
    /// oscillates like a klaxon.
    private func makeKlaxon() -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let segment = 0.25
        let frames = AVAudioFrameCount(2 * segment * sr)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        let segmentFrames = Int(segment * sr)
        for i in 0..<Int(frames) {
            let freq: Double = i >= segmentFrames ? 1000 : 760
            let t = Double(i) / sr
            channel[i] = 0.98 * Float(sin(2 * .pi * freq * t))  // near full-scale klaxon
        }
        return buffer
    }
}
#endif
