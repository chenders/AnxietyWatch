import SwiftUI
import Testing

@testable import AnxietyWatch

struct ClinicalSeverityTests {
    @Test("AHI severity boundaries")
    func ahiBoundaries() {
        #expect(ClinicalSeverity.ahiSeverity(0) == .normal)
        #expect(ClinicalSeverity.ahiSeverity(4.99) == .normal)
        #expect(ClinicalSeverity.ahiSeverity(5.0) == .mild)
        #expect(ClinicalSeverity.ahiSeverity(14.99) == .mild)
        #expect(ClinicalSeverity.ahiSeverity(15.0) == .moderate)
        #expect(ClinicalSeverity.ahiSeverity(29.99) == .moderate)
        #expect(ClinicalSeverity.ahiSeverity(30.0) == .severe)
        #expect(ClinicalSeverity.ahiSeverity(99.0) == .severe)
    }

    @Test("SpO2 nadir severity boundaries")
    func spo2NadirBoundaries() {
        #expect(ClinicalSeverity.spo2NadirSeverity(95.0) == .normal)
        #expect(ClinicalSeverity.spo2NadirSeverity(94.99) == .mild)
        #expect(ClinicalSeverity.spo2NadirSeverity(90.0) == .mild)
        #expect(ClinicalSeverity.spo2NadirSeverity(89.99) == .moderate)
        #expect(ClinicalSeverity.spo2NadirSeverity(85.0) == .moderate)
        #expect(ClinicalSeverity.spo2NadirSeverity(84.99) == .severe)
    }

    @Test("T90 severity boundaries")
    func t90Boundaries() {
        #expect(ClinicalSeverity.t90Severity(0) == .normal)
        #expect(ClinicalSeverity.t90Severity(1) == .mild)
        #expect(ClinicalSeverity.t90Severity(5) == .mild)
        #expect(ClinicalSeverity.t90Severity(6) == .moderate)
        #expect(ClinicalSeverity.t90Severity(30) == .moderate)
        #expect(ClinicalSeverity.t90Severity(31) == .severe)
    }

    @Test("Desat count severity boundaries")
    func desatBoundaries() {
        #expect(ClinicalSeverity.desatCountSeverity(0) == .normal)
        #expect(ClinicalSeverity.desatCountSeverity(4) == .normal)
        #expect(ClinicalSeverity.desatCountSeverity(5) == .mild)
        #expect(ClinicalSeverity.desatCountSeverity(15) == .mild)
        #expect(ClinicalSeverity.desatCountSeverity(16) == .moderate)
        #expect(ClinicalSeverity.desatCountSeverity(30) == .moderate)
        #expect(ClinicalSeverity.desatCountSeverity(31) == .severe)
    }

    @Test("Glucose CV severity boundaries")
    func glucoseCVBoundaries() {
        #expect(ClinicalSeverity.glucoseCVSeverity(35.99) == .normal)
        #expect(ClinicalSeverity.glucoseCVSeverity(36.0) == .mild)
        #expect(ClinicalSeverity.glucoseCVSeverity(50.0) == .mild)
        #expect(ClinicalSeverity.glucoseCVSeverity(50.01) == .severe)
    }

    @Test("Glucose value severity boundaries")
    func glucoseValueBoundaries() {
        #expect(ClinicalSeverity.glucoseValueSeverity(70.0) == .normal)
        #expect(ClinicalSeverity.glucoseValueSeverity(180.0) == .normal)
        #expect(ClinicalSeverity.glucoseValueSeverity(69.99) == .mild)
        #expect(ClinicalSeverity.glucoseValueSeverity(180.01) == .mild)
        #expect(ClinicalSeverity.glucoseValueSeverity(250.0) == .mild)
        #expect(ClinicalSeverity.glucoseValueSeverity(250.01) == .severe)
    }

    @Test("Severity color mapping")
    func severityColors() {
        #expect(ClinicalSeverity.Severity.normal.color == .green)
        #expect(ClinicalSeverity.Severity.mild.color == .yellow)
        #expect(ClinicalSeverity.Severity.moderate.color == .orange)
        #expect(ClinicalSeverity.Severity.severe.color == .red)
    }
}
