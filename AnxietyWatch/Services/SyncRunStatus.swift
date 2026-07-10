import Foundation

/// Typed outcome of one completed `SyncService.sync()` run.
///
/// `SyncService.lastSyncResult` remains the raw user-facing string (existing
/// call sites and tests read it); this enum is the machine-readable companion
/// so the settings UI and the failure notifier don't have to string-match
/// "failed"/"error" to know what happened. Motivated by a real incident: the
/// sync server's ingress was down for over a month and every sync failed with
/// nothing in the app saying so.
enum SyncRunOutcome: Equatable {
    /// Every round trip returned 2xx and post-upload flagging succeeded.
    case success(summary: String, finishedAt: Date)

    /// Data reached the server, but a post-upload step failed (e.g. flagging
    /// rows as synced) — the affected rows re-send next sync. Connectivity is
    /// proven, so staleness logic treats this as "server received data",
    /// while the UI renders it as a warning.
    ///
    /// Notification policy: a single or occasional partial stays quiet — but
    /// a *persistent* run of partials is the silent-failure mode relocated
    /// (a permanently failing flag flip means the same rows re-upload
    /// forever and nothing ever fully succeeds), so `SyncFailureNotifier`
    /// escalates after `partialEscalationThreshold` consecutive partials,
    /// under the same 12h throttle. Only a full success resets the streak.
    case partial(summary: String, finishedAt: Date)

    /// The run aborted before (or while) reaching the server. `detail` is the
    /// full user-facing message; `kind` is the classified short diagnosis.
    /// `madeProgress` is true when earlier round trips of this run committed
    /// before the failure — the notification body must not claim ALL data
    /// stayed on the phone in that case.
    case failure(kind: SyncFailureKind, detail: String, madeProgress: Bool, finishedAt: Date)

    /// The user-facing message for this outcome — always the exact string the
    /// run wrote to `lastSyncResult`, which is what lets
    /// `SyncStatusPresentation.statusLine` match the two up for styling.
    var message: String {
        switch self {
        case .success(let summary, _), .partial(let summary, _):
            return summary
        case .failure(_, let detail, _, _):
            return detail
        }
    }

    /// True when data reached the server (success or partial). Drives the
    /// `lastSyncSuccessDate` advance.
    var reachedServer: Bool {
        if case .failure = self { return false }
        return true
    }

    var finishedAt: Date {
        switch self {
        case .success(_, let date), .partial(_, let date), .failure(_, _, _, let date):
            return date
        }
    }
}

/// Classified diagnosis of a failed sync run — the three things a user can
/// act on are deliberately distinct: bad credentials, a server-side error
/// (HTTP status), and no route to the server at all (the silent
/// month-long-outage case).
enum SyncFailureKind: Equatable {
    /// HTTP 401/403 — the server answered but rejected the API key.
    case authRejected(statusCode: Int)
    /// Any other non-2xx HTTP status.
    case httpError(statusCode: Int)
    /// No HTTP response at all: DNS, refused connection, timeout, offline.
    case networkUnreachable
    case invalidURL
    case other

    static func classify(_ error: Error) -> SyncFailureKind {
        if let syncError = error as? SyncService.SyncError {
            switch syncError {
            case .serverError(let code, _):
                return code == 401 || code == 403
                    ? .authRejected(statusCode: code)
                    : .httpError(statusCode: code)
            case .noConnection:
                return .networkUnreachable
            case .invalidURL:
                return .invalidURL
            case .notConfigured:
                return .other
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL:
                // A malformed endpoint is a configuration fault, not a
                // transient connectivity problem — don't tell the user to
                // check their network when the URL itself is wrong.
                return .invalidURL
            default:
                return .networkUnreachable
            }
        }
        return .other
    }

    /// Short, honest reason used in the failure notification body.
    var shortReason: String {
        switch self {
        case .authRejected(let code):
            return "server rejected the API key (HTTP \(code))"
        case .httpError(let code):
            return "server error (HTTP \(code))"
        case .networkUnreachable:
            return "server unreachable"
        case .invalidURL:
            return "invalid server URL"
        case .other:
            return "sync error"
        }
    }
}

/// Builds the drain-loop progress and final success strings for
/// `SyncService.sync()`. Extracted so the record/batch/byte phrasing is
/// unit-testable rather than buried in the drain loop.
enum SyncRunSummary {
    /// In-flight status after each completed round trip: how many batches
    /// have landed and how much data they carried. `records` counts the
    /// bulk-type rows (samples, sessions, readings, snapshots) the payloads
    /// contained — the cheaply-countable majority of sync volume; the
    /// small-volume tables ride along uncounted, so the clause is omitted
    /// when zero rather than showing a misleading "0 records".
    static func progressLine(batchesSent: Int, recordsSent: Int, bytesSent: Int) -> String {
        "Syncing… \(batchesSent) \(batchWord(batchesSent)) sent (\(sizeClause(recordsSent, bytesSent)))"
    }

    /// Final status for a fully successful run, timestamped so a stale
    /// message can't masquerade as a fresh one.
    static func successSummary(batches: Int, records: Int, bytes: Int, finishedAt: Date) -> String {
        let time = finishedAt.formatted(.dateTime.hour().minute())
        return "Synced \(batches) \(batchWord(batches)) (\(sizeClause(records, bytes))) at \(time)"
    }

    private static func batchWord(_ n: Int) -> String {
        n == 1 ? "batch" : "batches"
    }

    private static func sizeClause(_ records: Int, _ bytes: Int) -> String {
        let bytesFmt = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        guard records > 0 else { return bytesFmt }
        return "\(records) record\(records == 1 ? "" : "s"), \(bytesFmt)"
    }
}

/// Pure presentation derivation for `SyncSettingsView`'s Status section.
/// Kept out of the view body per the CLAUDE.md testability rule.
enum SyncStatusPresentation {
    /// Last-success age beyond which the "Last successful sync" row warns —
    /// but only when auto-sync is enabled: a manual-only setup going quiet
    /// is deliberate, an auto-syncing one going quiet is the incident.
    static let staleThreshold: TimeInterval = 7 * 24 * 60 * 60

    struct StatusLine: Equatable {
        let text: String
        let style: Style

        enum Style {
            case info, success, warning, error
        }
    }

    /// Derive the status row shown under the sync buttons.
    ///
    /// The `outcome` only styles the line when its message is the string
    /// currently displayed — that guards against painting an early-return
    /// message ("Not configured", "Sync already in progress") or an
    /// in-flight "Syncing…" progress line with a *previous* run's color.
    static func statusLine(lastResult: String?, outcome: SyncRunOutcome?) -> StatusLine? {
        guard let lastResult else { return nil }
        guard let outcome, outcome.message == lastResult else {
            return StatusLine(text: lastResult, style: .info)
        }
        switch outcome {
        case .success:
            return StatusLine(text: lastResult, style: .success)
        case .partial:
            return StatusLine(text: lastResult, style: .warning)
        case .failure:
            return StatusLine(text: lastResult, style: .error)
        }
    }

    struct StalenessLine: Equatable {
        let text: String
        let isWarning: Bool
    }

    /// "Last successful sync" row. `lastSuccess` is the last time data
    /// verifiably reached the server (`SyncService.lastKnownSuccessDate`);
    /// nil reads as "Never". Warns when auto-sync is enabled, the sync is
    /// actually configured (a user mid-configuration shouldn't see an
    /// orange "Never" for a server they haven't finished entering), and
    /// the server hasn't received data within `staleThreshold` — including
    /// the never-synced case, which is staler than any timestamp.
    static func stalenessLine(
        lastSuccess: Date?,
        autoSyncEnabled: Bool,
        isConfigured: Bool,
        now: Date
    ) -> StalenessLine {
        let warningsArmed = autoSyncEnabled && isConfigured
        guard let lastSuccess else {
            return StalenessLine(text: "Never", isWarning: warningsArmed)
        }
        // Clamp a future last-success to `now`: a device clock rolled back
        // after a sync would otherwise render "in 3 hours", which is
        // nonsensical for a staleness indicator. A clamped value reads as
        // "just now" and never trips the stale warning (elapsed ≤ 0).
        let elapsed = max(0, now.timeIntervalSince(lastSuccess))
        let effectiveSuccess = min(lastSuccess, now)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let text = formatter.localizedString(for: effectiveSuccess, relativeTo: now)
        let isStale = elapsed > staleThreshold
        return StalenessLine(text: text, isWarning: warningsArmed && isStale)
    }
}
