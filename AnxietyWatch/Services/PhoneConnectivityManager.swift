import Foundation
import os.log
import SwiftData
import UserNotifications
import WatchConnectivity

/// iPhone-side WatchConnectivity. Receives anxiety entries from Watch, sends stats back.
@MainActor
final class PhoneConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = PhoneConnectivityManager()
    nonisolated private let log = Logger(subsystem: "AnxietyWatch", category: "PhoneConnectivity")

    // Set once during app launch
    var modelContainer: ModelContainer?

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

        // Explicitly clean up the file when done, though WCSession normally handles it
        defer { try? FileManager.default.removeItem(at: file.fileURL) }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: file.fileURL)
        } catch {
            log.error("Sensor data read failed: \(String(describing: type(of: error)), privacy: .public)")
            return
        }

        Task { @MainActor in
            guard let container = self.modelContainer else { return }
            do {
                let payload = try JSONDecoder().decode(SensorTransferPayload.self, from: fileData)
                try Self.ingestSensorPayload(payload, into: ModelContext(container))
            } catch {
                // Log the error TYPE only — a SwiftData/decoding error's string can
                // embed the failing row's field values (health data), which must
                // not reach logs (matches handleIncoming).
                self.log.error("Sensor data receive failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Ingests a decoded sensor transfer into `context`. `nonisolated static`
    /// so `didReceive`'s nonisolated WCSession callback can call it synchronously
    /// (no main-actor hop) and so it's unit-testable without a WCSession/file
    /// (F-096 regression test).
    ///
    /// These sensor rows are write-once per id, and WCSession can REDELIVER a
    /// file across a watch relaunch mid-transfer. A blind `insert` with the
    /// models' `#Unique(\.id)` constraint upserts on redelivery, re-writing the
    /// row from the DTO defaults — which for HRVReading resets `syncedToServer`
    /// back to false and triggers a redundant server re-upload of an
    /// already-synced reading (F-096). We skip any id already stored (one
    /// batched lookup per type), so a redelivery is a no-op and the stored row
    /// (incl. its syncedToServer flag) is preserved. New rows still insert.
    nonisolated static func ingestSensorPayload(_ payload: SensorTransferPayload, into context: ModelContext) throws {
        // Each block is guarded on a non-empty array so a transfer carrying
        // only one type doesn't issue existence queries against the other
        // (unbounded, growing) tables — matches SyncService.markSamplesSynced's
        // `if !uploaded.X.isEmpty` convention for the same Set<UUID>.contains
        // fetch shape.
        // The existence-check fetches use `try` (not `try?`): a swallowed
        // fetch failure would leave the "existing ids" set empty, re-enabling
        // the blind upsert this method exists to prevent (F-096). The method
        // throws, so a fetch failure aborts the ingest and surfaces in
        // didReceive's catch instead of silently corrupting sync state.
        if !payload.spectrograms.isEmpty {
            let specIDs = Set(payload.spectrograms.map(\.id))
            let existingSpecIDs = Set(try context.fetch(
                FetchDescriptor<AccelSpectrogram>(predicate: #Predicate { specIDs.contains($0.id) })
            ).map(\.id))
            for dto in payload.spectrograms where !existingSpecIDs.contains(dto.id) {
                context.insert(AccelSpectrogram(
                    id: dto.id,
                    timestamp: dto.timestamp,
                    tremorBandPower: dto.tremorBandPower,
                    breathingBandPower: dto.breathingBandPower,
                    fidgetBandPower: dto.fidgetBandPower,
                    activityLevel: dto.activityLevel,
                    sensorSessionID: dto.sensorSessionID
                ))
            }
        }

        if !payload.breathingRates.isEmpty {
            let rateIDs = Set(payload.breathingRates.map(\.id))
            let existingRateIDs = Set(try context.fetch(
                FetchDescriptor<DerivedBreathingRate>(predicate: #Predicate { rateIDs.contains($0.id) })
            ).map(\.id))
            for dto in payload.breathingRates where !existingRateIDs.contains(dto.id) {
                context.insert(DerivedBreathingRate(
                    id: dto.id,
                    timestamp: dto.timestamp,
                    breathsPerMinute: dto.breathsPerMinute,
                    confidence: dto.confidence,
                    source: dto.source,
                    sensorSessionID: dto.sensorSessionID
                ))
            }
        }

        if !payload.hrvReadings.isEmpty {
            let hrvIDs = Set(payload.hrvReadings.map(\.id))
            let existingHRVIDs = Set(try context.fetch(
                FetchDescriptor<HRVReading>(predicate: #Predicate { hrvIDs.contains($0.id) })
            ).map(\.id))
            for dto in payload.hrvReadings where !existingHRVIDs.contains(dto.id) {
                context.insert(HRVReading(
                    id: dto.id,
                    timestamp: dto.timestamp,
                    rmssd: dto.rmssd, sdnn: dto.sdnn, pnn50: dto.pnn50,
                    lfPower: dto.lfPower, hfPower: dto.hfPower, lfHfRatio: dto.lfHfRatio,
                    sensorSessionID: dto.sensorSessionID
                ))
            }
        }

        try context.save()
    }

    nonisolated private func handleIncoming(_ message: [String: Any]) {
        guard message["type"] as? String == "anxietyEntry",
              let severity = message["severity"] as? Int,
              let ts = message["timestamp"] as? TimeInterval
        else { return }

        let notes = message["notes"] as? String ?? ""
        let source = message["source"] as? String
        let timestamp = Date(timeIntervalSince1970: ts)

        Task { @MainActor in
            guard let container = self.modelContainer else { return }
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
                self.log.error("Watch quick-log save failed, entry lost: \(String(describing: type(of: error)), privacy: .public)")

                let content = UNMutableNotificationContent()
                content.title = "Journal Entry Failed"
                content.body = "Your recent journal entry from the Apple Watch could not be saved to your iPhone. Please try logging it again."
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)

                return
            }

            // If this was a check-in from the Watch, complete it on the iPhone side
            if source == "random_checkin" {
                RandomCheckInManager.completeCheckIn()
            }
        }
    }
}
