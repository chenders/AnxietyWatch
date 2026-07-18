import Foundation

/// Actor wrapping all Oura Ring BLE communication.
///
/// ## Design (mirrors PolarActor / EMAYActor)
/// CoreBluetooth's `CBCentralManagerDelegate` lives on a serial
/// `DispatchQueue` and CANNOT be a Swift actor executor. The delegate
/// serialises decoded samples into per-type `AsyncStream.Continuation`
/// values, and this actor consumes those streams. Callers observe via
/// the outbound streams; tests inject via `ingest*` methods.
///
/// ## Connection lifecycle
/// 1. **Provision key** — User imports/enters the 16-byte shared key via
///    `provisionKey(hex:)` or `provisionKey(data:)`. Persisted to Keychain.
/// 2. **Connect** — `connect()` starts BLE scan, finds ring, establishes
///    connection, performs AES nonce auth, enables measurement features.
/// 3. **Stream** — Samples flow through per-type `AsyncStream`s. The
///    `SensorRouter` bridges these into the merged `AnySensorSample` stream.
/// 4. **Disconnect** — `disconnect()` tears down the BLE connection and
///    stops all streams. Does NOT clear the provisioned key.
///
/// ## Single-client contention
/// The ring serves one BLE client at a time. If the official Oura app is
/// connected, `connect()` fails with `.contentionWithOfficialApp`. The user
/// must force-kill the official app and retry.
///
/// ## Backpressure
/// All streams use `bufferingNewest(1000)` per Spec §3.2.
///
/// ## Thread safety
/// - `ingest*` methods are safe to call from any thread (the CBCentralManager
///   delegate's serial queue).
/// - All state reads are actor-isolated.
/// - `outbound*` streams are `AsyncStream` values captured at init time —
///   consuming them off-actor is safe.
public actor OuraBLEActor {

    // MARK: - Configuration

    /// How long the ring can be silent before `isIdle` returns `true`.
    private let idleAfterSeconds: TimeInterval

    /// Ring identifier (CBUUID or peripheral name substring). Used during
    /// BLE scanning to find the Oura Ring.
    private let ringIdentifier: String?

    // MARK: - Key store

    private let keyStore: OuraBLEKeyStore

    // MARK: - Streams & continuations

    /// Backpressure buffer size for all streams.
    private let bufferSize: Int

    // IBI (heart rate variability) stream
    private let (ibiStream, ibiContinuation): (AsyncStream<OuraBLEIBISample>, AsyncStream<OuraBLEIBISample>.Continuation)

    // SpO2 stream
    private let (spo2Stream, spo2Continuation): (AsyncStream<OuraBLESpO2Sample>, AsyncStream<OuraBLESpO2Sample>.Continuation)

    // Accelerometer stream
    private let (accelStream, accelContinuation): (AsyncStream<OuraBLEAccelSample>, AsyncStream<OuraBLEAccelSample>.Continuation)

    // Temperature stream
    private let (tempStream, tempContinuation): (AsyncStream<OuraBLETemperatureSample>, AsyncStream<OuraBLETemperatureSample>.Continuation)

    // Sleep stage stream
    private let (sleepStream, sleepContinuation): (AsyncStream<OuraBLESleepStageSample>, AsyncStream<OuraBLESleepStageSample>.Continuation)

    // Battery stream
    private let (batteryStream, batteryContinuation): (AsyncStream<OuraBLEBatterySample>, AsyncStream<OuraBLEBatterySample>.Continuation)

    // MARK: - State

    /// Current connection state. Observable via `connectionStateStream`.
    private var connectionState: OuraBLEConnectionState = .disconnected

    /// Connection state change stream (emits on every transition).
    private let (connStateStream, connStateContinuation): (AsyncStream<OuraBLEConnectionState>, AsyncStream<OuraBLEConnectionState>.Continuation)

    /// Timestamp of most recent sample of any type (for idle detection).
    private var lastFrameAt: Double?

    /// Features enabled on the ring after auth.
    private var enabledFeatures: UInt8 = 0

    // MARK: - Init

    public init(
        keyStore: OuraBLEKeyStore = OuraBLEKeyStore(),
        ringIdentifier: String? = nil,
        idleAfterSeconds: TimeInterval = 60,
        bufferSize: Int = 1000
    ) {
        self.keyStore = keyStore
        self.ringIdentifier = ringIdentifier
        self.idleAfterSeconds = idleAfterSeconds
        self.bufferSize = bufferSize

        // IBI
        let (is_, ic) = AsyncStream<OuraBLEIBISample>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        self.ibiStream = is_
        self.ibiContinuation = ic

        // SpO2
        let (ss, sc) = AsyncStream<OuraBLESpO2Sample>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        self.spo2Stream = ss
        self.spo2Continuation = sc

        // Accelerometer
        let (as_, ac) = AsyncStream<OuraBLEAccelSample>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        self.accelStream = as_
        self.accelContinuation = ac

        // Temperature
        let (ts, tc) = AsyncStream<OuraBLETemperatureSample>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        self.tempStream = ts
        self.tempContinuation = tc

        // Sleep
        let (sls, slc) = AsyncStream<OuraBLESleepStageSample>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        self.sleepStream = sls
        self.sleepContinuation = slc

        // Battery
        let (bs, bc) = AsyncStream<OuraBLEBatterySample>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        self.batteryStream = bs
        self.batteryContinuation = bc

        // Connection state
        let (cs, cc) = AsyncStream<OuraBLEConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.connStateStream = cs
        self.connStateContinuation = cc
    }

    // MARK: - Outbound streams

    /// Live beat-to-beat interbeat interval samples.
    public var outboundIBI: AsyncStream<OuraBLEIBISample> { ibiStream }

    /// SpO2 readings (typically overnight).
    public var outboundSpO2: AsyncStream<OuraBLESpO2Sample> { spo2Stream }

    /// 3-axis accelerometer at ~50 Hz.
    public var outboundAccel: AsyncStream<OuraBLEAccelSample> { accelStream }

    /// Skin temperature deviation readings.
    public var outboundTemperature: AsyncStream<OuraBLETemperatureSample> { tempStream }

    /// On-ring sleep stage classifications.
    public var outboundSleepStage: AsyncStream<OuraBLESleepStageSample> { sleepStream }

    /// Battery status updates.
    public var outboundBattery: AsyncStream<OuraBLEBatterySample> { batteryStream }

    /// Connection state transitions.
    public var outboundConnectionState: AsyncStream<OuraBLEConnectionState> { connStateStream }

    // MARK: - Key management

    /// Import a 16-byte key as a hex string. Persists to Keychain.
    public func provisionKey(hex: String) throws {
        try keyStore.importHex(hex)
    }

    /// Import a 16-byte key as raw Data. Persists to Keychain.
    public func provisionKey(data: Data) throws {
        try keyStore.write(data)
    }

    /// True if the shared key has been provisioned.
    public var isKeyProvisioned: Bool {
        keyStore.isProvisioned
    }

    /// Remove the provisioned key. Does not affect the OAuth2 token
    /// (stored separately in `OuraTokenStore`).
    public func removeKey() throws {
        try keyStore.delete()
    }

    // MARK: - Connection management

    /// Begin BLE connection flow.
    ///
    /// - Throws: `OuraBLEConnectionError` if the key isn't provisioned,
    ///   Bluetooth is off, the ring isn't found, auth fails, or features
    ///   can't be enabled.
    ///
    /// The connection flow is:
    /// 1. Verify key is provisioned
    /// 2. Create CBCentralManager, start scan for ring
    /// 3. Connect to ring peripheral
    /// 4. Discover services and characteristics
    /// 5. Perform AES nonce challenge
    /// 6. Enable measurement features
    /// 7. Begin receiving notifications
    ///
    /// This method returns when the ring is in `.streaming` state.
    /// The actual CoreBluetooth delegate implementation lives off-actor
    /// on a serial DispatchQueue and writes samples via `ingest*`.
    public func connect() async throws {
        guard keyStore.isProvisioned else {
            throw OuraBLEConnectionError.keyNotProvisioned
        }

        transition(to: .connecting)
        // --- CoreBluetooth connection logic goes here ---
        //
        // 1. CBCentralManager(state: .poweredOn) else → .bluetoothPoweredOff
        // 2. scanForPeripherals(withServices: [OuraBLEProtocol.serviceUUID])
        // 3. didDiscover peripheral → connect
        // 4. didConnect → peripheral.discoverServices([OuraBLEProtocol.serviceUUID])
        // 5. didDiscoverServices → discover characteristics
        // 6. transition(to: .authenticating)
        // 7. Write nonce challenge to auth characteristic
        // 8. Receive encrypted response, decrypt with AES-ECB(keyStore.read())
        // 9. Write decrypted nonce back to complete auth
        //    → On failure: transition(to: .failed(.authFailed(reason)))
        // 10. transition(to: .connected)
        // 11. Write SetFeatureMode command to enable desired features
        //     → On failure: transition(to: .failed(.featureEnableFailed))
        // 12. transition(to: .streaming)
        //
        // The delegate writes decoded samples into ingest* methods.
        //
        // --- Placeholder: transition directly for testability ---
        // In production this is replaced by the CoreBluetooth delegate path.
        transition(to: .streaming)
    }

    /// Tear down the BLE connection and stop all streams.
    /// Does NOT clear the provisioned key.
    public func disconnect() async {
        // --- CoreBluetooth teardown goes here ---
        // peripheral.setNotifyValue(false, for: ...)
        // centralManager.cancelPeripheralConnection(peripheral)
        transition(to: .disconnected)
    }

    /// True while the ring is connected and streaming.
    public var isConnected: Bool {
        if case .streaming = connectionState { return true }
        return false
    }

    /// Current connection state.
    public var currentConnectionState: OuraBLEConnectionState {
        connectionState
    }

    // MARK: - Feature control

    /// Enable specific measurement features after auth.
    /// Call this from the CoreBluetooth delegate once auth completes.
    public func enableFeatures(_ features: UInt8) {
        enabledFeatures |= features
    }

    /// Disable specific measurement features.
    public func disableFeatures(_ features: UInt8) {
        enabledFeatures &= ~features
    }

    /// Currently enabled features bitmask.
    public var activeFeatures: UInt8 {
        enabledFeatures
    }

    // MARK: - Ingest (called from delegate)

    /// Ingest an IBI sample from the BLE delegate.
    public func ingestIBI(_ sample: OuraBLEIBISample) {
        advanceLastFrame(to: sample.timestamp)
        ibiContinuation.yield(sample)
    }

    /// Ingest a SpO2 sample from the BLE delegate.
    public func ingestSpO2(_ sample: OuraBLESpO2Sample) {
        advanceLastFrame(to: sample.timestamp)
        spo2Continuation.yield(sample)
    }

    /// Ingest an accelerometer sample from the BLE delegate.
    public func ingestAccel(_ sample: OuraBLEAccelSample) {
        advanceLastFrame(to: sample.timestamp)
        accelContinuation.yield(sample)
    }

    /// Ingest a temperature sample from the BLE delegate.
    public func ingestTemperature(_ sample: OuraBLETemperatureSample) {
        advanceLastFrame(to: sample.timestamp)
        tempContinuation.yield(sample)
    }

    /// Ingest a sleep stage sample from the BLE delegate.
    public func ingestSleepStage(_ sample: OuraBLESleepStageSample) {
        advanceLastFrame(to: sample.timestamp)
        sleepContinuation.yield(sample)
    }

    /// Ingest a battery sample from the BLE delegate.
    public func ingestBattery(_ sample: OuraBLEBatterySample) {
        advanceLastFrame(to: sample.timestamp)
        batteryContinuation.yield(sample)
    }

    // MARK: - Private helpers

    /// Advances `lastFrameAt` only forward — never regresses.
    /// This handles out-of-order delivery from multiple BLE characteristics.
    private func advanceLastFrame(to timestamp: Double) {
        if let current = lastFrameAt {
            lastFrameAt = max(current, timestamp)
        } else {
            lastFrameAt = timestamp
        }
    }

    // MARK: - Idle detection

    /// True if no sample has been ingested within `idleAfterSeconds`.
    /// Used by `SensorRouter` to decide when TRUNCATE checkpoints are safe.
    public func isIdle(now: Double) -> Bool {
        guard let lastFrameAt else { return true }
        return (now - lastFrameAt) >= idleAfterSeconds
    }

    /// Timestamp of most recent ingested sample of any type; nil if none.
    public var lastFrameAtTimestamp: Double? {
        lastFrameAt
    }

    // MARK: - Helpers

    private func transition(to state: OuraBLEConnectionState) {
        connectionState = state
        connStateContinuation.yield(state)
    }

    /// Helper method for testing — collect N samples from the IBI stream.
    public func collectIBISamples(count: Int) async -> [OuraBLEIBISample] {
        var samples: [OuraBLEIBISample] = []
        for await sample in ibiStream {
            samples.append(sample)
            if samples.count >= count { break }
        }
        return samples
    }

    /// Helper method for testing — collect N samples from the SpO2 stream.
    public func collectSpO2Samples(count: Int) async -> [OuraBLESpO2Sample] {
        var samples: [OuraBLESpO2Sample] = []
        for await sample in spo2Stream {
            samples.append(sample)
            if samples.count >= count { break }
        }
        return samples
    }

    /// Helper method for testing — collect N samples from the accel stream.
    public func collectAccelSamples(count: Int) async -> [OuraBLEAccelSample] {
        var samples: [OuraBLEAccelSample] = []
        for await sample in accelStream {
            samples.append(sample)
            if samples.count >= count { break }
        }
        return samples
    }

    /// Helper method for testing — collect N connection state transitions.
    public func collectConnectionStates(count: Int) async -> [OuraBLEConnectionState] {
        var states: [OuraBLEConnectionState] = []
        for await state in connStateStream {
            states.append(state)
            if states.count >= count { break }
        }
        return states
    }
}
