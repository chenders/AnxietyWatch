import SwiftUI

/// Compact "Care" row that pushes the existing `LabResultsView`. Replaces the
/// previous full lab-results section that surfaced up to 4 latest results
/// inline. Recent count comes from the parent.
struct CareSectionRowView: View {
    let recentLabResultsCount: Int

    var body: some View {
        NavigationLink {
            LabResultsView()
                .equatable()
        } label: {
            HStack {
                Text("Care").font(.headline)
                Spacer()
                if recentLabResultsCount > 0 {
                    Text("\(recentLabResultsCount) recent lab result\(recentLabResultsCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recentLabResultsCount > 0
            ? "Care, \(recentLabResultsCount) recent lab result\(recentLabResultsCount == 1 ? "" : "s")"
            : "Care"
        )
        .accessibilityHint("Tap to view lab results")
    }
}
