import Foundation
import SwiftData
import WatchConnectivity
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

    /// Batch sensor data into JSON and transfer to iPhone via file transfer.
    /// Call periodically (e.g., every 5 minutes) during active sensor capture.
    func transferSensorData(modelContainer: ModelContainer) {
        guard WCSession.default.activationState == .activated else { return }

        let context = ModelContext(modelContainer)

        do {
            // Fetch un-synced spectrograms (most recent 500)
            var specDescriptor = FetchDescriptor<AccelSpectrogram>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            specDescriptor.fetchLimit = 500
            let spectrograms = try context.fetch(specDescriptor)

            // Fetch un-synced breathing rates
            var brDescriptor = FetchDescriptor<DerivedBreathingRate>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            brDescriptor.fetchLimit = 500
            let breathingRates = try context.fetch(brDescriptor)

            // Fetch un-synced HRV readings
            var hrvDescriptor = FetchDescriptor<HRVReading>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            hrvDescriptor.fetchLimit = 500
            let hrvReadings = try context.fetch(hrvDescriptor)

            guard !spectrograms.isEmpty || !breathingRates.isEmpty || !hrvReadings.isEmpty else { return }

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
                .appendingPathComponent("sensor_\(Int(Date.now.timeIntervalSinceReferenceDate)).json")
            try data.write(to: tempURL)
            WCSession.default.transferFile(tempURL, metadata: ["type": "sensorData"])

        } catch {
            lastSyncStatus = "Sensor sync failed"
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

    // MARK: - Helpers

    @MainActor
    private func applyIncomingData(_ data: [String: Any]) {
        if let v = data[SharedData.Key.lastAnxiety] as? Int { lastAnxiety = v }
        if let v = data[SharedData.Key.hrvAvg] as? Double { hrvAvg = v }
        if let v = data[SharedData.Key.restingHR] as? Double { restingHR = v }
        pendingRandomCheckIn = data[SharedData.Key.pendingRandomCheckIn] as? Bool ?? pendingRandomCheckIn
        pushToWidget()
    }
}
