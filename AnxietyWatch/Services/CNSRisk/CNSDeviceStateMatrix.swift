import Foundation

/// A source's presence/reporting status at a point in time (spec §7:
/// "present-and-reporting / present-but-idle / absent-from-start /
/// died-mid-session"). `CNSDeviceStateMatrix.state(...)` derives this from
/// raw sample timestamps; `.idle` is reserved for a future cadence-aware
/// derivation path (see that function's doc comment) and is not produced by
/// it today, but remains a valid, independently-testable input to
/// `classify(source:state:isOnlyPrimarySource:)`.
enum CNSDeviceState: String, Sendable {
    case reporting
    case idle
    case absentFromStart
    case diedMidSession
}

/// The §7 matrix's verdict for a (source, state) pair: whether Phase 3
/// alerting should ignore it, disclose a degradation, or end monitoring
/// outright. Never silent — `.ignorable` is the only outcome that produces no
/// user-facing signal, and it is reserved for states the spec's own worked
/// examples call genuinely benign (e.g. a corroborating-only source that
/// never showed up).
enum CNSDeviceStateClassification: String, Sendable {
    case ignorable
    case degradeDisclosed
    case endMonitoring
}

/// Per-device fallback action when the §7 matrix classifies a source as
/// degraded or ended, persisted via `UserDefaults` (Codable) so the choice
/// survives relaunch. Phase 2 only detects and persists this; Phase 3's
/// `KlaxonAlarmService` is what actually executes `.klaxon`/`.gentleAlarm` —
/// Phase 2's interim measure is a standard local notification regardless of
/// the configured action (spec asymmetry rule: degradation is disclosed,
/// never silent, even before the loud-alerting UI exists).
struct CNSDeviceFallbackConfig: Codable, Equatable {
    enum Action: String, Codable, CaseIterable, Sendable {
        case klaxon
        case gentleAlarm
        case notifyOnly
    }

    /// Losing the only continuous SpO₂ source is the dangerous silent-gap
    /// case (§7) — the loudest default is deliberate, not an oversight.
    var emay: Action
    var polar: Action
    var appleWatch: Action

    init(emay: Action = .klaxon, polar: Action = .notifyOnly, appleWatch: Action = .notifyOnly) {
        self.emay = emay
        self.polar = polar
        self.appleWatch = appleWatch
    }

    /// Custom decode with `decodeIfPresent` (rather than relying on
    /// synthesized `Codable`, which would throw `keyNotFound` on a missing
    /// key) so a persisted blob from an earlier schema — or a hand-crafted
    /// partial payload — still resolves every absent field to this struct's
    /// declared default rather than failing the whole decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emay = try container.decodeIfPresent(Action.self, forKey: .emay) ?? .klaxon
        polar = try container.decodeIfPresent(Action.self, forKey: .polar) ?? .notifyOnly
        appleWatch = try container.decodeIfPresent(Action.self, forKey: .appleWatch) ?? .notifyOnly
    }

    private enum CodingKeys: String, CodingKey {
        case emay, polar, appleWatch
    }

    private static let defaultsKey = "cns.deviceFallbackConfig"

    /// No stored data (fresh install) or an undecodable blob both resolve to
    /// the declared defaults — never a crash, never a silently-empty config.
    static func load(from defaults: UserDefaults) -> CNSDeviceFallbackConfig {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(CNSDeviceFallbackConfig.self, from: data)
        else {
            return CNSDeviceFallbackConfig()
        }
        return decoded
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// The §7 "enumerate and mark" device-state matrix, resolved conservatively
/// (spec asymmetry rule: degradation is disclosed, never silent).
///
/// `isOnlyPrimarySource` is caller-computed (Task 6's coordinator): whether
/// the source under evaluation is the only currently-present primary-capable
/// (continuous SpO₂) source. In practice only `.emayOximeter` is ever
/// primary-capable (decision 5 — Polar has no primary kind; Apple Watch SpO₂
/// is periodic, not continuous), so passing `true` for `.polarH10` or
/// `.appleWatch` is a caller contract violation. `classify` still resolves it
/// per the literal matrix rule below (source-independent for `.idle`/
/// `.diedMidSession`) rather than asserting/trapping — a pure decision
/// function should never crash on an out-of-band input from a caller bug,
/// and the fail-safe direction (favoring `.endMonitoring`) is the same
/// either way.
enum CNSDeviceStateMatrix {

    /// The §7 enumerated matrix. Inputs: per-source state + whether that
    /// source is the ONLY present primary-capable (continuous SpO₂) source.
    ///
    /// - `.reporting` → `.ignorable`: nothing to disclose or end.
    /// - `.absentFromStart` → `.ignorable` for corroborating-only sources
    ///   (`.polarH10`, `.appleWatch`) — the spec's own worked example: "H10
    ///   absent from start on a Watch+EMAY night is fine." `.degradeDisclosed`
    ///   for `.emayOximeter` — arming without the primary source is allowed
    ///   but must be disclosed (decision 5's minimum-bar guardrail).
    /// - `.idle` / `.diedMidSession` → `.endMonitoring` when
    ///   `isOnlyPrimarySource` (the dangerous silent gap: nothing else
    ///   primary-capable remains), else `.degradeDisclosed`. Source-
    ///   independent: any source stopping is disclosed at minimum, and the
    ///   only thing that escalates to ending the session is losing the last
    ///   primary-capable stream.
    static func classify(
        source: CNSSignalSource, state: CNSDeviceState, isOnlyPrimarySource: Bool
    ) -> CNSDeviceStateClassification {
        switch state {
        case .reporting:
            return .ignorable
        case .absentFromStart:
            return source == .emayOximeter ? .degradeDisclosed : .ignorable
        case .idle, .diedMidSession:
            return isOnlyPrimarySource ? .endMonitoring : .degradeDisclosed
        }
    }

    /// Derive a source's state from observation timestamps.
    ///
    /// - No sample yet this session (`lastSample == nil`), or the caller's
    ///   `wasEverReporting` flag disagrees with having a timestamp at all →
    ///   `.absentFromStart`. A `lastSample` that predates `sessionStart` is
    ///   treated the same way: it is stale evidence from a previous session,
    ///   not proof this source has reported yet in the CURRENT one.
    /// - Otherwise, `.diedMidSession` once more than
    ///   `CNSThresholds.standard.gateWindowSeconds` (60s) has elapsed since
    ///   the last sample; `.reporting` while within that window.
    ///
    /// Design note (resolved ambiguity, reported per task escalation
    /// instructions): this function's signature — timestamps only, no source
    /// or cadence — cannot distinguish "idle" (a source that is present but
    /// briefly quiet, e.g. a periodic device between spot-checks) from "died"
    /// (a continuous source that stopped for good). The brief's own worked
    /// example (61s silence after reporting → `.diedMidSession`, not
    /// `.idle`) confirms this function's threshold crossing always resolves
    /// to `.diedMidSession`; `.idle` is intentionally unreachable here and is
    /// reserved for a future cadence-aware derivation (flagged in the plan as
    /// Phase 3/2b work) that knows a given source's *expected* reporting
    /// cadence. `classify(source:state:isOnlyPrimarySource:)` treats both
    /// identically, so this does not change any classification outcome
    /// today — it only affects which of the two equally-classified enum
    /// cases gets reported.
    static func state(
        lastSample: Date?, sessionStart: Date, now: Date, wasEverReporting: Bool
    ) -> CNSDeviceState {
        guard let lastSample, wasEverReporting, lastSample >= sessionStart else {
            return .absentFromStart
        }
        let sinceLastSample = now.timeIntervalSince(lastSample)
        return sinceLastSample > CNSThresholds.standard.gateWindowSeconds ? .diedMidSession : .reporting
    }
}
