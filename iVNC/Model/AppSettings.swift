import Foundation

/// 앱 설정 (기기마다 저장, iCloud 동기화 안 함: 기기마다 화면이 달라서)
enum AppSettings {
    /// 원격 화면 해상도: 맥 고성능(가상 디스플레이)과 윈도우 접속에 쓴다. 배율 1 (레티나 아님)
    struct Resolution: Hashable, Identifiable {
        let width: Int
        let height: Int
        var id: String { "\(width)x\(height)" }
        var title: String { "\(width) × \(height)" }

        static let presets: [Resolution] = [
            .init(width: 1280, height: 800),
            .init(width: 1440, height: 900),
            .init(width: 1600, height: 900),
            .init(width: 1680, height: 1050),
            .init(width: 1920, height: 1080),
            .init(width: 1920, height: 1200),
            .init(width: 2560, height: 1440),
        ]
    }

    static let resolutionKey = "settings.resolution"

    /// 고른 해상도. nil 이면 "기기에 맞춤"
    static var resolution: Resolution? {
        get {
            guard let s = UserDefaults.standard.string(forKey: resolutionKey) else { return nil }
            return Resolution.presets.first { $0.id == s }
        }
        set { UserDefaults.standard.set(newValue?.id, forKey: resolutionKey) }
    }
}
