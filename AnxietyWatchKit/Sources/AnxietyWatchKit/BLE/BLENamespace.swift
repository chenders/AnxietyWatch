import Foundation

/// Namespace for Bluetooth Low Energy hardware actors.
///
/// ## Available actors
/// - `PolarActor` — Polar H10 / H9 chest strap (HR + RR intervals)
/// - `EMAYActor` — EMAY pulse oximeter (SpO2 + PR + signal quality)
/// - `OuraBLEActor` — Oura Ring 3/4/5 direct BLE (IBI, SpO2, accel, temp,
///   sleep stages, battery). Phase 3 only — requires user-provisioned
///   16-byte shared key. See `OuraBLEKeyStore`.
///
/// ## Fan-in
/// `SensorRouter` merges BLE and HealthKit streams into a single
/// `AsyncStream<AnySensorSample>`. Register new actors via
/// `SensorRouter.startBridging()` / `SensorRouter.startOuraBLEBridging()`.
public enum BLE {}
