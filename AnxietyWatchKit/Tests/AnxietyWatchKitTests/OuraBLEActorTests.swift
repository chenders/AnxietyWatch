import XCTest
@testable import AnxietyWatchKit

final class OuraBLEActorTests: XCTestCase {

    private final class SuccessfulConnection: OuraBLEConnecting, @unchecked Sendable {
        private weak var actor: OuraBLEActor?

        init(actor: OuraBLEActor) {
            self.actor = actor
        }

        func connect() async throws {
            await actor?.transition(to: .streaming)
        }

        func disconnect() {}
    }

    private final class FailingConnection: OuraBLEConnecting, @unchecked Sendable {
        private(set) var disconnectCallCount = 0

        func connect() async throws {
            throw OuraBLEConnectionError.connectionTimeout
        }

        func disconnect() {
            disconnectCallCount += 1
        }
    }

    private func makeConnectedActor(testID: String) -> (OuraBLEActor, OuraBLEKeyStore) {
        let keyStore = OuraBLEKeyStore(
            service: "com.anxietywatch.test.connection.\(testID)",
            account: testID
        )
        try? keyStore.delete()
        let actor = OuraBLEActor(
            keyStore: keyStore,
            connectionFactory: { actor, _ in SuccessfulConnection(actor: actor) }
        )
        return (actor, keyStore)
    }

    // MARK: - IBI ingest & stream

    func testIngestIBIYieldsOnOutbound() async throws {
        let actor = OuraBLEActor()

        let s1 = OuraBLEIBISample(timestamp: 100.0, ibiMs: 800)
        let s2 = OuraBLEIBISample(timestamp: 101.0, ibiMs: 820)
        let s3 = OuraBLEIBISample(timestamp: 102.0, ibiMs: 780)

        await actor.ingestIBI(s1)
        await actor.ingestIBI(s2)
        await actor.ingestIBI(s3)

        let received = await actor.collectIBISamples(count: 3)
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received[0], s1)
        XCTAssertEqual(received[1], s2)
        XCTAssertEqual(received[2], s3)
    }

    func testInstantHRDerivedFromIBI() {
        let sample = OuraBLEIBISample(timestamp: 100.0, ibiMs: 800)
        XCTAssertEqual(sample.instantHR, 75.0, accuracy: 0.01)

        let zeroSample = OuraBLEIBISample(timestamp: 101.0, ibiMs: 0)
        XCTAssertEqual(zeroSample.instantHR, 0.0)
    }

    // MARK: - SpO2 ingest & stream

    func testIngestSpO2YieldsOnOutbound() async throws {
        let actor = OuraBLEActor()

        let s1 = OuraBLESpO2Sample(timestamp: 200.0, spo2Percent: 96, signalQuality: 12)
        let s2 = OuraBLESpO2Sample(timestamp: 201.0, spo2Percent: 95, signalQuality: 14)

        await actor.ingestSpO2(s1)
        await actor.ingestSpO2(s2)

        let received = await actor.collectSpO2Samples(count: 2)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0], s1)
        XCTAssertEqual(received[1], s2)
    }

    // MARK: - Accelerometer

    func testIngestAccelYieldsOnOutbound() async throws {
        let actor = OuraBLEActor()

        let s1 = OuraBLEAccelSample(timestamp: 300.0, x: 0.01, y: -0.98, z: 0.05)
        await actor.ingestAccel(s1)

        let received = await actor.collectAccelSamples(count: 1)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0], s1)
    }

    // MARK: - Temperature

    func testTemperatureDeviationRoundTrip() async throws {
        let actor = OuraBLEActor()
        let sample = OuraBLETemperatureSample(timestamp: 400.0, deviationCelsius: -0.15)
        await actor.ingestTemperature(sample)

        let lastFrame = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame, 400.0)
    }

    // MARK: - Sleep stage

    func testSleepStageRoundTrip() async throws {
        let actor = OuraBLEActor()

        let deep = OuraBLESleepStageSample(timestamp: 500.0, stage: .deep)
        let rem  = OuraBLESleepStageSample(timestamp: 501.0, stage: .rem)

        await actor.ingestSleepStage(deep)
        await actor.ingestSleepStage(rem)

        let lastFrame = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame, 501.0)
    }

    // MARK: - Battery

    func testBatteryRoundTrip() async throws {
        let actor = OuraBLEActor()

        let sample = OuraBLEBatterySample(timestamp: 600.0, percent: 85, isCharging: false)
        await actor.ingestBattery(sample)

        let lastFrame = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame, 600.0)
    }

    // MARK: - Idle detection

    func testIsIdleTrueWhenNoFrames() async throws {
        let actor = OuraBLEActor()
        let isIdle = await actor.isIdle(now: 1000.0)
        XCTAssertTrue(isIdle)
    }

    func testIsIdleFalseWithinWindow() async throws {
        let actor = OuraBLEActor()
        let sample = OuraBLEIBISample(timestamp: 100.0, ibiMs: 800)
        await actor.ingestIBI(sample)

        let isIdle = await actor.isIdle(now: 130.0)
        XCTAssertFalse(isIdle)
    }

    func testIsIdleTrueAfterWindow() async throws {
        let actor = OuraBLEActor()
        let sample = OuraBLEIBISample(timestamp: 100.0, ibiMs: 800)
        await actor.ingestIBI(sample)

        let isIdle = await actor.isIdle(now: 200.0)
        XCTAssertTrue(isIdle)
    }

    func testIsIdleWindowConfigurable() async throws {
        let actor = OuraBLEActor(idleAfterSeconds: 30)
        let sample = OuraBLEIBISample(timestamp: 100.0, ibiMs: 800)
        await actor.ingestIBI(sample)

        let idle1 = await actor.isIdle(now: 110.0)
        XCTAssertFalse(idle1)  // 10s < 30s

        let idle2 = await actor.isIdle(now: 140.0)
        XCTAssertTrue(idle2)   // 40s > 30s
    }

    func testLastFrameAtUpdatesAcrossAllSampleTypes() async throws {
        let actor = OuraBLEActor()

        // IBI
        await actor.ingestIBI(OuraBLEIBISample(timestamp: 100.0, ibiMs: 800))
        var lastFrame = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame, 100.0)

        // SpO2 later
        await actor.ingestSpO2(OuraBLESpO2Sample(timestamp: 150.0, spo2Percent: 97, signalQuality: 13))
        lastFrame = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame, 150.0)

        // Accel doesn't regress
        await actor.ingestAccel(OuraBLEAccelSample(timestamp: 120.0, x: 0, y: 0, z: 0))
        lastFrame = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame, 150.0)
    }

    // MARK: - Connection state

    func testInitialStateIsDisconnected() async throws {
        let actor = OuraBLEActor()
        let state = await actor.currentConnectionState
        XCTAssertEqual(state, .disconnected)
    }

    func testConnectionStateStreamEmitsOnConnect() async throws {
        let (actor, keyStore) = makeConnectedActor(testID: "states")
        defer { try? keyStore.delete() }

        try await actor.provisionKey(hex: "00112233445566778899AABBCCDDEEFF")
        try await actor.connect()

        let states = await actor.collectConnectionStates(count: 3)
        XCTAssertEqual(states, [.connecting, .authenticating, .streaming])
    }

    func testConnectFailsWithoutKey() async throws {
        let keyStore = OuraBLEKeyStore(service: "com.anxietywatch.test.ble9", account: "test9")
        defer { try? keyStore.delete() }
        let actor = OuraBLEActor(keyStore: keyStore)

        do {
            try await actor.connect()
            XCTFail("Expected keyNotProvisioned error")
        } catch let error as OuraBLEConnectionError {
            XCTAssertEqual(error, .keyNotProvisioned)
        }
    }

    func testConnectFailureDisconnectsConnectorAndTransitionsToFailed() async throws {
        let keyStore = OuraBLEKeyStore(
            service: "com.anxietywatch.test.connection.failure",
            account: "failure"
        )
        defer { try? keyStore.delete() }
        try keyStore.importHex("00112233445566778899AABBCCDDEEFF")

        let connector = FailingConnection()
        let actor = OuraBLEActor(
            keyStore: keyStore,
            connectionFactory: { _, _ in connector }
        )

        do {
            try await actor.connect()
            XCTFail("Expected connectionTimeout error")
        } catch let error as OuraBLEConnectionError {
            XCTAssertEqual(error, .connectionTimeout)
        }

        XCTAssertEqual(connector.disconnectCallCount, 1)
        let state = await actor.currentConnectionState
        XCTAssertEqual(state, .failed(.connectionTimeout))
    }

    func testIsConnectedTrueAfterConnect() async throws {
        let (actor, keyStore) = makeConnectedActor(testID: "connected")
        defer { try? keyStore.delete() }
        try await actor.provisionKey(hex: "00112233445566778899AABBCCDDEEFF")
        try await actor.connect()

        let connected = await actor.isConnected
        XCTAssertTrue(connected)
    }

    func testIsConnectedFalseAfterDisconnect() async throws {
        let (actor, keyStore) = makeConnectedActor(testID: "disconnected")
        defer { try? keyStore.delete() }
        try await actor.provisionKey(hex: "00112233445566778899AABBCCDDEEFF")
        try await actor.connect()
        await actor.disconnect()

        let connected = await actor.isConnected
        XCTAssertFalse(connected)
    }

    // MARK: - Key management

    func testKeyProvisioning() async throws {
        let keyStore = OuraBLEKeyStore(service: "com.anxietywatch.test.ble1", account: "test1")
        defer { try? keyStore.delete() }

        let actor = OuraBLEActor(keyStore: keyStore)

        var provisioned = await actor.isKeyProvisioned
        XCTAssertFalse(provisioned)

        try await actor.provisionKey(hex: "00112233445566778899AABBCCDDEEFF")
        provisioned = await actor.isKeyProvisioned
        XCTAssertTrue(provisioned)

        let key = try keyStore.read()
        XCTAssertEqual(key?.count, 16)
    }

    func testKeyProvisioningViaData() async throws {
        let keyStore = OuraBLEKeyStore(service: "com.anxietywatch.test.ble2", account: "test2")
        defer { try? keyStore.delete() }

        let actor = OuraBLEActor(keyStore: keyStore)
        let keyData = Data((0..<16).map { UInt8($0) })

        try await actor.provisionKey(data: keyData)
        let provisioned = await actor.isKeyProvisioned
        XCTAssertTrue(provisioned)

        let stored = try keyStore.read()
        XCTAssertEqual(stored, keyData)
    }

    func testRemoveKey() async throws {
        let keyStore = OuraBLEKeyStore(service: "com.anxietywatch.test.ble3", account: "test3")
        let actor = OuraBLEActor(keyStore: keyStore)

        try await actor.provisionKey(hex: "AABBCCDDEEFF00112233445566778899")
        var provisioned = await actor.isKeyProvisioned
        XCTAssertTrue(provisioned)

        try await actor.removeKey()
        provisioned = await actor.isKeyProvisioned
        XCTAssertFalse(provisioned)
    }

    func testRemoveKeyWhenNotProvisionedIsSafe() async throws {
        let keyStore = OuraBLEKeyStore(service: "com.anxietywatch.test.ble4", account: "test4")
        let actor = OuraBLEActor(keyStore: keyStore)

        try await actor.removeKey()
        let provisioned = await actor.isKeyProvisioned
        XCTAssertFalse(provisioned)
    }

    // MARK: - Feature flags

    func testFeatureEnableDisable() async throws {
        let actor = OuraBLEActor()

        await actor.enableFeatures(OuraBLEProtocol.capDaytimeHR | OuraBLEProtocol.capSpO2)
        var features = await actor.activeFeatures
        XCTAssertEqual(features, OuraBLEProtocol.capDaytimeHR | OuraBLEProtocol.capSpO2)

        await actor.disableFeatures(OuraBLEProtocol.capSpO2)
        features = await actor.activeFeatures
        XCTAssertEqual(features, OuraBLEProtocol.capDaytimeHR)

        await actor.disableFeatures(OuraBLEProtocol.capDaytimeHR)
        features = await actor.activeFeatures
        XCTAssertEqual(features, 0)
    }

    // MARK: - Key store correctness

    func testKeyStoreRejectsWrongLength() async throws {
        let keyStore = OuraBLEKeyStore(service: "com.anxietywatch.test.ble5", account: "test5")
        let shortKey = Data([0x01, 0x02, 0x03])

        do {
            try keyStore.write(shortKey)
            XCTFail("Expected invalidKeyLength error")
        } catch let error as OuraBLEKeyStoreError {
            XCTAssertEqual(error, .invalidKeyLength(3))
        }
    }

    func testKeyStoreHexImportRejectsBadLength() async throws {
        let keyStore = OuraBLEKeyStore(service: "com.anxietywatch.test.ble6", account: "test6")

        do {
            try keyStore.importHex("AABB")
            XCTFail("Expected invalidHexLength error")
        } catch let error as OuraBLEKeyStoreError {
            XCTAssertEqual(error, .invalidHexLength(4))
        }
    }

    func testKeyStoreHexImportRejectsBadChars() async throws {
        let keyStore = OuraBLEKeyStore(service: "com.anxietywatch.test.ble7", account: "test7")

        do {
            try keyStore.importHex("ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ")
            XCTFail("Expected invalidHexCharacters error")
        } catch let error as OuraBLEKeyStoreError {
            XCTAssertEqual(error, .invalidHexCharacters)
        }
    }

    func testKeyStoreHexImportWith0xPrefix() async throws {
        let keyStore = OuraBLEKeyStore(service: "com.anxietywatch.test.ble8", account: "test8")
        defer { try? keyStore.delete() }

        try keyStore.importHex("0x00112233445566778899AABBCCDDEEFF")
        let key = try keyStore.read()
        XCTAssertEqual(key?.count, 16)
    }

    // MARK: - SensorRouter bridge

    func testIBIBridgedToSensorRouter() async throws {
        let actor = OuraBLEActor()
        let router = SensorRouter(polar: nil, emay: nil, healthKit: nil)

        await router.startOuraBLEBridging(ouraBLE: actor)

        // Ingest an IBI sample
        await actor.ingestIBI(OuraBLEIBISample(timestamp: 777.0, ibiMs: 900))

        // Should arrive in the merged stream as .oura
        let samples = await router.collectSamples(count: 1)
        XCTAssertEqual(samples.count, 1)

        if case .oura(let ouraSample) = samples[0] {
            XCTAssertEqual(ouraSample.timestamp, 777.0)
            XCTAssertEqual(ouraSample.ibiMs, 900)
            XCTAssertEqual(ouraSample.instantHR, 60000.0 / 900.0, accuracy: 0.01)
            XCTAssertNil(ouraSample.validity)
        } else {
            XCTFail("Expected .oura sample, got \(samples[0])")
        }
    }
}
