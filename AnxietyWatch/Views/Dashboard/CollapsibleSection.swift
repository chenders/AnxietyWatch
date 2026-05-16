import SwiftUI

/// Disclosure-style section. Persists expansion state per `id` via @AppStorage
/// so the user's choice survives app launches.
struct CollapsibleSection<Content: View>: View {
    let id: String
    let title: String
    var preview: String?
    @ViewBuilder let content: () -> Content

    @AppStorage private var expanded: Bool

    init(
        id: String,
        title: String,
        preview: String? = nil,
        defaultExpanded: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.content = content
        self._expanded = AppStorage(wrappedValue: defaultExpanded, "dashboard.section.\(id).expanded")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    if let preview {
                        Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Tap to collapse" : "Tap to expand")

            if expanded {
                content()
            }
        }
    }
}
