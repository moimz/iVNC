import Foundation

/// 썸네일 iCloud Drive 동기화 (iSQL Cloud.swift 와 같은 방식, 앱 전용 폴더 iCloud.com.moimz.iVNC/Data/Thumbnails — Finder 에는 안 보임).
/// 사용자 2026-11-22: 맥은 자기 자신 카드처럼 접속할 일이 없는 컴퓨터 썸네일이 영원히 비어 있다 →
/// 기기마다 찍은 썸네일은 무조건 작게(600px) 올린다. 이 기기가 찍은 게 없으면 iCloud 것을 받아 쓰고("빌린 것"),
/// 직접 찍기 전까지는 iCloud 에 더 새 것이 오면 계속 받는다. 직접 찍으면 그때부터는 이 기기 것만 (사용자).
/// 키-값 저장소(1MB)는 컴퓨터 목록·설정용으로 남겨 둔다
final class ThumbnailCloud: NSObject, @unchecked Sendable {
    static let shared = ThumbnailCloud()
    static let containerID = "iCloud.com.moimz.iVNC"

    /// iCloud 폴더 (iCloud 를 못 쓰면 nil: 그냥 이 기기 썸네일만)
    private var folder: URL?
    private let queue = DispatchQueue(label: "ThumbnailCloud", qos: .utility)
    private let query = NSMetadataQuery()
    private var onFilled: (@MainActor () -> Void)?

    /// iCloud 에서 받아 쓰는(이 기기가 찍지 않은) 썸네일의 컴퓨터 id. queue 에서만 만진다
    private static let borrowedKey = "thumbnail.borrowed"
    private var borrowed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.borrowedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.borrowedKey) }
    }

    /// iCloud 폴더를 찾고(오래 걸릴 수 있어 뒤에서) 지켜보기 시작. 받은 썸네일로 빈 카드를 채우면 onFilled
    func start(onFilled: @escaping @MainActor () -> Void) {
        self.onFilled = onFilled
        queue.async {
            let fm = FileManager.default
            guard fm.ubiquityIdentityToken != nil, let c = fm.url(forUbiquityContainerIdentifier: Self.containerID) else {
                DebugLog.write("썸네일 iCloud: 쓸 수 없음 (iCloud Drive 꺼짐 등)")
                return
            }
            let f = c.appendingPathComponent("Data", isDirectory: true).appendingPathComponent("Thumbnails", isDirectory: true)
            try? fm.createDirectory(at: f, withIntermediateDirectories: true)
            self.folder = f
            self.uploadMissing()
            DispatchQueue.main.async { self.startQuery() }
        }
    }

    private func file(_ id: UUID) -> URL? { folder?.appendingPathComponent(id.uuidString + ".jpg") }

    /// 이 기기에서 새로 찍은 썸네일을 올린다 (이제 이 기기 것이니 빌린 표시를 지운다)
    func upload(computer id: UUID) {
        queue.async {
            self.borrowed.remove(id.uuidString)
            guard let target = self.file(id), let data = Thumbnails.cloudData(computer: id) else { return }
            Self.write(data, to: target)
        }
    }

    func remove(computer id: UUID) {
        queue.async {
            self.borrowed.remove(id.uuidString)
            guard let target = self.file(id) else { return }
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &error) { u in
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    /// 처음 한 번: 이 기기엔 있는데 iCloud 엔 없는 썸네일을 올린다 (아직 안 받은 파일 ".이름.jpg.icloud" 는 있는 것으로 본다)
    private func uploadMissing() {
        guard let folder else { return }
        let fm = FileManager.default
        let there = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        let local = (try? fm.contentsOfDirectory(at: Thumbnails.url(computer: UUID()).deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        for f in local where f.pathExtension == "jpg" {
            // 화면별 썸네일(<id>-<화면>.jpg)은 올리지 않는다
            let name = f.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name), !borrowed.contains(name) else { continue }
            if there.contains(name + ".jpg") || there.contains("." + name + ".jpg.icloud") { continue }
            if let target = file(id), let data = Thumbnails.cloudData(computer: id) { Self.write(data, to: target) }
        }
    }

    private static func write(_ data: Data, to target: URL) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &error) { u in
            try? data.write(to: u, options: .atomic)
        }
    }

    // MARK: 다른 기기가 올린 것 받기

    private func startQuery() {
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.jpg'", NSMetadataItemFSNameKey)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .NSMetadataQueryDidUpdate, object: query)
        query.start()
    }

    /// 이 기기에 썸네일이 없거나 빌린 것이면: 받은 iCloud 것이 더 새로우면 이 기기 썸네일로 복사하고, 아직 안 받은 것은 받기 시작.
    /// 이 기기가 직접 찍은 썸네일은 건드리지 않는다
    @objc private func changed() {
        query.disableUpdates()
        var items: [(id: UUID, url: URL, current: Bool, date: Date?)] = []
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            items.append((id, url, status == NSMetadataUbiquitousItemDownloadingStatusCurrent,
                          item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date))
        }
        query.enableUpdates()
        queue.async {
            var filled = false
            var borrowed = self.borrowed
            let fm = FileManager.default
            for it in items {
                let key = it.id.uuidString
                let local = Thumbnails.url(computer: it.id)
                let have = fm.fileExists(atPath: local.path)
                guard !have || borrowed.contains(key) else { continue }   // 직접 찍은 것
                if have, let cloudDate = it.date,
                   let localDate = (try? fm.attributesOfItem(atPath: local.path))?[.modificationDate] as? Date,
                   localDate >= cloudDate { continue }                       // 이미 최신
                guard it.current else { try? fm.startDownloadingUbiquitousItem(at: it.url); continue }
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: it.url, options: [], error: &error) { u in
                    guard let data = try? Data(contentsOf: u), (try? data.write(to: local, options: .atomic)) != nil else { return }
                    // 다음에 같은 파일을 또 받지 않게 iCloud 파일 시각을 붙여 둔다
                    if let d = it.date { try? fm.setAttributes([.modificationDate: d], ofItemAtPath: local.path) }
                    borrowed.insert(key)
                    filled = true
                }
            }
            self.borrowed = borrowed
            if filled { DispatchQueue.main.async { self.onFilled?() } }
        }
    }
}
