import MapKit

/// Stateless service for searching nearby pharmacies via MapKit.
enum PharmacySearchService {

    struct PharmacySearchResult: Identifiable {
        let id = UUID()
        let name: String
        let address: String
        let phoneNumber: String?
        let coordinate: CLLocationCoordinate2D
    }

    /// Search for pharmacies matching `query` within the optional `region`.
    /// Falls back to a wide default region when none is provided.
    static func search(
        query: String,
        region: MKCoordinateRegion? = nil
    ) async throws -> [PharmacySearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region {
            request.region = region
        }
        // Restrict to pharmacies / health-related points of interest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.pharmacy])

        let search = MKLocalSearch(request: request)
        let response = try await search.start()

        return response.mapItems.compactMap { item in
            guard let name = item.name else { return nil }
            let placemark = item.placemark
            let address = Self.formattedAddress(from: placemark)
            return PharmacySearchResult(
                name: name,
                address: address,
                phoneNumber: item.phoneNumber,
                coordinate: placemark.coordinate
            )
        }
    }

    // MARK: - Helpers

    /// Build a single-line address string from a placemark's components.
    private static func formattedAddress(from placemark: MKPlacemark) -> String {
        let components: [String?] = [
            placemark.subThoroughfare,
            placemark.thoroughfare,
            placemark.locality,
            placemark.administrativeArea,
            placemark.postalCode
        ]
        return components.compactMap { $0 }.joined(separator: " ")
    }
}
