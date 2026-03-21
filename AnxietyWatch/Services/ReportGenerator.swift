import Foundation
import UIKit

/// Generates a formatted PDF clinical report for a date range.
enum ReportGenerator {

    static func generatePDF(
        entries: [AnxietyEntry],
        doses: [MedicationDose],
        definitions: [MedicationDefinition],
        snapshots: [HealthSnapshot],
        cpapSessions: [CPAPSession],
        labResults: [ClinicalLabResult] = [],
        start: Date,
        end: Date
    ) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let margin: CGFloat = 50
        let contentWidth = pageRect.width - margin * 2

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        return renderer.pdfData { ctx in
            var cursor = PDFCursor(y: margin, pageRect: pageRect, margin: margin, context: ctx)

            // -- Page 1: Title & Anxiety Summary --
            cursor.beginPage()
            cursor.drawTitle("Anxiety Watch Clinical Report")
            cursor.drawSubtitle(dateRangeString(start: start, end: end))
            cursor.y += 10

            cursor.drawSectionHeader("Anxiety Summary")
            if entries.isEmpty {
                cursor.drawBody("No anxiety entries recorded in this period.")
            } else {
                let severities = entries.map(\.severity)
                let avg = Double(severities.reduce(0, +)) / Double(severities.count)
                let maxEntry = entries.max(by: { $0.severity < $1.severity })!
                let minEntry = entries.min(by: { $0.severity < $1.severity })!

                cursor.drawBody("Total entries: \(entries.count)")
                cursor.drawBody(String(format: "Average severity: %.1f / 10", avg))
                cursor.drawBody("Highest: \(maxEntry.severity)/10 on \(shortDate(maxEntry.timestamp))")
                cursor.drawBody("Lowest: \(minEntry.severity)/10 on \(shortDate(minEntry.timestamp))")

                let highCount = entries.filter { $0.severity >= 7 }.count
                if highCount > 0 {
                    cursor.drawBody("Episodes ≥ 7/10: \(highCount) (\(pct(highCount, entries.count)))")
                }
            }
            cursor.y += 12

            // -- Medication Adherence --
            cursor.drawSectionHeader("Medication Adherence")
            if doses.isEmpty {
                cursor.drawBody("No medication doses recorded in this period.")
            } else {
                let days = max(1, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1)
                let grouped = Dictionary(grouping: doses, by: \.medicationName)
                for (name, medDoses) in grouped.sorted(by: { $0.key < $1.key }) {
                    let perDay = Double(medDoses.count) / Double(days)
                    cursor.drawBody(String(format: "%@: %d doses (%.1f/day)", name, medDoses.count, perDay))
                }
            }
            cursor.y += 12

            // -- Sleep Quality --
            cursor.ensureSpace(120)
            cursor.drawSectionHeader("Sleep Quality")
            let sleepSnapshots = snapshots.filter { $0.sleepDurationMin != nil }
            if sleepSnapshots.isEmpty {
                cursor.drawBody("No sleep data available.")
            } else {
                let durations = sleepSnapshots.compactMap(\.sleepDurationMin)
                let avgSleep = Double(durations.reduce(0, +)) / Double(durations.count)
                cursor.drawBody(String(format: "Average duration: %.1f hours", avgSleep / 60.0))

                let deepAvg = avg(sleepSnapshots.compactMap(\.sleepDeepMin))
                let remAvg = avg(sleepSnapshots.compactMap(\.sleepREMMin))
                let coreAvg = avg(sleepSnapshots.compactMap(\.sleepCoreMin))
                if let d = deepAvg { cursor.drawBody(String(format: "Average deep sleep: %.0f min", d)) }
                if let r = remAvg { cursor.drawBody(String(format: "Average REM sleep: %.0f min", r)) }
                if let c = coreAvg { cursor.drawBody(String(format: "Average core sleep: %.0f min", c)) }

                if let worst = sleepSnapshots.min(by: { ($0.sleepDurationMin ?? 0) < ($1.sleepDurationMin ?? 0) }),
                   let mins = worst.sleepDurationMin {
                    cursor.drawBody(String(format: "Worst night: %@ (%.1f hours)", shortDate(worst.date), Double(mins) / 60.0))
                }
            }
            cursor.y += 12

            // -- HRV --
            cursor.ensureSpace(100)
            cursor.drawSectionHeader("Heart Rate Variability")
            let hrvSnapshots = snapshots.filter { $0.hrvAvg != nil }
            if hrvSnapshots.isEmpty {
                cursor.drawBody("No HRV data available.")
            } else {
                let values = hrvSnapshots.compactMap(\.hrvAvg)
                let mean = values.reduce(0, +) / Double(values.count)
                let min = values.min()!
                let max = values.max()!
                cursor.drawBody(String(format: "Period average: %.1f ms (SDNN)", mean))
                cursor.drawBody(String(format: "Range: %.0f – %.0f ms", min, max))

                if let baseline = BaselineCalculator.hrvBaseline(from: snapshots) {
                    cursor.drawBody(String(format: "30-day baseline: %.1f ms (σ = %.1f)", baseline.mean, baseline.standardDeviation))
                    let belowBaseline = BaselineCalculator.isHRVBelowBaseline(snapshots: snapshots)
                    cursor.drawBody("Current status: \(belowBaseline ? "BELOW BASELINE" : "Within normal range")")
                }
            }
            cursor.y += 12

            // -- Resting HR --
            let hrSnapshots = snapshots.filter { $0.restingHR != nil }
            if !hrSnapshots.isEmpty {
                cursor.ensureSpace(80)
                cursor.drawSectionHeader("Resting Heart Rate")
                let values = hrSnapshots.compactMap(\.restingHR)
                let mean = values.reduce(0, +) / Double(values.count)
                cursor.drawBody(String(format: "Average: %.0f bpm", mean))
                cursor.drawBody(String(format: "Range: %.0f – %.0f bpm", values.min()!, values.max()!))
                cursor.y += 12
            }

            // -- CPAP --
            if !cpapSessions.isEmpty {
                cursor.ensureSpace(100)
                cursor.drawSectionHeader("CPAP Compliance")
                let avgAHI = cpapSessions.map(\.ahi).reduce(0, +) / Double(cpapSessions.count)
                let avgUsage = Double(cpapSessions.map(\.totalUsageMinutes).reduce(0, +)) / Double(cpapSessions.count)
                let highAHI = cpapSessions.filter { $0.ahi >= 5 }.count

                cursor.drawBody(String(format: "Sessions recorded: %d", cpapSessions.count))
                cursor.drawBody(String(format: "Average AHI: %.1f events/hr", avgAHI))
                cursor.drawBody(String(format: "Average usage: %.1f hours", avgUsage / 60.0))
                cursor.drawBody("Nights with AHI ≥ 5: \(highAHI)")
                cursor.y += 12
            }

            // -- Blood Pressure --
            let bpSnapshots = snapshots.filter { $0.bpSystolic != nil }
            if !bpSnapshots.isEmpty {
                cursor.ensureSpace(80)
                cursor.drawSectionHeader("Blood Pressure")
                let sys = bpSnapshots.compactMap(\.bpSystolic)
                let dia = bpSnapshots.compactMap(\.bpDiastolic)
                let avgSys = sys.reduce(0, +) / Double(sys.count)
                let avgDia = dia.reduce(0, +) / Double(dia.count)
                cursor.drawBody(String(format: "Average: %.0f/%.0f mmHg", avgSys, avgDia))
                cursor.y += 12
            }

            // -- Lab Results --
            if !labResults.isEmpty {
                cursor.ensureSpace(100)
                cursor.drawSectionHeader("Clinical Lab Results")

                // Latest value per test
                var seen = Set<String>()
                let latestPerTest = labResults
                    .sorted { $0.effectiveDate > $1.effectiveDate }
                    .filter { seen.insert($0.loincCode).inserted }

                for result in latestPerTest {
                    let def = LabTestRegistry.definition(for: result.loincCode)
                    let name = def?.shortName ?? result.testName
                    let refLow = result.referenceRangeLow ?? def?.normalRangeLow
                    let refHigh = result.referenceRangeHigh ?? def?.normalRangeHigh

                    var line = String(format: "%@: %.1f %@", name, result.value, result.unit)
                    if let low = refLow, let high = refHigh {
                        line += String(format: " (ref: %.1f–%.1f)", low, high)
                    }
                    if result.value < (refLow ?? -.infinity) {
                        line += " ▼ LOW"
                    } else if result.value > (refHigh ?? .infinity) {
                        line += " ▲ HIGH"
                    }
                    line += " — \(shortDate(result.effectiveDate))"

                    cursor.ensureSpace(22)
                    cursor.drawBody(line)
                }
                cursor.y += 12
            }

            // -- Footer --
            cursor.ensureSpace(60)
            cursor.y += 20
            cursor.drawCaption("Generated by Anxiety Watch on \(shortDate(.now))")
            cursor.drawCaption("This report is for informational purposes. Discuss findings with your clinician.")
        }
    }

    // MARK: - Helpers

    private static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private static func dateRangeString(start: Date, end: Date) -> String {
        "\(shortDate(start)) — \(shortDate(end))"
    }

    private static func pct(_ part: Int, _ total: Int) -> String {
        String(format: "%.0f%%", Double(part) / Double(total) * 100)
    }

    private static func avg(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
}

// MARK: - PDF Drawing Helper

private struct PDFCursor {
    var y: CGFloat
    let pageRect: CGRect
    let margin: CGFloat
    let context: UIGraphicsPDFRendererContext

    var maxY: CGFloat { pageRect.height - margin }
    var contentWidth: CGFloat { pageRect.width - margin * 2 }

    mutating func beginPage() {
        context.beginPage()
        y = margin
    }

    mutating func ensureSpace(_ height: CGFloat) {
        if y + height > maxY {
            beginPage()
        }
    }

    mutating func drawTitle(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 30))
        y += 32
    }

    mutating func drawSubtitle(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 20))
        y += 22
    }

    mutating func drawSectionHeader(_ text: String) {
        ensureSpace(40)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 22))
        y += 26
    }

    mutating func drawBody(_ text: String) {
        ensureSpace(22)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let rect = CGRect(x: margin + 10, y: y, width: contentWidth - 10, height: 18)
        str.draw(in: rect)
        y += 18
    }

    mutating func drawCaption(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: UIColor.tertiaryLabel,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 14))
        y += 16
    }
}
