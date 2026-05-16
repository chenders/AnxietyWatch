import SwiftUI

/// Section header used inside Dashboard. Title + optional chevron + optional
/// preview text on the right. Decorative — does not push any navigation by
/// itself; if a section needs to push, wrap the header in a `Button` /
/// `NavigationLink` at the call site.
struct SectionHeader: View {
    let title: String
    var preview: String? = nil
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
            Spacer()
            if let preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}
