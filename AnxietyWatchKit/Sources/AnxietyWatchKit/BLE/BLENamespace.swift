import Foundation

/// Namespace for Bluetooth Low Energy hardware actors.
///
/// ## Available actors
/// - `PolarActor` — Polar H10 / H9 chest strap (HR + RR intervals)
/// - `EMAYActor` — EMAY pulse oximeter (SpO2 + PR + signal quality)
///
/// ## Fan-in
/// `SensorRouter` merges BLE and HealthKit streams into a single
/// `AsyncStream<AnySensorSample>`. Register new actors via
/// `SensorRouter.startBridging()`.
public enum BLE {}
