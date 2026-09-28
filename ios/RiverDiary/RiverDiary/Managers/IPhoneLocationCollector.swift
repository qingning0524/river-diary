import CoreLocation
import CryptoKit
import Foundation
import MapKit
import RiverDiaryCore
import SwiftUI

@MainActor
final class IPhoneLocationCollector: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var isEnabled: Bool
    @Published private(set) var latestLocationName: String?
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()
    private let database: RiverLocalDatabase
    private let mapProvider: any MapPlaceProvider
    private var lastRecordedLocation: CLLocation?
    private var lastRecordedAt: Date?
    private var lastResolvedLocation: CLLocation?
    private var lastResolvedAt: Date?
    private let preferenceKey = "river.location.enabled"

    init(database: RiverLocalDatabase, mapProvider: (any MapPlaceProvider)? = nil) {
        self.database = database
        self.mapProvider = mapProvider ?? AppleMapPlaceProvider()
        self.isEnabled = UserDefaults.standard.bool(forKey: preferenceKey)
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        restoreRecentLocationState()
        if isEnabled { startIfAuthorized() }
    }

    var statusText: String {
        switch authorizationStatus {
        case .authorizedAlways: "始终允许"
        case .authorizedWhenInUse: "使用 App 时允许"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        case .notDetermined: "尚未授权"
        @unknown default: "未知状态"
        }
    }

    var backgroundDeliveryAvailable: Bool { authorizationStatus == .authorizedAlways }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        guard enabled else {
            manager.stopMonitoringVisits()
            manager.stopMonitoringSignificantLocationChanges()
            return
        }
        guard CLLocationManager.locationServicesEnabled() else {
            lastError = "系统定位服务已关闭。请在 iPhone 设置中开启定位服务。"
            return
        }
        if authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        } else if authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        } else {
            startIfAuthorized()
        }
    }

    func requestPrecisionSample() {
        guard isEnabled,
              authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            lastError = "先启用位置记录并允许 River Diary 使用位置。"
            return
        }
        manager.requestLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            authorizationStatus = manager.authorizationStatus
            if authorizationStatus == .denied || authorizationStatus == .restricted {
                lastError = "系统位置权限未开启；位置记录已暂停。"
                manager.stopMonitoringVisits()
                manager.stopMonitoringSignificantLocationChanges()
            } else if isEnabled {
                startIfAuthorized()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if visit.arrivalDate != .distantPast {
                recordVisit(visit, transition: "arrival", at: visit.arrivalDate)
            }
            if visit.departureDate != .distantFuture {
                recordVisit(visit, transition: "departure", at: visit.departureDate)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let copiedLocations = locations
        Task { @MainActor [weak self] in
            guard let self else { return }
            for location in copiedLocations {
                recordSignificantLocation(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.lastError = error.localizedDescription }
    }

    private func startIfAuthorized() {
        guard isEnabled,
              authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        manager.startMonitoringVisits()
        manager.startMonitoringSignificantLocationChanges()
        lastError = authorizationStatus == .authorizedAlways
            ? nil
            : "当前只在使用 App 时记录；若要后台接收地点到访，请在系统提示中允许“始终”。"
    }

    private func recordVisit(_ visit: CLVisit, transition: String, at timestamp: Date) {
        let coordinate = visit.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              visit.horizontalAccuracy >= 0 else { return }
        let payload = RiverEventPayload(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: visit.horizontalAccuracy
        )
        persistLocation(
            payload,
            kind: "location.visit.\(transition)",
            observedAt: timestamp,
            stableSourceKey: "visit|\(transition)|\(timestamp.timeIntervalSince1970)|\(coordinate.latitude)|\(coordinate.longitude)"
        )
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        resolvePlaceIfNeeded(for: location, sourceEventKind: "location.visit.\(transition)")
    }

    private func recordSignificantLocation(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0,
              Date().timeIntervalSince(location.timestamp) <= 300,
              location.timestamp <= Date().addingTimeInterval(30) else { return }
        if let lastRecordedLocation, let lastRecordedAt,
           location.timestamp.timeIntervalSince(lastRecordedAt) < 60,
           location.distance(from: lastRecordedLocation) < 100 { return }

        let payload = RiverEventPayload(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy
        )
        persistLocation(
            payload,
            kind: "location.significant",
            observedAt: location.timestamp,
            stableSourceKey: "significant|\(location.timestamp.timeIntervalSince1970)|\(location.coordinate.latitude)|\(location.coordinate.longitude)"
        )
        lastRecordedLocation = location
        lastRecordedAt = location.timestamp
        resolvePlaceIfNeeded(for: location, sourceEventKind: "location.significant")
    }

    private func persistLocation(_ payload: RiverEventPayload, kind: String, observedAt: Date, stableSourceKey: String) {
        do {
            let sourceHash = Self.sha256(Data(stableSourceKey.utf8))
            _ = try database.append(
                id: RiverStableIdentifier.uuid(namespace: database.deviceID.rawValue, key: stableSourceKey),
                source: "core_location",
                kind: kind,
                payload: payload,
                observedAt: observedAt,
                sourceHash: sourceHash
            )
            database.refreshTimeline()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func resolvePlaceIfNeeded(for location: CLLocation, sourceEventKind: String) {
        guard shouldResolvePlace(at: location) else { return }
        lastResolvedLocation = location
        lastResolvedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let candidate = try await mapProvider.candidate(for: location) else { return }
                let coordinate = location.coordinate
                let sourceKey = "place-candidate|\(sourceEventKind)|\(Int(coordinate.latitude * 10_000))|\(Int(coordinate.longitude * 10_000))"
                let payload = RiverEventPayload(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    horizontalAccuracy: location.horizontalAccuracy,
                    locationName: candidate.name,
                    mapAddress: candidate.address,
                    poiCategory: candidate.category,
                    mapProvider: candidate.provider,
                    mapResultIdentifier: candidate.resultIdentifier
                )
                let bytes = try JSONEncoder().encode(payload)
                let hash = Self.sha256(bytes)
                _ = try database.append(
                    id: RiverStableIdentifier.uuid(namespace: database.deviceID.rawValue, key: "\(sourceKey)|\(hash)"),
                    source: "mapkit",
                    kind: "location.placeCandidate",
                    payload: payload,
                    observedAt: location.timestamp,
                    sourceHash: hash
                )
                latestLocationName = candidate.name ?? candidate.address
                database.refreshTimeline()
            } catch {
                // Geocoding enriches an already persisted observation. A map
                // service failure never removes the underlying location event.
                lastError = error.localizedDescription
            }
        }
    }

    private func shouldResolvePlace(at location: CLLocation) -> Bool {
        let now = Date()
        if let lastResolvedLocation, let lastResolvedAt,
           location.distance(from: lastResolvedLocation) < 250,
           now.timeIntervalSince(lastResolvedAt) < 30 * 60 {
            return false
        }
        if database.hasRecentPlaceCandidate(
            near: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            since: now.addingTimeInterval(-30 * 60)
        ) {
            lastResolvedLocation = location
            lastResolvedAt = now
            return false
        }
        return true
    }

    private func restoreRecentLocationState() {
        guard let events = try? database.allEvents() else { return }
        let locationEvents = events.filter { $0.source == "core_location" || $0.source == "mapkit" }
        if let latest = locationEvents.filter({ $0.source == "core_location" }).max(by: { $0.observedAt < $1.observedAt }),
           let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: latest.payload),
           let latitude = payload.latitude, let longitude = payload.longitude {
            lastRecordedAt = latest.observedAt
            lastRecordedLocation = CLLocation(latitude: latitude, longitude: longitude)
        }
        if let latestCandidate = locationEvents.filter({ $0.kind == "location.placeCandidate" }).max(by: { $0.observedAt < $1.observedAt }),
           let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: latestCandidate.payload),
           let latitude = payload.latitude, let longitude = payload.longitude {
            lastResolvedAt = latestCandidate.observedAt
            lastResolvedLocation = CLLocation(latitude: latitude, longitude: longitude)
            latestLocationName = payload.locationName
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
