import Foundation
import Testing
@testable import AnxietyWatchKit

@Suite struct OuraServiceTests {

    /// `OuraService`'s default `tokenStore` is the real keychain, so a bare
    /// `OuraService()` restores whatever token the host machine happens to have
    /// persisted (see `OuraService.init`). Every service test must inject a
    /// store scoped to a unique service name or it passes on empty CI and fails
    /// on a developer machine that has authenticated against Oura for real.
    private func isolatedService(pollInterval: TimeInterval = 300) -> OuraService {
        OuraService(
            tokenStore: isolatedTokenStore(),
            pollInterval: pollInterval
        )
    }

    private func isolatedTokenStore(account: String = "test") -> OuraTokenStore {
        OuraTokenStore(service: "com.test.oura.\(UUID().uuidString)", account: account)
    }

    // MARK: - OuraService lifecycle

    @Test func serviceStartsWithoutToken() async {
        let service = isolatedService()
        let authed = await service.isAuthenticated
        #expect(authed == false)
    }

    @Test func configureTokenSetsAuthenticated() async {
        let service = isolatedService()
        let token = OuraTokenStore.Token(
            accessToken: "test-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3600)
        )

        await service.configure(token: token)
        let authed = await service.isAuthenticated
        #expect(authed)
    }

    @Test func expiredTokenIsNotAuthenticated() async {
        let service = isolatedService()
        let token = OuraTokenStore.Token(
            accessToken: "test-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(-60) // already expired
        )

        await service.configure(token: token)
        let authed = await service.isAuthenticated
        #expect(authed == false)
    }

    @Test func pollingStartsAndStops() async {
        let service = isolatedService()
        let router = SensorRouter(polar: nil, emay: nil, healthKit: nil)

        let pollingBefore = await service.isPolling
        #expect(pollingBefore == false)

        await service.startPolling(router: router)
        let pollingDuring = await service.isPolling
        #expect(pollingDuring)

        await service.stopPolling()
        // Give the task a moment to cancel
        try? await Task.sleep(nanoseconds: 100_000_000)

        let pollingAfter = await service.isPolling
        #expect(pollingAfter == false)
    }

    // MARK: - Token store

    @Test func tokenRoundTrip() throws {
        let store = isolatedTokenStore()

        let token = OuraTokenStore.Token(
            accessToken: "access-abc",
            refreshToken: "refresh-xyz",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try store.write(token)
        let restored = try store.read()

        #expect(restored != nil)
        #expect(restored?.accessToken == "access-abc")
        #expect(restored?.refreshToken == "refresh-xyz")
        #expect(restored?.tokenType == "Bearer")

        // Cleanup
        try store.delete()
        #expect(try store.read() == nil)
    }

    @Test func tokenStoreReadWhenEmpty() throws {
        let store = isolatedTokenStore(account: "nonexistent")
        let token = try store.read()
        #expect(token == nil)
    }

    @Test func tokenExpiryDetection() {
        let valid = OuraTokenStore.Token(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date().addingTimeInterval(300)
        )
        #expect(valid.isExpired == false)

        let almostExpired = OuraTokenStore.Token(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date().addingTimeInterval(30) // within 60s grace
        )
        #expect(almostExpired.isExpired)

        let expired = OuraTokenStore.Token(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date().addingTimeInterval(-1)
        )
        #expect(expired.isExpired)
    }

    /// Deleting an absent keychain item must be a no-op rather than an error.
    /// The `try` is the assertion — a thrown error fails the test.
    @Test func tokenDeleteNonExistentIsOk() throws {
        let store = isolatedTokenStore(account: "ghost")
        try store.delete()
    }

    // MARK: - OuraIBISample

    @Test func ouraIBISampleInstantHR() {
        let sample = SensorRouter.AnySensorSample.OuraIBISample(
            timestamp: 1_700_000_000,
            ibiMs: 850,
            validity: .good
        )
        // instantHR = 60000 / 850 ≈ 70.59
        #expect(abs(sample.instantHR - 60_000.0 / 850.0) < 0.001)
        #expect(sample.ibiMs == 850)
        #expect(sample.validity == .good)
    }

    @Test func ouraIBISampleZeroIBI() {
        let sample = SensorRouter.AnySensorSample.OuraIBISample(
            timestamp: 1_700_000_000,
            ibiMs: 0,
            validity: nil
        )
        #expect(abs(sample.instantHR) < 0.001)
    }
}
