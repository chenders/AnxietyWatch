import Foundation
import HealthKit

/// Classifies whether the app is actually *receiving* HealthKit data, so the
/// silent read-authorization freeze can be surfaced instead of masquerading as
/// "No data."
///
/// The freeze: when HealthKit read authorization is not in the `.unnecessary`
/// request state (fresh install, bundle-ID rename, entitlement change forcing
/// re-provision, or grants toggled off), every ingestion path — `aggregateDay`,
/// `backfillIfNeeded`, Rebuild All History — takes the reduced pass and reads
/// nothing. iOS Settings still shows "Health Data — On", so the failure is
/// invisible. This has frozen ingestion in production twice (2026-07-13,
/// 2026-07-18). See `docs/superpowers/specs/2026-07-18-healthkit-access-diagnostic-design.md`.
enum HealthKitAccessState: Sendable, Equatable {
    /// Reads are returning data — everything is healthy.
    case receiving
    /// The auth gate reports the request sheet has never resolved
    /// (`authorizationNeedsRequest() == true`). Every read will fail; the app
    /// must prompt. This is the exact state both prior incidents were in.
    case notRequested
    /// Auth is determined, yet no read returns anything — but we *did* have
    /// recent data, so grants were most likely revoked. Worth surfacing.
    case likelyRevoked
    /// Auth is determined, no read returns anything, and we never had data.
    /// A legitimately empty / brand-new store — do NOT alarm the user.
    case noDataYet

    /// Whether the proactive Dashboard banner should appear for this state.
    /// Deliberately scoped to `.notRequested` only — the sole unambiguous,
    /// zero-false-positive state (the auth gate is pending, so a prompt is
    /// always correct). `.likelyRevoked` is intentionally excluded from the
    /// banner and surfaced only in Settings → Apple Health, because it can't be
    /// distinguished from a genuine multi-day no-data stretch. Changing this
    /// widens the banner's false-positive surface — see the design doc's
    /// approved scope decision before editing.
    var showsDashboardBanner: Bool {
        self == .notRequested
    }
}

/// Pure classifier — no HealthKit, no SwiftData — so the decision logic is
/// exhaustively unit-testable in isolation. Precedence is deliberate: a pending
/// request dominates (reads can't be trusted), then observed data, then the
/// revoked-vs-empty disambiguation carried by `hadRecentHistory`.
func evaluateHealthKitAccess(
    needsRequest: Bool,
    probeReturnedValue: Bool,
    hadRecentHistory: Bool
) -> HealthKitAccessState {
    if needsRequest { return .notRequested }
    if probeReturnedValue { return .receiving }
    if hadRecentHistory { return .likelyRevoked }
    return .noDataYet
}

/// Runs a live presence probe against HealthKit and classifies the result.
/// Depends only on the injectable `HealthKitDataSource` protocol, so it is
/// fully mockable. `hadRecentHistory` is supplied by the caller (computed from
/// SwiftData via `HealthKitHistoryProbe`) to keep this type HealthKit-only.
struct HealthKitAccessDiagnostic: Sendable {
    let source: HealthKitDataSource

    /// Probe outcome plus the per-signal flags the Settings panel renders.
    struct Result: Sendable, Equatable {
        let state: HealthKitAccessState
        let stepsPresent: Bool
        let restingHRPresent: Bool
        let sleepPresent: Bool
    }

    /// Rolling window for the presence probe. Wider than a single day so an
    /// early-morning check (before today's sleep / resting HR have landed)
    /// doesn't read as "no data." Steps in particular come from the iPhone
    /// pedometer too, so a non-zero 3-day step count is present for anyone
    /// carrying their phone — the strongest single "reads work" signal.
    private static let probeWindowDays = 3

    func run(now: Date, hadRecentHistory: Bool) async -> Result {
        // A pending request dominates: reads would all error with code 5, so
        // don't bother probing — report the gate state and let the caller
        // prompt. This also matches what the Settings panel should show.
        if await source.authorizationNeedsRequest() {
            return Result(state: .notRequested, stepsPresent: false,
                          restingHRPresent: false, sleepPresent: false)
        }

        // Calendar-based window (not `now - N*86400`) so it stays correct
        // across DST transitions — see the date-arithmetic pitfall in CLAUDE.md.
        let windowStart = Calendar.current.date(
            byAdding: .day, value: -Self.probeWindowDays, to: now
        ) ?? now

        let steps = (try? await source.cumulativeQuantity(
            .stepCount, unit: .count(), start: windowStart, end: now)) ?? nil
        let restingHR = (try? await source.averageQuantity(
            .restingHeartRate, unit: .count().unitDivided(by: .minute()),
            start: windowStart, end: now)) ?? nil
        let sleep = (try? await source.querySleepAnalysis(
            start: windowStart, end: now)) ?? SleepData()

        let stepsPresent = (steps ?? 0) > 0
        let restingHRPresent = restingHR != nil
        let sleepPresent = sleep.totalMinutes > 0

        let state = evaluateHealthKitAccess(
            needsRequest: false,
            probeReturnedValue: stepsPresent || restingHRPresent || sleepPresent,
            hadRecentHistory: hadRecentHistory
        )
        return Result(state: state, stepsPresent: stepsPresent,
                      restingHRPresent: restingHRPresent, sleepPresent: sleepPresent)
    }
}

/// Answers "did HealthKit ever give us data recently?" from the local
/// `HealthSnapshot` store. This is the signal that separates a grant revoke
/// (freeze after a history of real data) from a brand-new empty store, so the
/// `.likelyRevoked` verdict never fires on a user who simply has no data yet.
enum HealthKitHistoryProbe {
    /// Default look-back for "recent" history.
    static let defaultWindowDays = 30

    /// True if any snapshot within the window carries a HealthKit-derived
    /// field. Only fields that are essentially always Watch/phone-sourced are
    /// checked — CPAP, barometric, and other non-HealthKit fields must not
    /// count, or a CPAP-only night would mask a revoked HealthKit grant.
    static func hadRecentHealthKitData(
        in snapshots: [HealthSnapshot],
        now: Date,
        windowDays: Int = defaultWindowDays
    ) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: now) ?? now
        return snapshots.contains { snapshot in
            snapshot.date >= cutoff && (
                snapshot.restingHR != nil ||
                snapshot.steps != nil ||
                snapshot.sleepDurationMin != nil ||
                snapshot.respiratoryRate != nil
            )
        }
    }
}
