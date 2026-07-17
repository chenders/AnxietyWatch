import XCTest
@testable import AnxietyWatchKit

final class CNSFusionEngineTests: XCTestCase {
    
    private func makeState() -> PipelineState {
        PipelineState()
    }
    
    func testFuseEmptyStateReturnsZero() {
        let state = makeState()
        let fusion = CNSFusionEngine.fuse(state)
        
        XCTAssertEqual(fusion.overall, 0.0, accuracy: 0.001)
        XCTAssertEqual(fusion.hrContribution, 0.0, accuracy: 0.001)
        XCTAssertEqual(fusion.hrvContribution, 0.0, accuracy: 0.001)
        XCTAssertEqual(fusion.spo2Contribution, 0.0, accuracy: 0.001)
        XCTAssertEqual(fusion.accelContribution, 0.0, accuracy: 0.001)
        XCTAssertEqual(fusion.breathContribution, 0.0, accuracy: 0.001)
        XCTAssertTrue(fusion.sampleCountsUsed.isEmpty)
    }
    
    func testFuseLowHRProducesHighContribution() {
        var state = makeState()
        
        // Add HR samples that are significantly below threshold
        let hrMin = state.thresholds.hrMin
        for i in 0..<30 {
            state.hrRing.push(PipelineSample(tMs: Int64(i * 1000), value: Double(hrMin - 20))) // 20 BPM below threshold (HR=20 with threshold=40)
        }
        
        let fusion = CNSFusionEngine.fuse(state)
        
        XCTAssertGreaterThan(fusion.hrContribution, 0.0)
        // With HR 20 BPM below threshold, contribution should be (40-20)/20 = 1.0
        XCTAssertGreaterThan(fusion.hrContribution, 0.8)
        XCTAssertEqual(fusion.sampleCountsUsed["hr"], 30)
    }
    
    func testFuseNormalHRProducesZeroContribution() {
        var state = makeState()
        
        // Add HR samples that are normal
        let hrMin = state.thresholds.hrMin
        for i in 0..<30 {
            state.hrRing.push(PipelineSample(tMs: Int64(i * 1000), value: Double(hrMin + 10))) // 10 BPM above threshold
        }
        
        let fusion = CNSFusionEngine.fuse(state)
        
        XCTAssertEqual(fusion.hrContribution, 0.0, accuracy: 0.001)
        XCTAssertEqual(fusion.sampleCountsUsed["hr"], 30)
    }
    
    func testFuseLowSpO2Dominates() {
        var state = makeState()
        
        // Add SpO2 samples that are below alert threshold
        let spo2Alert = state.thresholds.spo2Alert
        for i in 0..<5 {
            state.spo2Ring.push(PipelineSample(tMs: Int64(i * 1000), value: Double(spo2Alert - 2))) // 2% below alert
        }
        
        let fusion = CNSFusionEngine.fuse(state)
        
        // SpO2 contribution should be 1.0 when below alert threshold
        XCTAssertEqual(fusion.spo2Contribution, 1.0, accuracy: 0.001)
        XCTAssertEqual(fusion.sampleCountsUsed["spo2"], 5)
        
        // Overall should be at least 0.35 (weightSpO2 * 1.0)
        XCTAssertGreaterThanOrEqual(fusion.overall, 0.35)
    }
    
    func testFuseAccelFusionRequiresLowHR() {
        var state = makeState()
        
        // Add normal HR samples
        let hrMin = state.thresholds.hrMin
        for i in 0..<30 {
            state.hrRing.push(PipelineSample(tMs: Int64(i * 1000), value: Double(hrMin + 10))) // Normal HR
        }
        
        // Add low accel samples
        for i in 0..<30 {
            state.accelRing.push(PipelineSample(tMs: Int64(i * 1000), value: 0.5)) // Low accel
        }
        
        let fusion = CNSFusionEngine.fuse(state)
        
        // Accel contribution should be 0 since HR contribution is 0 (normal HR)
        XCTAssertEqual(fusion.accelContribution, 0.0, accuracy: 0.001)
        XCTAssertEqual(fusion.sampleCountsUsed["accel"], 30)
    }
    
    func testFuseAccelFusionActivatesWithLowHR() {
        var state = makeState()
        
        // Add low HR samples
        let hrMin = state.thresholds.hrMin
        for i in 0..<30 {
            state.hrRing.push(PipelineSample(tMs: Int64(i * 1000), value: Double(hrMin - 10))) // Low HR
        }
        
        // Add low accel samples
        for i in 0..<30 {
            state.accelRing.push(PipelineSample(tMs: Int64(i * 1000), value: 0.5)) // Low accel
        }
        
        let fusion = CNSFusionEngine.fuse(state)
        
        // Accel contribution should be non-zero since HR contribution > 0.3
        XCTAssertGreaterThan(fusion.accelContribution, 0.0)
        XCTAssertEqual(fusion.sampleCountsUsed["accel"], 30)
    }
    
    func testFuseOverallInRange() {
        var state = makeState()
        
        // Add a mixture of samples to get a range of contributions
        let hrMin = state.thresholds.hrMin
        for i in 0..<30 {
            state.hrRing.push(PipelineSample(tMs: Int64(i * 1000), value: Double(hrMin - 5))) // Slightly low HR
        }
        
        let hrvLow = state.thresholds.hrvLowSDNN
        for i in 0..<10 {
            state.hrvRing.push(PipelineSample(tMs: Int64(i * 1000), value: hrvLow - 2)) // Low HRV
        }
        
        let spo2Warn = state.thresholds.spo2Warn
        for i in 0..<5 {
            state.spo2Ring.push(PipelineSample(tMs: Int64(i * 1000), value: Double(spo2Warn - 3))) // Slightly low SpO2
        }
        
        for i in 0..<30 {
            state.accelRing.push(PipelineSample(tMs: Int64(i * 1000), value: 0.5)) // Low accel
        }
        
        let fusion = CNSFusionEngine.fuse(state)
        
        // Overall score should be between 0.0 and 1.0
        XCTAssertGreaterThanOrEqual(fusion.overall, 0.0)
        XCTAssertLessThanOrEqual(fusion.overall, 1.0)
        
        // All contributions should be between 0.0 and 1.0
        XCTAssertGreaterThanOrEqual(fusion.hrContribution, 0.0)
        XCTAssertLessThanOrEqual(fusion.hrContribution, 1.0)
        XCTAssertGreaterThanOrEqual(fusion.hrvContribution, 0.0)
        XCTAssertLessThanOrEqual(fusion.hrvContribution, 1.0)
        XCTAssertGreaterThanOrEqual(fusion.spo2Contribution, 0.0)
        XCTAssertLessThanOrEqual(fusion.spo2Contribution, 1.0)
        XCTAssertGreaterThanOrEqual(fusion.accelContribution, 0.0)
        XCTAssertLessThanOrEqual(fusion.accelContribution, 1.0)
        XCTAssertGreaterThanOrEqual(fusion.breathContribution, 0.0)
        XCTAssertLessThanOrEqual(fusion.breathContribution, 1.0)
    }
    
    func testApplyFusionUpgradesTierOnly() {
        var state = makeState()
        state.currentAlertTier = .advisory
        state.hysteresisAnchorMs = 1000
        
        let commands: [AlertCommand] = []
        
        // Create a high fusion score that should trigger critical tier
        let highFusion = CNSFusionEngine.FusionScore(
            overall: 0.9,
            hrContribution: 0.0,
            hrvContribution: 0.0,
            spo2Contribution: 0.0,
            accelContribution: 0.0,
            breathContribution: 0.0,
            sampleCountsUsed: [:]
        )
        
        let (upgradedState, upgradedCommands) = PipelineStep.applyFusion(state, commands, fusion: highFusion, tMs: 1000)
        
        // Should upgrade to critical
        XCTAssertEqual(upgradedState.currentAlertTier, .critical)
        XCTAssertFalse(upgradedCommands.isEmpty)
        
        // Test that downgrades don't happen
        var criticalState = makeState()
        criticalState.currentAlertTier = .critical
        criticalState.hysteresisAnchorMs = 1000
        
        let lowFusion = CNSFusionEngine.FusionScore(
            overall: 0.1,
            hrContribution: 0.0,
            hrvContribution: 0.0,
            spo2Contribution: 0.0,
            accelContribution: 0.0,
            breathContribution: 0.0,
            sampleCountsUsed: [:]
        )
        
        let (downgradedState, downgradedCommands) = PipelineStep.applyFusion(criticalState, commands, fusion: lowFusion, tMs: 2000)
        
        // Should stay critical (no downgrade)
        XCTAssertEqual(downgradedState.currentAlertTier, .critical)
        // Should have same number of commands (no new commands added)
        XCTAssertEqual(downgradedCommands.count, commands.count)
    }
    
    func testFusionResultDeterministic() {
        var state = makeState()
        
        // Add consistent data
        let hrMin = state.thresholds.hrMin
        for i in 0..<30 {
            state.hrRing.push(PipelineSample(tMs: Int64(i * 1000), value: Double(hrMin - 5)))
        }
        
        let hrvLow = state.thresholds.hrvLowSDNN
        for i in 0..<10 {
            state.hrvRing.push(PipelineSample(tMs: Int64(i * 1000), value: hrvLow - 2))
        }
        
        // Run fusion multiple times
        let fusion1 = CNSFusionEngine.fuse(state)
        let fusion2 = CNSFusionEngine.fuse(state)
        let fusion3 = CNSFusionEngine.fuse(state)
        
        // All results should be identical
        XCTAssertEqual(fusion1.overall, fusion2.overall)
        XCTAssertEqual(fusion2.overall, fusion3.overall)
        XCTAssertEqual(fusion1.hrContribution, fusion2.hrContribution)
        XCTAssertEqual(fusion2.hrContribution, fusion3.hrContribution)
    }
    
    func testFuseHonorsInsufficientDataThresholds() {
        var state = makeState()
        
        // Add only 3 HR samples (less than required 5)
        let hrMin = state.thresholds.hrMin
        for i in 0..<3 {
            state.hrRing.push(PipelineSample(tMs: Int64(i * 1000), value: Double(hrMin - 20)))
        }
        
        let fusion = CNSFusionEngine.fuse(state)
        
        // HR contribution should be 0 due to insufficient data
        XCTAssertEqual(fusion.hrContribution, 0.0, accuracy: 0.001)
        XCTAssertNil(fusion.sampleCountsUsed["hr"]) // No count recorded due to insufficient data
        
        // Add 2 more samples to reach threshold
        for i in 3..<5 {
            state.hrRing.push(PipelineSample(tMs: Int64(i * 1000), value: Double(hrMin - 20)))
        }
        
        let fusionAfter = CNSFusionEngine.fuse(state)
        
        // Now HR contribution should be non-zero
        XCTAssertGreaterThan(fusionAfter.hrContribution, 0.0)
        XCTAssertEqual(fusionAfter.sampleCountsUsed["hr"], 5)
    }
}
extension CNSFusionEngineTests {
    /// Regression: applyFusion must set a FRESH hysteresisAnchorMs on any
    /// upgrade so subsequent downgrade math is measured from THIS upgrade,
    /// not a stale/epoch anchor. Opus R1 T25 caught the missing-tMs bug that
    /// would have made anchor=0 → immediate downgrade permitted.
    func testApplyFusionSetsFreshHysteresisAnchor() {
        var state = PipelineState()
        state.currentAlertTier = .normal
        state.hysteresisAnchorMs = nil
        let high = CNSFusionEngine.FusionScore(
            overall: 0.9,
            hrContribution: 0,
            hrvContribution: 0,
            spo2Contribution: 0,
            accelContribution: 0,
            breathContribution: 0,
            sampleCountsUsed: [:]
        )
        let (upgraded, _) = PipelineStep.applyFusion(state, [], fusion: high, tMs: 5_555)
        XCTAssertEqual(upgraded.currentAlertTier, .critical)
        XCTAssertEqual(upgraded.hysteresisAnchorMs, 5_555,
            "Fresh anchor must equal the upgrade tMs — regression against Opus-caught stale-anchor bug.")
    }

    /// Regression: applyFusion is UPGRADE-ONLY. Even with a nonzero tMs, a
    /// lower target tier must not modify state.
    func testApplyFusionNeverDowngrades() {
        var state = PipelineState()
        state.currentAlertTier = .critical
        state.hysteresisAnchorMs = 1_000
        let low = CNSFusionEngine.FusionScore(
            overall: 0.05,
            hrContribution: 0,
            hrvContribution: 0,
            spo2Contribution: 0,
            accelContribution: 0,
            breathContribution: 0,
            sampleCountsUsed: [:]
        )
        let (unchanged, cmds) = PipelineStep.applyFusion(state, [], fusion: low, tMs: 9_999)
        XCTAssertEqual(unchanged.currentAlertTier, .critical)
        XCTAssertEqual(unchanged.hysteresisAnchorMs, 1_000)
        XCTAssertTrue(cmds.isEmpty)
    }
}
