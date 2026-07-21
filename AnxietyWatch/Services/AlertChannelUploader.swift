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
    // Reuse SyncService's configured server URL + API key. The UserDefaults keys
    // are SyncService's constants (single source of truth) — not re-typed here,
    // so a future rename can't silently break this uploader's requests.

    private let urlSession: URLSession
    private let defaults: UserDefaults

    init(urlSession: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.urlSession = urlSession
        self.defaults = defaults
    }

    // MARK: - Pure mapping (unit-tested)

    /// The server channel label for a signal kind. Every kind is uploaded so the
    /// server's no-data heartbeat can track liveness for ANY armed session —
    /// including a CPAP-only respiratory-rate stream with no oximeter — while the
    /// SpO2 backstop simply ignores every channel except "SPO2".
    static func channelLabel(for kind: CNSSignalKind) -> String {
        switch kind {
        case .spo2: return "SPO2"
        case .heartRate: return "HR"
        case .respiratoryRate: return "RR"
        case .hrv: return "HRV"
        }
    }

    /// The alert-channel wire discriminator for a source, so the backstop can
    /// evaluate each SpO2 source independently — a normal reading from one
    /// concurrently-active source (e.g. the oximeter) must not reset, and thereby
    /// mask, a genuine sustained low on another (e.g. the CPAP bridge). This is a
    /// self-contained wire vocabulary the server only groups by opaquely; it
    /// deliberately does NOT reuse the HealthKit source-label strings.
    static func sourceLabel(for source: CNSSignalSource) -> String {
        switch source {
        case .emayOximeter: return "oximeter"
        case .polarH10: return "polar"
        case .appleWatch: return "watch"
        case .as11Bridge: return "as11"
        }
    }

    /// Map CNS samples to the server's `{ts_utc, source, channel, value}` wire
    /// form. ARTIFACT samples are dropped — invalid data must be ABSENT from the
    /// server buffer (a gap is indeterminate, never "safe"), never uploaded as a
    /// coerced value.
    static func wireSamples(from samples: [CNSSignalSample]) -> [[String: Any]] {
        return samples.compactMap { sample -> [String: Any]? in
            guard !sample.isArtifact else { return nil }
            return [
                // Date.ISO8601Format() avoids allocating an ISO8601DateFormatter
                // per call (this runs in the 1 Hz monitoring hot path).
                "ts_utc": sample.timestamp.ISO8601Format(),
                "source": sourceLabel(for: sample.source),
                "channel": channelLabel(for: sample.kind),
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

    // MARK: - Channel health (for the T6 surface)

    // The server emits fractional-second ISO8601 (Python datetime.isoformat()
    // includes microseconds), which a bare ISO8601DateFormatter rejects. Try
    // fractional first, then plain — mirrors AS11StreamSource's dual-formatter.
    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]  // explicit, not Foundation defaults
        return formatter
    }()

    /// Outcome of a health probe. Distinguishes "sync not set up" from
    /// "configured but unreachable" so the UI can be honest (own-failure-visible)
    /// instead of showing a perpetual "checking" spinner for a dark channel.
    enum ChannelHealthResult: Sendable, Equatable {
        case notConfigured
        case unreachable
        case ok(ChannelHealth)
    }

    /// Server channel-health snapshot. `Decodable` from GET /health; the raw
    /// last-delivered timestamp is a string so decoding never fails on null.
    struct ChannelHealth: Decodable, Sendable, Equatable {
        let apnsConfigured: Bool
        let registeredTokens: Int
        let lastDeliveredAlertUTC: String?

        enum CodingKeys: String, CodingKey {
            case apnsConfigured = "apns_configured"
            case registeredTokens = "registered_tokens"
            case lastDeliveredAlertUTC = "last_delivered_alert_utc"
        }

        var lastDeliveredAlert: Date? {
            guard let raw = lastDeliveredAlertUTC else { return nil }
            return AlertChannelUploader.iso8601Fractional.date(from: raw)
                ?? AlertChannelUploader.iso8601Plain.date(from: raw)
        }
    }

    /// Probe the channel-health endpoint. `.notConfigured` when sync isn't set
    /// up; `.unreachable` on any network/HTTP/decode failure (logged, metadata
    /// only — never the token); `.ok` otherwise. Never throws.
    func fetchHealth() async -> ChannelHealthResult {
        let baseURL = (defaults.string(forKey: SyncService.serverURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (defaults.string(forKey: SyncService.apiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !apiKey.isEmpty else { return .notConfigured }
        guard var request = makeRequest(endpoint: "health", method: "GET") else { return .unreachable }
        request.cachePolicy = .reloadIgnoringLocalCacheData  // never serve a stale health snapshot
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.health.warning("AlertChannel health HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return .unreachable
            }
            guard let health = try? JSONDecoder().decode(ChannelHealth.self, from: data) else {
                Log.health.warning("AlertChannel health decode failed")
                return .unreachable
            }
            return .ok(health)
        } catch {
            Log.health.warning("AlertChannel health fetch failed: \(error.localizedDescription, privacy: .public)")
            return .unreachable
        }
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

    private func makeRequest(endpoint: String, method: String = "POST", body: [String: Any]? = nil) -> URLRequest? {
        // Trim newlines too: a copy-pasted URL/key with a trailing newline would
        // otherwise make URL(string:) fail and silently no-op ("channel dark").
        let baseURL = (defaults.string(forKey: SyncService.serverURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (defaults.string(forKey: SyncService.apiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !apiKey.isEmpty, let base = URL(string: baseURL) else { return nil }

        let url = base.appendingPathComponent("api/alert-channel/\(endpoint)")
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        return request
    }
}
