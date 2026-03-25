import MapKit
import SwiftUI

struct PharmacySearchView: View {
    let onSelect: (PharmacySearchService.PharmacySearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [PharmacySearchService.PharmacySearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchMap
                resultsList
            }
            .navigationTitle("Search Pharmacies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Subviews

    private var searchMap: some View {
        Map(position: $cameraPosition) {
            ForEach(results) { result in
                Marker(result.name, coordinate: result.coordinate)
            }
        }
        .frame(height: 220)
        .searchable(text: $searchText, prompt: "Search pharmacies...")
        .onSubmit(of: .search) {
            performSearch()
        }
    }

    private var resultsList: some View {
        Group {
            if isSearching {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Search Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if results.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(results) { result in
                    SearchResultRow(result: result)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(result)
                        }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Search

private extension PharmacySearchView {
    func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        results = []

        Task {
            do {
                let found = try await PharmacySearchService.search(query: query)
                results = found
                if let first = found.first {
                    cameraPosition = .region(
                        MKCoordinateRegion(
                            center: first.coordinate,
                            latitudinalMeters: 10_000,
                            longitudinalMeters: 10_000
                        )
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}

// MARK: - Row Subview

private struct SearchResultRow: View {
    let result: PharmacySearchService.PharmacySearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.name)
                .font(.headline)
            if !result.address.isEmpty {
                Text(result.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let phone = result.phoneNumber {
                Text(phone)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
