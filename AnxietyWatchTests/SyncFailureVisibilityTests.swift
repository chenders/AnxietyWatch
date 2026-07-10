import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Sync-failure visibility: outcome classification, status-line derivation,
/// staleness warning, summary strings, and the failure-notification
/// throttle. Motivated by a real incident where the sync server's ingress
/// was down for over a month and every sync failed silently.
@Suite(.serialized)
struct SyncFailureVisibilityTests {

    // Fixed reference clock — never Date.now in assertions.
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - SyncFailureKind.classify

    @Test("HTTP 401 and 403 classify as authRejected")
    func classifyAuthRejected() {
        #expect(SyncFailureKind.classify(SyncService.SyncError.serverError(401, nil))
            == .authRejected(statusCode: 401))
        #expect(SyncFailureKind.classify(SyncService.SyncError.serverError(403, "forbidden"))
            == .authRejected(statusCode: 403))
    }

    @Test("Other non-2xx statuses classify as httpError with the code")
    func classifyHTTPError() {
        #expect(SyncFailureKind.classify(SyncService.SyncError.serverError(500, "boom"))
            == .httpError(statusCode: 500))
        #expect(SyncFailureKind.classify(SyncService.SyncError.serverError(503, nil))
            == .httpError(statusCode: 503))
    }

    @Test("URLError and SyncError.noConnection classify as networkUnreachable")
    func classifyNetworkUnreachable() {
        #expect(SyncFailureKind.classify(URLError(.cannotConnectToHost)) == .networkUnreachable)
        #expect(SyncFailureKind.classify(URLError(.timedOut)) == .networkUnreachable)
        #expect(SyncFailureKind.classify(SyncService.SyncError.noConnection) == .networkUnreachable)
    }

    @Test("invalidURL and unknown errors classify honestly")
    func classifyInvalidURLAndOther() {
        #expect(SyncFailureKind.classify(SyncService.SyncError.invalidURL) == .invalidURL)
        let unknown = NSError(domain: "TestDomain", code: 42)
        #expect(SyncFailureKind.classify(unknown) == .other)
    }

    @Test("Malformed-URL URLErrors classify as invalidURL, not network")
    func classifyMalformedURLError() {
        #expect(SyncFailureKind.classify(URLError(.badURL)) == .invalidURL)
        #expect(SyncFailureKind.classify(URLError(.unsupportedURL)) == .invalidURL)
    }

    @Test("shortReason names the specific diagnosis, not a generic 'error'")
    func shortReasonSpecificity() {
        #expect(SyncFailureKind.authRejected(statusCode: 401).shortReason.contains("401"))
        #expect(SyncFailureKind.authRejected(statusCode: 401).shortReason.contains("API key"))
        #expect(SyncFailureKind.httpError(statusCode: 500).shortReason.contains("500"))
        #expect(SyncFailureKind.networkUnreachable.shortReason.contains("unreachable"))
        #expect(SyncFailureKind.invalidURL.shortReason.contains("URL"))
        #expect(!SyncFailureKind.other.shortReason.isEmpty)
    }

    // MARK: - SyncRunOutcome

    @Test("reachedServer is true for success and partial, false for failure")
    func outcomeReachedServer() {
        #expect(SyncRunOutcome.success(summary: "ok", finishedAt: Self.t0).reachedServer)
        #expect(SyncRunOutcome.partial(summary: "flag fail", finishedAt: Self.t0).reachedServer)
        #expect(!SyncRunOutcome.failure(
            kind: .networkUnreachable, detail: "down", madeProgress: false, finishedAt: Self.t0
        ).reachedServer)
    }

    @Test("message carries the exact user-facing string for each case")
    func outcomeMessage() {
        #expect(SyncRunOutcome.success(summary: "Synced 1 batch", finishedAt: Self.t0)
            .message == "Synced 1 batch")
        #expect(SyncRunOutcome.partial(summary: "flag fail", finishedAt: Self.t0)
            .message == "flag fail")
        #expect(SyncRunOutcome.failure(kind: .other, detail: "boom", madeProgress: false, finishedAt: Self.t0)
            .message == "boom")
    }

    // MARK: - SyncStatusPresentation.statusLine

    @Test("statusLine is nil when there is no result string")
    func statusLineNil() {
        #expect(SyncStatusPresentation.statusLine(lastResult: nil, outcome: nil) == nil)
    }

    @Test("statusLine without an outcome renders as info")
    func statusLineInfoWithoutOutcome() {
        let line = SyncStatusPresentation.statusLine(lastResult: "Not configured", outcome: nil)
        #expect(line == SyncStatusPresentation.StatusLine(text: "Not configured", style: .info))
    }

    @Test("statusLine styles success, partial, and failure from a matching outcome")
    func statusLineStylesFromMatchingOutcome() {
        let success = SyncStatusPresentation.statusLine(
            lastResult: "Synced 1 batch (2 KB) at 9:00 AM",
            outcome: .success(summary: "Synced 1 batch (2 KB) at 9:00 AM", finishedAt: Self.t0)
        )
        #expect(success?.style == .success)

        let partial = SyncStatusPresentation.statusLine(
            lastResult: "Synced 2 KB, but failed to flag samples",
            outcome: .partial(summary: "Synced 2 KB, but failed to flag samples", finishedAt: Self.t0)
        )
        #expect(partial?.style == .warning)

        let failure = SyncStatusPresentation.statusLine(
            lastResult: "Connection failed — check server URL",
            outcome: .failure(
                kind: .networkUnreachable,
                detail: "Connection failed — check server URL",
                madeProgress: false,
                finishedAt: Self.t0
            )
        )
        #expect(failure?.style == .error)
    }

    @Test("statusLine does NOT paint a newer message with a stale outcome's color")
    func statusLineMismatchFallsBackToInfo() {
        // A previous run failed, then an early return wrote a fresh message
        // (or the drain loop wrote a progress line). The red must not bleed
        // onto the unrelated text.
        let line = SyncStatusPresentation.statusLine(
            lastResult: "Syncing… 2 batches sent (10 records, 4 KB)",
            outcome: .failure(
                kind: .httpError(statusCode: 500), detail: "Server returned 500",
                madeProgress: false, finishedAt: Self.t0
            )
        )
        #expect(line == SyncStatusPresentation.StatusLine(
            text: "Syncing… 2 batches sent (10 records, 4 KB)", style: .info
        ))
    }

    // MARK: - SyncStatusPresentation.stalenessLine

    @Test("Never-synced reads 'Never' and warns only when auto-sync is on")
    func stalenessNeverSynced() {
        let warning = SyncStatusPresentation.stalenessLine(
            lastSuccess: nil, autoSyncEnabled: true, isConfigured: true, now: Self.t0
        )
        #expect(warning == SyncStatusPresentation.StalenessLine(text: "Never", isWarning: true))

        let quiet = SyncStatusPresentation.stalenessLine(
            lastSuccess: nil, autoSyncEnabled: false, isConfigured: true, now: Self.t0
        )
        #expect(quiet == SyncStatusPresentation.StalenessLine(text: "Never", isWarning: false))
    }

    @Test("An unconfigured sync never warns — a user mid-configuration shouldn't see orange")
    func stalenessUnconfiguredNeverWarns() {
        let neverSynced = SyncStatusPresentation.stalenessLine(
            lastSuccess: nil, autoSyncEnabled: true, isConfigured: false, now: Self.t0
        )
        #expect(neverSynced == SyncStatusPresentation.StalenessLine(text: "Never", isWarning: false))

        // A stale timestamp with the config since removed also stays quiet.
        let staleButUnconfigured = SyncStatusPresentation.stalenessLine(
            lastSuccess: Self.t0.addingTimeInterval(-30 * 24 * 3600),
            autoSyncEnabled: true,
            isConfigured: false,
            now: Self.t0
        )
        #expect(!staleButUnconfigured.isWarning)
    }

    @Test("A future last-success (clock rollback) clamps to now and never warns")
    func stalenessFutureClamped() {
        let line = SyncStatusPresentation.stalenessLine(
            lastSuccess: Self.t0.addingTimeInterval(3 * 3600),  // 3h in the future
            autoSyncEnabled: true,
            isConfigured: true,
            now: Self.t0
        )
        #expect(!line.isWarning)
        // Clamped to now → RelativeDateTimeFormatter renders the present,
        // never a nonsensical "in 3 hours".
        #expect(!line.text.isEmpty)
    }

    @Test("A recent success does not warn")
    func stalenessRecentSuccess() {
        let line = SyncStatusPresentation.stalenessLine(
            lastSuccess: Self.t0.addingTimeInterval(-3600),
            autoSyncEnabled: true,
            isConfigured: true,
            now: Self.t0
        )
        #expect(!line.isWarning)
        #expect(!line.text.isEmpty)
    }

    @Test("A success older than 7 days warns only when auto-sync is enabled")
    func stalenessOldSuccess() {
        let eightDaysAgo = Self.t0.addingTimeInterval(-8 * 24 * 3600)

        let autoOn = SyncStatusPresentation.stalenessLine(
            lastSuccess: eightDaysAgo, autoSyncEnabled: true, isConfigured: true, now: Self.t0
        )
        #expect(autoOn.isWarning)

        // Manual-only setups going quiet is deliberate, not an incident.
        let autoOff = SyncStatusPresentation.stalenessLine(
            lastSuccess: eightDaysAgo, autoSyncEnabled: false, isConfigured: true, now: Self.t0
        )
        #expect(!autoOff.isWarning)
    }

    @Test("Staleness threshold boundary: just inside 7 days does not warn, just past does")
    func stalenessBoundary() {
        let threshold = SyncStatusPresentation.staleThreshold
        let justInside = SyncStatusPresentation.stalenessLine(
            lastSuccess: Self.t0.addingTimeInterval(-threshold + 1),
            autoSyncEnabled: true,
            isConfigured: true,
            now: Self.t0
        )
        #expect(!justInside.isWarning)

        let justPast = SyncStatusPresentation.stalenessLine(
            lastSuccess: Self.t0.addingTimeInterval(-threshold - 1),
            autoSyncEnabled: true,
            isConfigured: true,
            now: Self.t0
        )
        #expect(justPast.isWarning)
    }

    // MARK: - SyncRunSummary

    @Test("progressLine pluralizes batches and omits a zero record count")
    func progressLinePhrasing() {
        let single = SyncRunSummary.progressLine(batchesSent: 1, recordsSent: 0, bytesSent: 2048)
        #expect(single.contains("1 batch sent"))
        #expect(!single.contains("record"), "a zero record count would misread as 'nothing synced'")

        let multi = SyncRunSummary.progressLine(batchesSent: 3, recordsSent: 2500, bytesSent: 4096)
        #expect(multi.contains("3 batches sent"))
        #expect(multi.contains("2500 records"))
    }

    @Test("successSummary carries batches, records, and a timestamp")
    func successSummaryPhrasing() {
        let summary = SyncRunSummary.successSummary(
            batches: 2, records: 1500, bytes: 4096, finishedAt: Self.t0
        )
        #expect(summary.hasPrefix("Synced 2 batches"))
        #expect(summary.contains("1500 records"))
        #expect(summary.contains(" at "))

        let single = SyncRunSummary.successSummary(
            batches: 1, records: 1, bytes: 512, finishedAt: Self.t0
        )
        #expect(single.hasPrefix("Synced 1 batch ("))
        #expect(single.contains("1 record,"))
    }

    // MARK: - Failure-notification throttle (pure rule)

    @Test("shouldNotify: first failure always notifies")
    func throttleFirstFailure() {
        #expect(SyncFailureNotifier.shouldNotify(lastNotifiedAt: nil, now: Self.t0))
    }

    @Test("shouldNotify: a failure inside the window is suppressed")
    func throttleSuppressedInsideWindow() {
        let oneHourAgo = Self.t0.addingTimeInterval(-3600)
        #expect(!SyncFailureNotifier.shouldNotify(lastNotifiedAt: oneHourAgo, now: Self.t0))
    }

    @Test("shouldNotify: notifies again once the window has elapsed")
    func throttleReleasesAfterWindow() {
        let window = SyncFailureNotifier.throttleWindow
        #expect(SyncFailureNotifier.shouldNotify(
            lastNotifiedAt: Self.t0.addingTimeInterval(-window), now: Self.t0
        ))
        #expect(!SyncFailureNotifier.shouldNotify(
            lastNotifiedAt: Self.t0.addingTimeInterval(-window + 1), now: Self.t0
        ))
    }

    @Test("shouldNotify: a future last-notified timestamp (clock rollback) notifies rather than suppressing")
    func throttleClockRollback() {
        let inTheFuture = Self.t0.addingTimeInterval(3600)
        #expect(SyncFailureNotifier.shouldNotify(lastNotifiedAt: inTheFuture, now: Self.t0))
    }

    // MARK: - Failure-notification throttle (persisted state, isolated suite)

    private func makeIsolatedDefaults() throws -> (UserDefaults, () -> Void) {
        let suiteName = "SyncFailureVisibilityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test("recordFailureAndDecide posts once per window and re-arms after success")
    @MainActor
    func throttlePersistedLifecycle() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults()
        defer { cleanup() }

        // First failure: notify and stamp the throttle.
        #expect(SyncFailureNotifier.recordFailureAndDecide(defaults: defaults, now: Self.t0))
        #expect(SyncFailureNotifier.lastNotifiedAt(defaults: defaults) == Self.t0)

        // Retry loop an hour later: suppressed, stamp unchanged.
        let retry = Self.t0.addingTimeInterval(3600)
        #expect(!SyncFailureNotifier.recordFailureAndDecide(defaults: defaults, now: retry))
        #expect(SyncFailureNotifier.lastNotifiedAt(defaults: defaults) == Self.t0)

        // Past the window: notify again.
        let later = Self.t0.addingTimeInterval(SyncFailureNotifier.throttleWindow + 60)
        #expect(SyncFailureNotifier.recordFailureAndDecide(defaults: defaults, now: later))
        #expect(SyncFailureNotifier.lastNotifiedAt(defaults: defaults) == later)

        // A success resets the throttle: the very next failure notifies
        // immediately even though the window hasn't elapsed.
        SyncFailureNotifier.recordSuccess(defaults: defaults)
        #expect(SyncFailureNotifier.lastNotifiedAt(defaults: defaults) == nil)
        let rightAfter = later.addingTimeInterval(60)
        #expect(SyncFailureNotifier.recordFailureAndDecide(defaults: defaults, now: rightAfter))
    }

    // MARK: - Consecutive-partial escalation (persisted state, isolated suite)

    @Test("Partial escalation: two consecutive partials stay quiet, the third notifies under the throttle")
    func partialEscalationLifecycle() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults()
        defer { cleanup() }

        // 1st and 2nd consecutive partials: quiet by design.
        #expect(!SyncFailureNotifier.recordPartialAndDecide(defaults: defaults, now: Self.t0))
        #expect(!SyncFailureNotifier.recordPartialAndDecide(
            defaults: defaults, now: Self.t0.addingTimeInterval(3600)
        ))
        #expect(SyncFailureNotifier.partialStreak(defaults: defaults) == 2)

        // 3rd: escalates and stamps the shared 12h throttle.
        let third = Self.t0.addingTimeInterval(7200)
        #expect(SyncFailureNotifier.recordPartialAndDecide(defaults: defaults, now: third))

        // 4th, inside the window: past the threshold but throttled.
        #expect(!SyncFailureNotifier.recordPartialAndDecide(
            defaults: defaults, now: third.addingTimeInterval(3600)
        ))

        // Still failing past the window: re-notifies once per window.
        #expect(SyncFailureNotifier.recordPartialAndDecide(
            defaults: defaults, now: third.addingTimeInterval(SyncFailureNotifier.throttleWindow)
        ))
    }

    @Test("A full success resets the partial streak and the throttle together")
    func successResetsPartialStreakAndThrottle() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults()
        defer { cleanup() }

        // Drive to an escalated state.
        for hour in 0..<3 {
            _ = SyncFailureNotifier.recordPartialAndDecide(
                defaults: defaults, now: Self.t0.addingTimeInterval(Double(hour) * 3600)
            )
        }
        try #require(SyncFailureNotifier.partialStreak(defaults: defaults) == 3)

        SyncFailureNotifier.recordSuccess(defaults: defaults)
        #expect(SyncFailureNotifier.partialStreak(defaults: defaults) == 0)
        #expect(SyncFailureNotifier.lastNotifiedAt(defaults: defaults) == nil)

        // Post-reset: the count starts over — two partials stay quiet, and
        // the third notifies immediately (throttle was re-armed too).
        let after = Self.t0.addingTimeInterval(24 * 3600)
        #expect(!SyncFailureNotifier.recordPartialAndDecide(defaults: defaults, now: after))
        #expect(!SyncFailureNotifier.recordPartialAndDecide(
            defaults: defaults, now: after.addingTimeInterval(60)
        ))
        #expect(SyncFailureNotifier.recordPartialAndDecide(
            defaults: defaults, now: after.addingTimeInterval(120)
        ))
    }

    @Test("A hard failure breaks the consecutive-partial streak")
    func failureResetsPartialStreak() throws {
        let (defaults, cleanup) = try makeIsolatedDefaults()
        defer { cleanup() }

        #expect(!SyncFailureNotifier.recordPartialAndDecide(defaults: defaults, now: Self.t0))
        #expect(!SyncFailureNotifier.recordPartialAndDecide(defaults: defaults, now: Self.t0))

        // handle(.failure) calls this before its own throttle check — the
        // streak must be *consecutive* partials, not "partials since ever".
        SyncFailureNotifier.resetPartialStreak(defaults: defaults)
        #expect(SyncFailureNotifier.partialStreak(defaults: defaults) == 0)

        // Two more partials are again below the threshold.
        #expect(!SyncFailureNotifier.recordPartialAndDecide(defaults: defaults, now: Self.t0))
        #expect(!SyncFailureNotifier.recordPartialAndDecide(defaults: defaults, now: Self.t0))
    }

    // MARK: - Notification content

    @Test("Failure body names the reason; mid-drain progress softens the data-stays-local claim")
    func notificationBodyVariants() {
        let clean = SyncFailureNotifier.notificationBody(
            reason: "server unreachable", madeProgress: false
        )
        #expect(clean == "AnxietyWatch sync failed: server unreachable. "
            + "Data stays on this phone until a sync succeeds.")

        let progressed = SyncFailureNotifier.notificationBody(
            reason: "server unreachable", madeProgress: true
        )
        #expect(progressed == "AnxietyWatch sync failed: server unreachable. "
            + "Some data uploaded before the failure; "
            + "the rest stays on this phone until a sync succeeds.")

        #expect(!SyncFailureNotifier.notificationTitle.isEmpty)
    }

    @Test("Partial-escalation body admits the server IS receiving data")
    func partialEscalationBodyHonesty() {
        // "Sync failed" would be false for a partial — the failure is local
        // bookkeeping, and the body must say so.
        #expect(SyncFailureNotifier.partialEscalationBody.contains("reaching the server"))
        #expect(SyncFailureNotifier.partialEscalationBody.contains("re-uploading"))
        #expect(!SyncFailureNotifier.escalationTitle.isEmpty)
    }

    // MARK: - sync() outcome plumbing (injected transport, no live network)

    private static let syncKeys = [
        "syncServerURL", "syncApiKey", "syncAutoEnabled", "lastSyncDate", "lastSyncSuccessDate",
    ]

    /// Save current UserDefaults values and return a restore closure —
    /// same pattern as SyncServiceTests.
    private func saveSyncDefaults() -> (() -> Void) {
        let saved = Self.syncKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        return {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    /// Configure standard defaults for an injected-transport sync run.
    /// 127.0.0.1:1 makes the incidental SongService catalog pull fail fast;
    /// the /api/sync POST is served by the injected transport.
    private func configureFictionalServer() {
        UserDefaults.standard.set("http://127.0.0.1:1", forKey: "syncServerURL")
        UserDefaults.standard.set("test-key", forKey: "syncApiKey")
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")
        UserDefaults.standard.removeObject(forKey: "lastSyncSuccessDate")
    }

    /// A strictly-increasing fake clock (1h per read), mirroring
    /// SyncServiceTests.incrementingClock.
    @MainActor
    private func incrementingClock(from base: Date) -> (@MainActor () -> Date) {
        var tick = 0
        return {
            defer { tick += 1 }
            return base.addingTimeInterval(Double(tick) * 3600)
        }
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:1/api/sync")!,
            statusCode: status, httpVersion: nil, headerFields: nil
        )!
    }

    @Test("A successful sync records a success outcome, advances lastSyncSuccessDate, and calls the handler")
    @MainActor
    func syncSuccessOutcome() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        configureFictionalServer()

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()
        var received: [SyncRunOutcome] = []
        service.outcomeHandler = { received.append($0) }

        await service.sync(
            modelContext: context,
            now: incrementingClock(from: Self.t0),
            performRequest: { _ in (Data("{}".utf8), self.response(status: 200)) }
        )

        // Clock reads: cursor upper bound (t0), then finishedAt (t0 + 1h).
        let expectedFinish = Self.t0.addingTimeInterval(3600)
        guard case .success(let summary, let finishedAt)? = service.lastRunOutcome else {
            Issue.record("expected a success outcome, got \(String(describing: service.lastRunOutcome))")
            return
        }
        #expect(finishedAt == expectedFinish)
        #expect(summary == service.lastSyncResult)
        #expect(service.lastSyncSuccessDate == expectedFinish)
        #expect(service.lastKnownSuccessDate == expectedFinish)
        #expect(received.count == 1)
        #expect(received.first == service.lastRunOutcome)
    }

    @Test("A failing flag flip in a LIVE sync yields a partial outcome that advances lastSyncSuccessDate")
    @MainActor
    func syncPartialOutcome() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        configureFictionalServer()

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()
        var received: [SyncRunOutcome] = []
        service.outcomeHandler = { received.append($0) }

        struct FlagFlipError: Error {}
        await service.sync(
            modelContext: context,
            now: incrementingClock(from: Self.t0),
            performRequest: { _ in (Data("{}".utf8), self.response(status: 200)) },
            markSamples: { _, _ in throw FlagFlipError() }
        )

        // Clock reads: cursor upper bound (t0), then finishedAt (t0 + 1h).
        let expectedFinish = Self.t0.addingTimeInterval(3600)
        guard case .partial(let summary, let finishedAt)? = service.lastRunOutcome else {
            Issue.record("expected a partial outcome, got \(String(describing: service.lastRunOutcome))")
            return
        }
        #expect(finishedAt == expectedFinish)
        #expect(summary == service.lastSyncResult)
        #expect(summary.contains("failed to flag samples"))
        // The upload verifiably reached the server, so the staleness anchor
        // advances even though the local flag flip failed…
        #expect(service.lastSyncSuccessDate == expectedFinish)
        // …and the typed outcome reaches the notifier hook exactly once, so
        // the consecutive-partial escalation counts real runs.
        #expect(received.count == 1)
        #expect(received.first == service.lastRunOutcome)
    }

    @Test("A mid-drain failure reports madeProgress so the notification body can't overclaim")
    @MainActor
    func syncMidDrainFailureReportsProgress() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        configureFictionalServer()

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        // Exactly the bulk cap (1000) of HRV readings: iteration 0 fills the
        // batch, forcing a second round trip that the transport then fails.
        let session = SensorSession(startTime: Self.t0, batteryAtStart: 90)
        context.insert(session)
        for i in 0..<1000 {
            context.insert(HRVReading(
                timestamp: Self.t0.addingTimeInterval(Double(i)),
                rmssd: 30, sdnn: 40, pnn50: 10,
                lfPower: 100, hfPower: 200, lfHfRatio: 0.5,
                sensorSessionID: session.id, source: PolarHRMService.sourceLabel
            ))
        }
        try context.save()

        let service = SyncService()
        var calls = 0
        await service.sync(
            modelContext: context,
            now: incrementingClock(from: Self.t0),
            performRequest: { _ in
                calls += 1
                if calls == 1 { return (Data("{}".utf8), self.response(status: 200)) }
                throw URLError(.networkConnectionLost)
            }
        )

        guard case .failure(let kind, let detail, let madeProgress, _)? = service.lastRunOutcome else {
            Issue.record("expected a failure outcome, got \(String(describing: service.lastRunOutcome))")
            return
        }
        #expect(kind == .networkUnreachable)
        #expect(madeProgress, "one batch committed before the failure — the body must admit it")
        #expect(detail == "Synced 1 batch, then connection failed — will retry")
    }

    @Test("A network failure records failure(networkUnreachable) and does not advance lastSyncSuccessDate")
    @MainActor
    func syncNetworkFailureOutcome() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        configureFictionalServer()

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()
        var received: [SyncRunOutcome] = []
        service.outcomeHandler = { received.append($0) }

        await service.sync(
            modelContext: context,
            now: incrementingClock(from: Self.t0),
            performRequest: { _ in throw URLError(.cannotConnectToHost) }
        )

        guard case .failure(let kind, let detail, let madeProgress, _)? = service.lastRunOutcome else {
            Issue.record("expected a failure outcome, got \(String(describing: service.lastRunOutcome))")
            return
        }
        #expect(kind == .networkUnreachable)
        #expect(detail == "Connection failed — check server URL")
        #expect(detail == service.lastSyncResult)
        #expect(!madeProgress, "no round trip committed, so the body may claim all data stayed local")
        #expect(service.lastSyncSuccessDate == nil)
        #expect(received.count == 1)
    }

    @Test("An auth rejection surfaces as failure(authRejected) with the HTTP status")
    @MainActor
    func syncAuthFailureOutcome() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        configureFictionalServer()

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()

        await service.sync(
            modelContext: context,
            now: incrementingClock(from: Self.t0),
            performRequest: { _ in (Data("denied".utf8), self.response(status: 401)) }
        )

        guard case .failure(let kind, let detail, _, _)? = service.lastRunOutcome else {
            Issue.record("expected a failure outcome, got \(String(describing: service.lastRunOutcome))")
            return
        }
        #expect(kind == .authRejected(statusCode: 401))
        #expect(detail.contains("401"))
        #expect(service.lastSyncSuccessDate == nil)
    }

    @Test("A server error surfaces as failure(httpError) with the HTTP status")
    @MainActor
    func syncServerErrorOutcome() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        configureFictionalServer()

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()

        await service.sync(
            modelContext: context,
            now: incrementingClock(from: Self.t0),
            performRequest: { _ in (Data("boom".utf8), self.response(status: 500)) }
        )

        guard case .failure(let kind, _, _, _)? = service.lastRunOutcome else {
            Issue.record("expected a failure outcome, got \(String(describing: service.lastRunOutcome))")
            return
        }
        #expect(kind == .httpError(statusCode: 500))
        #expect(service.lastSyncResult?.contains("500") == true)
    }

    @Test("The not-configured early return records no run outcome and calls no handler")
    @MainActor
    func syncEarlyReturnRecordsNoOutcome() async throws {
        let restore = saveSyncDefaults()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: "syncServerURL")
        UserDefaults.standard.removeObject(forKey: "syncApiKey")

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let service = SyncService()
        var handlerCalls = 0
        service.outcomeHandler = { _ in handlerCalls += 1 }

        await service.sync(modelContext: context)

        #expect(service.lastRunOutcome == nil)
        #expect(handlerCalls == 0)
        #expect(service.lastSyncResult == "Not configured")
    }

    @Test("lastSyncSuccessDate persists through UserDefaults across instances")
    func lastSyncSuccessDateRoundTrip() {
        let restore = saveSyncDefaults()
        defer { restore() }

        SyncService().lastSyncSuccessDate = Date(timeIntervalSince1970: 1_711_300_000)
        #expect(SyncService().lastSyncSuccessDate?.timeIntervalSince1970 == 1_711_300_000)

        SyncService().lastSyncSuccessDate = nil
        #expect(SyncService().lastSyncSuccessDate == nil)
    }

    @Test("lastKnownSuccessDate falls back to the cursor for pre-feature installs")
    func lastKnownSuccessDateFallback() {
        let restore = saveSyncDefaults()
        defer { restore() }

        // Pre-feature install: cursor exists, success timestamp doesn't.
        UserDefaults.standard.set(
            Date(timeIntervalSince1970: 1_711_300_000).timeIntervalSince1970,
            forKey: "lastSyncDate"
        )
        UserDefaults.standard.removeObject(forKey: "lastSyncSuccessDate")
        #expect(SyncService().lastKnownSuccessDate?.timeIntervalSince1970 == 1_711_300_000)

        // Neither: never synced.
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")
        #expect(SyncService().lastKnownSuccessDate == nil)
    }
}
