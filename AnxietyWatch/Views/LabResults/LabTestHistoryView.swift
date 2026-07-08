import Charts
import SwiftData
import SwiftUI

/// Shows all historical values for a single lab test with a trend chart
/// and reference range bands.
struct LabTestHistoryView: View, Equatable {
    let loincCode: String
    let definition: LabTestRegistry.TestDefinition

    // Bounded to this test's LOINC code at the SwiftData layer (single-clause
    // #Predicate — safe from the compound-predicate hang) and sorted ascending
    // in SQLite, rather than fetching the whole ClinicalLabResult table and
    // filter+sorting it in an uncached computed property on every access
    // (F-070). loincCode is captured from init.
    @Query private var allResults: [ClinicalLabResult]

    init(loincCode: String, definition: LabTestRegistry.TestDefinition) {
        self.loincCode = loincCode
        self.definition = definition
        _allResults = Query(
            filter: #Predicate<ClinicalLabResult> { $0.loincCode == loincCode },
            sort: \ClinicalLabResult.effectiveDate
        )
    }

    // Equatable on `loincCode` (stable identity) only; paired with `.equatable()`
    // at the NavigationLink destination call site so SwiftUI dedupes rebuilds when
    // the parent body re-runs. Default memberwise comparison can't dedupe because
    // @Query state is part of the struct. See CLAUDE.md render-pitfall #2.
    static func == (lhs: LabTestHistoryView, rhs: LabTestHistoryView) -> Bool {
        lhs.loincCode == rhs.loincCode
    }

    /// Already filtered to `loincCode` and sorted ascending by the @Query — a
    /// plain passthrough so `body` and `labChartData` share one array with no
    /// per-access filter/sort work.
    private var results: [ClinicalLabResult] { allResults }

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

    private var labChartData: [LabChartDatum] {
        var data: [LabChartDatum] = []
        if let first = results.first?.effectiveDate, let last = results.last?.effectiveDate {
            data.append(.referenceRange(xStart: first, xEnd: last,
                                        yLow: definition.normalRangeLow, yHigh: definition.normalRangeHigh))
        }
        data += results.map { .result($0) }
        return data
    }

    private var chartView: some View {
        Chart(labChartData) { datum in
            switch datum {
            case .referenceRange(let xStart, let xEnd, let yLow, let yHigh):
                RectangleMark(
                    xStart: .value("Start", xStart),
                    xEnd: .value("End", xEnd),
                    yStart: .value("Low", yLow),
                    yEnd: .value("High", yHigh)
                )
                .foregroundStyle(.green.opacity(0.1))
            case .result(let result):
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
        // See LabResultsView.statusColor — neutral when no unit-compatible
        // range exists rather than a wrong cross-unit LOW/HIGH (F-008).
        guard let range = LabTestRegistry.applicableRange(for: result) else { return .secondary }
        if let low = range.low, result.value < low { return .orange }
        if let high = range.high, result.value > high { return .red }
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

private enum LabChartDatum: Identifiable {
    case referenceRange(xStart: Date, xEnd: Date, yLow: Double, yHigh: Double)
    case result(ClinicalLabResult)

    var id: String {
        switch self {
        case .referenceRange: "reference-range"
        case .result(let r): "result-\(r.id)"
        }
    }
}
