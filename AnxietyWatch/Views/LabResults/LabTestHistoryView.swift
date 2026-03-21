import Charts
import SwiftData
import SwiftUI

/// Shows all historical values for a single lab test with a trend chart
/// and reference range bands.
struct LabTestHistoryView: View {
    let loincCode: String
    let definition: LabTestRegistry.TestDefinition

    @Query private var allResults: [ClinicalLabResult]

    private var results: [ClinicalLabResult] {
        allResults
            .filter { $0.loincCode == loincCode }
            .sorted { $0.effectiveDate < $1.effectiveDate }
    }

    var body: some View {
        List {
            if !results.isEmpty {
                Section {
                    chartView
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section("About This Test") {
                    Text(definition.rationale)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LabeledContent("Normal Range") {
                        Text("\(formatted(definition.normalRangeLow))–\(formatted(definition.normalRangeHigh)) \(definition.unit)")
                    }
                    LabeledContent("Category", value: definition.category.rawValue)
                }

                Section("Results") {
                    ForEach(results.reversed(), id: \.id) { result in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatted(result.value) + " " + result.unit)
                                    .font(.body.bold())
                                    .foregroundStyle(statusColor(for: result))
                                if let source = result.sourceName {
                                    Text(source)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(result.effectiveDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                    .font(.subheadline)
                                if let interp = result.interpretation {
                                    Text(interpretationLabel(interp))
                                        .font(.caption)
                                        .foregroundStyle(statusColor(for: result))
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "flask",
                    description: Text("No \(definition.displayName) results have been imported yet.")
                )
            }
        }
        .navigationTitle(definition.shortName)
    }

    // MARK: - Chart

    private var chartView: some View {
        Chart {
            // Reference range band
            RectangleMark(
                xStart: .value("Start", results.first?.effectiveDate ?? .now),
                xEnd: .value("End", results.last?.effectiveDate ?? .now),
                yStart: .value("Low", definition.normalRangeLow),
                yEnd: .value("High", definition.normalRangeHigh)
            )
            .foregroundStyle(.green.opacity(0.1))

            // Data points and line
            ForEach(results, id: \.id) { result in
                LineMark(
                    x: .value("Date", result.effectiveDate),
                    y: .value(definition.unit, result.value)
                )
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", result.effectiveDate),
                    y: .value(definition.unit, result.value)
                )
                .foregroundStyle(statusColor(for: result))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .padding(.horizontal)
    }

    // MARK: - Helpers

    private func statusColor(for result: ClinicalLabResult) -> Color {
        let low = result.referenceRangeLow ?? definition.normalRangeLow
        let high = result.referenceRangeHigh ?? definition.normalRangeHigh
        if result.value < low { return .orange }
        if result.value > high { return .red }
        return .green
    }

    private func formatted(_ value: Double) -> String {
        if value == value.rounded() && value < 10000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func interpretationLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "Normal"
        case "H": return "High"
        case "L": return "Low"
        case "HH": return "Critical High"
        case "LL": return "Critical Low"
        case "A": return "Abnormal"
        default: return code
        }
    }
}
