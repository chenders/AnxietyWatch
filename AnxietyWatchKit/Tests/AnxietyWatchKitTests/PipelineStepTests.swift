import XCTest
@testable import AnxietyWatchKit

final class PipelineStepTests: XCTestCase {
    private func makeState() -> PipelineState {
        PipelineState()
    }

    // MARK: - RingBuffer

    func testRingBufferPushAndOverflow() {
        let capacity = 5
        var ring = RingBuffer<Int>(capacity: capacity)
        XCTAssertTrue(ring.isEmpty)

        // Push N+3 items into capacity N.
        for i in 0..<(capacity + 3) {
            ring.push(i)
        }

        XCTAssertEqual(ring.count, capacity)
        // Last N in insertion order, oldest first: 3, 4, 5, 6, 7.
        XCTAssertEqual(ring.elements, [3, 4, 5, 6, 7])

        // removeAll(where:) keeps order.
        ring.removeAll { $0 % 2 == 0 }
        XCTAssertEqual(ring.elements, [3, 5, 7])
        XCTAssertEqual(ring.count, 3)
    }

    // MARK: - Purity

    func testStepIsPureAcrossRepeatedCalls() {
        let state = makeState()
        let event = SensorEvent.hr(tMs: 1_000, bpm: 200)

        let (state1, commands1) = PipelineStep.step(state, event)
        let (state2, commands2) = PipelineStep.step(state, event)

        // Same (state, event) → identical (state', commands), byte for byte.
        XCTAssertEqual(state1, state2)
        XCTAssertEqual(commands1, commands2)

        // And the input state was not mutated (value semantics).
        XCTAssertEqual(state, makeState())
    }

    /// The full ban list enforced against Pipeline sources: impure APIs plus
    /// every common source of non-determinism (randomness, timing, dispatch,
    /// singletons). Shared between the lint test and its self-test.
    private static let bannedSubstrings: [String] = [
        // Impure APIs
        "Date(",
        "DispatchTime",
        "Task.sleep",
        "Task {",
        "DispatchQueue",
        "UNUserNotificationCenter",
        "WCSession",
        "URLSession",
        // Randomness (determinism killers)
        "random(",
        "arc4random",
        "UUID(",
        ".shuffled",
        ".randomElement",
        "Int.random",
        "Double.random",
        "Float.random",
        "Bool.random",
        // Impure timing / dispatch / globals
        "Task(",
        "Task.detached",
        ".shared",
        "Date.now",
        "CACurrentMediaTime",
        "mach_absolute_time",
        "Timer(",
        "Thread(",
        "RunLoop.",
    ]

    func testPipelineHasNoImpureReferences() throws {
        // Swift has no purity type system — this lint is the enforcement.
        let pipelineDir = URL(fileURLWithPath: #filePath)          // .../Tests/AnxietyWatchKitTests/PipelineStepTests.swift
            .deletingLastPathComponent()                            // .../Tests/AnxietyWatchKitTests
            .deletingLastPathComponent()                            // .../Tests
            .deletingLastPathComponent()                            // .../AnxietyWatchKit
            .appendingPathComponent("Sources/AnxietyWatchKit/Pipeline", isDirectory: true)

        let files = try FileManager.default.contentsOfDirectory(at: pipelineDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "purity lint found no Pipeline sources — path broken?")

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for symbol in Self.bannedSubstrings {
                if contents.contains(symbol) {
                    XCTFail("\(file.lastPathComponent) contains banned impure symbol '\(symbol)' — the pipeline core must stay pure and deterministic")
                }
            }
        }
    }

    func testPurityLintCatchesKnownImpureSnippets() {
        // Self-test: prevents the ban list from silently drifting to
        // non-matching substrings over time. Each snippet is a realistic
        // impure line the lint MUST flag.
        let knownImpureSnippets = [
            "let x = UUID()",
            "let t = Date()",
            "let n = Date.now",
            "let r = Int.random(in: 0...9)",
            "let s = [1, 2, 3].shuffled()",
            "let e = [1, 2, 3].randomElement()",
            "let v = arc4random()",
            "Task { await doWork() }",
            "Task(priority: .low) { }",
            "Task.detached { }",
            "try await Task.sleep(nanoseconds: 1)",
            "DispatchQueue.main.async { }",
            "let d = DispatchTime.now()",
            "let f = FileManager.default; let nc = NotificationCenter.shared",
            "let m = CACurrentMediaTime()",
            "let a = mach_absolute_time()",
            "let timer = Timer(timeInterval: 1, repeats: false) { _ in }",
            "let th = Thread(block: {})",
            "RunLoop.main.run()",
            "UNUserNotificationCenter.current()",
            "WCSession.default.activate()",
            "URLSession(configuration: .default)",
        ]

        for snippet in knownImpureSnippets {
            let caught = Self.bannedSubstrings.contains { snippet.contains($0) }
            XCTAssertTrue(caught, "ban list failed to catch known-impure snippet: \(snippet)")
        }
    }

    // MARK: - Escalations

    func testHRHighTierEscalation() {
        let state = makeState()

        let (escalated, commands) = PipelineStep.step(state, .hr(tMs: 1_000, bpm: 200))
        XCTAssertEqual(escalated.currentAlertTier, .warning)
        XCTAssertEqual(commands, [.notify(tier: .warning, message: "Heart rate 200 BPM outside 40–180")])
        XCTAssertEqual(escalated.hysteresisAnchorMs, 1_000)

        // Second identical event: same tier — transition-only, no new command.
        let (again, commands2) = PipelineStep.step(escalated, .hr(tMs: 2_000, bpm: 200))
        XCTAssertEqual(again.currentAlertTier, .warning)
        XCTAssertTrue(commands2.isEmpty)
        XCTAssertEqual(again.hysteresisAnchorMs, 1_000, "anchor unchanged without a transition")
    }

    func testSpo2CriticalDrop() {
        let state = makeState()

        let (critical, commands) = PipelineStep.step(
            state, .spo2(tMs: 1_000, percent: 85, signalQuality: 8))

        XCTAssertEqual(critical.currentAlertTier, .critical)
        XCTAssertTrue(commands.contains(.notify(tier: .critical, message: "SpO2 85% below threshold")))
        XCTAssertTrue(commands.contains(.haptic(pattern: .failure)))

        // Bad signal quality suppresses alerting entirely (but still records).
        let (suppressed, noCommands) = PipelineStep.step(
            makeState(), .spo2(tMs: 1_000, percent: 85, signalQuality: 2))
        XCTAssertEqual(suppressed.currentAlertTier, .normal)
        XCTAssertTrue(noCommands.isEmpty)
        XCTAssertEqual(suppressed.spo2Ring.count, 1, "reading still recorded")
    }

    // MARK: - Gaps

    func testDataGapEmitsInfoOnlyOverFiveMinutes() {
        // 3-minute gap → no command.
        let (afterShort, shortCommands) = PipelineStep.step(
            makeState(), .dataGap(range: 0...(3 * 60 * 1_000)))
        XCTAssertTrue(shortCommands.isEmpty)
        XCTAssertEqual(afterShort.lastGapEndMs, 3 * 60 * 1_000)

        // 10-minute gap → advisory notify (no .info tier exists).
        let (afterLong, longCommands) = PipelineStep.step(
            makeState(), .dataGap(range: 0...(10 * 60 * 1_000)))
        XCTAssertEqual(longCommands, [.notify(tier: .advisory, message: "Monitoring gap: 10 min without data")])
        XCTAssertEqual(afterLong.lastGapEndMs, 10 * 60 * 1_000)
    }

    func testDataGapClearsCoveredRingEntries() {
        var state = makeState()
        (state, _) = PipelineStep.step(state, .hr(tMs: 1_000, bpm: 70))
        (state, _) = PipelineStep.step(state, .hr(tMs: 50_000, bpm: 71))

        // Gap covering only the first sample.
        let (after, _) = PipelineStep.step(state, .dataGap(range: 0...10_000))
        XCTAssertEqual(after.hrRing.elements.map(\.tMs), [50_000])
    }

    // MARK: - Tick / staleness / hysteresis

    func testTickTransitionsBackToNormal() {
        var state = makeState()
        (state, _) = PipelineStep.step(state, .hr(tMs: 1_000, bpm: 200))
        XCTAssertEqual(state.currentAlertTier, .warning)

        // 90 s later, no fresh samples anywhere: stale (>= 60 s) AND past
        // hysteresis (>= 30 s) → decays to normal.
        let (decayed, commands) = PipelineStep.step(state, .tick(tMs: 91_000))
        XCTAssertEqual(decayed.currentAlertTier, .normal)
        XCTAssertEqual(commands, [.notify(tier: .normal, message: "Condition improved")])
    }

    func testHysteresisPreventsRapidDowngrade() {
        var state = makeState()
        (state, _) = PipelineStep.step(state, .hr(tMs: 1_000_000, bpm: 200))
        XCTAssertEqual(state.currentAlertTier, .warning)

        // 10 s later a healthy reading arrives — downgrade wanted, but the
        // 30 s hysteresis window is not met: tier must stay elevated.
        let (held, commands) = PipelineStep.step(state, .hr(tMs: 1_010_000, bpm: 80))
        XCTAssertEqual(held.currentAlertTier, .warning)
        XCTAssertTrue(commands.isEmpty)

        // 40 s after escalation the same healthy reading may downgrade.
        let (downgraded, downCommands) = PipelineStep.step(held, .hr(tMs: 1_040_000, bpm: 80))
        XCTAssertEqual(downgraded.currentAlertTier, .normal)
        XCTAssertEqual(downCommands, [.notify(tier: .normal, message: "Condition improved")])
    }

    func testHysteresisExactBoundary() {
        // Pin the >= semantics of the 30_000 ms window.
        var state = makeState()
        (state, _) = PipelineStep.step(state, .hr(tMs: 1_000_000, bpm: 200))
        XCTAssertEqual(state.currentAlertTier, .warning)

        // 29_999 ms after escalation: one below the window — MUST hold.
        let (held, heldCommands) = PipelineStep.step(state, .hr(tMs: 1_029_999, bpm: 80))
        XCTAssertEqual(held.currentAlertTier, .warning)
        XCTAssertTrue(heldCommands.isEmpty)

        // Exactly 30_000 ms after escalation: window met (>=) — MUST downgrade.
        // (Start from the original escalated state so the anchor is unchanged.)
        let (downgraded, downCommands) = PipelineStep.step(state, .hr(tMs: 1_030_000, bpm: 80))
        XCTAssertEqual(downgraded.currentAlertTier, .normal)
        XCTAssertEqual(downCommands, [.notify(tier: .normal, message: "Condition improved")])
    }

    // MARK: - Multi-sensor

    func testMultipleSensorTypesCoexist() {
        var state = makeState()
        (state, _) = PipelineStep.step(state, .hr(tMs: 1_000, bpm: 72))
        (state, _) = PipelineStep.step(state, .spo2(tMs: 2_000, percent: 97, signalQuality: 9))
        (state, _) = PipelineStep.step(state, .hrv(tMs: 3_000, sdnnMs: 42.0))
        (state, _) = PipelineStep.step(state, .accel(tMs: 4_000, magnitude: 3.5))

        XCTAssertEqual(state.hrRing.elements, [PipelineSample(tMs: 1_000, value: 72)])
        XCTAssertEqual(state.spo2Ring.elements, [PipelineSample(tMs: 2_000, value: 97)])
        XCTAssertEqual(state.hrvRing.elements, [PipelineSample(tMs: 3_000, value: 42.0)])
        XCTAssertEqual(state.accelRing.elements, [PipelineSample(tMs: 4_000, value: 3.5)])

        // Healthy values everywhere: tier untouched.
        XCTAssertEqual(state.currentAlertTier, .normal)
    }
}
