import CoreBluetooth
import Foundation
import Observation
import os
import SwiftData

/// One real-time sample from the EMAY SleepO2 oximeter.
/// `nonisolated`: a pure value type whose computed accessors must be
/// callable from nonisolated contexts (`EMAYLiveDownsampler`).
nonisolated struct EMAYReading: Equatable, Sendable {
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
            // Pulse rate: validate the byte is not sentinel.
            // A plausibility *range* is deliberately NOT used here: narrowing it would
            // silently drop a real dangerous bradycardia as if it were "no data".
            pulseRate: (!isSentinel(pr)) ? pr : nil,
            timestamp: timestamp
        )
    }
}

/// Pure per-minute downsampler for live EMAY readings. The BLE stream arrives
/// at ~1 Hz; persisting every frame would add ~28k SwiftData rows per
/// overnight session for data whose only persistent consumer (the Trends
/// "Oximeter (live sessions)" card) needs minute resolution. Buffers valid
/// readings and emits one mean-per-minute value per metric, mirroring
/// `EMAYImporter`'s persisted shapes (SpO₂ as a 0–1 fraction, pulse in bpm).
///
/// Kept free of SwiftData/CoreBluetooth so the bucketing/mean/flush logic is
/// unit-testable without a device (see `EMAYLiveDownsamplerTests`).
nonisolated struct EMAYLiveDownsampler {
    /// One finalized minute for one metric, ready to persist as a
    /// `QuantityHealthSample`.
    struct MinuteSample: Equatable, Sendable {
        /// Start of the minute bucket the mean covers.
        let minuteStart: Date
        /// Raw `HKQuantityTypeIdentifier` value — always one of
        /// `EMAYImporter.spo2MetricType` / `EMAYImporter.heartRateMetricType`
        /// (typed constants, per the source-label-drift rule).
        let metricType: String
        /// SpO₂: mean as a **0–1 fraction** (`EMAYReading.spo2` integer
        /// percents ÷ 100 — the repo's documented SpO₂ percent-vs-fraction
        /// pitfall; matches `EMAYImporter`). Pulse: mean bpm.
        let value: Double
        let unitString: String
    }

    /// Minimum valid samples a metric must accumulate in a minute before its
    /// mean is emitted. A single probe-contact artifact out of ~60 possible
    /// 1 Hz samples must not masquerade as a full minute's mean — mirrors the
    /// intent of `SnapshotAggregator.minSamplesForOvernightStats` at minute
    /// scale. Applied per metric: a minute rich in pulse but with only a
    /// couple of SpO₂ readings emits pulse alone.
    ///
    /// Known representativeness limit (decision record, continuous mode): a
    /// minute that clears this floor is persisted as an ordinary mean whether
    /// it covers the full ~60 samples or only a tail (e.g. the ≥10 samples
    /// captured after a mid-minute jetsam relaunch reconnects). Nothing
    /// downstream can tell the two apart — `MinuteSample` carries no coverage
    /// count. Continuous mode makes tail-only minutes a nightly occurrence
    /// rather than a rarity; if the CNS Klaxon ever needs coverage-weighted
    /// confidence, persist the per-minute sample count alongside the mean
    /// rather than lowering/raising this floor.
    static let minimumSamplesPerMinute = 10

    private var bucketStart: Date?
    private var spo2PercentSum = 0.0
    private var spo2Count = 0
    private var pulseSum = 0.0
    private var pulseCount = 0

    /// Floor to the containing minute. Epoch arithmetic is safe at minute
    /// granularity (unlike the day-granularity pitfall in CLAUDE.md): every
    /// real-world UTC offset is a whole number of minutes, so epoch-minute
    /// boundaries coincide with wall-clock minute boundaries in any
    /// timezone/DST state.
    static func minuteStart(for date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    /// Feed one live reading; returns any minute completed by its arrival.
    /// Only non-nil fields contribute — the device's "no reading" sentinels
    /// are already nil on `EMAYReading` and are never coerced to a value. A
    /// reading in a *different* minute than the open bucket (later, or
    /// earlier after a device/phone clock adjustment) finalizes the open
    /// bucket first so a mean never mixes buckets.
    mutating func add(_ reading: EMAYReading) -> [MinuteSample] {
        guard reading.isMeasuring else { return [] }
        let bucket = Self.minuteStart(for: reading.timestamp)
        var completed: [MinuteSample] = []
        if let open = bucketStart, open != bucket {
            completed = finalizeOpenBucket()
        }
        bucketStart = bucket
        if let spo2 = reading.spo2 {
            spo2PercentSum += Double(spo2)
            spo2Count += 1
        }
        if let pulse = reading.pulseRate {
            pulseSum += Double(pulse)
            pulseCount += 1
        }
        return completed
    }

    /// Finalize the open (partial) minute — called on TERMINAL teardown
    /// (stop, failure, Bluetooth loss, stale-stream timeout) so the tail of
    /// a session isn't lost. Transient auto-reconnect disconnects
    /// deliberately do NOT flush — see
    /// `EMAYRealtimeService.resetConnectionState(flushPartialBucket:)`.
    /// Returns nothing when no reading is buffered, so repeated teardown
    /// paths can call it safely.
    mutating func flush() -> [MinuteSample] {
        finalizeOpenBucket()
    }

    /// Emission order is deterministic (SpO₂ then pulse) — dictionary-order
    /// nondeterminism is a documented pitfall for sequential output. Each
    /// metric is emitted only when it met `minimumSamplesPerMinute`.
    private mutating func finalizeOpenBucket() -> [MinuteSample] {
        guard let bucket = bucketStart else { return [] }
        var out: [MinuteSample] = []
        if spo2Count >= Self.minimumSamplesPerMinute {
            out.append(MinuteSample(
                minuteStart: bucket,
                metricType: EMAYImporter.spo2MetricType,
                value: (spo2PercentSum / Double(spo2Count)) / 100.0,
                unitString: "%"
            ))
        }
        if pulseCount >= Self.minimumSamplesPerMinute {
            out.append(MinuteSample(
                minuteStart: bucket,
                metricType: EMAYImporter.heartRateMetricType,
                value: pulseSum / Double(pulseCount),
                unitString: "count/min"
            ))
        }
        bucketStart = nil
        spo2PercentSum = 0
        spo2Count = 0
        pulseSum = 0
        pulseCount = 0
        return out
    }
}

/// Live SpO₂ / pulse from the EMAY SleepO2 over BLE. Owns a `CBCentralManager`
/// so it outlives any view; `@Observable` for SwiftUI environment injection.
/// The CoreBluetooth delegate callbacks are `nonisolated` (ObjC selectors) and
/// hop back onto the main actor, matching `PolarHRMService`.
///
/// Persists per-minute means of the stream as `QuantityHealthSample` rows
/// under `liveSourceBundleID` so live sessions reach the Trends tab. The
/// service is created once at app scope (`AnxietyWatchApp`) and injected via
/// `.environment` — the device supports a single central connection, so a
/// second view-local owner would race the first.
@MainActor
@Observable
final class EMAYRealtimeService: NSObject {
    enum Status: Equatable {
        case idle
        case scanning
        /// A pending `connect()` to a remembered peripheral is armed and will
        /// complete whenever the oximeter comes in range — distinct from
        /// `.scanning` (no known device, actively discovering) and
        /// `.connecting` (device found, link/handshake in progress) so the
        /// status line can honestly say "waiting" instead of implying an
        /// active search or an imminent connection.
        case waitingForDevice
        case connecting
        case streaming
        case failed(String)
        case bluetoothOff
        case bluetoothUnauthorized
        case bluetoothUnsupported

        /// True for the states where monitoring is underway and a Stop (not
        /// Start) action applies. Shared by `EMAYLiveView.isRunning` and the
        /// re-entrancy guard in `start()` so the two can't drift.
        var isActiveSession: Bool {
            switch self {
            case .scanning, .waitingForDevice, .connecting, .streaming: return true
            case .idle, .failed, .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported: return false
            }
        }
    }

    nonisolated static let serviceUUID = CBUUID(string: "FF12")
    nonisolated static let writeUUID = CBUUID(string: "FF01")
    nonisolated static let notifyUUID = CBUUID(string: "FF02")
    /// The EMAY SleepO2 advertises its local name with this prefix.
    nonisolated static let namePrefix = "SleepO2"
    /// Provenance for the per-minute rows this service persists. Deliberately
    /// distinct from BOTH bundle IDs the aggregation pipeline treats as
    /// preferred overnight oximetry (`com.emay.SleepO2` CSV imports,
    /// `com.emay.oximeter` HealthKit writes by the EMAY iOS app): the same
    /// night can later be covered by a CSV import of the identical session,
    /// and if live rows joined the preferred partition the night would
    /// double-count. The overnight SpO₂ aggregation explicitly excludes this
    /// bundle — see `SnapshotAggregator.excludingLiveOximeterRows(_:)`.
    nonisolated static let liveSourceBundleID = "com.emay.SleepO2.live"
    nonisolated static let liveSourceName = "EMAY SleepO2 (live)"
    /// Device model stamped on persisted rows — the hardware name the device
    /// itself advertises (same string as `namePrefix`, kept separate because
    /// the two would drift independently if EMAY ever changes advertising).
    nonisolated static let liveDeviceModel = "SleepO2"
    /// If no valid frame arrives within this window while nominally streaming,
    /// the stream has stalled (link up but data stopped) — ~2.5× the 1.5 s
    /// heartbeat interval.
    nonisolated static let staleTimeout: TimeInterval = 4.0
    /// Stable identifier so iOS can relaunch the app and call
    /// `centralManager(_:willRestoreState:)` for in-flight/pending
    /// peripherals after a background termination (jetsam). MUST stay
    /// constant across launches or restoration breaks (same rule as
    /// `PolarHRMService.restoreIdentifier`).
    nonisolated static let restoreIdentifier = "com.anxietywatch.emay-sleepo2"
    /// UserDefaults key for the user-facing "continuous streaming" toggle.
    /// When true, monitoring auto-starts at app launch and survives leaving
    /// `EMAYLiveView`.
    nonisolated static let continuousModeKey = "emay.continuousStreaming"
    /// UserDefaults key remembering the oximeter's `CBPeripheral.identifier`
    /// once discovered. The identifier is a local, per-device random UUID
    /// assigned by iOS (not a hardware address), so persisting it is not
    /// identifying. Lets reconnects use a pending `connect()` instead of a
    /// background-throttled scan.
    nonisolated static let knownPeripheralUUIDKey = "emay.peripheralUUID"

    private(set) var status: Status = .idle
    /// Mirrors the `continuousModeKey` default as a stored property so
    /// `@Observable` change tracking drives the Settings toggle; kept in
    /// sync exclusively via `setContinuousMode(_:)`.
    private(set) var continuousModeEnabled: Bool
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
    /// Persists per-minute live samples. Created from the shared container at
    /// app init and owned for the service's (= app's) lifetime; everything
    /// that touches it runs on the main actor.
    @ObservationIgnored private let modelContext: ModelContext
    /// Buffers the ~1 Hz stream into per-minute means; flushed on TERMINAL
    /// teardown via `resetConnectionState(flushPartialBucket: true)` and on
    /// stale-stream timeout — transient auto-reconnect disconnects keep the
    /// open bucket alive (see `resetConnectionState`).
    @ObservationIgnored private var downsampler = EMAYLiveDownsampler()

#if DEBUG
    /// Latched by `applyDemoStreamingState()`. While set, CoreBluetooth state
    /// callbacks are ignored so the synthetic screenshot readout survives the
    /// simulator reporting Bluetooth as `.unsupported` (which would otherwise
    /// reset `status` to `.bluetoothUnsupported`). DEBUG-only; only ever set
    /// via the `-seedDemoData` launch path.
    @ObservationIgnored private var isDemoStreaming = false
#endif

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.continuousModeEnabled = Self.isContinuousModeEnabled(defaults: .standard)
        super.init()
        // `queue: nil` → CoreBluetooth dispatches delegate callbacks on the
        // MAIN queue. CB requires every `central.*` call to be serialized on
        // the queue the manager was constructed with; since we drive it from
        // @MainActor methods (start/stop/beginScan/fail), the manager MUST be
        // bound to the main queue too — a dedicated background queue here is a
        // runtime race (the same lesson PolarHRMService documents).
        //
        // The restore identifier opts into CoreBluetooth state restoration:
        // if iOS terminates the app in the background while a connection or
        // pending connect is outstanding, the system keeps acting on our
        // behalf and relaunches the app (calling willRestoreState) when the
        // peripheral produces an event — the mechanism that makes overnight
        // continuous streaming survive a jetsam.
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    // MARK: - Pure decision helpers (unit-tested without CoreBluetooth hardware)

    /// Whether the user has opted into continuous streaming. `defaults` is
    /// injected so tests can use an isolated suite.
    nonisolated static func isContinuousModeEnabled(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: continuousModeKey)
    }

    /// The remembered oximeter identifier, or nil when none has been
    /// discovered yet (or the stored value is corrupt).
    nonisolated static func knownPeripheralUUID(defaults: UserDefaults) -> UUID? {
        defaults.string(forKey: knownPeripheralUUIDKey).flatMap(UUID.init(uuidString:))
    }

    /// Decision table for `start()`: the status to surface for a Bluetooth
    /// state that can't begin monitoring yet, or nil when the central is
    /// powered on and monitoring should actually begin. `.resetting` /
    /// `.unknown` report `.scanning` — monitoring auto-begins when the next
    /// state callback lands on `.poweredOn`.
    nonisolated static func startupStatus(for state: CBManagerState) -> Status? {
        switch state {
        case .poweredOn: return nil
        case .poweredOff: return .bluetoothOff
        case .unauthorized: return .bluetoothUnauthorized
        case .unsupported: return .bluetoothUnsupported
        case .resetting, .unknown: return .scanning
        @unknown default: return .scanning
        }
    }

    /// How to (re)acquire the oximeter when monitoring begins or resumes.
    nonisolated enum ReconnectApproach: Equatable {
        /// Issue `central.connect(_:)` against the remembered peripheral.
        /// Pending connects never time out, survive app suspension, and —
        /// combined with state restoration — relaunch the app when the
        /// device comes back in range, unlike background scans, which iOS
        /// throttles heavily.
        case pendingConnect(UUID)
        /// No remembered device: fall back to a service-UUID scan.
        case scan
    }

    nonisolated static func reconnectApproach(knownPeripheralUUID: UUID?) -> ReconnectApproach {
        knownPeripheralUUID.map { .pendingConnect($0) } ?? .scan
    }

    /// Which restored peripheral (by array index) to adopt in
    /// `willRestoreState`: the remembered one when present; otherwise the
    /// first — anything iOS restored for this central is a peripheral WE
    /// connected to through the FF12-filtered pipeline, so a stale/missing
    /// remembered UUID shouldn't orphan a live connection. nil when the
    /// restore dictionary held no peripherals.
    ///
    /// Deliberately more permissive than `PolarHRMService.willRestoreState`'s
    /// strict-match-or-drop: the EMAY frame parser's length+checksum
    /// validation drops any wrong-device data outright, so adopting an
    /// unexpected restored peripheral risks a dead connection, not a bad
    /// reading.
    nonisolated static func restoredPeripheralIndex(identifiers: [UUID], knownUUID: UUID?) -> Int? {
        if let knownUUID, let idx = identifiers.firstIndex(of: knownUUID) { return idx }
        return identifiers.isEmpty ? nil : 0
    }

    // MARK: - Public control

    /// Begin monitoring for the oximeter and stream once connected. Safe to
    /// call before Bluetooth is powered on; monitoring starts when it becomes
    /// ready. Reflects the real Bluetooth state rather than always reporting
    /// `.scanning`, so the UI can show an actionable message when BT is
    /// off/unauthorized/unsupported.
    ///
    /// No-op while a session is already active: `EMAYLiveView` calls this on
    /// every appear, and in continuous mode a live background session must
    /// not be knocked back to `.scanning` (dropping the connection) just
    /// because the user opened the screen.
    func start() {
        guard !status.isActiveSession else { return }
        wantScan = true
        if let notReady = Self.startupStatus(for: central.state) {
            status = notReady  // monitoring begins on the .poweredOn callback
        } else {
            beginMonitoring()
        }
    }

    /// App-launch entry point: arms monitoring if (and only if) the user
    /// enabled the continuous-streaming toggle. Called unconditionally from
    /// `AnxietyWatchApp`'s startup task so the decision logic lives here, not
    /// in the app file. Idempotent with state restoration: if
    /// `willRestoreState` already re-armed monitoring, `start()`'s
    /// active-session guard makes this a no-op.
    func startIfContinuousModeEnabled() {
        guard continuousModeEnabled else { return }
        start()
    }

    /// Flip the continuous-streaming toggle. Turning it ON starts monitoring
    /// immediately; turning it OFF is an explicit user stop — it ends any
    /// active session AND disarms auto-start at future launches. (A manual
    /// Stop with the toggle left on stops only the current session; the
    /// toggle re-arms monitoring at the next launch.)
    func setContinuousMode(_ enabled: Bool) {
        continuousModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.continuousModeKey)
        if enabled {
            start()
        } else {
            stop()
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
        }
        // Cancel UNCONDITIONALLY on peripheral presence, not central.state:
        // during the state-restoration window `willRestoreState` can hand us
        // a live/pending system connection while `central.state` is still
        // `.unknown`. Gating the cancel on `.poweredOn` here would skip it,
        // then resetConnectionState() drops our only reference — the system
        // keeps (re)connecting behind an "Idle" UI. cancelPeripheralConnection
        // is safe to call pre-poweredOn (CoreBluetooth queues/ignores it as
        // appropriate); this matches PolarHRMService.tearDownResources().
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        // Clear per-connection state SYNCHRONOUSLY so a notification still in
        // flight can't revive `.streaming` (see the `.idle` guard in
        // didUpdateValueFor) and a fast stop→start isn't blocked by a stale
        // peripheral reference.
        resetConnectionState()
        status = .idle
    }

#if DEBUG
    /// Drive the service into a synthetic `.streaming` state for simulator
    /// screenshots and SwiftUI previews, where no CoreBluetooth device exists.
    /// The values are obviously-fictional demo readings — NEVER real device
    /// data — and this method is compiled out of release builds entirely.
    /// Reached only via the `-seedDemoData` launch argument (`SeedDemoMode`);
    /// it deliberately bypasses the BLE handshake and persists nothing.
    func applyDemoStreamingState(spo2: Int = 97, pulseRate: Int = 62) {
        isDemoStreaming = true
        // Set the stored property directly rather than via setContinuousMode(_:)
        // — this deliberately does NOT persist to UserDefaults, so a demo/
        // screenshot run never leaves the real continuous-streaming toggle
        // flipped on for a later non-demo launch.
        continuousModeEnabled = true
        status = .streaming
        latestReading = EMAYReading(spo2: spo2, pulseRate: pulseRate, timestamp: Date())
    }
#endif

    /// Acquire (or re-acquire) the oximeter. Must only run with the central
    /// `.poweredOn` (`retrievePeripherals`/`connect` are invalid earlier).
    /// Preference order:
    /// 1. A peripheral we already hold (state restoration re-adopted it).
    /// 2. A pending `connect()` to the remembered identifier — reliable in
    ///    the background, where scans are heavily throttled.
    /// 3. A service-UUID scan (first-ever connection, or iOS no longer
    ///    recognizes the remembered identifier).
    private func beginMonitoring() {
        if let held = peripheral {
            adoptAndConnect(held)
            return
        }
        if case .pendingConnect(let uuid) =
            Self.reconnectApproach(knownPeripheralUUID: Self.knownPeripheralUUID(defaults: .standard)),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            adoptAndConnect(known)
            return
        }
        beginScan()
    }

    /// Take ownership of `p` and drive it toward streaming based on its
    /// current CB state. `.connected` (a restoration handoff) skips straight
    /// to service discovery; anything else arms a pending connect. A
    /// peripheral already `.connecting` (restored mid-attempt) just waits —
    /// its `didConnect` will fire without a second `connect()` call.
    private func adoptAndConnect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        switch p.state {
        case .connected:
            status = .connecting  // link is up; protocol handshake still pending
            p.discoverServices([Self.serviceUUID])
        case .connecting:
            // The system is actively establishing the link (restored
            // mid-attempt) — report .connecting per the Status contract;
            // .waitingForDevice is only for an armed-but-idle pending connect.
            status = .connecting
        default:
            status = .waitingForDevice
            central.connect(p)  // pending connect — persists until cancelled
            Log.ble.info("EMAY: pending connect armed for remembered oximeter")
        }
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
    ///
    /// Still the single funnel for every teardown path. TERMINAL paths —
    /// stop(), fail(), Bluetooth off/unauthorized/unsupported — keep the
    /// default `flushPartialBucket: true` so the partial final minute of a
    /// session is persisted here, before the buffered state below is
    /// cleared, and can't be lost. A TRANSIENT disconnect headed for
    /// auto-reconnect passes `false`: completed minutes were already
    /// persisted as they finalized, and keeping the open bucket alive lets
    /// a same-minute reconnect keep accumulating into ONE bucket, so the
    /// persisted mean stays weighted across every sample in that minute
    /// (two flushed partials would instead persist the first and drop the
    /// second under first-write-wins dedup).
    private func resetConnectionState(flushPartialBucket: Bool = true) {
        if flushPartialBucket {
            persist(downsampler.flush())
        }
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
    /// resume monitoring (pending connect or scan) if the caller still wants
    /// it (transient-hiccup retry); when there's nothing to disconnect, reset
    /// directly.
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
                        // A stalled stream is a terminal boundary for the
                        // open minute: persist the partial bucket now (the
                        // min-sample gate still applies) rather than holding
                        // the session tail against a link that may never
                        // resume. If the stream DOES resume within the same
                        // minute, persist-time dedup keeps first-write-wins.
                        self.persist(self.downsampler.flush())
                    }
                }
            }
        }
    }

    // MARK: - Persistence

    /// Insert finalized per-minute samples and save. Metric shapes mirror
    /// `EMAYImporter` exactly (SpO₂ as 0–1 fraction with "%", pulse in bpm
    /// with "count/min") so every `QuantityHealthSample` consumer sees one
    /// convention; only the provenance (`liveSourceBundleID`) differs.
    private func persist(_ minutes: [EMAYLiveDownsampler.MinuteSample]) {
        guard Self.insertLiveMinutes(minutes, into: modelContext) > 0 else { return }
        do {
            try modelContext.save()
        } catch {
            // Non-fatal: the live readout doesn't depend on persistence and
            // streaming continues. Log so a stuck store is diagnosable.
            Log.ble.error("EMAY: failed to save live minute samples: \(error, privacy: .public)")
        }
    }

    /// Insert `minutes` as live-bundle rows, skipping any whose
    /// `(timestamp, metricType)` already exists under `liveSourceBundleID`
    /// — first-write-wins, mirroring `EMAYImporter`'s prefetch/insertIfNew
    /// dedup. The residual duplicate path is a stop→restart within one
    /// wall-clock minute (two honest partial means for the same minute);
    /// the display-side same-minute merge in `OximeterLiveSeriesBuilder`
    /// remains as defense-in-depth. Each lookup is a single-property
    /// #Predicate on `timestamp` (avoiding the iOS 26 compound-#Predicate
    /// main-thread hang footgun that a three-clause `&&` would trigger),
    /// then filtered in-memory for the `(sourceBundleID, metricType)` match.
    /// Served by the model's dedicated standalone `timestamp` index (the
    /// compound `(sourceBundleID, timestamp)` index can NOT serve a
    /// timestamp-only lookup because timestamp is its trailing column).
    /// A failed existence check falls back to
    /// inserting (data preservation over dedup; the display merge absorbs a
    /// rare duplicate). Returns the number of rows inserted; caller saves.
    /// `static` so tests can exercise the dedup against an in-memory
    /// container without spinning up CoreBluetooth.
    static func insertLiveMinutes(
        _ minutes: [EMAYLiveDownsampler.MinuteSample],
        into modelContext: ModelContext
    ) -> Int {
        let bundleID = Self.liveSourceBundleID
        var inserted = 0
        for minute in minutes {
            let timestamp = minute.minuteStart
            let metricType = minute.metricType
            // Single-property #Predicate on Date (a primitive backed by
            // TimeInterval/Double) to avoid the iOS 26 compound-#Predicate
            // main-thread hang footgun. The compound form
            // (sourceBundleID && timestamp && metricType) captures two
            // String locals, which trips SwiftData's slow SQL generation
            // path. Filter the candidate rows in Swift instead — a live
            // session produces at most 60 rows/min, so the in-memory scan
            // is trivially cheap.
            let descriptor = FetchDescriptor<QuantityHealthSample>(
                predicate: #Predicate {
                    $0.timestamp == timestamp
                }
            )
            let candidates = (try? modelContext.fetch(descriptor)) ?? []
            let alreadyExists = candidates.contains {
                $0.sourceBundleID == bundleID && $0.metricType == metricType
            }
            guard !alreadyExists else { continue }
            modelContext.insert(QuantityHealthSample(
                timestamp: minute.minuteStart,
                metricType: minute.metricType,
                value: minute.value,
                unitString: minute.unitString,
                sourceBundleID: Self.liveSourceBundleID,
                sourceName: Self.liveSourceName,
                deviceModel: Self.liveDeviceModel
            ))
            inserted += 1
        }
        return inserted
    }
}

// MARK: - CBCentralManagerDelegate

extension EMAYRealtimeService: CBCentralManagerDelegate {
    /// Called when iOS relaunches (or resumes) the app for a BLE event after
    /// a background termination. Adopt the peripheral the system was
    /// tracking on our behalf — set the delegate and hold the reference —
    /// but defer every CB command (connect / discoverServices / cancel) to
    /// `centralManagerDidUpdateState`: the central is typically still
    /// `.unknown` here and CB forbids issuing commands before `.poweredOn`.
    ///
    /// The downsampler starts empty after a relaunch, so the minutes lost
    /// while the app was dead stay lost — a gap is a gap; continuity is
    /// never fabricated across it (CNS asymmetry invariant).
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor [weak self] in
            // If a peripheral is already held (re-entrant restoration, or a
            // start() raced ahead), keep it — adopting a second reference
            // would fork the delegate chain.
            guard let self, self.peripheral == nil, !restored.isEmpty else { return }
            let known = Self.knownPeripheralUUID(defaults: .standard)
            guard let idx = Self.restoredPeripheralIndex(
                identifiers: restored.map(\.identifier), knownUUID: known
            ) else { return }
            let p = restored[idx]
            p.delegate = self
            self.peripheral = p
            // Persist the adopted identifier: when the fallback branch of
            // restoredPeripheralIndex fired (remembered UUID stale/missing),
            // the next COLD launch would otherwise pending-connect against
            // the stale UUID and burn a scan round-trip re-learning this one.
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.knownPeripheralUUIDKey)
            // Re-arm ongoing monitoring only when the user opted into
            // continuous streaming. A view-scoped session that died with the
            // app shouldn't resurrect itself in the background; its adopted
            // peripheral is released in didUpdateState once the central is
            // powered on (the only point cancel is legal).
            self.wantScan = Self.isContinuousModeEnabled(defaults: .standard)
            self.status = self.wantScan ? .waitingForDevice : .idle
            Log.ble.info("EMAY: state restoration adopted peripheral (continuous=\(self.wantScan, privacy: .public))")
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
#if DEBUG
            // Demo screenshot mode owns `status`; don't let the simulator's
            // Bluetooth state clobber the synthetic streaming readout.
            if self.isDemoStreaming { return }
#endif
            switch central.state {
            case .poweredOn:
                if self.wantScan {
                    self.beginMonitoring()
                } else if let orphan = self.peripheral {
                    // State restoration adopted a peripheral but monitoring
                    // isn't wanted (continuous mode off) — release the
                    // system-held connection now that cancel is legal.
                    central.cancelPeripheralConnection(orphan)
                    self.resetConnectionState()
                }
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
            // Remember the identifier so future launches and mid-session
            // reconnects can use a pending connect() instead of a
            // background-throttled scan (see `beginMonitoring`).
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPeripheralUUIDKey)
            // Log the name as private: BLE local names can contain
            // user-supplied personal text (e.g. a person's name).
            Log.ble.info("EMAY: connecting to \(name.isEmpty ? "device" : name, privacy: .private)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self, peripheral.identifier == self.peripheral?.identifier else { return }
            // A pending-connect/restoration path arrives here from
            // `.waitingForDevice`; the device is now found, so advance to
            // `.connecting` (link/handshake in progress) per the Status
            // doc-comment contract. Scan-path connects set it earlier.
            if self.status == .waitingForDevice { self.status = .connecting }
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
                // Retry through beginMonitoring so a known peripheral gets
                // another pending connect (background-safe) instead of
                // falling back to a throttled scan.
                self.beginMonitoring()
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
            // A transient drop headed for auto-reconnect keeps the open
            // minute bucket alive (completed minutes were persisted as they
            // finalized) so a same-minute reconnect keeps accumulating into
            // one correctly-weighted mean; failure/stop paths are terminal
            // and flush the partial tail.
            let isTransientReconnect = self.wantScan && !wasFailure
            self.resetConnectionState(flushPartialBucket: !isTransientReconnect)
            if self.wantScan {
                // Auto-reconnect. The identifier persisted at discovery makes
                // this a pending connect() (background-safe) rather than a
                // rescan. Bucket semantics are unchanged: a same-minute
                // reconnect keeps accumulating into the ONE open bucket kept
                // alive above; a reconnect in a later minute finalizes that
                // partial bucket on the first new reading — the dead air in
                // between is never interpolated.
                self.beginMonitoring()
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
                // Feed the per-minute downsampler; a reading that completes a
                // minute returns that minute's means, persisted immediately so
                // the Trends live card updates in near real time.
                self.persist(self.downsampler.add(reading))
            }
        }
    }
}
