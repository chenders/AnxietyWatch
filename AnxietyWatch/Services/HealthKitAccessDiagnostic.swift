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

    /// HealthKit is not available on this device (unsupported hardware or a
    /// restriction). Distinct from `.notRequested`: requesting access can't
    /// fix it, so the banner stays hidden and Settings says so plainly rather
    /// than misclassifying it as "access not granted."
    case unavailable

    /// Whether the proactive Dashboard banner should appear for this state.
    /// Scoped to `.notRequested` and `.likelyRevoked`. While `.likelyRevoked`
    /// carries a small false-positive risk (a genuine 14-day stretch of zero
    /// Watch wear across all metrics), surfacing it proactively is preferred
    /// over a silent freeze, as it routes the user to Settings to fix broken
    /// read access.
    var showsDashboardBanner: Bool {
        self == .notRequested || self == .likelyRevoked
    }
}

/// Pure classifier — no HealthKit, no SwiftData — so the decision logic is
/// exhaustively unit-testable in isolation.
///
/// **Precedence (revised 2026-07-19): a successful data read outranks the
/// ask-status gate.** A read from a foreign-source sample positively proves
/// read access is granted (Design Principle #1: this app is read-only, so every
/// readable sample is Watch/iPhone-authored, never our own write). That ground
/// truth is stronger than `needsRequest`, which is derived from
/// `getRequestStatusForAuthorization` — a flag that answers only "would a sheet
/// appear if I ask," not "is read granted." Verified on-device 2026-07-19: a
/// **full** grant flips that flag to `.unnecessary` (needsRequest=false), but a
/// **partial** grant — any requested type left unresolved — leaves it at
/// `.shouldRequest` (needsRequest=true) *indefinitely*, even while other types
/// read real data. Checking the probe first means such a partial grant resolves
/// to `.receiving` rather than stranding both the Dashboard banner and the
/// `SnapshotAggregator`/`backfill` reduced-pass gate on a store that is, in
/// fact, readable.
///
/// This only changes the `(needsRequest: true, probeReturnedValue: true)` case
/// (now `.receiving` instead of `.notRequested`); every other combination —
/// including the freeze the diagnostic targets (`needsRequest: true`, probe
/// empty → `.notRequested`) — is unchanged.
func evaluateHealthKitAccess(
    needsRequest: Bool,
    probeReturnedValue: Bool,
    hadRecentHistory: Bool,
    watchPaired: Bool,
    graceElapsed: Bool
) -> HealthKitAccessState {
    if probeReturnedValue { return .receiving }
    if needsRequest { return .notRequested }
    if hadRecentHistory && watchPaired && graceElapsed { return .likelyRevoked }
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
        let heartRatePresent: Bool
    }

    /// Rolling window for the presence probe. Wider than a single day so an
    /// early-morning check (before today's sleep / resting HR have landed)
    /// doesn't read as "no data." The 14-day window reduces false positives
    /// for occasional Watch wearers. Steps in particular come from the iPhone
    /// pedometer too, so a non-zero 14-day step count is present for almost
    /// anyone carrying their phone — the strongest single "reads work" signal.
    private static let probeWindowDays = 14

    func run(now: Date, hadRecentHistory: Bool,
             watchPaired: Bool, graceElapsed: Bool) async -> Result {
        if await !source.isHealthDataAvailable() {
            return Result(state: .unavailable, stepsPresent: false, restingHRPresent: false,
                          sleepPresent: false, heartRatePresent: false)
        }
        // Capture the gate but do NOT early-return on it: run the presence probe
        // unconditionally so a *partial* grant that still reads data resolves to
        // `.receiving`. On a genuinely unauthorized store the probe reads just
        // return nothing (HealthKit reports unauthorized reads as "no data"), so
        // the evaluator still returns `.notRequested` — the early-return only
        // saved four cheap queries, at the cost of the false-positive we now fix.
        let needsRequest = await source.authorizationNeedsRequest()

        let windowStart = Calendar.current.date(
            byAdding: .day, value: -Self.probeWindowDays, to: now) ?? now

        let steps = (try? await source.cumulativeQuantity(
            .stepCount, unit: .count(), start: windowStart, end: now)) ?? nil
        let restingHR = (try? await source.averageQuantity(
            .restingHeartRate, unit: .count().unitDivided(by: .minute()),
            start: windowStart, end: now)) ?? nil
        let heartRate = (try? await source.averageQuantity(
            .heartRate, unit: .count().unitDivided(by: .minute()),
            start: windowStart, end: now)) ?? nil
        let sleep = (try? await source.querySleepAnalysis(
            start: windowStart, end: now)) ?? SleepData()

        let stepsPresent = (steps ?? 0) > 0
        let restingHRPresent = restingHR != nil
        let heartRatePresent = heartRate != nil
        let sleepPresent = sleep.totalMinutes > 0

        let state = evaluateHealthKitAccess(
            needsRequest: needsRequest,
            probeReturnedValue: stepsPresent || restingHRPresent || heartRatePresent || sleepPresent,
            hadRecentHistory: hadRecentHistory,
            watchPaired: watchPaired,
            graceElapsed: graceElapsed
        )
        return Result(state: state, stepsPresent: stepsPresent, restingHRPresent: restingHRPresent,
                      sleepPresent: sleepPresent, heartRatePresent: heartRatePresent)
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
