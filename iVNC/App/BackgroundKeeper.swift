import CoreLocation

/// 앱을 나가도 원격 서버와의 연결을 붙잡아 두려고 위치를 아주 낮은 정확도로 켜 둔다 (위치 값은 쓰지 않는다).
/// iOS 는 위치를 받는 중인 앱을 백그라운드에서 멈추지 않는다 (터미널 앱 Blink 와 같은 방식).
/// 설정 > 일반 > "백그라운드에서 연결 유지" 가 켜져 있고, 연결된 원격 화면·SSH 터미널이 하나라도 있을 때만 켠다
@MainActor
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()
    private let manager = CLLocationManager()
    /// 연결을 붙잡아 달라고 한 쪽들 (원격 화면 세션 · SSH 터미널)
    private var holders = Set<ObjectIdentifier>()
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func start(for owner: AnyObject) {
        holders.insert(ObjectIdentifier(owner))
        refresh()
    }

    func stop(for owner: AnyObject) {
        holders.remove(ObjectIdentifier(owner))
        refresh()
    }

    /// 설정이나 연결이 바뀌면 켜거나 끈다
    func refresh() {
        let want = AppSettings.keepAliveInBackground && !holders.isEmpty
        if want == running { return }
        if want {
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways: begin()
            default: DebugLog.write("백그라운드 유지: 위치 권한이 없어 못 켬")
            }
        } else {
            running = false
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            DebugLog.write("백그라운드 유지: 위치 끔")
        }
    }

    private func begin() {
        running = true
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        DebugLog.write("백그라운드 유지: 위치 켬")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            let s = self.manager.authorizationStatus
            if !self.running, AppSettings.keepAliveInBackground, !self.holders.isEmpty,
               s == .authorizedWhenInUse || s == .authorizedAlways { self.begin() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
