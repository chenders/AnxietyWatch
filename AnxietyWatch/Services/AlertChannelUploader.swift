import Foundation
import os

/// Uploads the SpO₂/HR the on-device CNS pipeline consumes to the server's
/// redundant alert channel (sub-project C) while a monitoring session is armed,
/// and registers this device's APNs token. It is the CLIENT of the server-side
/// backstop / no-data heartbeat — it never makes an alerting decision; it only
/// feeds the server so a silent on-device or whole-phone failure is still caught
/// (the redundant channel; sub-project A carries the primary alarm).
///
/// Best-effort by construction: every call is fire-and-forget and swallows
/// failures (logged, never surfaced). A dropped upload just means the server's
/// redundant view is briefly stale. Reuses `SyncService`'s configured server URL
/// + API key (UserDefaults), so it is active only once the user has set up sync.
protocol AlertChannelUploading: AnyObject {
    /// A monitoring session started — an explicit hook for future server-side
    /// "armed" state (the first `uploadSamples` is what establishes the buffer).
    func sessionStarted(_ sessionID: UUID)
    /// Upload this tick's freshly-collected samples for an armed session.
    func uploadSamples(sessionID: UUID, samples: [CNSSignalSample])
    /// A monitoring session ended — tell the server so its no-data heartbeat
    /// doesn't fire a false "monitoring stopped" alert for a clean disarm.
    func sessionEnded(_ sessionID: UUID)
    /// Register this device's APNs token so the server can push to it.
    func registerPushToken(_ deviceToken: Data)
}

final class AlertChannelUploader: AlertChannelUploading {
    // Reuse the SyncService-configured server URL + API key (same UserDefaults
    // keys) so there is a single place to point the app at its server.
    static let serverURLDefaultsKey = "syncServerURL"
    static let apiKeyDefaultsKey = "syncApiKey"

    private let urlSession: URLSession
    private let defaults: UserDefaults

    init(urlSession: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.urlSession = urlSession
        self.defaults = defaults
    }

    // MARK: - Pure mapping (unit-tested)

    /// The server channel label for a signal kind, or nil for kinds the server
    /// does not buffer/evaluate.
    static func channelLabel(for kind: CNSSignalKind) -> String? {
        switch kind {
        case .spo2: return "SPO2"
        case .heartRate: return "HR"
        case .respiratoryRate, .hrv: return nil
        }
    }

    /// Map CNS samples to the server's `{ts_utc, channel, value}` wire form.
    /// ARTIFACT samples are dropped — invalid data must be ABSENT from the
    /// server buffer (the backstop treats a gap as indeterminate, never as safe),
    /// never uploaded as a coerced value. Kinds the server ignores are dropped.
    static func wireSamples(from samples: [CNSSignalSample]) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return samples.compactMap { sample -> [String: Any]? in
            guard !sample.isArtifact, let channel = channelLabel(for: sample.kind) else { return nil }
            return [
                "ts_utc": formatter.string(from: sample.timestamp),
                "channel": channel,
                "value": sample.value,
            ]
        }
    }

    /// Lowercase-hex encode an APNs device token (the value is never logged).
    static func hexToken(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - AlertChannelUploading (fire-and-forget)

    func sessionStarted(_ sessionID: UUID) {
        // No distinct server call today; the first uploadSamples establishes the
        // per-session buffer. Kept as an explicit lifecycle hook.
    }

    func uploadSamples(sessionID: UUID, samples: [CNSSignalSample]) {
        let wire = Self.wireSamples(from: samples)
        guard !wire.isEmpty else { return }
        post(endpoint: "samples",
             body: ["session_id": sessionID.uuidString, "samples": wire],
             label: "samples")
    }

    func sessionEnded(_ sessionID: UUID) {
        post(endpoint: "disarm", body: ["session_id": sessionID.uuidString], label: "disarm")
    }

    func registerPushToken(_ deviceToken: Data) {
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        post(endpoint: "push-token",
             body: ["token": Self.hexToken(deviceToken), "env": env],
             label: "push-token")
    }

    // MARK: - Thin network

    private func post(endpoint: String, body: [String: Any], label: String) {
        guard let request = makeRequest(endpoint: endpoint, body: body) else { return }
        let session = urlSession
        // Sendable captures only (request/session/label); self is not captured.
        Task {
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    Log.health.warning("AlertChannel \(label, privacy: .public) HTTP \(http.statusCode)")
                }
            } catch {
                Log.health.warning(
                    "AlertChannel \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func makeRequest(endpoint: String, body: [String: Any]) -> URLRequest? {
        let baseURL = (defaults.string(forKey: Self.serverURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let apiKey = (defaults.string(forKey: Self.apiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !baseURL.isEmpty, !apiKey.isEmpty, let base = URL(string: baseURL),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        let url = base.appendingPathComponent("api/alert-channel/\(endpoint)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        return request
    }
}
