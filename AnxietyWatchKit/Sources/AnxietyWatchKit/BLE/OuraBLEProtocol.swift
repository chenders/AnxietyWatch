import Foundation

/// GATT service and characteristic UUIDs, packet framing, and command
/// structure for the Oura Ring BLE protocol (Ring 3 / 4 / 5).
///
/// Sources: open_oura (Th0rgal), ringverse protocol docs, open_ring (LogosIsLife).
/// All three generations share the same GATT layout and packet framing.
///
/// ## Packet framing
/// Every packet is 16 bytes:
/// ```
/// [command:1][data:14][checksum:1]
/// ```
/// The checksum byte is a simple XOR of bytes 0–14 (ringverse docs) or a
/// CRC-8 (open_oura). We document both; the delegate side is responsible
/// for validation.
///
/// ## Auth flow (per-connection)
/// 1. Write a nonce challenge to the auth characteristic.
/// 2. Receive a handle-value notification with the encrypted response.
/// 3. Decrypt with the shared 16-byte key (AES-ECB).
/// 4. Write the decrypted nonce to complete auth.
///
/// ## Measurement features
/// After auth, features are OFF by default. Send `SetFeatureMode` with
/// `CAP_DAYTIME_HR` + `CONNECTED_LIVE` to enable live HR IBI notifications
/// on tag `0x2f` sub-tag `40`. Accelerometer streaming uses tag `0x06` at
/// ~50 Hz with ~20 ms latency.
public enum OuraBLEProtocol {

    // MARK: - GATT Service

    /// Primary Oura service UUID (Ring 3/4/5).
    public static let serviceUUID = "0000XXXX-0000-1000-8000-00805F9B34FB"

    // MARK: - GATT Characteristics

    /// Auth challenge/response characteristic (write + notify).
    public static let authCharacteristicUUID = "0000XXXX-0000-1000-8000-00805F9B34FB"

    /// Command characteristic — write to enable features, request data.
    public static let commandCharacteristicUUID = "0000XXXX-0000-1000-8000-00805F9B34FB"

    /// Live measurement notifications (IBI, HR, SpO2, motion, temp).
    public static let measurementCharacteristicUUID = "0000XXXX-0000-1000-8000-00805F9B34FB"

    /// Device info (battery, firmware version).
    public static let deviceInfoCharacteristicUUID = "0000XXXX-0000-1000-8000-00805F9B34FB"

    /// History event stream — full-ring dump of PPG/IBI/temp/motion/SpO2/
    /// sleep stages/MET/HRV.
    public static let historyCharacteristicUUID = "0000XXXX-0000-1000-8000-00805F9B34FB"

    // MARK: - Packet structure

    /// Fixed packet size in bytes.
    public static let packetSize = 16

    /// Byte index of the command/type field.
    public static let commandByteIndex = 0

    /// Byte range of the payload.
    public static let payloadRange: Range<Int> = 1 ..< 15

    /// Byte index of the checksum.
    public static let checksumByteIndex = 15

    // MARK: - Commands (byte 0)

    /// Set feature mode (enable HR, SpO2, accelerometer, etc.).
    public static let cmdSetFeatureMode: UInt8 = 0x01

    /// Request latest single reading.
    public static let cmdRequestLatest: UInt8 = 0x02

    /// Begin history event dump.
    public static let cmdStartHistory: UInt8 = 0x03

    /// Auth challenge response (from ring).
    public static let cmdAuthResponse: UInt8 = 0x10

    /// Auth challenge request (to ring).
    public static let cmdAuthChallenge: UInt8 = 0x11

    // MARK: - Feature mode flags (payload of cmdSetFeatureMode)

    public static let capDaytimeHR: UInt8    = 0x01
    public static let capSpO2: UInt8         = 0x02
    public static let capAccelerometer: UInt8 = 0x04
    public static let capTemperature: UInt8   = 0x08
    public static let capConnectedLive: UInt8 = 0x80  // push IBI notifications live

    // MARK: - Measurement tags

    /// Live IBI notification tag (sub-tag 40 = IBI in ms).
    public static let tagLiveHR: UInt8 = 0x2F

    /// IBI sub-tag within a tagLiveHR packet.
    public static let subTagIBI: UInt8 = 40

    /// Accelerometer streaming tag.
    public static let tagAccelerometer: UInt8 = 0x06

    /// SpO2 reading tag.
    public static let tagSpO2: UInt8 = 0x07

    /// Temperature reading tag.
    public static let tagTemperature: UInt8 = 0x08

    /// Sleep stage tag.
    public static let tagSleepStage: UInt8 = 0x09

    /// Battery level tag.
    public static let tagBattery: UInt8 = 0x0A

    // MARK: - Auth

    /// Shared key length in bytes.
    public static let sharedKeyLength = 16

    /// Nonce length in bytes.
    public static let nonceLength = 16

    /// AES block size for auth encryption.
    public static let aesBlockSize = 16
}
