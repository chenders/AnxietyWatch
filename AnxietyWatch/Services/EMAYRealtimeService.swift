import CoreBluetooth
import Foundation
import Observation
import os

/// One real-time sample from the EMAY SleepO2 oximeter.
struct EMAYReading: Equatable, Sendable {
    /// SpO₂ as an **integer percentage on a 0–100 scale** (NOT a 0–1 fraction),
    /// or nil when the sensor reports its no-reading sentinel. When persisting
    /// to HealthKit / `QuantityHealthSample` (which use `HKUnit.percent()`,
    /// 0–1), divide by 100 at that boundary — the SpO₂ percent-vs-fraction
    /// pitfall (`EMAYImporter` stores the fraction).
    let spo2: Int?
    /// Pulse rate in bpm, or nil when the sensor reports its no-reading
    /// sentinel. Genuine extremes (profound bradycardia, tachycardia) are
    /// preserved — only the sentinel is dropped.
    let pulseRate: Int?
    let timestamp: Date

    var hasSpO2: Bool { spo2 != nil }
    var hasPulse: Bool { pulseRate != nil }
    /// True when *any* field is present. NOTE: a pulse-only reading (SpO₂
    /// dropped as no-finger) is `isMeasuring == true` with no SpO₂ — an
    /// SpO₂-driven consumer (e.g. the CNS-depression alarm) must gate on
    /// `hasSpO2`, never on `isMeasuring`.
    var isMeasuring: Bool { spo2 != nil || pulseRate != nil }
}

/// Pure, hardware-independent EMAY SleepO2 "S50" BLE protocol
/// (reverse-engineered + live-verified 2026-07-09; see the
/// `reference-emay-realtime-ble` memory note). Kept free of CoreBluetooth so
/// the framing/checksum/parse logic can be unit-tested without a device.
///
/// Transport: GATT service `FF12`, write `FF01`, notify `FF02`. Every command
/// is `payload + checksum`, checksum = `sum(payload) & 0x7F` (the 0x7F mask —
/// not 0xFF — is the crucial detail). Start sequence:
/// `hello → deviceState → startRealtime → getBattery`, then `heartbeat` ~every
/// 1.5 s to sustain the stream. Data arrives on `FF02` as
/// `EB 01 05 [PR] [SpO2] 7F 00 [cks]`.
nonisolated enum EMAYProtocol {
    /// Trailing checksum: sum of the payload bytes masked with 0x7F.
    static func checksum(_ payload: [UInt8]) -> UInt8 {
        UInt8(payload.reduce(0) { $0 + Int($1) } & 0x7F)
    }

    /// Frame a command payload by appending its checksum.
    static func command(_ payload: [UInt8]) -> [UInt8] {
        payload + [checksum(payload)]
    }

    static var hello: [UInt8] { command([0x89]) }             // 89 09
    static var deviceState: [UInt8] { command([0x8E, 0x05]) } // 8E 05 13
    static var startRealtime: [UInt8] { command([0x9B, 0x01]) } // 9B 01 1C  (type 1 = start)
    static var getBattery: [UInt8] { command([0x86]) }        // 86 06
    static var heartbeat: [UInt8] { command([0x9A]) }         // 9A 1A
    static var stopRealtime: [UInt8] { command([0x9B, 0x7F]) } // 9B 7F 1A (type 0x7F = stop)

    /// The ordered writes that begin a real-time session.
    static var startSequence: [[UInt8]] { [hello, deviceState, startRealtime, getBattery] }

    /// Full real-time data frame: `EB 01 05 [PR] [SpO2] 7F 00 [cks]` (8 bytes).
    static let dataFrameLength = 8

    /// Device "no reading" sentinels for a value byte (no finger / not
    /// measuring). Everything else — including clinically severe lows — is
    /// trusted and passed through, matching `EMAYImporter`'s convention. A
    /// plausibility *range* is deliberately NOT used: narrowing it would
    /// silently drop a real dangerous desaturation/bradycardia as if it were
    /// "no data" — a false-reassurance hazard for the alarm path.
    static func isSentinel(_ v: Int) -> Bool { v == 0x00 || v == 0xFF }

    /// Parse an `FF02` notification into a reading, or nil for anything that
    /// isn't an authentic real-time data frame. Validates the full frame —
    /// length, the fixed header/trailer bytes, AND the trailing checksum
    /// (`sum(first 7 bytes) & 0x7F`) — so a corrupted notification that merely
    /// starts with `EB 01` cannot be accepted as a genuine reading.
    static func parseReading(_ data: Data, at timestamp: Date) -> EMAYReading? {
        let b = [UInt8](data)
        // Exact length: the data frame is always 8 bytes. Accepting >8 would
        // silently ignore trailing bytes and let a concatenated/corrupted
        // notification through.
        guard b.count == dataFrameLength,
              b[0] == 0xEB, b[1] == 0x01, b[2] == 0x05,
              b[5] == 0x7F, b[6] == 0x00,
              b[7] == checksum(Array(b[0..<7])) else { return nil }
        let pr = Int(b[3])
        let spo2 = Int(b[4])
        return EMAYReading(
            // SpO₂ is a percentage, so >100 is non-physiological → invalid.
            spo2: (!isSentinel(spo2) && spo2 <= 100) ? spo2 : nil,
            pulseRate: isSentinel(pr) ? nil : pr,
            timestamp: timestamp
        )
    }
}

/// Live SpO₂ / pulse from the EMAY SleepO2 over BLE. Owns a `CBCentralManager`
/// so it outlives any view; `@Observable` for SwiftUI environment injection.
/// The CoreBluetooth delegate callbacks are `nonisolated` (ObjC selectors) and
/// hop back onto the main actor, matching `PolarHRMService`.
@MainActor
@Observable
final class EMAYRealtimeService: NSObject {
    enum Status: Equatable {
        case idle
        case scanning
        case connecting
        case streaming
        case failed(String)
        case bluetoothOff
        case bluetoothUnauthorized
        case bluetoothUnsupported
    }

    nonisolated static let serviceUUID = CBUUID(string: "FF12")
    nonisolated static let writeUUID = CBUUID(string: "FF01")
    nonisolated static let notifyUUID = CBUUID(string: "FF02")
    /// The EMAY SleepO2 advertises its local name with this prefix.
    nonisolated static let namePrefix = "SleepO2"
    /// Provenance label for live-BLE EMAY samples when they are eventually
    /// persisted — MUST differ from `EMAYImporter`'s CSV bundle
    /// (`com.emay.SleepO2`) so `DeviceProvenance`/arbitration can tell a live
    /// reading apart from a CSV-imported one. (Not persisted yet.)
    nonisolated static let sourceLabel = "emay_ble_live"
    /// If no valid frame arrives within this window while nominally streaming,
    /// the stream has stalled (link up but data stopped) — ~2.5× the 1.5 s
    /// heartbeat interval.
    nonisolated static let staleTimeout: TimeInterval = 4.0

    private(set) var status: Status = .idle
    private(set) var latestReading: EMAYReading?
    /// When the last valid frame (measuring OR no-finger) arrived — used to
    /// detect a stalled stream. A consumer can also read
    /// `latestReading?.timestamp` for freshness.
    private(set) var lastReadingAt: Date?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeChar: CBCharacteristic?
    @ObservationIgnored private var notifyChar: CBCharacteristic?
    /// Start-sequence commands not yet sent, drained one per `didWriteValueFor`
    /// so each write-with-response completes before the next (CoreBluetooth
    /// serialization requirement).
    @ObservationIgnored private var pendingWrites: [[UInt8]] = []
    /// The start-sequence command whose write-completion callback we're
    /// awaiting (so `didWriteValueFor` knows WHICH command just completed —
    /// e.g. to flip to `.streaming` only once `startRealtime` is acknowledged,
    /// not merely issued). Heartbeats bypass this (sent directly).
    @ObservationIgnored private var inFlightWrite: [UInt8]?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var wantScan = false

    override init() {
        super.init()
        // `queue: nil` → CoreBluetooth dispatches delegate callbacks on the
        // MAIN queue. CB requires every `central.*` call to be serialized on
        // the queue the manager was constructed with; since we drive it from
        // @MainActor methods (start/stop/beginScan/fail), the manager MUST be
        // bound to the main queue too — a dedicated background queue here is a
        // runtime race (the same lesson PolarHRMService documents).
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public control

    /// Begin scanning for the oximeter and stream once connected. Safe to call
    /// before Bluetooth is powered on; the scan starts when it becomes ready.
    /// Reflects the real Bluetooth state rather than always reporting
    /// `.scanning`, so the UI can show an actionable message when BT is
    /// off/unauthorized/unsupported.
    func start() {
        wantScan = true
        switch central.state {
        case .poweredOn: beginScan()
        case .poweredOff: status = .bluetoothOff
        case .unauthorized: status = .bluetoothUnauthorized
        case .unsupported: status = .bluetoothUnsupported
        case .resetting, .unknown: status = .scanning  // will scan when ready
        @unknown default: status = .scanning
        }
    }

    /// Issue a best-effort stop command (not guaranteed to flush before the
    /// disconnect below — the device stops streaming on disconnect regardless)
    /// and tear down cleanly.
    func stop() {
        wantScan = false
        if let peripheral, let writeChar {
            peripheral.writeValue(Data(EMAYProtocol.stopRealtime), for: writeChar, type: .withResponse)
        }
        if central.state == .poweredOn {
            central.stopScan()
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
        // Clear per-connection state SYNCHRONOUSLY so a notification still in
        // flight can't revive `.streaming` (see the `.idle` guard in
        // didUpdateValueFor) and a fast stop→start isn't blocked by a stale
        // peripheral reference.
        resetConnectionState()
        status = .idle
    }

    private func beginScan() {
        status = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID])
        Log.ble.info("EMAY: scanning for service FF12")
    }

    private func write(_ bytes: [UInt8]) {
        guard let peripheral, let writeChar else { return }
        peripheral.writeValue(Data(bytes), for: writeChar, type: .withResponse)
    }

    /// Send the next queued start-sequence command (if any), recording it as
    /// in-flight so its write-completion can be attributed in didWriteValueFor.
    private func sendNextWrite() {
        guard !pendingWrites.isEmpty else { inFlightWrite = nil; return }
        let next = pendingWrites.removeFirst()
        inFlightWrite = next
        write(next)
    }

    /// Synchronously drop all per-connection references (heartbeat, write
    /// queue, peripheral/characteristics, last reading). Idempotent.
    private func resetConnectionState() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pendingWrites = []
        inFlightWrite = nil
        peripheral?.delegate = nil
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        latestReading = nil
        lastReadingAt = nil
    }

    /// Single funnel for connection/discovery failures: surface an actionable
    /// message and tear down. Disconnecting lets `didDisconnectPeripheral`
    /// resume scanning if the caller still wants monitoring (transient-hiccup
    /// retry); when there's nothing to disconnect, reset directly.
    private func fail(_ message: String) {
        Log.ble.error("EMAY: \(message, privacy: .public)")
        status = .failed(message)
        if central.state == .poweredOn, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            resetConnectionState()
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, self.status == .streaming else { return }
                self.write(EMAYProtocol.heartbeat)
                // Staleness watchdog: the link can stay nominally connected
                // while the stream silently stalls (firmware hang, RF loss).
                // Drop the frozen reading so a consumer never treats a stale
                // value as current — absence of data, not a lie.
                if let last = self.lastReadingAt,
                   Date().timeIntervalSince(last) > Self.staleTimeout {
                    if self.latestReading != nil {
                        self.latestReading = nil
                        Log.ble.notice("EMAY: stream stalled — dropping stale reading")
                    }
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension EMAYRealtimeService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch central.state {
            case .poweredOn:
                if self.wantScan { self.beginScan() }
            case .poweredOff:
                self.resetConnectionState()
                self.status = .bluetoothOff
            case .unauthorized:
                self.resetConnectionState()
                self.status = .bluetoothUnauthorized
            case .unsupported:
                self.resetConnectionState()
                self.status = .bluetoothUnsupported
            case .resetting, .unknown:
                break  // transient — wait for the next state callback
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
        Task { @MainActor [weak self] in
            guard let self, self.peripheral == nil else { return }
            // Primary filter is the FF12 service UUID (scan filter); also match
            // the advertised name prefix as defense-in-depth against another
            // product advertising a colliding vendor-specific UUID. Accept when
            // the name is absent (can't filter) rather than risk rejecting the
            // real device.
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
            guard name.isEmpty || name.hasPrefix(Self.namePrefix) else { return }
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            self.status = .connecting
            central.connect(peripheral)
            // Log the name as private: BLE local names can contain
            // user-supplied personal text (e.g. a person's name).
            Log.ble.info("EMAY: connecting to \(name.isEmpty ? "device" : name, privacy: .private)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self, peripheral.identifier == self.peripheral?.identifier else { return }
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let msg = "connect failed: \(error?.localizedDescription ?? "unknown")"
            Log.ble.error("EMAY: \(msg, privacy: .public)")
            self.resetConnectionState()
            if self.wantScan {
                self.beginScan()   // retry
            } else {
                self.status = .failed(msg)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wasFailure: Bool = { if case .failed = self.status { return true }; return false }()
            self.resetConnectionState()
            if self.wantScan {
                self.beginScan()   // auto-reconnect
            } else if !wasFailure {
                // Preserve a failure message set by fail(); otherwise idle.
                self.status = .idle
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension EMAYRealtimeService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, peripheral.identifier == self.peripheral?.identifier else { return }
            if let error { self.fail("service discovery failed: \(error.localizedDescription)"); return }
            guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                self.fail("EMAY service FF12 not found"); return
            }
            peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: svc)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self, peripheral.identifier == self.peripheral?.identifier else { return }
            if let error { self.fail("characteristic discovery failed: \(error.localizedDescription)"); return }
            for ch in service.characteristics ?? [] {
                if ch.uuid == Self.writeUUID { self.writeChar = ch }
                if ch.uuid == Self.notifyUUID { self.notifyChar = ch }
            }
            guard let notifyChar = self.notifyChar, self.writeChar != nil else {
                self.fail("EMAY FF01/FF02 characteristics not found"); return
            }
            peripheral.setNotifyValue(true, for: notifyChar)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self, characteristic.uuid == Self.notifyUUID else { return }
            if let error { self.fail("enabling notifications failed: \(error.localizedDescription)"); return }
            guard characteristic.isNotifying else { self.fail("notifications not enabled on FF02"); return }
            // Notifications are live — kick off the start sequence; commands
            // drain one-per-completion via sendNextWrite/didWriteValueFor.
            self.pendingWrites = EMAYProtocol.startSequence
            self.sendNextWrite()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let completed = self.inFlightWrite   // the command this callback is for
            self.inFlightWrite = nil
            if let error {
                Log.ble.error("EMAY: write failed: \(error.localizedDescription, privacy: .public)")
                // A failed write during the start handshake means the device
                // hasn't accepted the sequence — abort rather than proceeding to
                // a false `.streaming`. (A failed heartbeat while already
                // streaming is transient; the staleness watchdog handles a real
                // stall.)
                if self.status != .streaming {
                    self.fail("start-sequence write failed: \(error.localizedDescription)")
                }
                return
            }
            // The startRealtime write has now COMPLETED (with-response) — only
            // now is it safe to declare streaming and begin heartbeats.
            if completed == EMAYProtocol.startRealtime, self.status != .streaming {
                self.status = .streaming
                self.startHeartbeat()
            }
            self.sendNextWrite()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.notifyUUID, let value = characteristic.value else { return }
        if let error {
            Log.ble.error("EMAY: notify read error: \(error.localizedDescription, privacy: .public)")
            return  // don't parse a value CoreBluetooth flagged as errored
        }
        Task { @MainActor [weak self] in
            // Ignore notifications that arrive after stop() (status .idle) so a
            // late in-flight frame can't revive `.streaming`.
            guard let self, self.status != .idle else { return }
            if let reading = EMAYProtocol.parseReading(value, at: Date()) {
                self.latestReading = reading
                self.lastReadingAt = reading.timestamp  // any valid frame = stream alive
                if self.status != .streaming { self.status = .streaming }
            }
        }
    }
}
