import Foundation
import os
import SwiftData
import WatchConnectivity
import WatchKit
import WidgetKit

/// Watch-side connectivity. Sends anxiety entries to iPhone, receives stats via applicationContext.
@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    var lastAnxiety: Int?
    var hrvAvg: Double?
    var restingHR: Double?
    var lastSyncStatus: String?
    var pendingRandomCheckIn = false

    /// Guards against a second `transferSensorData` call re-fetching the same
    /// not-yet-flagged rows while the first call's detached fetch/encode/write
    /// is still in flight (the `outstandingFileTransfers` check alone can't
    /// see a transfer that hasn't been handed to WCSession yet). Set/cleared
    /// only on the main actor.
    private var isFetchingSensorData = false

    private let log = Logger(subsystem: "AnxietyWatch", category: "WatchConnectivity")

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendAnxietyEntry(severity: Int, notes: String = "", source: String? = nil) {
        var message: [String: Any] = [
            "type": "anxietyEntry",
            "severity": severity,
            "timestamp": Date().timeIntervalSince1970,
            "notes": notes,
        ]
        if let source {
            message["source"] = source
        }

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { [weak self] _ in
                // Phone not reachable — queue for later delivery
                WCSession.default.transferUserInfo(message)
                Task { @MainActor in
                    self?.lastSyncStatus = "Queued"
                }
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    // MARK: - Sensor Data Transfer

    /// Persistent identifiers of the rows in each in-flight transfer, keyed
    /// by the temp file's path. The rows' `transferredToPhone` flag is flipped
    /// only when that transfer COMPLETES (`didFinish`, no error), so an
    /// interrupted transfer leaves them eligible for the next cycle — at worst
    /// re-sent (the phone dedups on `#Unique(\.id)`), never lost. See F-018.
    private var pendingTransfers: [String: [PersistentIdentifier]] = [:]
    /// Container captured from the most recent transfer call so `didFinish`
    /// (which carries no context of its own) can flip the delivered rows'
    /// transferredToPhone flag.
    private var transferModelContainer: ModelContainer?

    /// `@MainActor` (explicit, though the target's default actor isolation
    /// already provides it): this mutates `pendingTransfers`/@Observable state
    /// that the `didFinish` delegate callback also touches, so both must share
    /// the main actor to stay race-free (Copilot review of #164).
    @MainActor
    func transferSensorData(modelContainer: ModelContainer) {
        guard WCSession.default.activationState == .activated else { return }

        // Don't stack a new batch on top of an outstanding one: overlapping
        // transfers of the same not-yet-flagged rows would re-deliver
        // duplicates to the phone (F-018 review). One in-flight sensor
        // transfer at a time; the next tick picks up where this one leaves off.
        let sensorTransfersInFlight = WCSession.default.outstandingFileTransfers.contains {
            $0.file.metadata?["type"] as? String == "sensorData"
        }
        guard !sensorTransfersInFlight && !isFetchingSensorData else { return }

        isFetchingSensorData = true

        Task.detached(priority: .background) {
            let context = ModelContext(modelContainer)

            do {
                // Fetch only rows NOT yet transferred to the phone (persistent
                // per-row flag, not a timestamp watermark — a backward clock step
                // can't make a row permanently unfetchable). Ascending + capped so
                // the oldest un-sent rows go first. Single-clause Bool predicate,
                // safe under the iOS 26 compound-#Predicate footgun.
                var specDescriptor = FetchDescriptor<AccelSpectrogram>(
                    predicate: #Predicate { !$0.transferredToPhone },
                    sortBy: [SortDescriptor(\.timestamp, order: .forward)]
                )
                specDescriptor.fetchLimit = 500
                let spectrograms = try context.fetch(specDescriptor)

                var brDescriptor = FetchDescriptor<DerivedBreathingRate>(
                    predicate: #Predicate { !$0.transferredToPhone },
                    sortBy: [SortDescriptor(\.timestamp, order: .forward)]
                )
                brDescriptor.fetchLimit = 500
                let breathingRates = try context.fetch(brDescriptor)

                var hrvDescriptor = FetchDescriptor<HRVReading>(
                    predicate: #Predicate { !$0.transferredToPhone },
                    sortBy: [SortDescriptor(\.timestamp, order: .forward)]
                )
                hrvDescriptor.fetchLimit = 500
                let hrvReadings = try context.fetch(hrvDescriptor)

                guard !spectrograms.isEmpty || !breathingRates.isEmpty || !hrvReadings.isEmpty else {
                    await MainActor.run { self.isFetchingSensorData = false }
                    return
                }

                // Encode to JSON
                let payload = SensorTransferPayload(
                    spectrograms: spectrograms.map { SensorTransferPayload.SpectrogramDTO(from: $0) },
                    breathingRates: breathingRates.map { SensorTransferPayload.BreathingRateDTO(from: $0) },
                    hrvReadings: hrvReadings.map { SensorTransferPayload.HRVDTO(from: $0) }
                )
                let data = try JSONEncoder().encode(payload)

                // Clean up any leftover temp files from completed transfers
                let tempDir = FileManager.default.temporaryDirectory
                if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
                    let activeTransferURLs = Set(WCSession.default.outstandingFileTransfers.map(\.file.fileURL))
                    for url in contents where url.lastPathComponent.hasPrefix("sensor_") && !activeTransferURLs.contains(url) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }

                // Write to temp file and transfer
                let tempURL = tempDir
                    .appendingPathComponent("sensor_\(UUID().uuidString).json")
                try data.write(to: tempURL)

                let ids = spectrograms.map(\.persistentModelID)
                    + breathingRates.map(\.persistentModelID)
                    + hrvReadings.map(\.persistentModelID)

                await MainActor.run {
                    self.transferModelContainer = modelContainer
                    // Stash this batch's row IDs; flip transferredToPhone only when the
                    // transfer completes (didFinish).
                    self.pendingTransfers[tempURL.path] = ids
                    WCSession.default.transferFile(tempURL, metadata: ["type": "sensorData"])
                    self.isFetchingSensorData = false
                }

            } catch {
                await MainActor.run {
                    self.lastSyncStatus = "Sensor sync failed"
                    self.isFetchingSensorData = false
                }
            }
        }
    }

    /// Flip `transferredToPhone` on the rows a completed transfer carried.
    /// Uses a fresh context off the shared container so it works regardless of
    /// which context fetched them. IDs missing from the store (deleted) are
    /// skipped.
    @MainActor
    private func markTransferred(_ ids: [PersistentIdentifier], modelContainer: ModelContainer) {
        guard !ids.isEmpty else { return }
        let context = ModelContext(modelContainer)
        for id in ids {
            if let row = context.model(for: id) as? any PhoneTransferable {
                row.transferredToPhone = true
            }
        }
        do {
            try context.save()
        } catch {
            // If the flags don't persist, the rows stay un-flagged and get
            // re-transferred next cycle (benign — the phone dedups on
            // #Unique(\.id)); surface it so the re-transfer loop is
            // diagnosable rather than silent (Copilot review of #164).
            lastSyncStatus = "Sensor sync flag save failed"
            log.error(
                "markTransferred save failed: \(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    private func loadContext() {
        let ctx = WCSession.default.receivedApplicationContext
        lastAnxiety = ctx[SharedData.Key.lastAnxiety] as? Int
        hrvAvg = ctx[SharedData.Key.hrvAvg] as? Double
        restingHR = ctx[SharedData.Key.restingHR] as? Double
        pendingRandomCheckIn = ctx[SharedData.Key.pendingRandomCheckIn] as? Bool ?? false
        pushToWidget()
    }

    /// Write stats to shared UserDefaults so the widget extension can read them.
    private func pushToWidget() {
        guard let defaults = SharedData.shared else { return }
        if let v = lastAnxiety { defaults.set(v, forKey: SharedData.Key.lastAnxiety) }
        if let v = hrvAvg { defaults.set(v, forKey: SharedData.Key.hrvAvg) }
        if let v = restingHR { defaults.set(v, forKey: SharedData.Key.restingHR) }
        defaults.set(Date().timeIntervalSince1970, forKey: SharedData.Key.lastUpdate)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor in self.loadContext() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.applyIncomingData(message) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            self.applyIncomingData(applicationContext)
        }
    }

    /// Handle queued `transferUserInfo` deliveries from the phone side.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            self.applyIncomingData(userInfo)
        }
    }

    /// Flip transferredToPhone on a batch's rows only when its file transfer
    /// actually finished (F-018). A failed/interrupted transfer leaves them
    /// unflagged so the next cycle re-sends them rather than losing them.
    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: (any Error)?
    ) {
        let path = fileTransfer.file.fileURL.path
        Task { @MainActor in
            defer { self.pendingTransfers[path] = nil }
            guard error == nil, let ids = self.pendingTransfers[path],
                  let container = self.transferModelContainer else {
                if error != nil { self.lastSyncStatus = "Sensor sync failed" }
                return
            }
            self.markTransferred(ids, modelContainer: container)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func applyIncomingData(_ data: [String: Any]) {
        if data["type"] as? String == "cnsKlaxonHaptic" {
            playKlaxonHaptics()
            return
        }
        if let v = data[SharedData.Key.lastAnxiety] as? Int { lastAnxiety = v }
        if let v = data[SharedData.Key.hrvAvg] as? Double { hrvAvg = v }
        if let v = data[SharedData.Key.restingHR] as? Double { restingHR = v }
        pendingRandomCheckIn = data[SharedData.Key.pendingRandomCheckIn] as? Bool ?? pendingRandomCheckIn
        pushToWidget()
    }

    private func playKlaxonHaptics() {
        Task { @MainActor in
            for _ in 0..<3 {
                WKInterfaceDevice.current().play(.failure)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }
}
