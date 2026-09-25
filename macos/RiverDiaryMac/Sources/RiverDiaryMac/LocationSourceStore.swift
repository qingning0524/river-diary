import CoreLocation
import Foundation

/// macOS location source. It is opt-in and does not request permission on launch.
@MainActor
final class LocationSourceStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var latestPlaceName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var errorMessage: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private lazy var factStore = V2Store()
    private var lastRecordedLocation: CLLocation?
    private var lastRecordedAt: Date?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        authorizationStatus = manager.authorizationStatus
        restoreLatestLocation()
    }

    var statusState: SourceHealthState {
        if let errorMessage, !errorMessage.isEmpty { return .error }
        if latestLocation != nil { return .healthy }
        if isConnected { return .collecting }
        if authorizationStatus == .denied || authorizationStatus == .restricted { return .paused }
        return .missing
    }

    var statusDetail: String {
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        if let latestPlaceName, !latestPlaceName.isEmpty { return Self.recentPlaceDetail(latestPlaceName) }
        if latestLocation != nil { return "最近位置已在本机收到" }
        if isConnected { return "等待位置权限或定位结果" }
        if authorizationStatus == .denied || authorizationStatus == .restricted { return "系统位置权限未开启" }
        return "点击连接位置后开始"
    }

    static func recentPlaceDetail(_ placeName: String) -> String {
        "最近位置：\(placeName)"
    }

    func connect() {
        errorMessage = nil
        isConnected = true
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func disconnect() {
        manager.stopUpdatingLocation()
        isConnected = false
    }

    private func restoreLatestLocation() {
        guard let event = factStore.latestRawEvent(source: .location, kind: .locationUpdate),
              let latitude = event.payload.latitude,
              let longitude = event.payload.longitude else { return }
        latestLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: event.payload.horizontalAccuracy ?? 0,
            verticalAccuracy: -1,
            timestamp: event.timestamp
        )
        lastRecordedLocation = latestLocation
        lastRecordedAt = event.timestamp
        latestPlaceName = event.payload.locationName
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            authorizationStatus = manager.authorizationStatus
            if authorizationStatus == .authorized {
                if isConnected { manager.startUpdatingLocation() }
            } else if authorizationStatus == .denied || authorizationStatus == .restricted {
                errorMessage = "系统位置权限未开启"
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            latestLocation = location
            record(location)
            geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
                let name = placemarks?.first?.name ?? placemarks?.first?.locality
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    latestPlaceName = name
                }
            }
        }
    }

    private func record(_ location: CLLocation) {
        if let lastRecordedLocation,
           let lastRecordedAt,
           location.timestamp.timeIntervalSince(lastRecordedAt) < 60,
           location.distance(from: lastRecordedLocation) < 100 {
            return
        }

        let event = RawEvent(
            timestamp: location.timestamp,
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy,
                locationName: latestPlaceName
            )
        )
        _ = factStore.insertRawEvent(event)
        lastRecordedLocation = location
        lastRecordedAt = location.timestamp
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.errorMessage = error.localizedDescription
        }
    }
}
