import SwiftUI
import Testing

@testable import AnxietyWatch

/// Tests for Color.severity() and Color.severityLabel() — the severity band
/// mapping used across Dashboard, Journal, Trends, Watch, and Medication views.
struct SeverityColorTests {

    // MARK: - severityLabel mapping

    @Test("Severity 1 is Calm")
    func severity1Label() {
        #expect(Color.severityLabel(1) == "Calm")
    }

    @Test("Severity 2 is Calm")
    func severity2Label() {
        #expect(Color.severityLabel(2) == "Calm")
    }

    @Test("Severity 3 is Mild")
    func severity3Label() {
        #expect(Color.severityLabel(3) == "Mild")
    }

    @Test("Severity 4 is Mild")
    func severity4Label() {
        #expect(Color.severityLabel(4) == "Mild")
    }

    @Test("Severity 5 is Moderate")
    func severity5Label() {
        #expect(Color.severityLabel(5) == "Moderate")
    }

    @Test("Severity 6 is Moderate")
    func severity6Label() {
        #expect(Color.severityLabel(6) == "Moderate")
    }

    @Test("Severity 7 is High")
    func severity7Label() {
        #expect(Color.severityLabel(7) == "High")
    }

    @Test("Severity 8 is High")
    func severity8Label() {
        #expect(Color.severityLabel(8) == "High")
    }

    @Test("Severity 9 is Crisis")
    func severity9Label() {
        #expect(Color.severityLabel(9) == "Crisis")
    }

    @Test("Severity 10 is Crisis")
    func severity10Label() {
        #expect(Color.severityLabel(10) == "Crisis")
    }

    // MARK: - Edge cases: out-of-range values fall to Crisis (default)

    @Test("Severity 0 falls to Crisis default")
    func severity0Label() {
        #expect(Color.severityLabel(0) == "Crisis")
    }

    @Test("Severity 11 falls to Crisis default")
    func severity11Label() {
        #expect(Color.severityLabel(11) == "Crisis")
    }

    @Test("Negative severity falls to Crisis default")
    func negativeLabel() {
        #expect(Color.severityLabel(-1) == "Crisis")
    }

    // MARK: - severity color mapping (verify correct Color is returned)

    @Test("Severity 1-2 returns green")
    func calmColor() {
        #expect(Color.severity(1) == .green)
        #expect(Color.severity(2) == .green)
    }

    @Test("Severity 3-4 returns yellow")
    func mildColor() {
        #expect(Color.severity(3) == .yellow)
        #expect(Color.severity(4) == .yellow)
    }

    @Test("Severity 5-6 returns orange")
    func moderateColor() {
        #expect(Color.severity(5) == .orange)
        #expect(Color.severity(6) == .orange)
    }

    @Test("Severity 7-8 returns red")
    func highColor() {
        #expect(Color.severity(7) == .red)
        #expect(Color.severity(8) == .red)
    }

    @Test("Severity 9-10 returns dark red (custom)")
    func crisisColor() {
        let darkRed = Color(red: 0.6, green: 0.0, blue: 0.0)
        #expect(Color.severity(9) == darkRed)
        #expect(Color.severity(10) == darkRed)
    }

    // MARK: - All severity labels cover the full valid range

    @Test("Every severity in 1...10 returns a non-empty label")
    func allLabelsNonEmpty() {
        for level in 1...10 {
            #expect(!Color.severityLabel(level).isEmpty, "Severity \(level) should have a label")
        }
    }

    @Test("Severity labels cover exactly 5 bands")
    func fiveBands() {
        let labels = Set((1...10).map { Color.severityLabel($0) })
        #expect(labels.count == 5)
        #expect(labels == Set(["Calm", "Mild", "Moderate", "High", "Crisis"]))
    }
}
