import Foundation
import os.log
import SwiftData
import WatchConnectivity

/// iPhone-side WatchConnectivity. Receives anxiety entries from Watch, sends stats back.
final class PhoneConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = PhoneConnectivityManager()
    private let log = Logger(subsystem: "AnxietyWatch", category: "PhoneConnectivity")

    // Set once during app launch — accessed from nonisolated delegate callbacks
    nonisolated(unsafe) var modelContainer: ModelContainer?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Push latest metrics to the Watch's applicationContext.
    func sendStatsToWatch(lastAnxiety: Int?, hrvAvg: Double?, restingHR: Double?) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled
        else { return }

        var context: [String: Any] = [:]
        if let v = lastAnxiety { context["lastAnxiety"] = v }
        if let v = hrvAvg { context["hrvAvg"] = v }
        if let v = restingHR { context["restingHR"] = v }

        // Preserve pending check-in state
        if let pending = RandomCheckInManager.loadPending() {
            context["pendingRandomCheckIn"] = pending.scheduledTime <= Date.now
        }

        try? WCSession.default.updateApplicationContext(context)
    }

    // MARK: - Check-In Context

    /// Update Watch applicationContext with pending check-in state.
    func updateCheckInContext(pending: Bool) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled
        else { return }

        // Merge into the last context WE SENT (`applicationContext`), not the
        // context received FROM the Watch (`receivedApplicationContext`) —
        // the Watch never calls updateApplicationContext, so the received one
        // is always empty and starting from it wiped the stats keys
        // (lastAnxiety/hrvAvg/restingHR) that sendStatsToWatch had written on
        // every check-in state change (F-017).
        var context = WCSession.default.applicationContext
        context["pendingRandomCheckIn"] = pending
        try? WCSession.default.updateApplicationContext(context)
    }

    // MARK: - WCSessionDelegate (iOS requires all three activation methods)

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    // MARK: - Receiving entries from Watch

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncoming(userInfo)
    }

    // MARK: - Sensor Data Receive

    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        guard let metadata = file.metadata,
              metadata["type"] as? String == "sensorData" else { return }

        guard let container = modelContainer else { return }

        defer { try? FileManager.default.removeItem(at: file.fileURL) }

        do {
            let data = try Data(contentsOf: file.fileURL)
            let payload = try JSONDecoder().decode(SensorTransferPayload.self, from: data)
            let context = ModelContext(container)

            for dto in payload.spectrograms {
                let spec = AccelSpectrogram(
                    id: dto.id,
                    timestamp: dto.timestamp,
                    tremorBandPower: dto.tremorBandPower,
                    breathingBandPower: dto.breathingBandPower,
                    fidgetBandPower: dto.fidgetBandPower,
                    activityLevel: dto.activityLevel,
                    sensorSessionID: dto.sensorSessionID
                )
                context.insert(spec)
            }

            for dto in payload.breathingRates {
                let rate = DerivedBreathingRate(
                    id: dto.id,
                    timestamp: dto.timestamp,
                    breathsPerMinute: dto.breathsPerMinute,
                    confidence: dto.confidence,
                    source: dto.source,
                    sensorSessionID: dto.sensorSessionID
                )
                context.insert(rate)
            }

            for dto in payload.hrvReadings {
                let reading = HRVReading(
                    id: dto.id,
                    timestamp: dto.timestamp,
                    rmssd: dto.rmssd, sdnn: dto.sdnn, pnn50: dto.pnn50,
                    lfPower: dto.lfPower, hfPower: dto.hfPower, lfHfRatio: dto.lfHfRatio,
                    sensorSessionID: dto.sensorSessionID
                )
                context.insert(reading)
            }

            try context.save()
        } catch {
            log.error("Sensor data receive failed: \(error, privacy: .public)")
        }
    }

    nonisolated private func handleIncoming(_ message: [String: Any]) {
        guard message["type"] as? String == "anxietyEntry",
              let severity = message["severity"] as? Int,
              let ts = message["timestamp"] as? TimeInterval,
              let container = modelContainer
        else { return }

        let notes = message["notes"] as? String ?? ""
        let source = message["source"] as? String
        let timestamp = Date(timeIntervalSince1970: ts)

        Task { @MainActor in
            let context = ModelContext(container)
            let entry = AnxietyEntry(timestamp: timestamp, severity: severity, notes: notes, source: source)
            context.insert(entry)
            do {
                try context.save()
            } catch {
                // The Watch already played a success haptic and keeps no local
                // copy, so a swallowed save here permanently and silently loses
                // the journal entry (F-037). Log it, and do NOT mark the
                // check-in complete — leaving it pending lets the next sync/
                // prompt cycle recover rather than reporting phantom success.
                // Log the error TYPE only, never the error string — a
                // SwiftData save error can embed the failing row's field
                // values (the journal note), which must not reach logs.
                log.error("Watch quick-log save failed, entry lost: \(String(describing: type(of: error)), privacy: .public)")
                return
            }

            // If this was a check-in from the Watch, complete it on the iPhone side
            if source == "random_checkin" {
                RandomCheckInManager.completeCheckIn()
            }
        }
    }
}
