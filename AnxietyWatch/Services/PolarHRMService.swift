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
    /// Stable identifier so iOS can relaunch us and call
    /// `centralManager(_:willRestoreState:)` for in-flight peripherals.
    /// MUST stay constant across app launches or restoration breaks.
    nonisolated static let restoreIdentifier = "com.anxietywatch.polar-h10"

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
    private var reconnectTask: Task<Void, Never>?
    /// Latched by `startScan` when CB is in a transient state (`.unknown` /
    /// `.resetting`) or `.poweredOff` so the scan auto-resumes once
    /// `centralManagerDidUpdateState` fires with `.poweredOn`. Cleared by
    /// `stopScan` (so dismissing the pairing UI cancels the latch) and by
    /// `startScan` itself once a real scan begins. Scan-only — session
    /// start has no equivalent latch in Phase 2.
    private var pendingScan: Bool = false
    /// Backoff schedule for transient BLE disconnects mid-session, capped
    /// at the 10-min grace period. Each entry is a delay in seconds; after
    /// the schedule is exhausted the recorder finalizes and the session
    /// ends. Empirically the H10 reconnects within 1–8 seconds for
    /// rolling-over disconnects; the longer trailing intervals soak up
    /// signal blackouts (bathroom breaks, mattress shielding) without
    /// finalizing prematurely.
    private static let reconnectBackoffSeconds: [TimeInterval] = [1, 2, 4, 8, 30, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60]
    private static let reconnectGraceTotalSeconds: TimeInterval = 600  // 10 min

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
        //
        // Restore identifier enables iOS to relaunch the app for BLE events
        // when it has been suspended/terminated. When that happens,
        // `centralManager(_:willRestoreState:)` is called with the in-flight
        // peripheral so we can reattach without rescanning.
        self.central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
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

        // Close any open SensorInterruption before finalize — without this,
        // a reconnect-grace expiry would leave a never-closed interruption
        // attached to a now-finalized session, taint the gap-fraction
        // calculation, and leak across queries.
        if let session = finalRecorder?.session {
            let now = Date()
            for i in session.interruptions.indices where session.interruptions[i].endTime == nil {
                var entry = session.interruptions[i]
                entry.endTime = now
                session.interruptions[i] = entry
            }
        }

        peripheral = nil
        hrmCharacteristic = nil
        recorder = nil
        archive = nil
        buffer = nil
        tickTask?.cancel(); tickTask = nil
        elapsedTask?.cancel(); elapsedTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
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
            let archiveURL = RRArchiveWriter.archiveURL(for: sessionID)
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

    /// Append a SensorInterruption (open-ended) onto the active session.
    /// Used by the reconnect loop to track each disconnect gap, so the
    /// summary can report total gap time and the chart can render lossy
    /// regions.
    ///
    /// Idempotent: if an open-ended interruption already exists (e.g. a
    /// state-restoration round trip after the disconnect handler already
    /// logged one), this is a no-op. Without this guard, an interruption
    /// could be recorded by didDisconnectPeripheral and then again by
    /// willRestoreState on the next launch, producing overlapping
    /// open-ended entries that closeInterruption() couldn't clean up
    /// (it only closes the most recent open one).
    private func recordInterruption(reason: String) {
        guard let session = recorder?.session else { return }
        if session.interruptions.contains(where: { $0.endTime == nil }) {
            return
        }
        session.interruptions.append(SensorInterruption(reason: reason, startTime: Date(), endTime: nil))
        try? modelContext.save()
    }

    /// Close out the most recent open SensorInterruption (no endTime). Called
    /// when the reconnect succeeds.
    private func closeInterruption() {
        guard let session = recorder?.session else { return }
        guard let idx = session.interruptions.lastIndex(where: { $0.endTime == nil }) else { return }
        var entry = session.interruptions[idx]
        entry.endTime = Date()
        session.interruptions[idx] = entry
        try? modelContext.save()
    }

    /// Reconnect loop: walks `reconnectBackoffSeconds`, attempts
    /// `central.connect` on each tick, falls through to finalize once the
    /// total elapsed disconnect crosses the 10-min grace ceiling. Cancelled
    /// automatically by `tearDownResources` and on successful didConnect.
    private func scheduleReconnect(peripheralID: UUID) {
        reconnectTask?.cancel()
        let disconnectAt = Date()
        reconnectTask = Task { @MainActor [weak self] in
            for delay in Self.reconnectBackoffSeconds {
                if Task.isCancelled { return }
                // Check the grace ceiling BEFORE sleeping so we don't
                // overshoot by up to the length of the final backoff
                // interval. If only `remaining` seconds are left in the
                // grace window, cap the sleep at that.
                guard let self0 = self else { return }
                let elapsed = Date().timeIntervalSince(disconnectAt)
                let remaining = Self.reconnectGraceTotalSeconds - elapsed
                if remaining <= 0 {
                    self0.log.info("Reconnect grace exhausted (\(Int(elapsed), privacy: .public)s); finalizing session")
                    self0.stopSession()
                    return
                }
                let sleepFor = min(delay, remaining)
                try? await Task.sleep(for: .seconds(sleepFor))
                if Task.isCancelled { return }
                guard let self else { return }
                // Bail if user stopped or another stop path cleared state.
                guard self.state.status == .recording else { return }
                // Retry connect.
                guard let known = self.central.retrievePeripherals(withIdentifiers: [peripheralID]).first else {
                    continue
                }
                if known.state == .connected {
                    // CB says we're already connected to the strap. Treat
                    // this like a fresh didConnect: cancel the backoff loop,
                    // re-discover services so we can re-enable notify, and
                    // wait for didUpdateNotificationStateFor to confirm data
                    // is flowing before closing the interruption. Without
                    // this, the loop would exit without ever subscribing to
                    // HR notifications — leaving the session "Recording"
                    // while receiving zero packets.
                    self.peripheral = known
                    known.delegate = self
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    known.discoverServices([Self.heartRateServiceUUID])
                    return
                }
                self.peripheral = known
                known.delegate = self
                self.central.connect(known, options: nil)
            }
            // Schedule exhausted (shouldn't happen given the duration sum
            // exceeds the 10-min ceiling, but defensive): finalize.
            guard let self else { return }
            if !Task.isCancelled && self.state.status == .recording {
                self.log.info("Reconnect schedule exhausted; finalizing session")
                self.stopSession()
            }
        }
    }

    /// Pick up any SensorSession that was left open by a previous app
    /// lifecycle event. Two paths:
    ///
    /// 1. **State restoration brought a peripheral back** (`self.peripheral != nil`).
    ///    Rebuild the in-memory pipeline (buffer + recorder + archive) against
    ///    the existing row so RR data flowing through the reattached peripheral
    ///    lands on the same SwiftData session. Returns `true`.
    ///
    /// 2. **No peripheral** (cold launch after force-quit / crash, or state
    ///    restoration didn't bring one back). Finalize the orphaned row so it
    ///    doesn't shadow future sessions and so `beginRecording`'s
    ///    `recorder == nil` guard doesn't block the next `startSession`.
    ///    Returns `false`.
    ///
    /// Stale rows (>24h) are always finalized regardless of peripheral state —
    /// they're presumed to be app-crash residue.
    @discardableResult
    func recoverInFlightSessionIfNeeded() -> Bool {
        let staleCutoff = Date().addingTimeInterval(-24 * 3600)
        let now = Date()
        let polarSource = Self.sourceLabel
        let descriptor = FetchDescriptor<SensorSession>(
            predicate: #Predicate { $0.endTime == nil && $0.source == polarSource },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        guard let openSessions = try? modelContext.fetch(descriptor) else { return false }
        guard let candidate = openSessions.first else { return false }

        // Always finalize older opens — multiple endTime == nil rows can
        // accumulate from repeated crashes/force-quits, and leaving them
        // open indefinitely pollutes history and any future sync. Only the
        // newest candidate is a potential recovery target.
        for olderOpen in openSessions.dropFirst() {
            let id = olderOpen.id.uuidString
            log.info("Finalizing stranded older open SensorSession \(id, privacy: .public) from \(olderOpen.startTime, privacy: .public)")
            finalizeOrphan(olderOpen, at: now)
        }

        if candidate.startTime < staleCutoff {
            let id = candidate.id.uuidString
            log.warning("""
                Found stale open SensorSession \(id, privacy: .public) \
                from \(candidate.startTime, privacy: .public); finalizing without recovery
                """)
            finalizeOrphan(candidate, at: now)
            return false
        }

        // Without a restored peripheral, we have no data source. Finalize so
        // the orphaned row doesn't shadow future sessions and doesn't block
        // beginRecording's `recorder == nil` guard.
        guard peripheral != nil else {
            log.info("Found open SensorSession \(candidate.id.uuidString, privacy: .public) without a restored peripheral; finalizing")
            finalizeOrphan(candidate, at: now)
            return false
        }

        // Recovery is idempotent — if a recorder is already attached (e.g. a
        // re-entrant willRestoreState call), bail.
        guard recorder == nil else { return false }

        log.info("Recovering in-flight SensorSession \(candidate.id.uuidString, privacy: .public) (started \(candidate.startTime, privacy: .public))")

        // Rehydrate the running aggregates from persisted state so the final
        // summary covers the whole session, not just post-recovery minutes.
        // - rmssdValues: each persisted HRVReading row contributed one
        //   minute's RMSSD; replay them in chronological order.
        // - totalRRCount: every RR interval ever written to the archive is
        //   a 10-byte record on disk, so the file size divided by the
        //   record size is an exact count.
        let candidateID = candidate.id
        let priorReadingsDescriptor = FetchDescriptor<HRVReading>(
            predicate: #Predicate { $0.sensorSessionID == candidateID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let priorReadings = (try? modelContext.fetch(priorReadingsDescriptor)) ?? []
        let priorRMSSDs = priorReadings.map(\.rmssd)
        let archiveURL = RRArchiveWriter.archiveURL(for: candidate.id)
        // Artifact-filtered count so the recovered portion uses the same
        // counting basis as the live tick path (`totalRRCount += filtered.count`)
        // — the raw recordCount included artifacts and inflated rrCount for
        // any session that survived a restart (F-067). The helper returns 0
        // for a missing/unaligned file, matching recordCount's semantics.
        let priorRRCount = RRArchiveWriter.physiologicalRecordCount(url: archiveURL)

        // Rehydrate priorHRMeans by replaying the RR archive against each
        // persisted HRVReading row's 60s window. HR isn't stored on
        // HRVReading (only the time-domain rmssd/sdnn/pnn50 and frequency-
        // domain LF/HF) so the archive is the only source. Without this
        // the summary's hrMean would reflect only post-recovery minutes.
        let priorSamples = (try? RRArchiveWriter.read(url: archiveURL)) ?? []
        let priorHRMeans = HRVSessionRecorder.rehydratedHRValues(
            priorReadings: priorReadings,
            samples: priorSamples
        )

        let recoveredBuffer = RRIntervalBuffer(window: 60)
        let recoveredRecorder = HRVSessionRecorder(
            modelContext: modelContext,
            buffer: recoveredBuffer,
            source: Self.sourceLabel,
            existing: candidate,
            priorRMSSDs: priorRMSSDs,
            priorHRMeans: priorHRMeans,
            priorRRCount: priorRRCount
        )

        buffer = recoveredBuffer
        recorder = recoveredRecorder
        // Log archive-open failures explicitly — silently swallowing them
        // here used to make state-restoration archive drops invisible.
        // beginRecording logs the same way; the two paths now mirror each
        // other.
        do {
            archive = try RRArchiveWriter(url: archiveURL, append: true)
        } catch {
            archive = nil
            let path = archiveURL.path
            let message = error.localizedDescription
            log.warning("""
                RR archive writer failed to open at \(path, privacy: .public) during recovery: \
                \(message, privacy: .public); recovered session will record without raw archive
                """)
        }
        state.sessionStarted = candidate.startTime
        state.sessionElapsed = now.timeIntervalSince(candidate.startTime)
        scheduleTicks()
        return true
    }

    /// Close out a SensorSession we couldn't recover, including any open-
    /// ended SensorInterruption rows on it. Computes a best-effort summary
    /// from persisted state (HRVReading rows for the per-minute RMSSD
    /// series, the on-disk RR archive for the rrCount) so a force-quit
    /// orphan still shows up on the Dashboard's "Last session" tile with
    /// real metrics rather than blanks.
    ///
    /// `internal` (not `private`) so unit tests can exercise the orphan-
    /// finalize behavior without spinning up CoreBluetooth.
    func finalizeOrphan(_ session: SensorSession, at timestamp: Date) {
        session.endTime = timestamp
        for i in session.interruptions.indices where session.interruptions[i].endTime == nil {
            var entry = session.interruptions[i]
            entry.endTime = timestamp
            session.interruptions[i] = entry
        }

        // Rehydrate aggregates for the back-filled summary. Mirrors the
        // recovery path's rehydration so finalize-orphan and recover-then-
        // finalize produce comparable summaries for the same data.
        let sessionID = session.id
        let readingsDescriptor = FetchDescriptor<HRVReading>(
            predicate: #Predicate { $0.sensorSessionID == sessionID }
        )
        let rmssds = (try? modelContext.fetch(readingsDescriptor))?.map(\.rmssd) ?? []
        // Artifact-filtered for consistency with the live tick path's
        // counting basis — see recoverInFlightSessionIfNeeded (F-067).
        let rrCount = RRArchiveWriter.physiologicalRecordCount(url: RRArchiveWriter.archiveURL(for: session.id))
        // Skipped minutes weren't tracked across the suspend boundary, so
        // we report 0 here. Real per-minute "skipped" counts only exist
        // while the in-memory recorder is alive.
        // Orphan recovery can rehydrate RMSSDs from HRVReading rows but not
        // per-window HR (we don't persist it per minute). Pass an empty
        // hrValues so the summary's hrMean lands at 0 and the trend chart's
        // `hrMean > 0` gate correctly skips this session.
        session.summaryJSON = HRVSessionRecorder.buildSummaryJSON(
            rmssdValues: rmssds,
            hrValues: [],
            totalRRCount: rrCount,
            skippedMinutes: 0,
            session: session
        )
        // Re-dirty so the back-filled endTime + summary re-sync even if the
        // orphan was already flagged synced mid-recording. See F-013. The
        // version bump keeps an in-flight sync (payload built pre-finalize)
        // from flipping the flag back — see `SensorSession.pendingSyncVersion`.
        session.syncedToServer = false
        session.pendingSyncVersion &+= 1
        do {
            try modelContext.save()
        } catch {
            // A failed save silently drops the finalize (endTime, summary,
            // re-dirty, version bump) — log it so a sync-integrity
            // regression is diagnosable rather than invisible. The session
            // stays open-ended on disk and the next recovery pass retries.
            let id = session.id.uuidString
            let message = error.localizedDescription
            log.error("finalizeOrphan: save failed for session \(id, privacy: .public): \(message, privacy: .public)")
        }
    }
}

/// Lightweight value type for pairing UI — avoids exposing `CBPeripheral` to views.
struct DiscoveredPeripheralSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

// MARK: - CBCentralManagerDelegate

extension PolarHRMService: CBCentralManagerDelegate {
    /// Called when iOS relaunches the app for a BLE event after we were
    /// suspended/terminated. The dictionary's `RestoredPeripheralsKey`
    /// holds any peripheral the OS was tracking on our behalf — we
    /// reattach to it (set delegate, set self.peripheral) so the rest of
    /// the recording lifecycle can resume from didConnect /
    /// didUpdateValueFor as if the app had never gone away. Pairs with
    /// `recoverInFlightSessionIfNeeded` which rebuilds the SwiftData
    /// recorder for any session whose endTime is still nil.
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Unwrap the paired UUID first so the lookup compares
            // CBPeripheral.identifier (non-optional UUID) against a
            // concrete UUID rather than the optional accessor. Without
            // this, a missing pairedPeripheralUUID would yield a nil-vs-
            // UUID comparison that never matches.
            guard let pairedID = self.pairedPeripheralUUID else {
                self.log.info("State restoration received but no paired peripheral on record; ignoring \(restored.count, privacy: .public) restored entries")
                return
            }
            guard let p = restored.first(where: { $0.identifier == pairedID }) else {
                let count = restored.count
                self.log.info("""
                    State restoration received but no matching paired peripheral; \
                    ignoring \(count, privacy: .public) restored entries
                    """)
                return
            }
            let pid = p.identifier.uuidString
            let pstate = String(describing: p.state)
            self.log.info("""
                Restoring in-flight peripheral \(pid, privacy: .public) \
                (CB state=\(pstate, privacy: .public))
                """)
            p.delegate = self
            self.peripheral = p
            // Recover the SwiftData session row that was open when we got
            // suspended; without this, RR data flowing back in via
            // didUpdateValueFor would have no recorder to write to.
            let recovered = self.recoverInFlightSessionIfNeeded()
            guard recovered else {
                // State restoration brought a peripheral back, but there's no
                // open SensorSession to attach to (already-finalized stale
                // row, or no row at all). Drop the peripheral and return to
                // idle — the user must explicitly Start a new session. Without
                // this, RR data flowing through the restored peripheral would
                // be dropped on the floor while the UI claimed "Recording".
                self.peripheral = nil
                if p.state == .connected || p.state == .connecting {
                    self.central.cancelPeripheralConnection(p)
                }
                self.state.status = .idle
                return
            }
            // Recovery succeeded — bring up notifications based on the CB
            // peripheral state. Without an explicit .disconnected branch, a
            // restored-but-disconnected peripheral would leave the recovered
            // recorder hanging with no path back to data and beginRecording
            // permanently blocked by its `recorder == nil` guard.
            switch p.state {
            case .connected:
                self.state.status = .recording
                if let svc = p.services?.first(where: { $0.uuid == Self.heartRateServiceUUID }),
                   let ch = svc.characteristics?.first(where: { $0.uuid == Self.hrMeasurementCharacteristicUUID }) {
                    p.setNotifyValue(true, for: ch)
                    self.hrmCharacteristic = ch
                } else {
                    p.discoverServices([Self.heartRateServiceUUID])
                }
            case .connecting:
                self.state.status = .connecting
            case .disconnected, .disconnecting:
                // Recovered session needs a live peripheral to be useful.
                // Mark the recording active and kick off the reconnect grace
                // loop — same path as a mid-session BLE drop. If the grace
                // ceiling expires, the loop finalizes the session cleanly.
                self.state.status = .recording
                self.recordInterruption(reason: "state_restoration_disconnected")
                self.scheduleReconnect(peripheralID: p.identifier)
            @unknown default:
                break
            }
        }
    }

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
            // target.
            guard let active = self.peripheral, active.identifier == peripheralID else { return }
            // Two paths: fresh session start (.connecting) → discover services;
            // reconnect during the grace period (.recording) → cancel the
            // backoff loop and re-discover so notifications resume.
            switch self.state.status {
            case .connecting:
                active.discoverServices([Self.heartRateServiceUUID])
            case .recording:
                // Reconnect in progress — cancel the backoff loop, rediscover
                // so notify can re-enable. The interruption stays open until
                // didUpdateNotificationStateFor confirms data is flowing.
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
                active.discoverServices([Self.heartRateServiceUUID])
            default:
                return
            }
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
            // During the reconnect grace period, a single failed connect
            // attempt shouldn't tear down the session — the backoff loop
            // will try again. The 10-min ceiling is what finalizes a
            // genuinely-dead strap, not any individual failure.
            if self.state.status == .recording && self.reconnectTask != nil {
                self.log.debug("Reconnect attempt failed (\(message, privacy: .public)); backoff loop will retry")
                return
            }
            self.failConnection(message: message)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let peripheralID = peripheral.identifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Drop callbacks for a peripheral we're no longer tracking.
            guard let active = self.peripheral, active.identifier == peripheralID else { return }
            switch self.state.status {
            case .recording:
                // Mid-session disconnect: keep the recorder alive and kick
                // off the reconnect loop. After 10 min of continuous
                // disconnect the loop will finalize.
                self.recordInterruption(reason: "ble_disconnect")
                self.scheduleReconnect(peripheralID: peripheralID)
            case .connecting:
                // Disconnect during the connect/discover/notify handshake
                // (peripheral dropped before beginRecording flipped status
                // to .recording). Without explicit handling here, the UI
                // would stay stuck on "Connecting…" with peripheral still
                // set. Treat as a failed connection so the user gets a
                // clear error and can retry.
                let message = error?.localizedDescription ?? "Strap disconnected during connection setup"
                self.failConnection(message: message)
            default:
                // .idle / .scanning / .bluetooth* / .error: disconnect was
                // user-initiated or post-failConnection; nothing to clean up.
                return
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
            // Notifications are live — RR data is flowing. If we were
            // in a reconnect-grace window, this is the right moment to
            // close the open interruption (closeInterruption is a no-op
            // if there's nothing to close, so it's safe on fresh starts).
            self.closeInterruption()
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
                        let rr = sample.rrMs
                        let message = error.localizedDescription
                        self.log.warning("""
                            RR archive append failed (rrMs=\(rr, privacy: .public)): \
                            \(message, privacy: .public)
                            """)
                    }
                }
            }
        }
    }
}
