import CoreLocation
import Foundation
import MapKit

struct MapPlaceCandidate: Sendable {
    let name: String?
    let address: String?
    let category: String?
    let provider: String
    let resultIdentifier: String?
}

@MainActor
protocol MapPlaceProvider {
    func candidate(for location: CLLocation) async throws -> MapPlaceCandidate?
}

/// Apple-backed provider kept behind a narrow interface so a region-specific
/// provider can be added later without changing Place clustering or authority.
@MainActor
final class AppleMapPlaceProvider: MapPlaceProvider {
    private let geocoder = CLGeocoder()

    func candidate(for location: CLLocation) async throws -> MapPlaceCandidate? {
        async let placemarks = geocoder.reverseGeocodeLocation(location)
        async let poi = nearestPointOfInterest(to: location)
        let place = try await placemarks.first
        let point = try await poi
        let address = [place?.subThoroughfare, place?.thoroughfare, place?.subLocality,
                       place?.locality, place?.administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let name = point?.name ?? place?.name ?? place?.locality
        guard name != nil || !address.isEmpty else { return nil }
        return MapPlaceCandidate(
            name: name,
            address: address.isEmpty ? nil : address,
            category: point?.pointOfInterestCategory?.rawValue,
            provider: "MapKit + CLGeocoder",
            resultIdentifier: nil
        )
    }

    private func nearestPointOfInterest(to location: CLLocation) async throws -> MKMapItem? {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 250)
        request.pointOfInterestFilter = .includingAll
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
            .compactMap { item -> (MKMapItem, CLLocationDistance)? in
                guard let itemLocation = item.placemark.location else { return nil }
                return (item, itemLocation.distance(from: location))
            }
            .filter { $0.1 <= 250 }
            .min { $0.1 < $1.1 }?.0
    }
}
