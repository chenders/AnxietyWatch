import Foundation

/// Encodes and decodes SyncMessage to/from WCSession payload dictionaries.
///
/// WCSession transports `[String: Any]`. To keep payloads compact and avoid
/// `PropertyListSerialization` overhead, SyncMessageCodec serializes through
/// JSON Data and wraps it in a single-key dictionary.
///
/// Wire format: `["p": <JSON Data>]`
public enum SyncMessageCodec {

    // MARK: - Errors

    public enum CodecError: Error, Equatable {
        case missingPayload
        case invalidPayloadType
        case encodingFailed(String)
        case decodingFailed(String)
    }

    // MARK: - Public API

    /// Encodes a `SyncMessage` into a dictionary suitable for `WCSession`.
    ///
    /// - Parameter message: The message to encode.
    /// - Returns: `["p": <JSON-encoded Data>]`.
    /// - Throws: `CodecError.encodingFailed` if JSON encoding fails.
    public static func encode(_ message: SyncMessage) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let data: Data
        do {
            data = try encoder.encode(message)
        } catch {
            throw CodecError.encodingFailed(error.localizedDescription)
        }
        return ["p": data]
    }

    /// Decodes a `SyncMessage` from a WCSession payload dictionary.
    ///
    /// - Parameter payload: The `[String: Any]` dictionary received from
    ///   `WCSessionDelegate`.
    /// - Returns: The decoded `SyncMessage`.
    /// - Throws: `CodecError.missingPayload` if key `"p"` is absent,
    ///   `CodecError.invalidPayloadType` if the value is not `Data`,
    ///   `CodecError.decodingFailed` if JSON decoding fails.
    public static func decode(_ payload: [String: Any]) throws -> SyncMessage {
        guard let data = payload["p"] else {
            throw CodecError.missingPayload
        }
        guard let dataValue = data as? Data else {
            throw CodecError.invalidPayloadType
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(SyncMessage.self, from: dataValue)
        } catch {
            throw CodecError.decodingFailed(error.localizedDescription)
        }
    }
}
