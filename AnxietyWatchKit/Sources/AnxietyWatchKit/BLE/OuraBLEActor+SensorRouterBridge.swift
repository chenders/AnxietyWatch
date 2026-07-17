import Foundation

// MARK: - OuraBLEActor → SensorRouter bridging

extension SensorRouter {

    /// Bridge an `OuraBLEActor`'s IBI stream into the merged `outbound` stream.
    ///
    /// Oura BLE IBI samples are converted to `AnySensorSample.oura(OuraIBISample)`
    /// and flow through the existing pipeline path (same as cloud-API IBI).
    ///
    /// Other Oura BLE streams (SpO2, accelerometer, temperature, sleep stage,
    /// battery) should be consumed directly from the `OuraBLEActor`'s outbound
    /// streams rather than the merged SensorRouter stream. This keeps the
    /// SensorRouter's `AnySensorSample` enum focused on pipeline-primary types.
    ///
    /// Call once after creating the `OuraBLEActor`. Idempotent.
    public func startOuraBLEBridging(ouraBLE: OuraBLEActor) async {
        let ibiStream = await ouraBLE.outboundIBI
        Task {
            for await sample in ibiStream {
                let ouraSample = SensorRouter.AnySensorSample.OuraIBISample(
                    timestamp: sample.timestamp,
                    ibiMs: sample.ibiMs,
                    validity: nil  // BLE samples have no validity flag
                )
                await self.push(.oura(ouraSample))
            }
        }
    }
}
