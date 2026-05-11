// AnxietyWatch/Services/PolarHRMService.swift
import CoreBluetooth
import Foundation
import Observation
import SwiftData
import UIKit
import os

/// View-facing state for the Polar H10 BLE pipeline. Separate from
/// `PolarHRMService` because the service is a long-lived owner of the
/// `CBCentralManager` that needs to outlive any single view, while the
/// state changes drive view updates via `@Observable`.
@MainActor
@Observable
final class PolarHRMState {
    enum Status: Equatable {
        case idle
        case scanning
        case connecting
        case recording
        case bluetoothOff           // user has Bluetooth disabled — recoverable in iOS Settings
        case bluetoothUnauthorized  // app denied Bluetooth permission
        case bluetoothUnsupported   // device has no BLE radio (simulator counts)
        case error(String)
    }

    struct DiscoveredPeripheral: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    var status: Status = .idle
    var currentHR: Int?
    var lastMinuteRMSSD: Double?
    var sessionStarted: Date?
    var sessionElapsed: TimeInterval = 0
    var pairedDeviceName: String?
    var discoveredPeripherals: [DiscoveredPeripheral] = []
}

/// Owns the CoreBluetooth `CBCentralManager` and drives the Phase 1 HRV
/// pipeline (`RRIntervalBuffer` → `HRVSessionRecorder` → SwiftData) from a
/// paired Polar H10 chest strap. Foreground-only in Phase 2; background-mode
/// state restoration lands in Phase 2b. `@Observable` so it can be passed
/// via SwiftUI environment; views observe `state` (also `@Observable`) for
/// the per-property change tracking.
@MainActor
@Observable
final class PolarHRMService: NSObject {

    // MARK: - Constants
    // Marked nonisolated because the CBCentralManagerDelegate / CBPeripheralDelegate
    // methods on this @MainActor class are declared `nonisolated` (Objective-C
    // protocol requirements). They run on the main queue under our current
    // CBCentralManager configuration but still need nonisolated access to these
    // values.

    nonisolated static let heartRateServiceUUID = CBUUID(string: "180D")
    nonisolated static let hrMeasurementCharacteristicUUID = CBUUID(string: "2A37")
    nonisolated static let pairedUUIDKey = "polarH10.peripheralUUID"
    nonisolated static let pairedNameKey = "polarH10.peripheralName"
    nonisolated static let sourceLabel = "polar_h10"

    // MARK: - Dependencies

    let state = PolarHRMState()
    private let modelContext: ModelContext
    private let log = Logger(subsystem: "AnxietyWatch", category: "PolarHRM")

    // MARK: - Runtime

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var hrmCharacteristic: CBCharacteristic?
    private var buffer: RRIntervalBuffer?
    private var archive: RRArchiveWriter?
    private var recorder: HRVSessionRecorder?
    private var tickTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    /// Latched by `startScan` when CB is in a transient state (`.unknown` /
    /// `.resetting`) or `.poweredOff` so the scan auto-resumes once
    /// `centralManagerDidUpdateState` fires with `.poweredOn`. Cleared by
    /// `stopScan` (so dismissing the pairing UI cancels the latch) and by
    /// `startScan` itself once a real scan begins. Scan-only — session
    /// start has no equivalent latch in Phase 2.
    private var pendingScan: Bool = false

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        super.init()
        // Use `queue: nil` so CoreBluetooth dispatches delegate callbacks
        // to the main queue. CB requires every CBCentralManager call to be
        // serialized on the queue it was constructed with — driving it from
        // @MainActor while it was bound to a dedicated background queue (as
        // in the first cut of this file) is a runtime race. The main queue
        // is fine for our load (Polar H10 sends ~1 Hz HR packets).
        self.central = CBCentralManager(delegate: self, queue: nil)
        // Re-hydrate paired state from UserDefaults so the UI shows the
        // remembered strap name without requiring a fresh scan.
        if isPaired {
            state.pairedDeviceName = UserDefaults.standard.string(forKey: Self.pairedNameKey)
        }
        // Enable battery monitoring so we can stamp sessions with a real
        // percentage at start. Cheap; UIKit only reports while monitoring is on.
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Current iPhone battery percentage (0–100). Returns 0 if monitoring
    /// hasn't yielded a reading yet (simulator, etc.) so sessions don't fail.
    private var currentBatteryPercent: Int {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Int((level * 100).rounded()) : 0
    }

    // MARK: - Pairing

    var isPaired: Bool { pairedPeripheralUUID != nil }

    var pairedPeripheralUUID: UUID? {
        guard let str = UserDefaults.standard.string(forKey: Self.pairedUUIDKey),
              let uuid = UUID(uuidString: str) else { return nil }
        return uuid
    }

    func pair(_ peripheral: DiscoveredPeripheralSummary) {
        UserDefaults.standard.set(peripheral.id.uuidString, forKey: Self.pairedUUIDKey)
        UserDefaults.standard.set(peripheral.name, forKey: Self.pairedNameKey)
        state.pairedDeviceName = peripheral.name
        stopScan()
    }

    func unpair() {
        UserDefaults.standard.removeObject(forKey: Self.pairedUUIDKey)
        UserDefaults.standard.removeObject(forKey: Self.pairedNameKey)
        state.pairedDeviceName = nil
        state.discoveredPeripherals.removeAll()
        stopScan()
        // Cancel both .connecting and .recording so an in-flight connection
        // can't quietly continue and start a session after the user unpairs.
        if state.status == .recording || state.status == .connecting {
            stopSession()
        }
    }

    // MARK: - Scan

    func startScan() {
        switch PolarBluetoothStateMapping.resolve(central.state) {
        case .proceed:
            break
        case .pendingTransient:
            // CB state is often .unknown right after init. Defer the scan
            // until `centralManagerDidUpdateState` flips to .poweredOn so the
            // user doesn't see a misleading "Bluetooth Off" message.
            pendingScan = true
            state.status = .idle
            return
        case .status(.bluetoothOff):
            // Latch a pending scan so the moment the user re-enables
            // Bluetooth in Settings the scan resumes automatically — otherwise
            // the pairing view sits with an empty list until manually
            // reopened.
            pendingScan = true
            state.status = .bluetoothOff
            return
        case .status(let status):
            state.status = status
            return
        }
        pendingScan = false
        state.status = .scanning
        state.discoveredPeripherals.removeAll()
        central.scanForPeripherals(
            withServices: [Self.heartRateServiceUUID],
            options: nil
        )
    }

    func stopScan() {
        if central.isScanning { central.stopScan() }
        // Clear any pending-scan latch so dismissing the pairing view doesn't
        // trigger a background scan later when CB transitions to .poweredOn.
        pendingScan = false
        if state.status == .scanning { state.status = .idle }
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard let uuid = pairedPeripheralUUID else {
            state.status = .error("No strap paired")
            return
        }
        // Use the same CB-state mapping as startScan so all three callers
        // agree on what unauthorized / unsupported / transient .unknown means.
        switch PolarBluetoothStateMapping.resolve(central.state) {
        case .proceed:
            break
        case .pendingTransient:
            // Phase 2 surfaces an error and the user retries when CB is
            // ready; auto-retry of startSession lands in Phase 2b along with
            // the broader state-machine work.
            state.status = .error("Bluetooth is still starting up. Try again in a moment.")
            return
        case .status(let status):
            state.status = status
            return
        }
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        guard let p = known.first else {
            state.status = .error("Paired strap not visible. Make sure it's worn and in range.")
            return
        }
        self.peripheral = p
        p.delegate = self
        state.status = .connecting
        central.connect(p, options: nil)
    }

    func stopSession() {
        // Re-entry guard: a disconnect callback can race with the user tapping
        // Stop. Without this, two concurrent stops can both try to finalize.
        guard state.status != .idle else { return }
        let (rec, arc) = tearDownResources()
        // Flip the visible status BEFORE the finalize work so the live-view
        // sheet can dismiss instantly (.interactiveDismissDisabled keys off
        // .recording/.connecting). Finalize runs on the synchronous critical
        // path only for SwiftData; the file close goes off-main.
        state.status = .idle
        finalizeOffline(recorder: rec, archive: arc)
    }

    /// Synchronous resource teardown — captures the live recorder/archive
    /// references for the caller to finalize off the visible critical path,
    /// then nils everything else: peripheral, hrmCharacteristic, recorder,
    /// archive, buffer, both tasks, and the live-data observable fields.
    /// Leaves `state.status` for the caller to set (`.idle` for a clean
    /// stop, `.error(...)` for `failConnection`). Idempotent: all-nil input
    /// returns (nil, nil).
    private func tearDownResources() -> (HRVSessionRecorder?, RRArchiveWriter?) {
        let finalRecorder = recorder
        let finalArchive = archive
        let p = peripheral

        peripheral = nil
        hrmCharacteristic = nil
        recorder = nil
        archive = nil
        buffer = nil
        tickTask?.cancel(); tickTask = nil
        elapsedTask?.cancel(); elapsedTask = nil
        if let p, p.state == .connected || p.state == .connecting {
            central.cancelPeripheralConnection(p)
        }

        state.currentHR = nil
        state.lastMinuteRMSSD = nil
        state.sessionStarted = nil
        state.sessionElapsed = 0

        return (finalRecorder, finalArchive)
    }

    /// SwiftData finalize runs on @MainActor (the recorder owns a
    /// ModelContext and writes the session summary); the file close is
    /// dispatched off-main so it doesn't block the UI transition after
    /// `state.status` has already flipped.
    private func finalizeOffline(recorder: HRVSessionRecorder?, archive: RRArchiveWriter?) {
        let now = Date()
        do {
            try recorder?.finalize(at: now)
        } catch {
            log.error("Recorder finalize failed: \(error.localizedDescription, privacy: .public)")
        }
        if let archive {
            Task.detached(priority: .background) { [log] in
                do {
                    try archive.finalize()
                } catch {
                    log.warning("Archive finalize failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Recording wiring (runs on @MainActor after connect/discover)

    private func beginRecording() {
        guard recorder == nil else { return }
        // Build the buffer and recorder locally first — only commit to `self`
        // and flip observable state to .recording after start has succeeded.
        // If start throws, the locals fall out of scope cleanly with no
        // half-initialized buffer/sessionStarted lingering on the service.
        let localBuffer = RRIntervalBuffer(window: 60)
        let now = Date()
        let localRecorder = HRVSessionRecorder(
            modelContext: modelContext,
            buffer: localBuffer,
            source: Self.sourceLabel
        )
        do {
            try localRecorder.start(at: now, batteryAtStart: currentBatteryPercent)
        } catch {
            log.error("Recorder start failed: \(error.localizedDescription, privacy: .public)")
            state.status = .error("Couldn't start session: \(error.localizedDescription)")
            return
        }

        // Recorder is up — commit to self and flip the UI.
        self.buffer = localBuffer
        self.recorder = localRecorder
        state.sessionStarted = now
        state.status = .recording

        // Now we know the SensorSession's ID; mint the archive against the
        // same identifier so a later (Phase 3) sync can find both halves.
        if let sessionID = localRecorder.sessionID {
            let archiveURL = Self.archiveURL(for: sessionID)
            self.archive = try? RRArchiveWriter(url: archiveURL)
            if self.archive == nil {
                log.warning("RR archive writer failed to open at \(archiveURL.path, privacy: .public); proceeding without raw archive.")
            }
        }

        scheduleTicks()
    }

    private func scheduleTicks() {
        // Use Task.sleep loops instead of Timer.scheduledTimer so the cadence
        // isn't paused while the user is scrolling (Timer's default mode
        // suspends during UI tracking; a delayed 60s tick would let
        // RRIntervalBuffer.flush evict the trailing minute's data).
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                guard let self else { break }
                do {
                    try await self.recorder?.tick(at: Date())
                    if let mean = self.recorder?.rmssdValues.last {
                        self.state.lastMinuteRMSSD = mean
                    }
                } catch {
                    self.log.error("Tick failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                guard let self, let start = self.state.sessionStarted else { break }
                self.state.sessionElapsed = Date().timeIntervalSince(start)
            }
        }
    }

    /// Tear down any in-flight connection / active recording before surfacing
    /// an error. Used by the failure paths in the CBPeripheralDelegate /
    /// CBCentralManagerDelegate methods. If a recording was active (e.g. the
    /// HR Measurement notifications dropped mid-session), the recorder,
    /// archive, and tick tasks are finalized here — without this the
    /// resources would leak because didDisconnectPeripheral only cleans up
    /// when `state.status` is `.recording` / `.connecting`, not `.error`.
    private func failConnection(message: String) {
        let (rec, arc) = tearDownResources()
        state.status = .error(message)
        finalizeOffline(recorder: rec, archive: arc)
    }

    private static func archiveURL(for sessionID: UUID) -> URL {
        let supportDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return supportDir
            .appendingPathComponent("rr_archives", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString).rr")
    }
}

/// Lightweight value type for pairing UI — avoids exposing `CBPeripheral` to views.
struct DiscoveredPeripheralSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

// MARK: - CBCentralManagerDelegate

extension PolarHRMService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newCBState = central.state
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch newCBState {
            case .poweredOn:
                // Recover the UI from any stalled off/unauthorized/unsupported
                // status. Don't clobber active recording/connecting/scanning.
                switch self.state.status {
                case .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported:
                    self.state.status = .idle
                default:
                    break
                }
                // Honor any scan that was queued while CB was still .unknown.
                if self.pendingScan {
                    self.startScan()
                }
            case .poweredOff, .unauthorized, .unsupported:
                // Tear down any active session BEFORE flipping the visible
                // status. didDisconnectPeripheral can't catch this race —
                // it checks for .recording / .connecting which we're about
                // to overwrite — and without explicit cleanup here the
                // recorder, archive, and timers would leak when CB powers
                // off mid-session.
                if self.recorder != nil || self.peripheral != nil {
                    self.stopSession()
                }
                switch newCBState {
                case .poweredOff: self.state.status = .bluetoothOff
                case .unauthorized: self.state.status = .bluetoothUnauthorized
                case .unsupported: self.state.status = .bluetoothUnsupported
                default: break
                }
            case .resetting, .unknown:
                // Transient; don't change visible status. A later
                // centralManagerDidUpdateState call will resolve it.
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Polar device"
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.state.discoveredPeripherals.contains(where: { $0.id == id }) {
                self.state.discoveredPeripherals.append(.init(id: id, name: name))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Drop callbacks for a peripheral the user has already torn down
            // (Stop / Unpair) or that doesn't match the current connecting
            // target. Also bail if we're no longer in .connecting (a stale
            // didConnect could otherwise restart discovery for a session we
            // already finalized).
            guard let active = self.peripheral,
                  active.identifier == peripheralID,
                  self.state.status == .connecting else {
                return
            }
            active.discoverServices([Self.heartRateServiceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let peripheralID = peripheral.identifier
        let message = error?.localizedDescription ?? "Connection failed"
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Ignore late didFailToConnect callbacks for a peripheral the
            // user has already moved past — otherwise the UI flips to .error
            // for a stale connection attempt.
            guard let active = self.peripheral, active.identifier == peripheralID else { return }
            self.failConnection(message: message)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Auto-stop if we were recording — Phase 2 is intentionally simple;
            // Phase 2b adds the 10-min grace-period reconnect logic.
            if self.state.status == .recording || self.state.status == .connecting {
                self.stopSession()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PolarHRMService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let peripheralID = peripheral.identifier
        let errMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Drop stale callbacks before doing anything with the peripheral —
            // a disconnect/stop mid-discovery would otherwise let us continue
            // service discovery (or surface .error) for a peripheral the
            // service has already torn down.
            guard let active = self.peripheral, active.identifier == peripheralID else { return }
            if let errMessage {
                self.failConnection(message: "Service discovery failed: \(errMessage)")
                return
            }
            guard let svc = active.services?.first(where: { $0.uuid == Self.heartRateServiceUUID }) else {
                self.failConnection(message: "Heart Rate Service not advertised")
                return
            }
            active.discoverCharacteristics([Self.hrMeasurementCharacteristicUUID], for: svc)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let peripheralID = peripheral.identifier
        let serviceUUID = service.uuid
        let errMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let active = self.peripheral, active.identifier == peripheralID else { return }
            if let errMessage {
                self.failConnection(message: "Characteristic discovery failed: \(errMessage)")
                return
            }
            // Look up the characteristic from the active peripheral so we
            // don't capture a non-Sendable CBService across the actor hop.
            guard let activeService = active.services?.first(where: { $0.uuid == serviceUUID }),
                  let ch = activeService.characteristics?.first(where: {
                      $0.uuid == Self.hrMeasurementCharacteristicUUID
                  }) else {
                self.failConnection(message: "HR Measurement characteristic not found")
                return
            }
            // Subscribe to HR Measurement notifications. beginRecording is
            // deferred to didUpdateNotificationStateFor so we don't create a
            // SensorSession that never receives data if enabling notify
            // fails.
            active.setNotifyValue(true, for: ch)
            self.hrmCharacteristic = ch
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let peripheralID = peripheral.identifier
        let isNotifying = characteristic.isNotifying
        let charUUID = characteristic.uuid
        let errMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Drop stale callbacks for a peripheral we're no longer tracking.
            guard let active = self.peripheral, active.identifier == peripheralID else {
                return
            }
            guard charUUID == Self.hrMeasurementCharacteristicUUID else { return }
            if let errMessage {
                self.failConnection(message: "Failed to subscribe to HR notifications: \(errMessage)")
                return
            }
            guard isNotifying else {
                self.failConnection(message: "HR notifications didn't activate")
                return
            }
            self.beginRecording()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Bail on CB-reported errors — value may be stale or invalid.
        if let error {
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.log.warning("HR Measurement update error: \(message, privacy: .public)")
            }
            return
        }
        guard let data = characteristic.value else { return }
        let frame: PolarHRMParser.Frame
        do {
            frame = try PolarHRMParser.parse(data)
        } catch {
            return
        }
        let arrivalTime = Date()
        let peripheralID = peripheral.identifier
        // Back-project here, off the main actor, so the timestamps are
        // computed at packet-arrival time even if the main-actor hop is
        // delayed under load.
        let projected = RRTimestampBackprojection.project(
            arrival: arrivalTime,
            rrIntervalsMs: frame.rrIntervalsMs
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Drop stale callbacks for a peripheral we've already torn down
            // (e.g. user tapped Stop between the BLE callback and the hop
            // back to the main actor).
            guard let active = self.peripheral, active.identifier == peripheralID else {
                return
            }
            self.state.currentHR = frame.hrBpm
            guard let buffer = self.buffer else { return }
            for sample in projected {
                await buffer.append(timestamp: sample.timestamp, rrMs: sample.rrMs)
                if let archive = self.archive {
                    do {
                        try archive.append(.init(timestamp: sample.timestamp, rrMs: sample.rrMs))
                    } catch {
                        // Rate-limited via the unified logger; the same
                        // archive instance won't keep throwing for one
                        // session, so the first hit is what we want to see.
                        self.log.warning("RR archive append failed (rrMs=\(sample.rrMs, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }
}
