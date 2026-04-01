import SwiftData
import SwiftUI

/// Full lab results view grouped by test category.
/// Accessible from Dashboard and Settings.
struct LabResultsView: View {
    @Query(sort: \ClinicalLabResult.effectiveDate, order: .reverse)
    private var allResults: [ClinicalLabResult]

    var body: some View {
        Group {
            if allResults.isEmpty {
                ContentUnavailableView(
                    "No Lab Results",
                    systemImage: "flask",
                    description: Text("To see lab results here, link your hospital in the Health app.\n\nSettings → Health → Health Records → Get Started")
                )
            } else {
                List {
                    ForEach(LabTestRegistry.TestCategory.allCases) { category in
                        let categoryResults = latestPerTest(in: category)
                        if !categoryResults.isEmpty {
                            Section(category.rawValue) {
                                ForEach(categoryResults, id: \.loincCode) { result in
                                    if let def = LabTestRegistry.definition(for: result.loincCode) {
                                        NavigationLink {
                                            LabTestHistoryView(loincCode: result.loincCode, definition: def)
                                        } label: {
                                            labResultRow(result, definition: def)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Lab Results")
    }

    // MARK: - Row View

    private func labResultRow(_ result: ClinicalLabResult, definition: LabTestRegistry.TestDefinition) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.shortName)
                    .font(.body)
                Text(result.effectiveDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formattedValue(result.value) + " " + result.unit)
                .font(.body.bold())
                .foregroundStyle(statusColor(for: result, definition: definition))
        }
    }

    // MARK: - Helpers

    /// Returns the most recent result for each tracked test in a given category.
    private func latestPerTest(in category: LabTestRegistry.TestCategory) -> [ClinicalLabResult] {
        let categoryLoincCodes = Set(LabTestRegistry.definitions(in: category).map(\.loincCode))
        var latest: [String: ClinicalLabResult] = [:]

        for result in allResults where categoryLoincCodes.contains(result.loincCode) {
            if latest[result.loincCode] == nil {
                // allResults is sorted descending by date, so first match is latest
                latest[result.loincCode] = result
            }
        }

        // Sort by the registry order within the category
        let orderedCodes = LabTestRegistry.definitions(in: category).map(\.loincCode)
        return orderedCodes.compactMap { latest[$0] }
    }

    private func statusColor(for result: ClinicalLabResult, definition: LabTestRegistry.TestDefinition) -> Color {
        let low = result.referenceRangeLow ?? definition.normalRangeLow
        let high = result.referenceRangeHigh ?? definition.normalRangeHigh
        if result.value < low { return .orange }
        if result.value > high { return .red }
        return .green
    }

    private func formattedValue(_ value: Double) -> String {
        if value == value.rounded() && value < 10000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    NavigationStack {
        LabResultsView()
    }
    .modelContainer(container)
}
#endif
