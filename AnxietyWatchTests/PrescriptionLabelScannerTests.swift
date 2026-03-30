import Foundation
import Testing

@testable import AnxietyWatch

struct PrescriptionLabelScannerTests {

    // MARK: - Rx Number

    @Test("Parses Rx number with prefix")
    func parseRxNumber() {
        let result = PrescriptionLabelScanner.parse(lines: ["Rx# 7654321"])
        #expect(result.rxNumber == "7654321")
    }

    @Test("Parses Rx number with colon")
    func parseRxNumberColon() {
        let result = PrescriptionLabelScanner.parse(lines: ["Rx: 12345678"])
        #expect(result.rxNumber == "12345678")
    }

    @Test("Ignores Rx with fewer than 5 digits")
    func parseRxNumberTooShort() {
        let result = PrescriptionLabelScanner.parse(lines: ["Rx# 1234"])
        #expect(result.rxNumber == nil)
    }

    // MARK: - Quantity

    @Test("Parses quantity")
    func parseQuantity() {
        let result = PrescriptionLabelScanner.parse(lines: ["Qty: 60"])
        #expect(result.quantity == 60)
    }

    @Test("Parses quantity with full word")
    func parseQuantityFull() {
        let result = PrescriptionLabelScanner.parse(lines: ["Quantity 30"])
        #expect(result.quantity == 30)
    }

    // MARK: - Refills

    @Test("Parses refills remaining")
    func parseRefills() {
        let result = PrescriptionLabelScanner.parse(lines: ["Refills: 3"])
        #expect(result.refillsRemaining == 3)
    }

    @Test("Parses singular refill")
    func parseRefillSingular() {
        let result = PrescriptionLabelScanner.parse(lines: ["Refill 0"])
        #expect(result.refillsRemaining == 0)
    }

    // MARK: - Dose

    @Test("Parses dose in mg")
    func parseDoseMg() {
        let result = PrescriptionLabelScanner.parse(lines: ["10mg tablet"])
        #expect(result.dose != nil)
        #expect(result.dose!.contains("10"))
    }

    @Test("Parses dose in mcg")
    func parseDoseMcg() {
        let result = PrescriptionLabelScanner.parse(lines: ["500mcg capsule"])
        #expect(result.dose != nil)
    }

    // MARK: - Date

    @Test("Parses date MM/dd/yyyy")
    func parseDateSlash() {
        let result = PrescriptionLabelScanner.parse(lines: ["Date Filled: 12/31/2025"])
        #expect(result.dateFilled != nil)
        let calendar = Calendar.current
        #expect(calendar.component(.month, from: result.dateFilled!) == 12)
        #expect(calendar.component(.day, from: result.dateFilled!) == 31)
        #expect(calendar.component(.year, from: result.dateFilled!) == 2025)
    }

    @Test("Parses date MM-dd-yyyy")
    func parseDateDash() {
        let result = PrescriptionLabelScanner.parse(lines: ["01-15-2025"])
        #expect(result.dateFilled != nil)
    }

    // MARK: - Pharmacy Name

    @Test("Detects Walgreens pharmacy name")
    func detectWalgreens() {
        let result = PrescriptionLabelScanner.parse(lines: [
            "WALGREENS #12345",
            "123 Main Street",
            "Rx# 7654321",
        ])
        #expect(result.pharmacyName?.uppercased().contains("WALGREENS") == true)
    }

    @Test("Detects CVS pharmacy name")
    func detectCVS() {
        let result = PrescriptionLabelScanner.parse(lines: [
            "CVS PHARMACY",
            "456 Oak Ave",
            "Rx# 9876543",
        ])
        #expect(result.pharmacyName?.uppercased().contains("CVS") == true)
    }

    // MARK: - Full label

    @Test("Parses realistic prescription label")
    func parseFullLabel() {
        let lines = [
            "WALGREENS #12345",
            "100 Example Blvd, Anytown, ST 00000",
            "Rx# 7654321",
            "Clonazepam 1mg Tablets",
            "Qty: 60  Refills: 3",
            "Date Filled: 12/31/2025",
            "Dr. Jane Smith",
        ]
        let result = PrescriptionLabelScanner.parse(lines: lines)
        #expect(result.rxNumber == "7654321")
        #expect(result.quantity == 60)
        #expect(result.refillsRemaining == 3)
        #expect(result.dateFilled != nil)
        #expect(result.pharmacyName != nil)
    }

    // MARK: - Edge cases

    @Test("Empty lines returns all nil fields")
    func parseEmptyLines() {
        let result = PrescriptionLabelScanner.parse(lines: [])
        #expect(result.rxNumber == nil)
        #expect(result.quantity == nil)
        #expect(result.refillsRemaining == nil)
        #expect(result.dose == nil)
        #expect(result.dateFilled == nil)
    }

    @Test("Gibberish lines don't crash")
    func parseGibberish() {
        let result = PrescriptionLabelScanner.parse(lines: [
            "asdf12345qwerty",
            "!!@@##$$%%",
            "",
            "   ",
        ])
        #expect(result.rawText.count == 4)
    }
}
