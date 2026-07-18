import Foundation

// MARK: - OuraService

/// Coordinates Oura Ring cloud data polling, translating IBI readings into
/// `SensorRouter.AnySensorSample.oura(...)` and pushing them into the pipeline.
///
/// ## Lifecycle
/// 1. App obtains OAuth2 tokens via ASWebAuthenticationSession (out of scope
///    for this framework — the app layer handles the OAuth flow).
/// 2. App calls `configure(token:)` to persist the token and prime the client.
/// 3. App calls `startPolling(router:)` to begin periodic IBI fetches.
/// 4. `stopPolling()` pauses the loop; `configure(token:)` can swap tokens
///    without restarting.
///
/// ## Token refresh
/// The service detects 401 responses and calls `onTokenExpired` so the app
/// can use its refresh-token flow. The new token is written back through
/// `configure(token:)` and the failed request is not retried automatically
/// (the next poll interval picks up).
public actor OuraService {

    // MARK: - Dependencies

    private let client: OuraAPIClient
    private let tokenStore: OuraTokenStore
    private let dateFormatter: ISO8601DateFormatter

    /// Polling interval in seconds. Default 5 minutes (Oura rate limit is
    /// ~200 requests/day — 5 min → 288 req/day, comfortable margin).
    private let pollInterval: TimeInterval

    // MARK: - State

    private var pollingTask: Task<Void, Never>?
    private var router: SensorRouter?
    private var currentToken: OuraTokenStore.Token?

    /// Called when the server returns 401. The app should refresh the token
    /// via the Oura OAuth endpoint and call `configure(token:)` with the
    /// new credential.
    public var onTokenExpired: (@Sendable () async -> Void)?

    // MARK: - Init

    public init(
        client: OuraAPIClient = OuraAPIClient(),
        tokenStore: OuraTokenStore = OuraTokenStore(),
        pollInterval: TimeInterval = 300
    ) {
        self.client = client
        self.tokenStore = tokenStore
        self.pollInterval = pollInterval
        self.dateFormatter = ISO8601DateFormatter()

        // Restore persisted token synchronously during init
        if let saved = try? tokenStore.read(), !saved.isExpired {
            self.currentToken = saved
            // Must be set after init — use a detached task
            let clientRef = client
            Task { await clientRef.setAccessToken(saved.accessToken) }
        }
    }

    // MARK: - Configuration

    /// Persist and activate an OAuth2 token. Call after initial auth flow
    /// and after every token refresh. Safe to call while polling.
    public func configure(token: OuraTokenStore.Token) async {
        currentToken = token
        await client.setAccessToken(token.accessToken)

        do {
            try tokenStore.write(token)
        } catch {
            Log.ble.error("OuraService: failed to persist token: \(error)")
        }
    }

    /// True if a non-expired token is currently configured.
    public var isAuthenticated: Bool {
        currentToken != nil && !(currentToken!.isExpired)
    }

    // MARK: - Polling

    /// Start the periodic IBI fetch loop. Idempotent — safe to call multiple
    /// times (subsequent calls are no-ops if already running).
    ///
    /// - Parameter router: The `SensorRouter` whose `push(_:)` method receives
    ///   converted `OuraIBISample` values.
    public func startPolling(router: SensorRouter) async {
        guard pollingTask == nil else { return }
        self.router = router

        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.fetchAndPushIBI()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Stop the polling loop. Idempotent. Does not clear the token.
    public func stopPolling() async {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// True while the polling loop is active.
    public var isPolling: Bool {
        pollingTask != nil && !(pollingTask!.isCancelled)
    }

    // MARK: - Fetch cycle

    private func fetchAndPushIBI() async {
        guard let token = currentToken, !token.isExpired else {
            Log.ble.warning("OuraService: no valid token; skipping poll")
            return
        }

        let now = Date()
        let start = now.addingTimeInterval(-pollInterval - 60) // slight overlap

        let startStr = dateFormatter.string(from: start)
        let endStr = dateFormatter.string(from: now)

        do {
            let ibiData = try await client.fetchIBI(startDate: startStr, endDate: endStr)
            guard let router else { return }

            for entry in ibiData {
                // Only forward valid or raw readings; skip known-bad ones
                if let validity = entry.validity, validity == .bad {
                    continue
                }
                let sample = SensorRouter.AnySensorSample.OuraIBISample(
                    timestamp: entry.timestamp.timeIntervalSince1970,
                    ibiMs: entry.ibi,
                    validity: entry.validity
                )
                await router.push(.oura(sample))
            }

            if !ibiData.isEmpty {
                Log.ble.info("OuraService: pushed \(ibiData.count) IBI sample(s)")
            }
        } catch OuraAPIError.unauthorized {
            Log.ble.warning("OuraService: token expired — calling onTokenExpired")
            await onTokenExpired?()
        } catch OuraAPIError.rateLimited(let tier) {
            Log.ble.warning("OuraService: rate limited (tier: \(tier ?? "unknown")) — backing off")
        } catch {
            Log.ble.error("OuraService: IBI fetch failed: \(error)")
        }
    }

    // MARK: - Manual fetch (for diagnostics / pull-to-refresh)

    /// Fetch daily stress data for the given date range.
    /// - Returns: Array of `OuraStressData`, empty on error.
    public func fetchStress(startDate: Date, endDate: Date) async -> [OuraStressData] {
        guard let _ = currentToken else { return [] }
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        do {
            return try await client.fetchStress(startDate: startStr, endDate: endStr)
        } catch {
            Log.ble.error("OuraService: stress fetch failed: \(error)")
            return []
        }
    }

    /// Fetch daily readiness data for the given date range.
    public func fetchReadiness(startDate: Date, endDate: Date) async -> [OuraReadinessData] {
        guard let _ = currentToken else { return [] }
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        do {
            return try await client.fetchReadiness(startDate: startStr, endDate: endStr)
        } catch {
            Log.ble.error("OuraService: readiness fetch failed: \(error)")
            return []
        }
    }

    /// Fetch sleep data for the given date range.
    public func fetchSleep(startDate: Date, endDate: Date) async -> [OuraSleepData] {
        guard let _ = currentToken else { return [] }
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        do {
            return try await client.fetchSleep(startDate: startStr, endDate: endStr)
        } catch {
            Log.ble.error("OuraService: sleep fetch failed: \(error)")
            return []
        }
    }

    /// Fetch daily resilience data for the given date range.
    public func fetchResilience(startDate: Date, endDate: Date) async -> [OuraResilienceData] {
        guard let _ = currentToken else { return [] }
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        do {
            return try await client.fetchResilience(startDate: startStr, endDate: endStr)
        } catch {
            Log.ble.error("OuraService: resilience fetch failed: \(error)")
            return []
        }
    }
    
    // MARK: - New fetch methods
    
    /// Fetch cardiovascular age data for the given date range.
    public func fetchCardiovascularAge(startDate: Date, endDate: Date) async -> [OuraCardiovascularAgeData] {
        guard let _ = currentToken else { return [] }
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        do {
            return try await client.fetchCardiovascularAge(startDate: startStr, endDate: endStr)
        } catch {
            Log.ble.error("OuraService: cardiovascular age fetch failed: \(error)")
            return []
        }
    }
    
    /// Fetch VO2 max data for the given date range.
    public func fetchVO2Max(startDate: Date, endDate: Date) async -> [OuraVO2MaxData] {
        guard let _ = currentToken else { return [] }
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        do {
            return try await client.fetchVO2Max(startDate: startStr, endDate: endStr)
        } catch {
            Log.ble.error("OuraService: VO2 max fetch failed: \(error)")
            return []
        }
    }
    
    /// Fetch detailed sleep data for the given date range.
    public func fetchSleepDetail(startDate: Date, endDate: Date) async -> [OuraSleepDetailData] {
        guard let _ = currentToken else { return [] }
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        do {
            return try await client.fetchSleepDetail(startDate: startStr, endDate: endStr)
        } catch {
            Log.ble.error("OuraService: sleep detail fetch failed: \(error)")
            return []
        }
    }
    
    /// Fetch daily SpO2 data for the given date range.
    public func fetchDailySpO2(startDate: Date, endDate: Date) async -> [OuraDailySpO2Data] {
        guard let _ = currentToken else { return [] }
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        do {
            return try await client.fetchDailySpO2(startDate: startStr, endDate: endStr)
        } catch {
            Log.ble.error("OuraService: daily SpO2 fetch failed: \(error)")
            return []
        }
    }
    
    /// Fetch daily activity data for the given date range.
    public func fetchDailyActivity(startDate: Date, endDate: Date) async -> [OuraDailyActivityData] {
        guard let _ = currentToken else { return [] }
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        do {
            return try await client.fetchDailyActivity(startDate: startStr, endDate: endStr)
        } catch {
            Log.ble.error("OuraService: daily activity fetch failed: \(error)")
            return []
        }
    }
    
    /// Fetch all new Oura data types for the given date range.
    /// This method coordinates fetching cardiovascular age, VO2 max, sleep detail,
    /// SpO2, and activity data in parallel for efficiency.
    public func fetchAllNewData(startDate: Date, endDate: Date) async -> (
        cardiovascularAge: [OuraCardiovascularAgeData],
        vo2Max: [OuraVO2MaxData],
        sleepDetail: [OuraSleepDetailData],
        dailySpO2: [OuraDailySpO2Data],
        dailyActivity: [OuraDailyActivityData]
    ) {
        // Run all fetches in parallel
        async let cardiovascularAge = fetchCardiovascularAge(startDate: startDate, endDate: endDate)
        async let vo2Max = fetchVO2Max(startDate: startDate, endDate: endDate)
        async let sleepDetail = fetchSleepDetail(startDate: startDate, endDate: endDate)
        async let dailySpO2 = fetchDailySpO2(startDate: startDate, endDate: endDate)
        async let dailyActivity = fetchDailyActivity(startDate: startDate, endDate: endDate)
        
        return (
            cardiovascularAge: await cardiovascularAge,
            vo2Max: await vo2Max,
            sleepDetail: await sleepDetail,
            dailySpO2: await dailySpO2,
            dailyActivity: await dailyActivity
        )
    }
}