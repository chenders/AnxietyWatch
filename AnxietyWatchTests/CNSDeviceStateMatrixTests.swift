import Foundation
import Testing

@testable import AnxietyWatch

/// Covers the §7 device-state matrix (`CNSDeviceStateMatrix.classify`),
/// state derivation from timestamps (`CNSDeviceStateMatrix.state`), and the
/// per-device fallback config's `UserDefaults` round trip
/// (`CNSDeviceFallbackConfig`). SAFETY-CRITICAL — this decides when a device
/// dropout ends monitoring outright vs. merely discloses a degradation
/// (spec asymmetry rule: degradation is disclosed, never silent).
struct CNSDeviceStateMatrixTests {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - classify: reporting is always ignorable

    @Test(
        "A reporting source is ignorable regardless of source or only-primary flag — nothing to disclose or end",
        arguments: CNSSignalSource.allCases, [true, false]
    )
    func reportingIsIgnorable(source: CNSSignalSource, isOnlyPrimarySource: Bool) {
        let result = CNSDeviceStateMatrix.classify(
            source: source, state: .reporting, isOnlyPrimarySource: isOnlyPrimarySource
        )
        #expect(result == .ignorable)
    }

    // MARK: - classify: absentFromStart

    /// The spec's own worked example: "H10 absent from start on a Watch+EMAY
    /// night is fine." Corroborating-only sources (Polar H10, Apple Watch)
    /// never having shown up is benign — ignorable regardless of whether
    /// this source happens to be (mis-)reported as the only primary one.
    @Test(
        "absentFromStart: corroborating-only sources are ignorable (spec's H10-on-a-Watch+EMAY-night example)",
        arguments: [CNSSignalSource.polarH10, .appleWatch], [true, false]
    )
    func absentFromStartCorroboratingIsIgnorable(source: CNSSignalSource, isOnlyPrimarySource: Bool) {
        let result = CNSDeviceStateMatrix.classify(
            source: source, state: .absentFromStart, isOnlyPrimarySource: isOnlyPrimarySource
        )
        #expect(result == .ignorable)
    }

    /// Arming without the primary source is allowed (decision 5's
    /// minimum-bar guardrail) but must be disclosed — never silently
    /// "fine" the way a missing corroborating source is.
    @Test(
        "absentFromStart: EMAY (the primary-capable source) is degradeDisclosed, never ignorable",
        arguments: [true, false]
    )
    func absentFromStartEMAYIsDegradeDisclosed(isOnlyPrimarySource: Bool) {
        let result = CNSDeviceStateMatrix.classify(
            source: .emayOximeter, state: .absentFromStart, isOnlyPrimarySource: isOnlyPrimarySource
        )
        #expect(result == .degradeDisclosed)
    }

    // MARK: - classify: idle / diedMidSession

    @Test(
        "idle/diedMidSession + isOnlyPrimarySource true -> endMonitoring (the dangerous silent gap), any source",
        arguments: CNSSignalSource.allCases, [CNSDeviceState.idle, .diedMidSession]
    )
    func onlyPrimarySourceStoppingEndsMonitoring(source: CNSSignalSource, state: CNSDeviceState) {
        let result = CNSDeviceStateMatrix.classify(source: source, state: state, isOnlyPrimarySource: true)
        #expect(result == .endMonitoring)
    }

    @Test(
        "idle/diedMidSession + isOnlyPrimarySource false -> degradeDisclosed, any source",
        arguments: CNSSignalSource.allCases, [CNSDeviceState.idle, .diedMidSession]
    )
    func notOnlyPrimarySourceStoppingDegradesDisclosed(source: CNSSignalSource, state: CNSDeviceState) {
        let result = CNSDeviceStateMatrix.classify(source: source, state: state, isOnlyPrimarySource: false)
        #expect(result == .degradeDisclosed)
    }

    // MARK: - state derivation

    @Test("Never sampled + wasEverReporting false -> absentFromStart")
    func neverSampledIsAbsentFromStart() {
        let state = CNSDeviceStateMatrix.state(
            lastSample: nil, sessionStart: t0, now: t0.addingTimeInterval(300), wasEverReporting: false
        )
        #expect(state == .absentFromStart)
    }

    @Test("Last sample 30s ago after reporting -> still reporting (within the 60s gate window)")
    func recentSampleIsReporting() {
        let lastSample = t0.addingTimeInterval(100)
        let state = CNSDeviceStateMatrix.state(
            lastSample: lastSample, sessionStart: t0, now: lastSample.addingTimeInterval(30),
            wasEverReporting: true
        )
        #expect(state == .reporting)
    }

    @Test("Last sample exactly 60s ago (gateWindowSeconds) -> still reporting — boundary is inclusive")
    func exactlyAtGateWindowIsStillReporting() {
        let lastSample = t0.addingTimeInterval(100)
        let now = lastSample.addingTimeInterval(CNSThresholds.standard.gateWindowSeconds)
        let state = CNSDeviceStateMatrix.state(
            lastSample: lastSample, sessionStart: t0, now: now, wasEverReporting: true
        )
        #expect(state == .reporting)
    }

    @Test("Last sample 61s ago after reporting -> diedMidSession")
    func staleSampleAfterReportingIsDiedMidSession() {
        let lastSample = t0.addingTimeInterval(100)
        let state = CNSDeviceStateMatrix.state(
            lastSample: lastSample, sessionStart: t0, now: lastSample.addingTimeInterval(61),
            wasEverReporting: true
        )
        #expect(state == .diedMidSession)
    }

    @Test("Just past the gate window (60s + 1s) -> diedMidSession — guards > vs >= at the boundary")
    func justPastGateWindowIsDiedMidSession() {
        let lastSample = t0.addingTimeInterval(100)
        let now = lastSample.addingTimeInterval(CNSThresholds.standard.gateWindowSeconds + 1)
        let state = CNSDeviceStateMatrix.state(
            lastSample: lastSample, sessionStart: t0, now: now, wasEverReporting: true
        )
        #expect(state == .diedMidSession)
    }

    /// Resolved-ambiguity coverage: a `lastSample` timestamp from BEFORE the
    /// current session started is stale evidence from a prior session, not
    /// proof this source has reported yet in the current one — `sessionStart`
    /// exists precisely to catch this, distinguishing it from the "genuinely
    /// never reported" case only in provenance, not in outcome.
    @Test("A lastSample from before sessionStart (stale cross-session data) -> absentFromStart")
    func staleCrossSessionSampleIsAbsentFromStart() {
        let staleSample = t0.addingTimeInterval(-3600)
        let state = CNSDeviceStateMatrix.state(
            lastSample: staleSample, sessionStart: t0, now: t0.addingTimeInterval(10), wasEverReporting: true
        )
        #expect(state == .absentFromStart)
    }

    /// Defensive contract case: `wasEverReporting == true` but no timestamp
    /// to compute a gap from is a caller contract violation that should never
    /// occur from a correctly-implemented coordinator (once `lastSample` is
    /// set it stays set for the life of the session). Resolves to
    /// `.absentFromStart` — there is no timestamp evidence to say otherwise.
    @Test("wasEverReporting true but lastSample nil (caller contract violation) -> absentFromStart, not a crash")
    func wasEverReportingTrueWithNilLastSampleIsAbsentFromStart() {
        let state = CNSDeviceStateMatrix.state(
            lastSample: nil, sessionStart: t0, now: t0.addingTimeInterval(120), wasEverReporting: true
        )
        #expect(state == .absentFromStart)
    }

    /// Mirror contradiction of the case above: a `lastSample` timestamp
    /// exists but the caller's `wasEverReporting` flag says the source never
    /// reported. Also a caller contract violation; the flag governs — a
    /// source the caller has not acknowledged as ever-reporting cannot be
    /// `.reporting`, and cannot have "died" — so this resolves to
    /// `.absentFromStart`.
    @Test("lastSample non-nil but wasEverReporting false (mirror contract violation) -> absentFromStart")
    func lastSampleWithoutWasEverReportingIsAbsentFromStart() {
        let state = CNSDeviceStateMatrix.state(
            lastSample: t0.addingTimeInterval(30), sessionStart: t0, now: t0.addingTimeInterval(60),
            wasEverReporting: false
        )
        #expect(state == .absentFromStart)
    }

    // MARK: - CNSDeviceFallbackConfig: UserDefaults round trip

    /// Fresh, isolated UserDefaults per test — mirrors
    /// `TestHelpers.gateResolvedDefaults`'s suite-isolation pattern (a fresh
    /// suite name per test so persisted state can't leak between tests or
    /// between simulator runs).
    private func makeDefaults(_ suite: String = #function) -> UserDefaults {
        let name = "CNSDeviceStateMatrixTests.\(suite).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("could not create UserDefaults suite \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// "Losing the only continuous SpO₂ = loudest default": a fresh install
    /// with nothing persisted yet must load EMAY at `.klaxon`, not something
    /// milder.
    @Test("Loading from an empty suite yields the documented defaults, EMAY at the loudest (.klaxon)")
    func loadFromEmptySuiteYieldsDocumentedDefaults() throws {
        let defaults = makeDefaults()
        let config = CNSDeviceFallbackConfig.load(from: defaults)
        #expect(config.emay == .klaxon)
        #expect(config.polar == .notifyOnly)
        #expect(config.appleWatch == .notifyOnly)
    }

    @Test("A saved, non-default config round-trips exactly through the same suite")
    func savedConfigRoundTrips() throws {
        let defaults = makeDefaults()
        let saved = CNSDeviceFallbackConfig(emay: .gentleAlarm, polar: .klaxon, appleWatch: .notifyOnly)
        saved.save(to: defaults)
        let loaded = CNSDeviceFallbackConfig.load(from: defaults)
        #expect(loaded == saved)
    }

    /// A JSON payload missing keys (an earlier schema, or a hand-crafted
    /// partial blob) must fill in the struct's declared defaults for the
    /// absent fields rather than failing the whole decode.
    @Test("A persisted blob missing keys preserves this struct's defaults for the absent fields")
    func partialPersistedBlobPreservesDefaultsForMissingKeys() throws {
        let defaults = makeDefaults()
        let partialJSON = Data(#"{"emay":"gentleAlarm"}"#.utf8)
        defaults.set(partialJSON, forKey: "cns.deviceFallbackConfig")

        let loaded = CNSDeviceFallbackConfig.load(from: defaults)
        #expect(loaded.emay == .gentleAlarm)
        #expect(loaded.polar == .notifyOnly)
        #expect(loaded.appleWatch == .notifyOnly)
    }

    @Test("An undecodable blob (corrupt data) falls back to defaults rather than crashing")
    func undecodableBlobFallsBackToDefaults() throws {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "cns.deviceFallbackConfig")

        let loaded = CNSDeviceFallbackConfig.load(from: defaults)
        #expect(loaded == CNSDeviceFallbackConfig())
    }
}
