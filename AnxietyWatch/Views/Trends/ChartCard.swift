import SwiftUI

/// Consistent container for all trend charts.
struct ChartCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let isEmpty: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isEmpty {
                Text("No data for this period")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
            } else {
                content()
            }
        }
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }
}
