// AnxietyWatch/Services/PolarBluetoothStateMapping.swift
import CoreBluetooth

/// Pure mapping from `CBManagerState` to the equivalent
/// `PolarHRMState.Status`. Extracted from `PolarHRMService` so the
/// state-transition logic in `startScan`, `startSession`, and
/// `centralManagerDidUpdateState` can stay deduplicated and unit-testable
/// (CoreBluetooth itself doesn't run usefully in the simulator, but this
/// enum-to-enum mapping does).
enum PolarBluetoothStateMapping {

    /// Result of mapping a CB power state.
    enum Resolution: Equatable {
        /// CB is `.poweredOn` — the caller should proceed with scan / connect.
        case proceed
        /// CB is `.unknown` or `.resetting` — transient; the caller should
        /// latch a pending action and wait for the next state callback.
        case pendingTransient
        /// CB is in a terminal-for-now state; the caller should surface this
        /// status to the user.
        case status(PolarHRMState.Status)
    }

    static func resolve(_ cbState: CBManagerState) -> Resolution {
        switch cbState {
        case .poweredOn: return .proceed
        case .unknown, .resetting: return .pendingTransient
        case .poweredOff: return .status(.bluetoothOff)
        case .unauthorized: return .status(.bluetoothUnauthorized)
        case .unsupported: return .status(.bluetoothUnsupported)
        @unknown default: return .status(.error("Unknown Bluetooth state"))
        }
    }
}
