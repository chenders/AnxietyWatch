// AnxietyWatchTests/PolarBluetoothStateMappingTests.swift
import CoreBluetooth
import Testing

@testable import AnxietyWatch

@MainActor
struct PolarBluetoothStateMappingTests {

    @Test("poweredOn resolves to .proceed")
    func poweredOnProceeds() {
        #expect(PolarBluetoothStateMapping.resolve(.poweredOn) == .proceed)
    }

    @Test(".unknown and .resetting resolve to .pendingTransient")
    func transientsArePending() {
        #expect(PolarBluetoothStateMapping.resolve(.unknown) == .pendingTransient)
        #expect(PolarBluetoothStateMapping.resolve(.resetting) == .pendingTransient)
    }

    @Test("poweredOff resolves to .bluetoothOff status")
    func poweredOffToStatus() {
        #expect(PolarBluetoothStateMapping.resolve(.poweredOff) == .status(.bluetoothOff))
    }

    @Test("unauthorized resolves to .bluetoothUnauthorized status")
    func unauthorizedToStatus() {
        #expect(PolarBluetoothStateMapping.resolve(.unauthorized) == .status(.bluetoothUnauthorized))
    }

    @Test("unsupported resolves to .bluetoothUnsupported status")
    func unsupportedToStatus() {
        #expect(PolarBluetoothStateMapping.resolve(.unsupported) == .status(.bluetoothUnsupported))
    }
}
