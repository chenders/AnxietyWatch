import XCTest
@testable import AnxietyWatchKit

final class CNSAlertTierMachineTests: XCTestCase {

    private func containsNotify(_ commands: [AlertCommand], tier: AlertTier) -> Bool {
        commands.contains { command in
            if case .notify(let t, _) = command { return t == tier }
            return false
        }
    }

    // MARK: - Upgrades

    func testUpgradeAlwaysTakes() {
        let upgrades: [(from: AlertTier, to: AlertTier)] = [
            (.normal, .advisory),
            (.normal, .warning),
            (.normal, .critical),
            (.advisory, .warning),
            (.advisory, .critical),
            (.warning, .critical),
        ]

        for (from, to) in upgrades {
            for tMs: Int64 in [0, 1, 1_000, 999_999_999] {
                let decision = CNSAlertTierMachine.propose(
                    currentTier: from, currentAnchorMs: 500,
                    target: to, tMs: tMs, source: .perSample)
                XCTAssertEqual(decision.newTier, to, "\(from) → \(to) at tMs=\(tMs)")
                XCTAssertEqual(decision.newAnchorMs, tMs, "fresh anchor at upgrade time")
                XCTAssertTrue(containsNotify(decision.commands, tier: to))
            }
        }
    }

    func testUpgradeIncludesHaptic() {
        let expectations: [(AlertTier, AlertCommand.HapticPattern)] = [
            (.advisory, .singleTap),
            (.warning, .doubleTap),
            (.critical, .failure),
        ]

        for (target, pattern) in expectations {
            let decision = CNSAlertTierMachine.propose(
                currentTier: .normal, currentAnchorMs: nil,
                target: target, tMs: 1_000, source: .perSample)
            XCTAssertTrue(decision.commands.contains(.haptic(pattern: pattern)),
                          "upgrade to \(target) must include .haptic(\(pattern))")
        }
    }

    // MARK: - Downgrades / hysteresis

    func testDowngradeRequiresHysteresis() {
        // 10 s after the anchor: held, state unchanged, nothing emitted.
        let held = CNSAlertTierMachine.propose(
            currentTier: .warning, currentAnchorMs: 1_000,
            target: .normal, tMs: 11_000, source: .perSample)
        XCTAssertEqual(held, CNSAlertTierMachine.Decision(
            newTier: .warning, commands: [], newAnchorMs: 1_000))

        // Well past the window: downgrades with a notify.
        let downgraded = CNSAlertTierMachine.propose(
            currentTier: .warning, currentAnchorMs: 1_000,
            target: .normal, tMs: 1_030_000, source: .perSample)
        XCTAssertEqual(downgraded.newTier, .normal)
        XCTAssertEqual(downgraded.newAnchorMs, 1_030_000)
        XCTAssertEqual(downgraded.commands, [.notify(tier: .normal, message: "Condition improved")])
    }

    func testDowngradeBoundaryExactHysteresis() {
        // Exactly 30_000 ms after the anchor: window met (>=), must downgrade.
        let decision = CNSAlertTierMachine.propose(
            currentTier: .critical, currentAnchorMs: 1_000,
            target: .normal, tMs: 31_000, source: .tickStale)
        XCTAssertEqual(decision.newTier, .normal)
        XCTAssertEqual(decision.newAnchorMs, 31_000)
        XCTAssertEqual(decision.commands, [.notify(tier: .normal, message: "Condition improved")])
    }

    func testDowngradeBoundaryOneBelowHysteresis() {
        // 29_999 ms after the anchor: one below the window, must hold.
        let decision = CNSAlertTierMachine.propose(
            currentTier: .critical, currentAnchorMs: 1_000,
            target: .normal, tMs: 30_999, source: .tickStale)
        XCTAssertEqual(decision, CNSAlertTierMachine.Decision(
            newTier: .critical, commands: [], newAnchorMs: 1_000))
    }

    func testNilAnchorAllowsImmediateDowngrade() {
        // nil anchor = "no hysteresis window active" (fresh state).
        let decision = CNSAlertTierMachine.propose(
            currentTier: .warning, currentAnchorMs: nil,
            target: .normal, tMs: 100, source: .perSample)
        XCTAssertEqual(decision.newTier, .normal)
        XCTAssertEqual(decision.newAnchorMs, 100)
        XCTAssertEqual(decision.commands, [.notify(tier: .normal, message: "Condition improved")])
    }

    // MARK: - Equal proposals

    func testEqualProposalNeverEmits() {
        for tier in [AlertTier.normal, .advisory, .warning, .critical] {
            let decision = CNSAlertTierMachine.propose(
                currentTier: tier, currentAnchorMs: 1_000,
                target: tier, tMs: 999_999, source: .fusion)
            XCTAssertEqual(decision, CNSAlertTierMachine.Decision(
                newTier: tier, commands: [], newAnchorMs: 1_000),
                "equal proposal for \(tier) must be a silent no-op")
        }
    }

    // MARK: - Messages

    func testMessageOverrideAppliedIfProvided() {
        // Upgrade with override.
        let upgraded = CNSAlertTierMachine.propose(
            currentTier: .normal, currentAnchorMs: nil,
            target: .warning, tMs: 1_000, source: .perSample,
            messageOverride: "SpO2 89% below threshold")
        XCTAssertTrue(upgraded.commands.contains(.notify(tier: .warning, message: "SpO2 89% below threshold")))

        // Downgrade with override.
        let downgraded = CNSAlertTierMachine.propose(
            currentTier: .warning, currentAnchorMs: nil,
            target: .normal, tMs: 2_000, source: .tickStale,
            messageOverride: "Signal restored")
        XCTAssertEqual(downgraded.commands, [.notify(tier: .normal, message: "Signal restored")])
    }

    func testAllProposalSourcesRoundTrip() {
        // Each source produces a sensible default upgrade message + haptic.
        let sources: [CNSAlertTierMachine.ProposalSource] = [.perSample, .fusion, .tickStale, .dataGap]
        for source in sources {
            let decision = CNSAlertTierMachine.propose(
                currentTier: .normal, currentAnchorMs: nil,
                target: .warning, tMs: 1_000, source: source)
            XCTAssertEqual(decision.newTier, .warning)
            XCTAssertEqual(decision.commands.count, 2, "\(source): notify + haptic")
            guard case .notify(let tier, let message) = decision.commands[0] else {
                return XCTFail("\(source): first command must be a notify")
            }
            XCTAssertEqual(tier, .warning)
            XCTAssertFalse(message.isEmpty, "\(source): default message must be non-empty")
        }

        // Source-specific defaults spot check.
        let fusion = CNSAlertTierMachine.propose(
            currentTier: .normal, currentAnchorMs: nil,
            target: .critical, tMs: 1_000, source: .fusion)
        XCTAssertTrue(fusion.commands.contains(
            .notify(tier: .critical, message: "Fusion score indicated CNS depression risk")))
    }

    // MARK: - Purity

    func testPurityOfMachine() throws {
        // The machine lives in Pipeline/, so the main lint
        // (testPipelineHasNoImpureReferences) covers it. This test pins that
        // location AND double-checks the file directly so a future move out of
        // the linted directory can't silently drop coverage.
        let machineFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AnxietyWatchKit/Pipeline/CNSAlertTierMachine.swift")

        XCTAssertTrue(FileManager.default.fileExists(atPath: machineFile.path),
                      "CNSAlertTierMachine must live in the purity-linted Pipeline directory")

        let contents = try String(contentsOf: machineFile, encoding: .utf8)
        for symbol in ["Date(", "Date.now", "DispatchTime", "Task.sleep", "Task {",
                       "DispatchQueue", "random(", "UUID(", ".shared", "Timer("] {
            XCTAssertFalse(contents.contains(symbol),
                           "CNSAlertTierMachine contains banned impure symbol '\(symbol)'")
        }
    }

    // MARK: - Determinism

    func testProposeIsDeterministic() {
        let a = CNSAlertTierMachine.propose(
            currentTier: .advisory, currentAnchorMs: 1_000,
            target: .critical, tMs: 5_000, source: .fusion)
        let b = CNSAlertTierMachine.propose(
            currentTier: .advisory, currentAnchorMs: 1_000,
            target: .critical, tMs: 5_000, source: .fusion)
        XCTAssertEqual(a, b)
    }
}
