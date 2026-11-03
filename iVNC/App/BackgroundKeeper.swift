import CoreLocation

/// 앱을 나가도 맥과의 연결을 붙잡아 두려고 위치를 아주 낮은 정확도로 켜 둔다 (위치 값은 쓰지 않는다).
/// iOS 는 위치를 받는 중인 앱을 백그라운드에서 멈추지 않는다 (터미널 앱 Blink 와 같은 방식).
@MainActor
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()
    private let manager = CLLocationManager()
    /// 권한을 묻는 중에 켜 달라고 했는지 (허용되면 바로 켠다)
    private var wanted = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        wanted = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: begin()
        default: DebugLog.write("백그라운드 유지: 위치 권한이 없어 못 켬")
        }
    }

    func stop() {
        guard wanted else { return }
        wanted = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        DebugLog.write("백그라운드 유지: 위치 끔")
    }

    private func begin() {
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        DebugLog.write("백그라운드 유지: 위치 켬")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            let s = self.manager.authorizationStatus
            if self.wanted, s == .authorizedWhenInUse || s == .authorizedAlways { self.begin() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
