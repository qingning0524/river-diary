import CoreLocation
import Foundation
import MapKit
import RiverDiaryCore

@MainActor
protocol MapPlaceProvider {
    func candidates(for location: CLLocation) async throws -> [RiverPlaceCandidate]
}

/// Apple-backed provider kept behind a narrow interface so a region-specific
/// provider can be added later without changing Place clustering or authority.
@MainActor
final class AppleMapPlaceProvider: MapPlaceProvider {
    func candidates(for location: CLLocation) async throws -> [RiverPlaceCandidate] {
        let accuracy = max(0, location.horizontalAccuracy)
        let provider = "Apple Maps"
        let reverseTask = Task { try await reverseGeocode(location, provider: provider, accuracy: accuracy) }
        let poiTask = Task { try await nearestPointOfInterest(to: location) }
        let reverseResult = await reverseTask.result
        let poiResult = await poiTask.result
        let reverseCandidates = (try? reverseResult.get()) ?? []
        let fallbackAddress = reverseCandidates.compactMap(\.address).first
        let points = (try? poiResult.get()) ?? []
        let poiCandidates = points.compactMap { item -> RiverPlaceCandidate? in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let itemLocation = item.placemark.location else { return nil }
            return RiverPlaceCandidate(
                name: name,
                address: item.placemark.title ?? fallbackAddress,
                category: item.pointOfInterestCategory?.rawValue,
                provider: provider,
                distanceMeters: itemLocation.distance(from: location),
                horizontalAccuracyMeters: accuracy
            )
        }
        var seen = Set<String>()
        var candidates = poiCandidates.sorted { $0.distanceMeters < $1.distanceMeters }
            .filter { seen.insert($0.id).inserted }
        candidates.append(contentsOf: reverseCandidates
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .filter { seen.insert($0.id).inserted })
        if !candidates.isEmpty { return Array(candidates.prefix(4)) }
        if case .failure(let error) = reverseResult { throw error }
        if case .failure(let error) = poiResult { throw error }
        return []
    }

    private func reverseGeocode(_ location: CLLocation, provider: String,
                                accuracy: CLLocationDistance) async throws -> [RiverPlaceCandidate] {
        if #available(iOS 26.0, *) {
            if let request = MKReverseGeocodingRequest(location: location) {
                request.preferredLocale = Locale(identifier: "zh_CN")
                if let items = try? await request.mapItems {
                    let candidates = items.compactMap { item in
                        Self.candidate(from: item, location: location, provider: provider,
                                       accuracy: accuracy, category: item.pointOfInterestCategory?.rawValue)
                    }
                    if !candidates.isEmpty { return candidates }
                }
            }
        }

        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let place = placemarks.first else { return [] }
        let address = [place.subThoroughfare, place.thoroughfare, place.subLocality,
                       place.locality, place.administrativeArea, place.postalCode, place.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let name = [place.name, place.thoroughfare, place.locality]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) ?? (address.isEmpty ? nil : address) else { return [] }
        return [RiverPlaceCandidate(
            name: name,
            address: address.isEmpty ? nil : address,
            provider: provider,
            distanceMeters: place.location?.distance(from: location) ?? 0,
            horizontalAccuracyMeters: accuracy
        )]
    }

    private static func candidate(from item: MKMapItem, location: CLLocation,
                                  provider: String, accuracy: CLLocationDistance,
                                  category: String?) -> RiverPlaceCandidate? {
        guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let itemLocation = item.placemark.location else { return nil }
        return RiverPlaceCandidate(
            name: name,
            address: item.placemark.title,
            category: category,
            provider: provider,
            distanceMeters: itemLocation.distance(from: location),
            horizontalAccuracyMeters: accuracy
        )
    }

    private func nearestPointOfInterest(to location: CLLocation) async throws -> [MKMapItem] {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 250)
        request.pointOfInterestFilter = .includingAll
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
            .compactMap { item -> (MKMapItem, CLLocationDistance)? in
                guard let itemLocation = item.placemark.location else { return nil }
                return (item, itemLocation.distance(from: location))
            }
            .filter { $0.1 <= 250 }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
            .map(\.0)
    }
}
