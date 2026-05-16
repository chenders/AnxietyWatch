import SwiftUI

/// Thin view shell over `SmartSummaryComposer.Output`. The composer does all
/// the reasoning; this just renders the result.
struct SmartSummaryCard: View {
    let summary: SmartSummaryComposer.Output

    var body: some View {
        switch summary.kind {
        case .quiet:
            HStack {
                Text(summary.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
            .accessibilityLabel(summary.text)
        case .summary:
            VStack(alignment: .leading, spacing: 6) {
                Text("What changed today".uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple)
                    .tracking(0.5)
                Text(summary.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.purple.opacity(0.12), .indigo.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: .rect(cornerRadius: 14)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.purple.opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("What changed today: \(summary.text)")
        }
    }
}
