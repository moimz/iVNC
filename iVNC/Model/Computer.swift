import Foundation
import SwiftUI
import Security
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 등록한 컴퓨터 하나. 암호는 키체인에 따로 둔다.
struct Computer: Identifiable, Codable, Hashable {
    /// 컴퓨터 종류: 맥(화면 공유, VNC) / 윈도우(원격 데스크톱, RDP) / SSH(터미널)
    /// 주의: 2.2 이하 앱은 iCloud 로 받은 "ssh" 를 모르는 종류라 맥으로 본다 (그 앱에선 맥 카드로 보이고 접속은 실패)
    enum Kind: String, Codable, CaseIterable {
        case mac, windows, ssh
        var title: String {
            switch self {
            case .mac: return "맥"
            case .windows: return "윈도우"
            case .ssh: return "SSH"
            }
        }
        var defaultPort: Int {
            switch self {
            case .mac: return 5900
            case .windows: return 3389
            case .ssh: return 22
            }
        }
        /// 화면을 보는 종류 (맥·윈도우). SSH 는 터미널
        var showsScreen: Bool { self != .ssh }
    }

    var id = UUID()
    /// 예전 기록(종류 없음)은 맥
    var kind: Kind?
    var type: Kind { kind ?? .mac }
    var name: String
    var host: String
    var port: Int = 5900
    var username: String
    var lastConnected: Date?
    /// 설정을 마지막으로 바꾼 시각 (iCloud 동기화에서 더 늦은 쪽을 쓴다)
    var updatedAt: Date?
    /// 가능하면 고성능 모드(가상 디스플레이)를 먼저 쓴다. 이 값이 없던 예전 기록은 예전의 전체 "고성능 끔" 설정을 따른다
    var preferHighPerformance: Bool?

    /// 앱을 나가도 연결을 유지한다 (위치를 낮은 정확도로 켜 둔다). 예전 기록은 켬
    var keepAliveInBackground: Bool?
    var keepsAliveInBackground: Bool { keepAliveInBackground ?? true }

    /// SSH 인증 방식. 없으면 비밀번호
    var sshAuth: SSHAuth?
    /// 가져온 SSH 키 파일 이름 (보여 주기용. 키 내용은 키체인에)
    var sshKeyName: String?
    /// SSH 문자 인코딩 (IANA 이름). 없으면 UTF-8. 서버마다 다를 수 있어 컴퓨터마다 둔다
    var sshEncoding: String?
    /// SSH 서버 색 (목록 줄·터미널 제목 메뉴·탭의 색 점). iSQL 과 같은 8가지
    var sshColor: ServerColor?
    /// 경유 서버 (배스천): 다른 SSH 컴퓨터의 id. 그 서버를 거쳐 이 서버에 접속한다
    var sshJump: UUID?

    var prefersHighPerformance: Bool {
        preferHighPerformance ?? !UserDefaults.standard.bool(forKey: "debug.hpOff")
    }
}

/// SSH 인증 방식 (iSQL 과 같은 이름)
enum SSHAuth: String, Codable, CaseIterable {
    /// 키 파일 (내용과 키 암호는 키체인)
    case key
    /// 비밀번호 (키체인)
    case password
    var label: String { self == .key ? "키 파일" : "비밀번호" }
}

/// 서버 색 (iSQL ServerColor 와 같은 것)
enum ServerColor: String, Codable, CaseIterable, Identifiable {
    case none, red, orange, yellow, green, blue, purple, gray
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "없음"
        case .red: return "빨강 (운영)"
        case .orange: return "주황"
        case .yellow: return "노랑"
        case .green: return "초록 (개발)"
        case .blue: return "파랑"
        case .purple: return "보라"
        case .gray: return "회색"
        }
    }
    var color: Color? {
        switch self {
        case .none: return nil
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

/// SSH 문자 인코딩 (맥 터미널의 텍스트 인코딩 중 쓸 만한 것)
enum SSHEncoding {
    static let all: [(id: String, title: String)] = [
        ("UTF-8", "유니코드 (UTF-8)"),
        ("EUC-KR", "한국어 (EUC-KR · CP949)"),
        ("Shift_JIS", "일본어 (Shift JIS)"),
        ("EUC-JP", "일본어 (EUC-JP)"),
        ("GB18030", "중국어 간체 (GB 18030)"),
        ("Big5", "중국어 번체 (Big 5)"),
        ("ISO-8859-1", "서유럽 (ISO Latin 1)"),
    ]
    static let defaultID = "UTF-8"
}

/// 컴퓨터 목록 (Application Support/computers.json)
@MainActor
final class ComputerStore: ObservableObject {
    @Published private(set) var computers: [Computer] = []
    /// 미리보기 그림이 바뀌면 올려서 카드가 다시 읽게 한다
    @Published private(set) var thumbnailVersion = 0

    private let url: URL = {
        let dir = AppDirectories.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("computers.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Computer].self, from: data) {
            computers = list
        }
        Keychain.migrateToSynchronizable()
        startCloudSync()
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
        var c = c
        c.updatedAt = Date()
        if let i = computers.firstIndex(where: { $0.id == c.id }) { computers[i] = c } else { computers.append(c) }
        if let password { Keychain.setPassword(password, for: c.id) }
        persist()
        upload(c)
    }

    func delete(_ c: Computer) {
        computers.removeAll { $0.id == c.id }
        Keychain.deletePassword(for: c.id)
        Keychain.deleteSSHKey(for: c.id)
        Thumbnails.delete(computer: c.id)
        persist()
        uploadDeletion(c.id)
    }

    /// SSH 경유 서버들 (바깥쪽부터). 고리가 생기면 거기서 멈춘다
    func jumpChain(for c: Computer) -> [Computer] {
        var chain: [Computer] = []
        var seen: Set<UUID> = [c.id]
        var next = c.sshJump
        while let id = next, !seen.contains(id), let j = computers.first(where: { $0.id == id && $0.type == .ssh }) {
            chain.insert(j, at: 0)
            seen.insert(id)
            next = j.sshJump
        }
        return chain
    }

    /// 정렬 모드에서 순서 바꾸기: 한 묶음(화면 공유 / SSH) 안에서 offsets 를 to 로. 다른 묶음 컴퓨터 자리는 그대로
    func move(fromOffsets offsets: IndexSet, toOffset to: Int, screens: Bool) {
        let slots = computers.indices.filter { computers[$0].type.showsScreen == screens }
        var group = slots.map { computers[$0] }
        group.move(fromOffsets: offsets, toOffset: to)
        for (slot, c) in zip(slots, group) { computers[slot] = c }
        orderChanged()
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

    // MARK: - iCloud 동기화 (키-값 저장소)
    //
    // 컴퓨터마다 키 "computer.<id>" 하나. 지우면 deleted 표시를 남겨 다른 기기에서도 지운다.
    // 같은 컴퓨터를 두 기기에서 바꾸면 updatedAt 이 더 늦은 쪽을 쓴다.
    // 마지막 접속 시각·썸네일·마우스 모드는 기기마다 달라 넘기지 않는다. 암호는 iCloud 키체인으로 따로 넘어간다.

    private struct CloudEntry: Codable {
        var id: UUID
        var updatedAt: Date
        var deleted = false
        var name = ""
        var host = ""
        var port = 5900
        var username = ""
        var preferHighPerformance: Bool?
        var keepAliveInBackground: Bool?
        var kind: String?
        var sshAuth: String?
        var sshKeyName: String?
        var sshEncoding: String?
        var sshColor: String?
        var sshJump: String?
    }

    private let cloud = NSUbiquitousKeyValueStore.default
    private static let cloudPrefix = "computer."

    private func startCloudSync() {
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mergeFromCloud() }
        }
        cloud.synchronize()
        mergeFromCloud()
        // 이 기기에만 있거나 이 기기 것이 더 새로우면 올린다 (예전 기록은 시각이 없어 지금 시각으로)
        for c in computers {
            let remote = entry(for: c.id)
            if remote == nil || (remote!.updatedAt < (c.updatedAt ?? .distantPast) && !remote!.deleted) {
                var c = c
                if c.updatedAt == nil { c.updatedAt = Date(); replace(c) }
                upload(c)
            }
        }
        persist()
    }

    private func entry(for id: UUID) -> CloudEntry? {
        cloud.data(forKey: Self.cloudPrefix + id.uuidString).flatMap { try? JSONDecoder().decode(CloudEntry.self, from: $0) }
    }

    private func replace(_ c: Computer) {
        if let i = computers.firstIndex(where: { $0.id == c.id }) { computers[i] = c }
    }

    private func upload(_ c: Computer) {
        let e = CloudEntry(id: c.id, updatedAt: c.updatedAt ?? Date(), name: c.name, host: c.host, port: c.port, username: c.username,
                           preferHighPerformance: c.preferHighPerformance, keepAliveInBackground: c.keepAliveInBackground,
                           kind: c.kind?.rawValue, sshAuth: c.sshAuth?.rawValue, sshKeyName: c.sshKeyName, sshEncoding: c.sshEncoding, sshColor: c.sshColor?.rawValue,
                           sshJump: c.sshJump?.uuidString)
        if let data = try? JSONEncoder().encode(e) { cloud.set(data, forKey: Self.cloudPrefix + c.id.uuidString) }
        cloud.synchronize()
    }

    private func uploadDeletion(_ id: UUID) {
        let e = CloudEntry(id: id, updatedAt: Date(), deleted: true)
        if let data = try? JSONEncoder().encode(e) { cloud.set(data, forKey: Self.cloudPrefix + id.uuidString) }
        cloud.synchronize()
    }

    // MARK: 순서 (iCloud 키 "computerOrder" 하나: 바꾼 시각 + id 순서. 더 늦게 바꾼 쪽을 쓴다)

    private struct CloudOrder: Codable {
        var updatedAt: Date
        var ids: [String]
    }
    private static let orderKey = "computerOrder"
    private static let orderTimeKey = "computerOrder.updatedAt"
    private var orderUpload: DispatchWorkItem?

    private func orderChanged() {
        persist()
        UserDefaults.standard.set(Date(), forKey: Self.orderTimeKey)
        // 끄는 동안 여러 번 바뀌니 잠깐 모았다가 올린다
        orderUpload?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.uploadOrder() }
        orderUpload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func uploadOrder() {
        guard let t = UserDefaults.standard.object(forKey: Self.orderTimeKey) as? Date else { return }
        let o = CloudOrder(updatedAt: t, ids: computers.map(\.id.uuidString))
        if let data = try? JSONEncoder().encode(o) { cloud.set(data, forKey: Self.orderKey) }
        cloud.synchronize()
    }

    /// iCloud 순서가 이 기기 것보다 새로우면 따른다 (거기 없는 컴퓨터는 지금 순서대로 뒤에). 이 기기 것이 새로우면 올린다
    private func mergeOrder() {
        let localTime = UserDefaults.standard.object(forKey: Self.orderTimeKey) as? Date
        guard let data = cloud.data(forKey: Self.orderKey), let o = try? JSONDecoder().decode(CloudOrder.self, from: data) else {
            if localTime != nil { uploadOrder() }
            return
        }
        if let localTime, localTime > o.updatedAt { uploadOrder(); return }
        let rank = Dictionary(o.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = computers.enumerated().sorted { a, b in
            let ra = rank[a.element.id.uuidString] ?? (o.ids.count + a.offset)
            let rb = rank[b.element.id.uuidString] ?? (o.ids.count + b.offset)
            return ra < rb
        }.map(\.element)
        UserDefaults.standard.set(o.updatedAt, forKey: Self.orderTimeKey)
        if sorted.map(\.id) != computers.map(\.id) {
            computers = sorted
            persist()
        }
    }

    /// 다른 기기에서 바뀐 것을 받는다
    private func mergeFromCloud() {
        defer { mergeOrder() }
        var changed = false
        for key in cloud.dictionaryRepresentation.keys where key.hasPrefix(Self.cloudPrefix) {
            guard let data = cloud.data(forKey: key), let e = try? JSONDecoder().decode(CloudEntry.self, from: data) else { continue }
            let local = computers.first { $0.id == e.id }
            // 예전 앱(2.2 이하)은 iCloud 의 "ssh" 종류를 몰라 맥으로 저장해 두었다. 시각이 같아도 새 앱이 모르던 칸을
            // 그대로 두면 SSH 서버가 화면 공유 카드로 남는다 (사용자 아이패드에서 SUN) → 종류가 비어 있으면 다시 받는다
            let missedKind = local.map { $0.kind == nil && e.kind != nil } ?? false
            if let local, !missedKind, (local.updatedAt ?? .distantPast) >= e.updatedAt { continue }
            if e.deleted {
                guard local != nil else { continue }
                computers.removeAll { $0.id == e.id }
                Thumbnails.delete(computer: e.id)
            } else {
                var c = local ?? Computer(id: e.id, name: e.name, host: e.host, username: e.username)
                c.name = e.name; c.host = e.host; c.port = e.port; c.username = e.username
                c.preferHighPerformance = e.preferHighPerformance
                c.keepAliveInBackground = e.keepAliveInBackground
                c.kind = e.kind.flatMap(Computer.Kind.init(rawValue:))
                c.sshAuth = e.sshAuth.flatMap(SSHAuth.init(rawValue:))
                c.sshKeyName = e.sshKeyName
                c.sshEncoding = e.sshEncoding
                c.sshColor = e.sshColor.flatMap(ServerColor.init(rawValue:))
                c.sshJump = e.sshJump.flatMap(UUID.init(uuidString:))
                c.updatedAt = e.updatedAt
                if local == nil { computers.append(c) } else { replace(c) }
            }
            changed = true
        }
        if changed {
            persist()
            DebugLog.write("iCloud: 컴퓨터 목록 받음 (\(computers.count)대)")
        }
    }
}

/// 맥 암호. iCloud 키체인으로 동기화한다 (끝단 암호화, 같은 Apple 계정 기기끼리만)
enum Keychain {
    private static let service = "com.moimz.iVNC.password"
    /// SSH 키 파일 내용과 그 키 암호 (컴퓨터마다 하나씩, iCloud 키체인으로 아이폰·아이패드·맥이 같이 쓴다)
    private static let sshKeyService = "com.moimz.iVNC.sshkey"
    private static let sshKeyPassService = "com.moimz.iVNC.sshkeypass"

    static func setSSHKey(_ key: Data, for id: UUID) { setData(key, service: sshKeyService, id: id) }
    static func sshKey(for id: UUID) -> Data? { data(service: sshKeyService, id: id) }
    static func setSSHKeyPassphrase(_ pw: String, for id: UUID) { setData(Data(pw.utf8), service: sshKeyPassService, id: id) }
    static func sshKeyPassphrase(for id: UUID) -> String? { data(service: sshKeyPassService, id: id).map { String(decoding: $0, as: UTF8.self) } }
    static func deleteSSHKeyPassphrase(for id: UUID) { delete(service: sshKeyPassService, id: id) }
    static func deleteSSHKey(for id: UUID) {
        delete(service: sshKeyService, id: id)
        delete(service: sshKeyPassService, id: id)
    }

    private static func setData(_ d: Data, service: String, id: UUID) {
        delete(service: service, id: id)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString, kSecValueData as String: d,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                kSecAttrSynchronizable as String: true]
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func data(service: String, id: UUID) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
                                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func delete(service: String, id: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString,
                                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        SecItemDelete(q as CFDictionary)
    }

    static func setPassword(_ pw: String, for id: UUID) {
        deletePassword(for: id)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString, kSecValueData as String: Data(pw.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                kSecAttrSynchronizable as String: true]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func password(for id: UUID) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
                                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func deletePassword(for id: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString,
                                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        SecItemDelete(q as CFDictionary)
    }

    /// 예전에 이 기기에만 저장한 암호를 iCloud 키체인으로 옮긴다 (한 번)
    static func migrateToSynchronizable() {
        let flag = "keychain.synchronizable"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: false, kSecReturnAttributes as String: true,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String, let id = UUID(uuidString: account),
                      let data = item[kSecValueData as String] as? Data else { continue }
                setPassword(String(decoding: data, as: UTF8.self), for: id)
            }
            DebugLog.write("키체인: 암호 \(items.count)개를 iCloud 키체인으로 옮김")
        }
        UserDefaults.standard.set(true, forKey: flag)
    }
}

/// 마지막 접속 화면 그림 (Caches/Thumbnails). 컴퓨터 카드용 하나와, 모니터 배치 화면용 모니터별 그림.
enum Thumbnails {
    private static let dir: URL = {
        let d = AppDirectories.caches.appendingPathComponent("Thumbnails")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(computer: UUID, display: String? = nil) -> URL {
        dir.appendingPathComponent(computer.uuidString + (display.map { "-" + $0 } ?? "") + ".jpg")
    }

    static func load(computer: UUID, display: String? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url(computer: computer, display: display) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 긴 쪽 1200px 로 줄여 저장
    static func save(_ image: CGImage, computer: UUID, display: String?) {
        let maxSide: CGFloat = 1200
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * s).rounded(), height: (h * s).rounded())
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        guard let small = ctx.makeImage(), let data = jpegData(small, quality: 0.8) else { return }
        try? data.write(to: url(computer: computer), options: .atomic)
        if let display { try? data.write(to: url(computer: computer, display: display), options: .atomic) }
    }

    /// CGImage → JPEG (UIKit·AppKit 없이)
    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    static func delete(computer: UUID) {
        let prefix = computer.uuidString
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
