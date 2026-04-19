import SwiftUI

/// Mode determines behavior after selection.
enum SongSearchMode {
    /// Browsing catalog — selecting navigates to detail
    case catalog
    /// Picking for journal/check-in — selecting returns the song via binding
    case picker(Binding<Song?>)
}

struct SongSearchSheet: View {
    let mode: SongSearchMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Song Search — coming soon")
                .navigationTitle("Search Songs")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}
