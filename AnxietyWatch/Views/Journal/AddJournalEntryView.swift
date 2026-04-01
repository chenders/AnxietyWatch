import SwiftData
import SwiftUI

struct AddJournalEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \AnxietyEntry.timestamp, order: .reverse)
    private var recentEntries: [AnxietyEntry]

    @State private var severity: Int? = nil
    @State private var notes = ""
    @State private var tagText = ""
    @State private var tags: [String] = []
    @State private var timestamp = Date.now
    @State private var expressMode = true

    /// Express mode: tapping a severity circle saves immediately and dismisses.
    /// Toggle off to add notes/tags before saving.

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    severityPicker
                } header: {
                    Text("How are you feeling?")
                } footer: {
                    if let s = severity {
                        Text(Color.severityLabel(s))
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.severity(s))
                    }
                }

                Section {
                    Toggle("Express Mode", isOn: $expressMode)
                } footer: {
                    Text("When on, tapping a number saves immediately. Turn off to add notes first.")
                }

                if !expressMode {
                    Section("Notes") {
                        TextEditor(text: $notes)
                            .frame(minHeight: 80)
                    }
                }

                Section("Tags") {
                    quickTagChips
                    HStack {
                        TextField("Add tag...", text: $tagText)
                            .onSubmit { addTag() }
                        Button("Add") { addTag() }
                            .disabled(tagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("When") {
                    DatePicker("Time", selection: $timestamp)
                }
            }
            .navigationTitle("New Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(severity == nil)
                }
            }
        }
    }

    // MARK: - Severity Picker

    private var severityPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(1...10, id: \.self) { level in
                Button {
                    severity = level
                    if expressMode {
                        save()
                    }
                } label: {
                    Text("\(level)")
                        .font(.title3.bold())
                        .frame(minWidth: 44, minHeight: 44)
                        .background(
                            Circle()
                                .fill(severity == level
                                      ? Color.severity(level)
                                      : Color.severity(level).opacity(0.25))
                        )
                        .foregroundStyle(severity == level ? .white : Color.severity(level))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Severity \(level), \(Color.severityLabel(level))")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Quick Tag Chips

    /// Most-used tags from recent entries, deduplicated and ranked by frequency.
    private var frequentTags: [String] {
        var counts: [String: Int] = [:]
        for entry in recentEntries.prefix(50) {
            for tag in entry.tags {
                counts[tag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(8)
            .map(\.key)
            .filter { !tags.contains($0) }
    }

    @ViewBuilder
    private var quickTagChips: some View {
        let chips = frequentTags
        if !chips.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(chips, id: \.self) { tag in
                    Button {
                        if !tags.contains(tag) { tags.append(tag) }
                    } label: {
                        Text(tag)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !tags.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        tags.removeAll { $0 == tag }
                    } label: {
                        HStack(spacing: 4) {
                            Text(tag)
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Actions

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespaces).lowercased()
        if !tag.isEmpty && !tags.contains(tag) {
            tags.append(tag)
        }
        tagText = ""
    }

    private func save() {
        guard let severity else { return }
        let entry = AnxietyEntry(
            timestamp: timestamp,
            severity: severity,
            notes: notes,
            tags: tags
        )
        modelContext.insert(entry)
        dismiss()
    }
}

// MARK: - Flow Layout

/// Simple flow layout that wraps children horizontally.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (positions, CGSize(width: maxWidth, height: totalHeight))
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    AddJournalEntryView()
        .modelContainer(container)
}
#endif
