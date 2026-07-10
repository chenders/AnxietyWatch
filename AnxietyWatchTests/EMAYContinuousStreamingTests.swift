import CoreBluetooth
import Foundation
import Testing

@testable import AnxietyWatch

/// Covers the pure decision helpers behind EMAY continuous streaming —
/// launch auto-start, Bluetooth-state gating, reconnect-strategy choice, and
/// state-restoration peripheral adoption. The CoreBluetooth delegate glue is
/// deliberately thin and exercised on-device; everything decidable lives in
/// these `nonisolated static` helpers so it can be asserted without hardware.
struct EMAYContinuousStreamingTests {

    /// Fresh, isolated UserDefaults per test — never `.standard`, so tests
    /// can't leak state into each other or into the host app.
    private func makeDefaults() throws -> UserDefaults {
        let suite = "EMAYContinuousStreamingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Continuous-mode toggle persistence

    @Test("Continuous mode defaults to OFF — streaming must be opt-in")
    func continuousModeDefaultsOff() throws {
        let defaults = try makeDefaults()
        #expect(EMAYRealtimeService.isContinuousModeEnabled(defaults: defaults) == false)
    }

    @Test("Continuous mode round-trips through its UserDefaults key")
    func continuousModeRoundTrips() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: EMAYRealtimeService.continuousModeKey)
        #expect(EMAYRealtimeService.isContinuousModeEnabled(defaults: defaults) == true)
        defaults.set(false, forKey: EMAYRealtimeService.continuousModeKey)
        #expect(EMAYRealtimeService.isContinuousModeEnabled(defaults: defaults) == false)
    }

    // MARK: - Known-peripheral persistence

    @Test("No remembered peripheral yields nil")
    func knownPeripheralAbsent() throws {
        let defaults = try makeDefaults()
        #expect(EMAYRealtimeService.knownPeripheralUUID(defaults: defaults) == nil)
    }

    @Test("A remembered peripheral identifier round-trips")
    func knownPeripheralRoundTrips() throws {
        let defaults = try makeDefaults()
        let uuid = UUID()
        defaults.set(uuid.uuidString, forKey: EMAYRealtimeService.knownPeripheralUUIDKey)
        #expect(EMAYRealtimeService.knownPeripheralUUID(defaults: defaults) == uuid)
    }

    @Test("A corrupt stored identifier yields nil rather than crashing or mis-parsing")
    func knownPeripheralCorruptValue() throws {
        let defaults = try makeDefaults()
        defaults.set("not-a-uuid", forKey: EMAYRealtimeService.knownPeripheralUUIDKey)
        #expect(EMAYRealtimeService.knownPeripheralUUID(defaults: defaults) == nil)
    }

    // MARK: - start() Bluetooth-state gating

    @Test("poweredOn proceeds to monitoring (nil = no blocking status)")
    func startupProceedsWhenPoweredOn() {
        #expect(EMAYRealtimeService.startupStatus(for: .poweredOn) == nil)
    }

    @Test("Actionable Bluetooth problems surface their specific status")
    func startupSurfacesActionableStates() {
        #expect(EMAYRealtimeService.startupStatus(for: .poweredOff) == .bluetoothOff)
        #expect(EMAYRealtimeService.startupStatus(for: .unauthorized) == .bluetoothUnauthorized)
        #expect(EMAYRealtimeService.startupStatus(for: .unsupported) == .bluetoothUnsupported)
    }

    @Test("Transient central states report scanning and wait for poweredOn")
    func startupTransientStatesWait() {
        #expect(EMAYRealtimeService.startupStatus(for: .unknown) == .scanning)
        #expect(EMAYRealtimeService.startupStatus(for: .resetting) == .scanning)
    }

    // MARK: - Reconnect strategy

    @Test("A remembered peripheral is re-acquired via pending connect, never a background-throttled scan")
    func reconnectPrefersPendingConnect() {
        let uuid = UUID()
        #expect(EMAYRealtimeService.reconnectApproach(knownPeripheralUUID: uuid) == .pendingConnect(uuid))
    }

    @Test("With no remembered peripheral the only option is a scan")
    func reconnectFallsBackToScan() {
        #expect(EMAYRealtimeService.reconnectApproach(knownPeripheralUUID: nil) == .scan)
    }

    // MARK: - State-restoration peripheral adoption

    @Test("The remembered peripheral is preferred among restored entries")
    func restorationPrefersKnownPeripheral() {
        let known = UUID()
        let other = UUID()
        let idx = EMAYRealtimeService.restoredPeripheralIndex(
            identifiers: [other, known], knownUUID: known
        )
        #expect(idx == 1)
    }

    @Test("A stale remembered UUID doesn't orphan a restored connection — adopt the first entry")
    func restorationFallsBackToFirst() {
        let stale = UUID()
        let restored = [UUID(), UUID()]
        let idx = EMAYRealtimeService.restoredPeripheralIndex(
            identifiers: restored, knownUUID: stale
        )
        #expect(idx == 0)
    }

    @Test("No remembered UUID adopts the first restored entry")
    func restorationAdoptsFirstWithoutKnown() {
        let idx = EMAYRealtimeService.restoredPeripheralIndex(
            identifiers: [UUID()], knownUUID: nil
        )
        #expect(idx == 0)
    }

    @Test("An empty restoration dictionary adopts nothing")
    func restorationEmptyAdoptsNothing() {
        #expect(EMAYRealtimeService.restoredPeripheralIndex(identifiers: [], knownUUID: UUID()) == nil)
        #expect(EMAYRealtimeService.restoredPeripheralIndex(identifiers: [], knownUUID: nil) == nil)
    }

    // MARK: - Active-session classification (start() re-entrancy + Stop button)

    @Test("In-flight states are active: start() must not restart them and the button shows Stop")
    func activeSessionStates() {
        #expect(EMAYRealtimeService.Status.scanning.isActiveSession)
        #expect(EMAYRealtimeService.Status.waitingForDevice.isActiveSession)
        #expect(EMAYRealtimeService.Status.connecting.isActiveSession)
        #expect(EMAYRealtimeService.Status.streaming.isActiveSession)
    }

    @Test("Terminal and error states are inactive: Start applies and auto-start may proceed")
    func inactiveSessionStates() {
        #expect(!EMAYRealtimeService.Status.idle.isActiveSession)
        #expect(!EMAYRealtimeService.Status.failed("boom").isActiveSession)
        #expect(!EMAYRealtimeService.Status.bluetoothOff.isActiveSession)
        #expect(!EMAYRealtimeService.Status.bluetoothUnauthorized.isActiveSession)
        #expect(!EMAYRealtimeService.Status.bluetoothUnsupported.isActiveSession)
    }
}
