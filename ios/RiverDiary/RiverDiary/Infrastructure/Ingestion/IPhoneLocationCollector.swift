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
    @Published private(set) var isRequestingPrecisionSample = false
    @Published private(set) var latestSampleAccuracyMeters: CLLocationAccuracy?

    private let manager = CLLocationManager()
    private let database: RiverLocalDatabase
    private let preferences: UserDefaults
    private var sessionActive = true
    private var collectionGeneration = UUID()
    private let mapProvider: any MapPlaceProvider
    private var lastRecordedLocation: CLLocation?
    private var lastRecordedAt: Date?
    private var lastResolvedLocation: CLLocation?
    private var lastResolvedAt: Date?
    private var lastFailedResolveLocation: CLLocation?
    private var lastFailedResolveAt: Date?
    private var didRetryLatestUnresolvedPlace = false
    private var precisionSampleManager: CLLocationManager?
    private var precisionSampleBestLocation: CLLocation?
    private var precisionSampleTimeout: DispatchWorkItem?
    private let preferenceKey = "river.location.enabled"
    private let maximumPrecisionSampleAccuracy: CLLocationAccuracy = 100
    private let earlyPrecisionSampleAccuracy: CLLocationAccuracy = 30

    init(database: RiverLocalDatabase, mapProvider: (any MapPlaceProvider)? = nil, preferences: UserDefaults = .standard) {
        self.database = database
        self.preferences = preferences
        self.mapProvider = mapProvider ?? AppleMapPlaceProvider()
        self.isEnabled = preferences.bool(forKey: preferenceKey)
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
        collectionGeneration = UUID()
        isEnabled = enabled
        preferences.set(enabled, forKey: preferenceKey)
        guard enabled else {
            stopCollection()
            return
        }
        guard sessionActive else { return }
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

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        collectionGeneration = UUID()
        if active { startIfAuthorized() }
        else { stopCollection() }
    }

    private func stopCollection() {
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        precisionSampleTimeout?.cancel()
        precisionSampleTimeout = nil
        precisionSampleManager?.stopUpdatingLocation()
        precisionSampleManager?.delegate = nil
        precisionSampleManager = nil
        precisionSampleBestLocation = nil
        isRequestingPrecisionSample = false
    }

    func requestPrecisionSample() {
        guard sessionActive, isEnabled,
              authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            lastError = "先启用位置记录并允许 River Diary 使用位置。"
            return
        }
        guard !isRequestingPrecisionSample else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            lastError = "系统定位服务已关闭；当前位置没有记录。"
            return
        }
        guard manager.accuracyAuthorization == .fullAccuracy else {
            lastError = "系统目前只允许大致位置。请在 iPhone 设置 > River Diary > 位置中打开“精确位置”后重试。"
            return
        }

        let sampleManager = CLLocationManager()
        sampleManager.delegate = self
        sampleManager.desiredAccuracy = kCLLocationAccuracyBest
        sampleManager.distanceFilter = kCLDistanceFilterNone
        precisionSampleManager = sampleManager
        precisionSampleBestLocation = nil
        latestSampleAccuracyMeters = nil
        isRequestingPrecisionSample = true
        lastError = "正在获取高精度位置，请稍候……"
        sampleManager.startUpdatingLocation()

        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.finishPrecisionSample() }
        }
        precisionSampleTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
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
            guard let self, sessionActive, isEnabled else { return }
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
            guard let self, sessionActive, isEnabled else { return }
            if manager === precisionSampleManager {
                considerPrecisionLocations(copiedLocations)
                return
            }
            handleLocationUpdates(copiedLocations)
        }
    }

    func handleLocationUpdates(_ locations: [CLLocation]) {
        guard sessionActive, isEnabled else { return }
        for location in locations { recordSignificantLocation(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if manager === precisionSampleManager {
                if (error as? CLError)?.code != .locationUnknown {
                    finishPrecisionSample(errorMessage: error.localizedDescription)
                }
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    private func considerPrecisionLocations(_ locations: [CLLocation]) {
        guard isRequestingPrecisionSample else { return }
        let now = Date()
        for location in locations where location.coordinate.latitude.isFinite
            && location.coordinate.longitude.isFinite
            && location.horizontalAccuracy >= 0
            && now.timeIntervalSince(location.timestamp) <= 15
            && location.timestamp <= now.addingTimeInterval(5) {
            if let best = precisionSampleBestLocation,
               best.horizontalAccuracy <= location.horizontalAccuracy {
                continue
            }
            precisionSampleBestLocation = location
        }
        if let best = precisionSampleBestLocation,
           best.horizontalAccuracy <= earlyPrecisionSampleAccuracy {
            finishPrecisionSample()
        }
    }

    private func finishPrecisionSample(errorMessage: String? = nil) {
        guard isRequestingPrecisionSample else { return }
        precisionSampleTimeout?.cancel()
        precisionSampleTimeout = nil
        precisionSampleManager?.stopUpdatingLocation()
        precisionSampleManager?.delegate = nil
        precisionSampleManager = nil
        isRequestingPrecisionSample = false

        guard let location = precisionSampleBestLocation else {
            precisionSampleBestLocation = nil
            lastError = errorMessage.map { "定位失败：\($0)" }
                ?? "20 秒内没有获得有效位置；请到室外或靠近窗边后重试。"
            return
        }
        precisionSampleBestLocation = nil
        latestSampleAccuracyMeters = location.horizontalAccuracy
        guard location.horizontalAccuracy <= maximumPrecisionSampleAccuracy else {
            lastError = "系统给出的位置误差约 ±\(Int(location.horizontalAccuracy.rounded())) 米，超过 100 米，本次未作为准确标点保存。请打开“精确位置”并到室外重试。"
            return
        }
        recordPrecisionSample(location)
    }

    private func recordPrecisionSample(_ location: CLLocation) {
        let coordinate = location.coordinate
        let payload = RiverEventPayload(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy
        )
        let stableKey = "precision|\(location.timestamp.timeIntervalSince1970)|\(coordinate.latitude)|\(coordinate.longitude)"
        persistLocation(
            payload,
            kind: "location.precisionSample",
            observedAt: location.timestamp,
            stableSourceKey: stableKey
        )
        lastRecordedLocation = location
        lastRecordedAt = location.timestamp
        resolvePlaceIfNeeded(for: location, sourceEventKind: "location.precisionSample")
    }

    private func startIfAuthorized() {
        guard sessionActive, isEnabled,
              authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        manager.startMonitoringVisits()
        manager.startMonitoringSignificantLocationChanges()
        retryLatestUnresolvedPlaceIfNeeded()
        lastError = authorizationStatus == .authorizedAlways
            ? nil
            : "当前只在使用 App 时记录；若要后台接收地点到访，请在系统提示中允许“始终”。"
    }

    private func retryLatestUnresolvedPlaceIfNeeded() {
        guard !didRetryLatestUnresolvedPlace, let lastRecordedLocation,
              !database.hasRecentPlaceCandidate(
                  near: lastRecordedLocation.coordinate.latitude,
                  longitude: lastRecordedLocation.coordinate.longitude,
                  since: Date().addingTimeInterval(-30 * 60)
              ) else { return }
        didRetryLatestUnresolvedPlace = true
        resolvePlaceIfNeeded(for: lastRecordedLocation, sourceEventKind: "location.recheck")
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
        guard sessionActive, isEnabled else { return }
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
        guard sessionActive, isEnabled, shouldResolvePlace(at: location) else { return }
        let generation = collectionGeneration
        lastResolvedLocation = location
        lastResolvedAt = Date()
        latestLocationName = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await mapProvider.candidates(for: location)
                guard sessionActive, isEnabled, collectionGeneration == generation else { return }
                guard let candidate = candidates.first else {
                    recordPlaceResolutionFailure("地图没有返回附近商户或地址；坐标仍已保存，稍后会重试。", at: location)
                    return
                }
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
                    mapResultIdentifier: candidate.resultIdentifier,
                    mapCandidates: candidates
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
                latestLocationName = candidate.name
                lastError = nil
                lastFailedResolveLocation = nil
                lastFailedResolveAt = nil
                database.refreshTimeline()
            } catch {
                // A geocoder failure never removes the underlying location observation.
                recordPlaceResolutionFailure(error.localizedDescription, at: location)
            }
        }
    }

    private func recordPlaceResolutionFailure(_ message: String, at location: CLLocation) {
        lastError = "地图地点识别失败：\(message)"
        latestLocationName = nil
        lastFailedResolveLocation = location
        lastFailedResolveAt = Date()
        if let lastResolvedLocation, location.distance(from: lastResolvedLocation) < 1 {
            self.lastResolvedLocation = nil
            lastResolvedAt = nil
        }
    }

    private func shouldResolvePlace(at location: CLLocation) -> Bool {
        let now = Date()
        if let lastFailedResolveLocation, let lastFailedResolveAt,
           location.distance(from: lastFailedResolveLocation) < 250,
           now.timeIntervalSince(lastFailedResolveAt) < 2 * 60 {
            return false
        }
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
