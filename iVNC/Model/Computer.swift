import Foundation
import Security
import UIKit

/// 등록한 컴퓨터 하나. 암호는 키체인에 따로 둔다.
struct Computer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 5900
    var username: String
    var lastConnected: Date?
    /// 가능하면 고성능 모드(가상 디스플레이)를 먼저 쓴다. 이 값이 없던 예전 기록은 예전의 전체 "고성능 끔" 설정을 따른다
    var preferHighPerformance: Bool?

    /// 앱을 나가도 연결을 유지한다 (위치를 낮은 정확도로 켜 둔다). 예전 기록은 켬
    var keepAliveInBackground: Bool?
    var keepsAliveInBackground: Bool { keepAliveInBackground ?? true }

    var prefersHighPerformance: Bool {
        preferHighPerformance ?? !UserDefaults.standard.bool(forKey: "debug.hpOff")
    }
}

/// 컴퓨터 목록 (Application Support/computers.json)
@MainActor
final class ComputerStore: ObservableObject {
    @Published private(set) var computers: [Computer] = []
    /// 미리보기 그림이 바뀌면 올려서 카드가 다시 읽게 한다
    @Published private(set) var thumbnailVersion = 0

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("computers.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Computer].self, from: data) {
            computers = list
        }
        #if DEBUG
        // 시뮬레이터 시험용: IVNC_SEED="이름|주소|포트|계정|암호" 로 실행하면 컴퓨터 하나를 넣는다
        if let seed = ProcessInfo.processInfo.environment["IVNC_SEED"]?.split(separator: "|", omittingEmptySubsequences: false),
           seed.count == 5, !computers.contains(where: { $0.host == String(seed[1]) && $0.port == Int(seed[2]) }) {
            save(Computer(name: String(seed[0]), host: String(seed[1]), port: Int(seed[2]) ?? 5900, username: String(seed[3])),
                 password: String(seed[4]))
        }
        #endif
    }

    func save(_ c: Computer, password: String?) {
        if let i = computers.firstIndex(where: { $0.id == c.id }) { computers[i] = c } else { computers.append(c) }
        if let password { Keychain.setPassword(password, for: c.id) }
        persist()
    }

    func delete(_ c: Computer) {
        computers.removeAll { $0.id == c.id }
        Keychain.deletePassword(for: c.id)
        Thumbnails.delete(computer: c.id)
        persist()
    }

    func markConnected(_ id: UUID) {
        guard let i = computers.firstIndex(where: { $0.id == id }) else { return }
        computers[i].lastConnected = Date()
        persist()
    }

    func thumbnailsChanged() { thumbnailVersion += 1 }

    private func persist() {
        if let data = try? JSONEncoder().encode(computers) { try? data.write(to: url, options: .atomic) }
    }
}

enum Keychain {
    private static let service = "com.moimz.iVNC.password"

    static func setPassword(_ pw: String, for id: UUID) {
        deletePassword(for: id)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString, kSecValueData as String: Data(pw.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func password(for id: UUID) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func deletePassword(for id: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString]
        SecItemDelete(q as CFDictionary)
    }
}

/// 마지막 접속 화면 그림 (Caches/Thumbnails). 컴퓨터 카드용 하나와, 모니터 배치 화면용 모니터별 그림.
enum Thumbnails {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Thumbnails")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(computer: UUID, display: String? = nil) -> URL {
        dir.appendingPathComponent(computer.uuidString + (display.map { "-" + $0 } ?? "") + ".jpg")
    }

    static func load(computer: UUID, display: String? = nil) -> UIImage? {
        UIImage(contentsOfFile: url(computer: computer, display: display).path)
    }

    /// 긴 쪽 1200px 로 줄여 저장
    static func save(_ image: CGImage, computer: UUID, display: String?) {
        let maxSide: CGFloat = 1200
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * s).rounded(), height: (h * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = small.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: url(computer: computer), options: .atomic)
        if let display { try? data.write(to: url(computer: computer, display: display), options: .atomic) }
    }

    static func delete(computer: UUID) {
        let prefix = computer.uuidString
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
