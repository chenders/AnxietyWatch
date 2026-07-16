import Foundation
import GRDB

/// Hybrid Logical Clock service (Spec §2.1, Kulkarni et al. "Logical Physical
/// Clocks and Consistent Snapshots in Globally Distributed Databases").
///
/// Guarantees:
/// - `now()` is strictly monotonic on this node under the `HLCStamped`
///   comparator, even when the wall clock is frozen or steps backwards.
/// - `observe(_:)` merges remote HLCs so causality is preserved: the returned
///   local view is always > the (clamped) remote and > every prior local value.
/// - Bounded merge: local physical never advances more than 60 s past the local
///   wall clock, no matter how far ahead a remote's clock runs. The caller
///   persists the *incoming* HLC values unchanged, so peer causal history is
///   not corrupted by the clamp.
/// - Drift beyond 24 h throws `HLCError.driftExceeded`; the caller
///   (SyncCoordinator) must quarantine the row to `_sync_quarantine`.
public actor HLC {
    public enum HLCError: Error, Sendable, Equatable {
        case driftExceeded(driftMillis: Int64)
        case invalidRemote(String)
    }

    // MARK: - Synchronous clock core

    /// The actual clock state, lock-protected so it can be driven both from the
    /// actor's methods and — synchronously — from SQLite UDF bodies, which
    /// cannot `await` into an actor.
    private final class Core: @unchecked Sendable {
        private let lock = NSLock()
        private var physical: Int64 = 0
        private var logical: Int32 = 0

        let nodeID: Data
        private let wallNow: @Sendable () -> Int64
        private let monotonicNow: @Sendable () -> Int64

        init(
            nodeID: Data,
            wallNow: @escaping @Sendable () -> Int64,
            monotonicNow: @escaping @Sendable () -> Int64
        ) {
            self.nodeID = nodeID
            self.wallNow = wallNow
            self.monotonicNow = monotonicNow
        }

        /// Kulkarni send/local event:
        ///   pt' = max(local.pt, wall, boot_anchored_monotonic)
        ///   lc' = (pt' == local.pt) ? local.lc + 1 : 0
        func now() -> HLCStamped {
            lock.lock()
            defer { lock.unlock() }

            let wall = wallNow()
            let mono = monotonicNow()
            let candidate = max(physical, max(wall, mono))
            if candidate == physical {
                logical += 1
            } else {
                physical = candidate
                logical = 0
            }
            return HLCStamped(physical: physical, logical: logical, nodeID: nodeID)
        }

        /// Kulkarni receive event with bounded merge + drift quarantine gate.
        func observe(_ remote: HLCStamped) throws -> HLCStamped {
            guard remote.physical >= 0, remote.logical >= 0 else {
                throw HLCError.invalidRemote(
                    "negative HLC components (pt: \(remote.physical), lc: \(remote.logical))"
                )
            }
            guard !remote.nodeID.isEmpty else {
                throw HLCError.invalidRemote("empty nodeID")
            }

            lock.lock()
            defer { lock.unlock() }

            let wall = wallNow()
            let drift = remote.physical - wall
            if drift > 86_400_000 {
                // > 24 h ahead: refuse to merge; caller quarantines the row.
                throw HLCError.driftExceeded(driftMillis: drift)
            }

            // Bounded merge: never let a fast remote clock drag local physical
            // more than 60 s past the local wall clock.
            let clampedRemotePhysical = min(remote.physical, wall + 60_000)

            let candidate = max(physical, max(clampedRemotePhysical, wall))
            if candidate == physical && candidate == clampedRemotePhysical {
                logical = max(logical, remote.logical) + 1
            } else if candidate == physical {
                logical += 1
            } else if candidate == clampedRemotePhysical {
                logical = remote.logical + 1
            } else {
                logical = 0
            }
            physical = candidate
            return HLCStamped(physical: physical, logical: logical, nodeID: nodeID)
        }

        var current: HLCStamped {
            lock.lock()
            defer { lock.unlock() }
            return HLCStamped(physical: physical, logical: logical, nodeID: nodeID)
        }
    }

    // MARK: - State

    private let core: Core

    // MARK: - Init

    /// - Parameters:
    ///   - nodeID: 16 bytes; MUST come from Keychain in production (§2.1).
    ///     Keychain loading is a follow-up task (T13a); injectable here for tests.
    ///   - now: wall clock in ms since Unix epoch (injectable for tests).
    ///   - monotonicNow: boot-anchored monotonic clock in ms since Unix epoch
    ///     (injectable for tests). Guards `now()` against wall-clock steps back.
    public init(
        nodeID: Data,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        monotonicNow: @escaping @Sendable () -> Int64 = { HLC.defaultMonotonic() }
    ) {
        // Fail fast in debug on a mis-width node ID. Production keeps the type
        // width-agnostic (Data) so a future migration to a different length can
        // land without breaking the ABI, but the 16-byte contract is load-bearing
        // for the SchemaV1.samples.node_id BLOB and the wire codec (§5.1).
        assert(nodeID.count == 16,
               "HLC nodeID must be 16 raw bytes; got \(nodeID.count). See HLCStamped.nodeID.")
        self.core = Core(nodeID: nodeID, wallNow: now, monotonicNow: monotonicNow)
    }

    // MARK: - Public API

    /// Kulkarni HLC now(). Returns a fresh HLCStamped guaranteed to be strictly
    /// greater than every prior returned value on this node AND greater than
    /// every observed remote merged so far (bounded merge).
    public func now() -> HLCStamped {
        core.now()
    }

    /// Merge a remote HLC into the local clock.
    /// - If (remote.physical - localWallNow) > 86_400_000: throws
    ///   `HLCError.driftExceeded` — the caller (SyncCoordinator) must
    ///   quarantine to `_sync_quarantine`.
    /// - If (remote.physical - localWallNow) > 60_000: bounded merge — local
    ///   physical does NOT advance past localWallNow + 60_000. The caller
    ///   persists the event with the incoming HLC unchanged so peer causal
    ///   history isn't corrupted.
    /// - Otherwise: normal Kulkarni merge. Returns the freshly minted local
    ///   view (which the caller can persist alongside the remote value).
    @discardableResult
    public func observe(_ remote: HLCStamped) throws -> HLCStamped {
        try core.observe(remote)
    }

    /// Local view accessor (for tests + diagnostics). Does not tick the clock.
    public var currentLocal: HLCStamped {
        core.current
    }

    // MARK: - SQLite UDFs

    /// Registers ONE non-deterministic 0-arg UDF `hlc_now_json()` which mints
    /// a fresh HLC on EACH invocation and returns it as a JSON string:
    ///
    ///     {"pt":<Int64>,"lc":<Int32>,"n":"<32 lowercase hex chars = 16 raw bytes>"}
    ///
    /// T16 CONTRACT — the @Syncable macro-generated triggers MUST evaluate
    /// `hlc_now_json()` exactly once per row via the scalar-subquery pattern
    /// and extract the three fields with `json_extract()`:
    ///
    ///     CREATE TRIGGER trg_x AFTER INSERT ON x BEGIN
    ///         INSERT INTO _sync_log(table_name, row_pk, hlc_physical, hlc_logical, node_id, operation)
    ///             SELECT 'x', NEW.pk,
    ///                    json_extract(h, '$.pt'),
    ///                    json_extract(h, '$.lc'),
    ///                    unhex(json_extract(h, '$.n')),
    ///                    'upsert'
    ///               FROM (SELECT hlc_now_json() AS h);
    ///     END;
    ///
    /// Because `hlc_now_json` is non-deterministic (`pure: false`) and lives
    /// inside a scalar subquery, SQLite materializes the subquery once per
    /// outer row, guaranteeing all three extracts see the SAME stamp — with
    /// no dependency on SQLite's (uncontracted) evaluation order of scalar
    /// sub-expressions. Do NOT call `hlc_now_json()` multiple times directly
    /// in the column list: each call mints a fresh stamp and the row would
    /// store mismatched (physical, logical) — silent causal corruption.
    ///
    /// node_id travels as lowercase hex (not base64) so triggers can convert
    /// it back to a 16-byte BLOB with SQLite's `unhex()` (available since
    /// SQLite 3.41; iOS 17 ships 3.43+).
    public func registerUDFs(on dbManager: DatabaseManager) async throws {
        let core = self.core

        try await dbManager.registerFunction(name: "hlc_now_json", argumentCount: 0, pure: false) { _ in
            let stamp = core.now()
            return "{\"pt\":\(stamp.physical),\"lc\":\(stamp.logical),\"n\":\"\(stamp.nodeID.hlcHexString)\"}"
        }
    }

    // MARK: - Default monotonic clock

    /// Boot-anchored monotonic milliseconds mapped into the Unix epoch: the
    /// wall clock is sampled ONCE per process and subsequently advanced only
    /// by the monotonic clock, so it can never step backwards even if the user
    /// (or NTP) rewinds the system clock.
    public static func defaultMonotonic() -> Int64 {
        anchor.wallMillis + Int64((DispatchTime.now().uptimeNanoseconds - anchor.monoNanos) / 1_000_000)
    }

    private static let anchor: (wallMillis: Int64, monoNanos: UInt64) = (
        wallMillis: Int64(Date().timeIntervalSince1970 * 1000),
        monoNanos: DispatchTime.now().uptimeNanoseconds
    )
}

extension Data {
    /// Lowercase hex encoding used by `hlc_now_json()` for the 16-byte node ID.
    var hlcHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
