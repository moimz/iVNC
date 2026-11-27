import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 모델

/// 파일 하나 (이 맥·서버 공용)
struct FileItem: Identifiable, Hashable {
    /// 이 맥 = 파일 경로, 서버 = 서버 경로
    let id: String
    let name: String
    let isDirectory: Bool
    var isSymlink = false
    var size: Int64?
    var modified: Date?
    var permissions: UInt32?
    var isHidden: Bool { name.hasPrefix(".") }
    var url: URL { URL(fileURLWithPath: id) }
}

/// 표의 한 줄 (펼친 폴더 안쪽은 depth 만큼 들여 쓴다)
struct FileRowItem: Identifiable, Hashable {
    let item: FileItem
    let depth: Int
    var id: String { item.id }
    // 정렬 열
    var name: String { item.name }
    var sizeValue: Int64 { item.isDirectory ? -1 : (item.size ?? 0) }
    var dateValue: Date { item.modified ?? .distantPast }
    var kindValue: String { FileLook.kind(item) }
}

/// 한 칸 (이 맥 또는 서버): 지금 폴더 + 펼친 폴더들
@MainActor
final class FilePane: ObservableObject {
    let isRemote: Bool
    @Published var path = ""
    @Published private(set) var children: [String: [FileItem]] = [:]
    @Published var expanded: Set<String> = []
    @Published var loading = false
    @Published var error: String?
    var loader: ((String) async throws -> [FileItem])?
    var onOpen: ((String) -> Void)?

    init(isRemote: Bool) { self.isRemote = isRemote }

    func open(_ p: String) async {
        guard let loader else { return }
        loading = true
        do {
            let list = try await loader(p)
            children = [p: list]
            expanded = []
            path = p
            error = nil
            onOpen?(p)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loading = false
    }

    /// 지금 폴더와 펼친 폴더를 다시 읽는다
    func refresh() async {
        guard let loader, !path.isEmpty else { return }
        loading = true
        var next: [String: [FileItem]] = [:]
        for p in [path] + expanded.sorted() {
            if let list = try? await loader(p) { next[p] = list }
        }
        children = next
        expanded = expanded.filter { next[$0] != nil }
        loading = false
    }

    func toggle(_ item: FileItem) async {
        if expanded.contains(item.id) {
            expanded = expanded.filter { !$0.hasPrefix(item.id) }
            return
        }
        guard let loader else { return }
        if children[item.id] == nil {
            guard let list = try? await loader(item.id) else { return }
            children[item.id] = list
        }
        expanded.insert(item.id)
    }

    func up() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await open(parent.isEmpty ? "/" : parent)
    }

    /// 화면에 보일 줄 (정렬·숨김·폴더 먼저, 펼친 폴더 안쪽 포함)
    func rows(order: [KeyPathComparator<FileRowItem>], foldersFirst: Bool, showHidden: Bool) -> [FileRowItem] {
        var out: [FileRowItem] = []
        func add(_ dir: String, depth: Int) {
            var list = (children[dir] ?? []).filter { showHidden || !$0.isHidden }.map { FileRowItem(item: $0, depth: depth) }
            list.sort(using: order)
            if foldersFirst { list = list.filter(\.item.isDirectory) + list.filter { !$0.item.isDirectory } }
            for r in list {
                out.append(r)
                if r.item.isDirectory && expanded.contains(r.id) { add(r.id, depth: depth + 1) }
            }
        }
        add(path, depth: 0)
        return out
    }

    func item(_ id: String) -> FileItem? {
        for list in children.values { if let i = list.first(where: { $0.id == id }) { return i } }
        return nil
    }
}

/// 탭의 파인더 (왼쪽 이 맥, 오른쪽 서버 SFTP). 터미널과 같은 SSH 접속을 쓴다
@MainActor
final class FileSession: ObservableObject {
    weak var tab: TerminalTab?
    private(set) var client: SFTPClient?
    let local = FilePane(isRemote: false)
    let remote = FilePane(isRemote: true)
    @Published var transfers: [Transfer] = []
    /// 좁을 때(분할 칸) 한 칸만: 이 맥을 볼지 (아니면 서버)
    @Published var compactShowsLocal = false
    /// 서버 ↔ 서버 끌기에서 보낸 쪽을 찾으려고 탭 id 로 둔다
    private static var registry: [UUID: WeakSession] = [:]
    private struct WeakSession { weak var session: FileSession? }
    static func session(for tabID: UUID) -> FileSession? { registry[tabID]?.session }
    let tabID: UUID
    /// 서버 홈 (경로 메뉴)
    @Published private(set) var remoteHome: String?
    /// 마지막으로 따라간 터미널 폴더
    private var lastFollowed: String?
    /// 파인더가 보고 있는 사용자 (경로 줄 "root@SUN"). 터미널 앞쪽 셸 사용자를 따른다
    @Published private(set) var viewer: String?
    /// 다른 사용자 셸이 띄운 sftp-server 에 잇는 명령 (nil = 로그인 계정 sftp)
    private var bridge: String?
    var isOpen: Bool { client != nil }
    /// 맥 앱으로 열어 둔 서버 파일 (서버 경로 → 임시 파일, RemoteEdit.swift)
    var edits: [String: RemoteEdit] = [:]
    var editTimer: Timer?

    /// 볼 사용자를 정한다. 바뀌면 SFTP 를 닫고 다음 appear 에서 그 사용자로 다시 연다
    func useIdentity(user: String, bridge: String?) {
        if user != viewer || (bridge != nil && bridge != self.bridge) {
            client?.close()
            client = nil
            lastFollowed = nil
        }
        viewer = user
        self.bridge = bridge
    }
    private var ticker: Timer?

    static let localKey = "files.localPath"
    /// 동시에 옮기는 파일 수
    static let parallel = 4

    init(tab: TerminalTab) {
        self.tab = tab
        tabID = tab.id
        Self.registry = Self.registry.filter { $0.value.session != nil }
        Self.registry[tab.id] = WeakSession(session: self)
        local.loader = { p in try Self.listLocal(p) }
        local.onOpen = { UserDefaults.standard.set($0, forKey: Self.localKey) }
        let saved = UserDefaults.standard.string(forKey: Self.localKey)
        let start = saved.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
        Task { await local.open(start) }
    }

    nonisolated static func listLocal(_ path: String) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let perms = (try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.uint32Value
            // 앱 같은 꾸러미는 파일처럼
            let dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            return FileItem(id: u.path, name: u.lastPathComponent, isDirectory: dir, isSymlink: v?.isSymbolicLink ?? false,
                            size: v?.fileSize.map(Int64.init), modified: v?.contentModificationDate, permissions: perms)
        }
    }

    // MARK: 서버

    /// 파인더로 바꿀 때마다: SFTP 를 열고(처음만) 터미널이 있는 폴더로 간다
    func appear() async {
        guard let tab, let shell = tab.sshShell else {
            remote.error = "접속돼 있지 않습니다."
            return
        }
        do {
            if client == nil {
                remote.loading = true
                let c = try await Self.openSFTP(shell, bridge: bridge)
                client = c
                remote.loader = { p in try await c.list(p).map(Self.item) }
                if bridge != nil {
                    // 그 셸이 띄운 sftp-server 는 셸 폴더에서 시작한다 → "." 이 곧 터미널 폴더
                    remoteHome = nil
                    let here = try? await c.realpath(".")
                    if let here { lastFollowed = here; await remote.open(here); return }
                } else {
                    remoteHome = try? await c.realpath(".")
                }
            }
            // 다른 사용자 셸(root 등)로 보는 중이면 로그인 셸 폴더를 따라가지 않는다 (처음 열 때 그 셸 폴더로 갔다)
            if bridge != nil { await remote.refresh(); return }
            // 터미널 폴더: 셸이 알려 준 것(OSC 7) → 리눅스 /proc → 홈
            var dir = tab.directory.flatMap { URL(string: $0)?.path }.flatMap { $0.isEmpty ? nil : $0 }
            if dir == nil { dir = await shell.currentDirectory() }
            if dir == nil, remote.path.isEmpty { dir = remoteHome ?? "/" }
            if let dir, dir != lastFollowed {
                lastFollowed = dir
                await remote.open(dir)
            } else {
                await remote.refresh()
            }
        } catch {
            remote.loading = false
            remote.error = (error as? LocalizedError)?.errorDescription ?? "파일 목록을 열 수 없습니다: \(error)"
        }
    }

    /// SFTP 열기. 서버가 sftp 서브시스템을 꺼 두었으면(sshd_config 에 Subsystem 없음) sftp-server 를 직접 실행해 다시 해 본다.
    /// 둘 다 안 되면 알기 쉬운 말로 (사용자: 서버에서 막아 둘 수도 있지 않나)
    private static func openSFTP(_ shell: SSHShell, bridge: String?) async throws -> SFTPClient {
        if let bridge { return try await shell.openSFTP(command: bridge) }
        do {
            return try await shell.openSFTP()
        } catch {
            DebugLog.write("SFTP 서브시스템 안 됨, sftp-server 직접 실행 시도: \(error)")
            let direct = "for s in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server /usr/libexec/sftp-server; do [ -x $s ] && exec $s; done; exit 127"
            do {
                return try await shell.openSFTP(command: direct)
            } catch {
                throw SFTPUnavailable()
            }
        }
    }

    struct SFTPUnavailable: LocalizedError {
        var errorDescription: String? { "이 서버는 파일 전송(SFTP)을 쓸 수 없게 되어 있습니다.\n서버 관리자가 sshd 설정에서 SFTP 를 꺼 두었거나 sftp-server 가 없습니다." }
    }

    nonisolated static func item(_ e: SFTPClient.Entry) -> FileItem {
        FileItem(id: e.path, name: e.name, isDirectory: e.isDirectory, isSymlink: e.attrs.isSymlink,
                 size: e.attrs.size.map(Int64.init), modified: e.attrs.modified, permissions: e.attrs.permissions)
    }

    func makeRemoteFolder(_ name: String) async {
        guard let client, !name.isEmpty else { return }
        do { try await client.mkdir(SFTPClient.join(remote.path, name)) } catch { remote.error = error.localizedDescription }
        await remote.refresh()
    }

    func renameRemote(_ e: FileItem, to name: String) async {
        guard let client, !name.isEmpty, name != e.name else { return }
        let dir = (e.id as NSString).deletingLastPathComponent
        do { try await client.rename(e.id, to: SFTPClient.join(dir, name)) } catch { remote.error = error.localizedDescription }
        await remote.refresh()
    }

    func deleteRemote(_ list: [FileItem]) async {
        guard let client else { return }
        for e in list {
            let entry = SFTPClient.Entry(name: e.name, path: e.id,
                                         attrs: .init(size: e.size.map(UInt64.init), permissions: e.permissions, mtime: nil))
            do { try await client.removeRecursive(entry) } catch { remote.error = "\(e.name): \(error.localizedDescription)" }
        }
        await remote.refresh()
    }

    // MARK: 옮기기

    /// 이 맥 파일·폴더를 서버 폴더로 (폴더는 안까지)
    func upload(_ urls: [URL], to dir: String) {
        guard let client else { return }
        // 한 번에 시킨 것은 전송 내역에서 한 묶음 (제목 줄 ⇅)
        let g = TransferCenter.shared.begin(.upload, names: urls.map(\.lastPathComponent), server: serverName)
        Task {
            for u in urls {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    await uploadFolder(u, to: SFTPClient.join(dir, u.lastPathComponent), client: client, group: g)
                } else {
                    enqueue(Transfer(name: u.lastPathComponent, upload: true, total: Self.fileSize(u)) { t in
                        try await client.upload(u, to: SFTPClient.join(dir, u.lastPathComponent), progress: t.add, isCancelled: t.isCancelled)
                    }, group: g)
                }
            }
            g.preparing = false
        }
    }

    /// 전송 내역에 보일 서버 이름
    var serverName: String { tab?.computer.name ?? "" }

    private func uploadFolder(_ u: URL, to remotePath: String, client: SFTPClient, group g: TransferGroup) async {
        try? await client.mkdir(remotePath) // 이미 있으면 실패해도 그대로 쓴다
        let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for c in items {
            if (try? c.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                await uploadFolder(c, to: SFTPClient.join(remotePath, c.lastPathComponent), client: client, group: g)
            } else {
                enqueue(Transfer(name: c.lastPathComponent, upload: true, total: Self.fileSize(c)) { t in
                    try await client.upload(c, to: SFTPClient.join(remotePath, c.lastPathComponent), progress: t.add, isCancelled: t.isCancelled)
                }, group: g)
            }
        }
    }

    /// 서버 파일·폴더를 이 맥 폴더로
    @discardableResult
    func download(_ items: [FileItem], to dir: URL) -> TransferGroup? {
        guard let client else { return nil }
        let g = TransferCenter.shared.begin(.download, names: items.map(\.name), server: serverName)
        Task {
            for e in items {
                if e.isDirectory {
                    await downloadFolder(e.id, to: dir.appendingPathComponent(e.name), client: client, group: g)
                } else {
                    enqueueDownload(e.id, name: e.name, size: e.size ?? 0, to: dir.appendingPathComponent(e.name), client: client, group: g)
                }
            }
            g.preparing = false
        }
        return g
    }

    /// Finder·데스크탑에 끌어 놓은 서버 항목을 임시 폴더로 받는다. 메뉴의 다운로드와 같은 흐름이라 전송 내역(⇅)에 한 묶음으로 보인다.
    /// 다 받을 때까지 기다리고, 하나라도 못 받거나 취소되면 실패로 던진다 (Finder 가 그 항목을 만들지 않는다)
    func downloadForDrag(_ e: FileItem, to dir: URL, progress: Progress) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let g = download([e], to: dir) else { throw CocoaError(.fileReadUnknown) }
        while g.isActive {
            if progress.isCancelled || RemoteDrag.terminating { g.cancel() }
            // Finder 의 복사 진행 막대도 같이 움직이게
            progress.totalUnitCount = max(g.total, 1)
            progress.completedUnitCount = g.done
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let t = g.items.first(where: \.isFailed), case .failed(let message) = t.state {
            throw NSError(domain: "iVNC", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(t.name): \(message)"])
        }
        if g.cancelledCount > 0 { throw CocoaError(.userCancelled) }
        return dir.appendingPathComponent(e.name)
    }

    private func downloadFolder(_ path: String, to local: URL, client: SFTPClient, group g: TransferGroup) async {
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        guard let items = try? await client.list(path) else { return }
        for c in items {
            if c.isDirectory {
                await downloadFolder(c.path, to: local.appendingPathComponent(c.name), client: client, group: g)
            } else {
                enqueueDownload(c.path, name: c.name, size: Int64(c.attrs.size ?? 0), to: local.appendingPathComponent(c.name), client: client, group: g)
            }
        }
    }

    /// 다른 탭(서버)의 항목을 이 서버 폴더로 (폴더째, 이 맥 디스크를 거치지 않음)
    func relay(_ items: [FileItem], from source: FileSession, to dir: String) {
        guard let dst = client, let src = source.client, source !== self else { return }
        let g = TransferCenter.shared.begin(.relay, names: items.map(\.name), server: "\(source.serverName) → \(serverName)")
        Task {
            for e in items {
                if e.isDirectory {
                    await relayFolder(e.id, name: e.name, src: src, dst: dst, to: dir, group: g)
                } else {
                    enqueueRelay(e.id, name: e.name, size: e.size ?? 0, src: src, dst: dst, to: SFTPClient.join(dir, e.name), group: g)
                }
            }
            g.preparing = false
        }
    }

    private func relayFolder(_ path: String, name: String, src: SFTPClient, dst: SFTPClient, to dir: String, group g: TransferGroup) async {
        let target = SFTPClient.join(dir, name)
        try? await dst.mkdir(target)
        guard let items = try? await src.list(path) else { return }
        for c in items {
            if c.isDirectory {
                await relayFolder(c.path, name: c.name, src: src, dst: dst, to: target, group: g)
            } else {
                enqueueRelay(c.path, name: c.name, size: Int64(c.attrs.size ?? 0), src: src, dst: dst, to: SFTPClient.join(target, c.name), group: g)
            }
        }
    }

    private func enqueueRelay(_ path: String, name: String, size: Int64, src: SFTPClient, dst: SFTPClient, to target: String, group g: TransferGroup) {
        enqueue(Transfer(name: name, upload: true, total: size, relay: true) { t in
            try await SFTPClient.relay(from: src, path, size: UInt64(size), to: dst, target, progress: t.add, isCancelled: t.isCancelled)
        }, group: g)
    }

    private func enqueueDownload(_ path: String, name: String, size: Int64, to local: URL, client: SFTPClient, group g: TransferGroup) {
        enqueue(Transfer(name: name, upload: false, total: size) { t in
            try await client.download(path, to: local, progress: t.add, isCancelled: t.isCancelled)
        }, group: g)
    }

    func enqueue(_ t: Transfer, group g: TransferGroup) {
        g.add(t)
        guard t.state == .waiting else { return } // 묶음을 이미 취소했으면 넣지 않는다
        transfers.append(t)
        startTicker()
        runNext()
    }

    private func runNext() {
        while transfers.filter({ $0.state == .running }).count < Self.parallel,
              let t = transfers.first(where: { $0.state == .waiting }) {
            t.state = .running
            t.startedAt = Date()
            Task {
                do {
                    try await t.work(t)
                    t.state = .done
                } catch {
                    t.state = t.isCancelled() ? .cancelled : .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
                t.finishedAt = Date()
                objectWillChange.send()
                if t.upload { await remote.refresh() } else { await local.refresh() }
                runNext()
                clearLaterIfQuiet()
            }
        }
    }

    /// 다 끝나고 실패가 없으면 잠시 뒤 진행 줄을 걷는다
    private func clearLaterIfQuiet() {
        guard transfers.allSatisfy({ $0.state == .done || $0.state == .cancelled }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.transfers.allSatisfy({ $0.state == .done || $0.state == .cancelled }) else { return }
            withAnimation(.snappy) { self.clearFinished() }
        }
    }

    func cancelAll() {
        for t in transfers where t.state == .running || t.state == .waiting {
            t.cancel()
            if t.state == .waiting { t.state = .cancelled }
        }
        objectWillChange.send()
    }

    func clearFinished() { transfers.removeAll { $0.state != .running && $0.state != .waiting } }

    /// 진행 표시를 0.25초마다 다시 그린다 (조각마다 그리면 너무 잦다)
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.objectWillChange.send()
                if !self.transfers.contains(where: { $0.state == .running || $0.state == .waiting }) {
                    self.ticker?.invalidate(); self.ticker = nil
                }
            }
        }
    }

    /// 접속을 닫는다 (다시 접속할 때도). 열어 둔 파일 감시는 남겨서 다시 접속하면 이어서 올린다 — 탭을 닫을 때만 stopEdits
    func close() {
        cancelAll()
        client?.close()
        client = nil
    }

    static func fileSize(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
}

// Transfer 는 iVNC/Model/TransferCenter.swift (아이패드와 같이 쓴다)

// MARK: - 보기 옵션 (두 칸 공용, 이 맥에 저장)

enum FileViewOptions {
    static let showHidden = "files.showHidden"
    static let foldersFirst = "files.foldersFirst"
    /// 글자 크기는 고정: 이름 13pt, 크기·날짜 12pt (숫자 폭 같게), 아이콘 16pt
    static let nameFont = Font.system(size: 13)
    static let numberFont = Font.system(size: 12).monospacedDigit()
    /// 크기 단위(KB·MB·GB): 고정폭이라 단위마다 폭이 같다 (사용자)
    static let unitFont = Font.system(size: 11, design: .monospaced)
    static let iconSize: CGFloat = 16
}

/// 아이콘·종류·날짜 글자
@MainActor
enum FileLook {
    private static var icons: [String: NSImage] = [:]

    static func icon(_ item: FileItem, remote: Bool) -> NSImage {
        if !remote, item.isDirectory || item.name.hasSuffix(".app") { return NSWorkspace.shared.icon(forFile: item.id) }
        let key = item.isDirectory ? "/" : (item.name as NSString).pathExtension.lowercased()
        if let i = icons[key] { return i }
        let i = item.isDirectory ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        icons[key] = i
        return i
    }

    nonisolated static func kind(_ item: FileItem) -> String {
        if item.isDirectory { return "폴더" }
        let ext = (item.name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? "문서" : ext.uppercased() + " 파일")
    }

    static func permissions(_ p: UInt32?) -> String {
        guard let p else { return "" }
        let bits = Array("rwxrwxrwx")
        return String((0..<9).map { p & (0o400 >> UInt32($0)) != 0 ? bits[$0] : "-" })
    }

    /// 크기: 숫자와 단위를 나눠서. 바이트 단위는 쓰지 않고 KB 부터 ("17바이트" 대신 0.1 KB, 사용자).
    /// 10 미만은 소수 한 자리, 그 이상은 정수 (Finder 처럼 1000 단위)
    nonisolated static func size(_ bytes: Int64) -> (String, String) {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var v = Double(bytes) / 1000
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if bytes > 0 && v < 0.1 { v = 0.1 }
        let n = v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v.rounded())
        return (n, units[i])
    }

    /// 날짜는 늘 "2026-11-21 11:39" (글자 수가 같아 열 너비가 고정된다, 사용자)
    private static let fixed: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func date(_ d: Date?) -> String { d.map { fixed.string(from: $0) } ?? "" }
}

// MARK: - 화면

/// 서버 항목을 끌 때 쓰는 우리 앱 안 형식 (서버 경로)
private let remoteDragType = UTType(exportedAs: "com.moimz.ivnc.remote-files")

struct FileBrowserView: View {
    @ObservedObject var session: FileSession
    let serverName: String

    /// 서버 칸 맨 앞 이름: "root@SUN" 처럼 지금 보고 있는 사용자 (사용자)
    private var remoteTitle: String { session.viewer.map { "\($0)@\(serverName)" } ?? serverName }

    /// 이보다 좁으면(분할 칸 등) 한 칸만 보이고 [이 맥 | 서버] 로 바꾼다
    static let twoPaneWidth: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                if geo.size.width >= Self.twoPaneWidth {
                    HSplitView {
                        FilePaneView(session: session, pane: session.local, title: "이 맥").frame(minWidth: 260)
                        FilePaneView(session: session, pane: session.remote, title: remoteTitle).frame(minWidth: 260)
                    }
                } else if session.compactShowsLocal {
                    FilePaneView(session: session, pane: session.local, title: "이 맥", compact: true)
                } else {
                    FilePaneView(session: session, pane: session.remote, title: remoteTitle, compact: true)
                }
            }
            // 아래 진행 줄은 없앴다 (사용자): 진행은 제목 줄 ⇅ 배지 · 전송 내역(TransferCenter.swift)
        }
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
        .task { await session.appear() }
    }
}

/// 한 칸: 위 경로 줄 + 표 (Transmit 처럼)
private struct FilePaneView: View {
    @ObservedObject var session: FileSession
    @ObservedObject var pane: FilePane
    let title: String
    /// 좁은 한 칸 모양: 머리에 [이 맥 | 서버] 전환
    var compact = false

    @AppStorage(FileViewOptions.showHidden) private var showHidden = false
    @AppStorage(FileViewOptions.foldersFirst) private var foldersFirst = true

    @State private var selection = Set<String>()
    @State private var order = [KeyPathComparator(\FileRowItem.name, comparator: .localizedStandard)]
    @State private var showOptions = false
    @State private var dropTarget = false
    @State private var newFolder = false
    @State private var renaming: FileItem?
    @State private var deleting: [FileItem] = []
    @State private var nameInput = ""


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                table
                if let err = pane.error {
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            .overlay {
                if dropTarget { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(2) }
            }
        }
        .alert("새 폴더", isPresented: $newFolder) {
            TextField("이름", text: $nameInput)
            Button("만들기") { Task { await session.makeRemoteFolder(nameInput) } }
            Button("취소", role: .cancel) {}
        }
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $nameInput)
            Button("바꾸기") { if let r = renaming { Task { await session.renameRemote(r, to: nameInput) } } }
            Button("취소", role: .cancel) {}
        }
        .alert("서버에서 지울까요?", isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("삭제", role: .destructive) { let d = deleting; Task { await session.deleteRemote(d) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text(deleting.count == 1 ? "\(deleting[0].name) 을(를) 지웁니다. 폴더면 안의 내용도 모두 지워지고, 되돌릴 수 없습니다."
                 : "\(deleting.count)개를 지웁니다. 폴더면 안의 내용도 모두 지워지고, 되돌릴 수 없습니다.")
        }
    }

    // 위 줄: [이 맥/서버 아이콘 | 서버 › var › www › html ⌄] ··· [새로 고침] [보기 옵션] (좁으면 아이콘 대신 [이 맥 | 서버] 토글)
    private var header: some View {
        HStack(spacing: 8) {
            if compact {
                Picker("보기", selection: $session.compactShowsLocal) {
                    Image(systemName: "internaldrive").tag(true).help("이 맥")
                    Image(systemName: "server.rack").tag(false).help(title)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                // 이 맥 / 서버 표시 (좁아지면 위 토글로 바뀐다, 사용자)
                Image(systemName: pane.isRemote ? "server.rack" : "internaldrive")
                    .foregroundStyle(.secondary)
                    .help(pane.isRemote ? title : "이 맥")
            }
            Divider().frame(height: 14)
            PathBar(session: session, pane: pane, title: title)
            Spacer(minLength: 4)
            if pane.loading { ProgressView().controlSize(.small) }
            Button { Task { await pane.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("새로 고침")
            Button { showOptions.toggle() } label: { Image(systemName: "square.grid.2x2") }
                .buttonStyle(.borderless).help("보기 옵션")
                .popover(isPresented: $showOptions, arrowEdge: .bottom) { FileViewOptionsView() }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .foregroundStyle(.secondary)
    }

    private var table: some View {
        let rows = pane.rows(order: order, foldersFirst: foldersFirst, showHidden: showHidden)
        return Table(of: FileRowItem.self, selection: $selection, sortOrder: $order) {
            // 제목은 줄의 ▸ 자리만큼 띄운다 (열 제목에는 여백을 줄 수 없어 앞에 빈칸 글자: 전각 공백 + 가는 공백 ≈ 16pt)
            TableColumn(Text("\u{2003}\u{2009}이름"), value: \.name, comparator: .localizedStandard) { r in nameCell(r) }
                .width(min: 160, ideal: 300)
            TableColumn("크기", value: \.sizeValue) { r in
                // 숫자(숫자 폭 같게, 오른쪽 정렬) + 단위(고정 칸): 단위가 KB·MB·GB 로 달라도 숫자 끝과 단위가 세로로 맞는다 (사용자)
                HStack(spacing: 3) {
                    if r.item.isDirectory {
                        Text("•")
                    } else {
                        let (number, unit) = FileLook.size(r.item.size ?? 0)
                        Text(number).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(unit).font(FileViewOptions.unitFont).lineLimit(1).fixedSize().frame(width: 16, alignment: .leading)
                    }
                }
                .font(FileViewOptions.numberFont).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)
            TableColumn("날짜", value: \.dateValue) { r in
                Text(FileLook.date(r.item.modified)).font(FileViewOptions.numberFont).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(120)
        } rows: {
            ForEach(rows) { r in
                TableRow(r).itemProvider { provider(for: r.item) }
            }
        }
        .font(FileViewOptions.nameFont)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .background(TableLinesRemover())
        .contextMenu(forSelectionType: String.self) { ids in menu(ids) } primaryAction: { ids in open(ids) }
        // ⌘R: 포커스가 있는 칸(이 맥 / 서버)만 새로 고친다 (메뉴 보기 > 새로 고침, TerminalMenus.swift)
        .focusedValue(\.filePaneRefresh) { Task { await pane.refresh() } }
        .onDrop(of: pane.isRemote ? [remoteDragType, .fileURL] : [remoteDragType], isTargeted: $dropTarget) { items in drop(items) }
    }

    private func nameCell(_ r: FileRowItem) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(r.depth) * 16, height: 1)
            if r.item.isDirectory {
                Button { Task { await pane.toggle(r.item) } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(pane.expanded.contains(r.id) ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(nsImage: FileLook.icon(r.item, remote: pane.isRemote))
                .resizable().frame(width: FileViewOptions.iconSize, height: FileViewOptions.iconSize)
                .opacity(r.item.isHidden ? 0.55 : 1)
            Text(r.item.name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(r.item.isHidden ? .secondary : .primary)
        }
    }


    private func items(_ ids: Set<String>) -> [FileItem] { ids.compactMap { pane.item($0) } }

    /// 두 번 클릭: 폴더는 열고, 파일은 반대쪽으로
    private func open(_ ids: Set<String>) {
        let picked = items(ids)
        if picked.count == 1, let f = picked.first, f.isDirectory { Task { await pane.open(f.id) }; return }
        // 설정 > SSH > 파일: 맥 앱으로 열기(기본, 서버 파일은 받아서 열고 저장하면 다시 올림) 또는 업로드·다운로드 (사용자 2026-11-23)
        if UserDefaults.standard.string(forKey: TerminalSettings.filesDoubleClick) == "transfer" {
            confirmLarge(picked, opening: false) { transfer(picked) }
        } else {
            openFiles(picked.filter { !$0.isDirectory }, with: nil)
        }
    }

    private func openFiles(_ files: [FileItem], with app: URL?) {
        let files = Array(files.prefix(20))
        guard pane.isRemote else { files.forEach { FileSession.launch($0.url, with: app) }; return }
        confirmLarge(files, opening: true) { files.forEach { session.openRemote($0, with: app) } }
    }

    /// 큰 파일이면 옮기기 전에 묻는다 (설정 > SSH > 파일). 폴더는 크기를 몰라 빼고 센다
    private func confirmLarge(_ items: [FileItem], opening: Bool, then go: () -> Void) {
        let d = UserDefaults.standard
        let on = d.object(forKey: TerminalSettings.filesConfirmLarge) as? Bool ?? true
        let mb = d.object(forKey: TerminalSettings.filesLargeMB) as? Int ?? 50
        let total = items.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard on, total > Int64(mb) * 1_000_000 else { go(); return }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let what = items.count == 1 ? items[0].name : "\(items[0].name) 외 \(items.count - 1)개"
        let a = NSAlert()
        a.messageText = "큰 파일입니다 (\(size))"
        a.informativeText = opening ? "\(what) 을(를) 받아서 엽니다. 받는 데 시간이 걸릴 수 있습니다."
            : (pane.isRemote ? "\(what) 을(를) 이 맥으로 받습니다." : "\(what) 을(를) 서버로 올립니다.")
        a.addButton(withTitle: opening ? "받아서 열기" : (pane.isRemote ? "다운로드" : "업로드"))
        a.addButton(withTitle: "취소")
        if a.runModal() == .alertFirstButtonReturn { go() }
    }

    /// "다른 앱으로 열기" 하위 메뉴
    @ViewBuilder private func openWithMenu(_ files: [FileItem]) -> some View {
        let first = files.first
        let apps = first.map { FileSession.apps(for: $0.name, localURL: pane.isRemote ? nil : $0.url) } ?? []
        Menu("다른 앱으로 열기") {
            ForEach(apps.prefix(20), id: \.self) { app in
                Button {
                    openFiles(files, with: app)
                } label: {
                    Label { Text(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")) }
                        icon: { Image(nsImage: Self.appIcon(app)) }
                        .labelStyle(.titleAndIcon)
                }
            }
            if !apps.isEmpty { Divider() }
            Button("기타…") { if let app = FileSession.chooseApp() { openFiles(files, with: app) } }
        }
        .disabled(files.isEmpty)
    }

    private static func appIcon(_ app: URL) -> NSImage {
        let i = NSWorkspace.shared.icon(forFile: app.path)
        i.size = NSSize(width: 16, height: 16)
        return i
    }

    private func transfer(_ picked: [FileItem]) {
        if pane.isRemote { session.download(picked, to: URL(fileURLWithPath: session.local.path)) }
        else { session.upload(picked.map(\.url), to: session.remote.path) }
    }

    @ViewBuilder private func menu(_ ids: Set<String>) -> some View {
        let picked = items(ids)
        let files = picked.filter { !$0.isDirectory }
        Button("열기") { openFiles(files, with: nil) }.disabled(files.isEmpty)
        openWithMenu(files)
        Divider()
        Button(pane.isRemote ? "다운로드" : "업로드") { transfer(picked) }.disabled(picked.isEmpty)
        if pane.isRemote {
            Button("이름 바꾸기…") { nameInput = picked.first?.name ?? ""; renaming = picked.first }.disabled(picked.count != 1)
        } else {
            Button("Finder 에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url)) }.disabled(picked.isEmpty)
        }
        Button("경로 복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(picked.map(\.id).joined(separator: "\n"), forType: .string)
        }.disabled(picked.isEmpty)
        Divider()
        if pane.isRemote { Button("새 폴더…") { nameInput = ""; newFolder = true } }
        Button("새로 고침") { Task { await pane.refresh() } }
        Divider()
        if pane.isRemote {
            Button("삭제…", role: .destructive) { deleting = picked }.disabled(picked.isEmpty)
        } else {
            // Finder 처럼 묻지 않고 휴지통으로 (되돌릴 수 있다)
            Button("휴지통으로 이동") { moveToTrash(picked) }.disabled(picked.isEmpty)
        }
    }

    /// 이 맥 항목을 휴지통으로 옮기고 목록을 다시 읽는다
    private func moveToTrash(_ picked: [FileItem]) {
        NSWorkspace.shared.recycle(picked.map(\.url)) { _, error in
            Task { @MainActor in
                selection.subtract(picked.map(\.id))
                await pane.refresh()
                if let error { NSAlert(error: error).runModal() }
            }
        }
    }

    private func provider(for item: FileItem) -> NSItemProvider {
        if pane.isRemote { return RemoteDrag.provider(for: item, session: session) }
        // 파일 주소(URL)로 내보낸다. contentsOf 는 "파일 내용"으로만 실려서 서버 칸(파일 주소를 받음)에 놓아도
        // 올라가지 않았다 (사용자: Finder 에서는 되고 왼쪽 칸에서는 안 됨). 주소로 실으면 Finder 로 끌어내도 파일로 놓인다
        return NSItemProvider(object: item.url as NSURL)
    }

    private func drop(_ items: [NSItemProvider]) -> Bool {
        // 서버 항목 (이 탭 또는 다른 탭): 서버 칸이면 서버 ↔ 서버, 이 맥 칸이면 받기
        let refs = RemoteDrag.refs()
        if !refs.isEmpty {
            for (tabID, paths) in Dictionary(grouping: refs, by: \.0) {
                guard let source = FileSession.session(for: tabID) else { continue }
                let picked = paths.compactMap { source.remote.item($0.1) }
                if pane.isRemote {
                    if source !== session { session.relay(picked, from: source, to: session.remote.path) }
                } else {
                    source.download(picked, to: URL(fileURLWithPath: session.local.path))
                }
            }
            return true
        }
        guard pane.isRemote else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in items {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { DispatchQueue.main.async { urls.append(u) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { session.upload(urls, to: session.remote.path) }
        return true
    }
}


/// 파일 표의 줄 사이 선을 끈다 (사용자: 선 없이).
/// 맥 26 의 SwiftUI 표는 AppKit 격자선(gridStyleMask)이 아니라 행마다 붙는 `_NSTableRowSeparatorDrawingView` 가 선을 그린다.
/// gridStyleMask·listRowSeparator·행 뷰 drawSeparator 바꾸기·선 뷰 숨기기는 모두 안 먹었다 →
/// 그 선 뷰 종류의 draw(_:) 를 바꿔서, 표시(identifier)한 표 안이면 아무것도 안 그린다.
/// 시험 앱에서 스크롤·행 고르기 뒤에도 선이 안 생기는 것을 화면으로 확인 (2026-11-21)
private struct TableLinesRemover: NSViewRepresentable {
    static let tableID = NSUserInterfaceItemIdentifier("ivnc.files.table")

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.apply() }
        }

        func apply() {
            SeparatorPatch.install()
            guard let root = window?.contentView else { return }
            // 이 창의 파일 표 모두 (사이드바 목록 sourceList 는 빼고)
            func walk(_ v: NSView) {
                if let t = v as? NSTableView, t.style != .sourceList {
                    if t.identifier != TableLinesRemover.tableID {
                        t.identifier = TableLinesRemover.tableID
                        // 표시하기 전에 이미 그려 둔 선 뷰는 표만 다시 그려서는 안 지워진다 (선 뷰는 따로 그려 둔 그림을 쓴다) →
                        // 선 뷰마다 다시 그리게 (처음 열 때 선이 보였다가 표를 누르면 사라지던 것, 사용자 2026-11-23)
                        redrawSeparators(t)
                    }
                    if t.gridStyleMask != [] { t.gridStyleMask = [] }
                }
                v.subviews.forEach(walk)
            }
            walk(root)
        }

        private func redrawSeparators(_ v: NSView) {
            if NSStringFromClass(type(of: v)).contains("Separator") { v.needsDisplay = true }
            v.subviews.forEach(redrawSeparators)
        }
    }
    func makeNSView(context: Context) -> Probe {
        // 표가 처음 그려지기 전에 바꿔 둔다
        SeparatorPatch.install()
        return Probe()
    }
    func updateNSView(_ v: Probe, context: Context) { DispatchQueue.main.async { v.apply() } }
}

@MainActor
private enum SeparatorPatch {
    private static var installed = false

    static func install() {
        guard !installed, let cls = NSClassFromString("_NSTableRowSeparatorDrawingView") else { return }
        installed = true
        let sel = #selector(NSView.draw(_:))
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Draw = @convention(c) (NSView, Selector, NSRect) -> Void
        let previous = unsafeBitCast(method_getImplementation(m), to: Draw.self)
        let block: @convention(block) (NSView, NSRect) -> Void = { v, rect in
            var p: NSView? = v.superview
            while let x = p, !(x is NSTableView) { p = x.superview }
            if (p as? NSTableView)?.identifier == TableLinesRemover.tableID { return }
            previous(v, sel, rect)
        }
        let imp = imp_implementationWithBlock(block)
        // 그 종류에 자기 구현이 없으면 덧붙이고(부모 NSView 것은 그대로), 있으면 바꾼다
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(m)) { method_setImplementation(m, imp) }
    }
}

/// 경로 줄 (Transmit 처럼): 맨 위 › 폴더 › … › 지금 폴더 ⌄ (⏏ 는 뺌, 사용자: 필요 없다)
/// 앞 폴더는 눌러서 바로 가고, 지금 폴더(강조색)는 위 폴더 목록·자주 가는 곳 메뉴. 좁으면 가운데를 … 로 줄인다
private struct PathBar: View {
    @ObservedObject var session: FileSession
    @ObservedObject var pane: FilePane
    let title: String
    @State private var anchor = MenuAnchorBox()

    var body: some View {
        HStack(spacing: 6) {
            // 넓으면 다 보이고, 좁으면 맨 위와 지금 폴더는 남기고 가운데부터 … 로
            let chain = Array(ancestors.reversed())
            ViewThatFits(in: .horizontal) {
                ForEach(0..<max(1, chain.count - 1), id: \.self) { hide in crumbs(chain, hiding: hide) }
                current(chain.last ?? pane.path)
            }
        }
        .help(pane.path)
    }

    private func crumbs(_ chain: [String], hiding: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(chain.enumerated()), id: \.offset) { i, p in
                if i == chain.count - 1 {
                    current(p)
                } else if i == 0 || i > hiding {
                    Button { Task { await pane.open(p) } } label: { Text(display(p)).lineLimit(1) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary.opacity(0.85))
                    chevron
                } else if i == 1 {
                    Text("…").foregroundStyle(.secondary)
                    chevron
                }
            }
        }
        .fixedSize()
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
    }

    /// 지금 폴더: 강조색 이름 ⌄ → 위 폴더 목록 (Transmit 처럼 아이콘 + 이름만).
    /// SwiftUI Menu 는 그림을 단색으로 바꾸고 모양을 못 맞춰서 AppKit 메뉴로 (iSQL ServerSwitcher 방식)
    private func current(_ p: String) -> some View {
        Button { showMenu() } label: {
            HStack(spacing: 4) {
                Text(p.isEmpty ? title : display(p)).fontWeight(.semibold).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)
            .background(MenuAnchor(box: anchor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func showMenu() {
        let menu = NSMenu()
        // Transmit 처럼 위 폴더들: 아이콘 + 이름 (맥 26 메뉴는 항목 그림을 안 그려서 SwiftUI 줄로)
        for a in ancestors.dropFirst() {
            let row = HStack(spacing: 8) {
                Image(nsImage: folderIcon(a)).resizable().frame(width: 18, height: 18)
                Text(display(a)).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 12)
            }
            .padding(.leading, 14).padding(.trailing, 14).padding(.vertical, 3)
            menu.addItem(MenuAction.item(display(a), view: row, minWidth: 180) { [pane] in Task { await pane.open(a) } })
        }
        if !pane.isRemote {
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("다른 폴더…") { pickLocal() })
        }
        guard !menu.items.isEmpty else { return }
        menu.popUp(below: anchor)
    }

    private var ancestors: [String] {
        var out: [String] = []
        var p = pane.path
        while !p.isEmpty {
            out.append(p)
            if p == "/" { break }
            let parent = (p as NSString).deletingLastPathComponent
            p = parent.isEmpty ? "/" : parent
        }
        return out
    }

    private func display(_ p: String) -> String {
        if p == "/" { return pane.isRemote ? title : "Macintosh HD" }
        return (p as NSString).lastPathComponent
    }

    private func folderIcon(_ p: String) -> NSImage {
        if pane.isRemote {
            // 맨 위(서버)는 네트워크 서버 그림
            if p == "/" { return NSImage(named: NSImage.networkName) ?? NSWorkspace.shared.icon(for: .folder) }
            return NSWorkspace.shared.icon(for: .folder)
        }
        return NSWorkspace.shared.icon(forFile: p)
    }

    private func pickLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: pane.path)
        if panel.runModal() == .OK, let u = panel.url { Task { await pane.open(u.path) } }
    }
}

/// 보기 옵션 풍선
private struct FileViewOptionsView: View {
    @AppStorage(FileViewOptions.showHidden) private var showHidden = false
    @AppStorage(FileViewOptions.foldersFirst) private var foldersFirst = true

    var body: some View {
        Form {
            Section {
                Toggle("숨김 파일 보기", isOn: $showHidden)
                Toggle("폴더를 상단에 고정", isOn: $foldersFirst)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 끌기 파일 요청에 한 번만 답한다 (받기 Task 와 꺼짐 감시 중 먼저 온 쪽)
private final class DragAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var done: ((URL?, Bool, Error?) -> Void)?
    init(_ done: @escaping (URL?, Bool, Error?) -> Void) { self.done = done }
    var sent: Bool { lock.withLock { done == nil } }
    func send(_ url: URL?, _ error: Error?) {
        let d = lock.withLock { () -> ((URL?, Bool, Error?) -> Void)? in defer { done = nil }; return done }
        d?(url, false, error)
    }
}

/// 서버 항목 끌기: 우리 앱 안에서는 경로를, Finder 에 놓으면 그때 받아서 파일로 넘긴다
@MainActor
enum RemoteDrag {
    /// 앱이 꺼지는 중. 꺼질 때 AppKit 이 끌기 판에 약속해 둔 데이터를 모두 채우려고 기다리므로(CFPasteboardResolveAllPromisedData),
    /// 그때 서버에서 받기 시작하면 끝날 때까지(예전엔 영영) 앱이 멈춘다 → 바로 취소로 답하고, 받는 중인 것도 멈춘다
    nonisolated(unsafe) static var terminating = false
    /// 지금 놓는 끌기판에서 우리 서버 항목들 (보낸 탭 id, 서버 경로). 놓기 처리 중에만 부른다
    static func refs() -> [(UUID, String)] {
        let marker = NSPasteboard.PasteboardType(remoteDragType.identifier)
        return (NSPasteboard(name: .drag).pasteboardItems ?? []).compactMap { item in
            guard item.types.contains(marker), let d = item.data(forType: marker), let s = String(data: d, encoding: .utf8) else { return nil }
            let parts = s.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return nil }
            return (id, parts[1])
        }
    }

    static func provider(for e: FileItem, session: FileSession) -> NSItemProvider {
        let p = NSItemProvider()
        p.suggestedName = e.name
        let path = e.id
        // 끌기 시험 앱(Ai/iVNC/dragtest)에서 앱→Finder · Finder→앱 · 앱 안(서버↔서버, 서버→이 맥) · 여러 개를 마우스로 끌어 확인한 방식 (2026-11-27):
        // - Finder 는 맨 앞 표현만 가져간다 → 맨 앞은 Finder 용 받기. 폴더는 public.folder(public.data 면 zip 으로 묶여 넘어감),
        //   파일은 형식과 상관없이 public.data(글자 형식이면 Finder 가 경로 글을 가져갔고, 확장자 형식이면 a.sql.sql 처럼 덧붙였다)
        // - 앱 안 놓기는 SwiftUI 가 넘기는 형식 목록이 비어 오므로 끌기판에서 경로 글을 직접 읽는다 (FilePaneView.drop 의 RemoteDrag.refs)
        if session.client != nil {
            let type = e.isDirectory ? UTType.folder : UTType.data
            p.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
                // 꺼지는 중이면 받지 않는다 (RemoteDrag.terminating)
                if RemoteDrag.terminating { done(nil, false, CocoaError(.userCancelled)); return nil }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let progress = Progress(totalUnitCount: e.isDirectory ? -1 : max(e.size ?? 0, 1))
                let answer = DragAnswer(done)
                Task { @MainActor in
                    do {
                        answer.send(try await session.downloadForDrag(e, to: dir, progress: progress), nil)
                    } catch {
                        answer.send(nil, error)
                    }
                }
                // 받는 중에 꺼지면 메인 스레드는 끌기 약속을 채우려고 전용 런루프 모드에서 기다려 메인 액터 일이 돌지 않는다
                // → 위 Task 가 답할 수 없으니, 메인 밖에서 지켜보다 바로 취소로 답한다
                Task.detached {
                    while !answer.sent {
                        if RemoteDrag.terminating { answer.send(nil, CocoaError(.userCancelled)); return }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                return progress
            }
        }
        // 우리 앱 안: "탭 id \n 경로" (다른 탭의 서버로 옮길 때 보낸 쪽을 찾는다). 맨 뒤라 Finder 는 안 가져간다.
        // 형식은 public.item (데이터가 아님, iVNCMac-Info.plist) 이라 Finder 가 파일로 만들 수 없다
        let ref = session.tabID.uuidString + "\n" + path
        p.registerDataRepresentation(forTypeIdentifier: remoteDragType.identifier, visibility: .ownProcess) { done in
            done(ref.data(using: .utf8), nil)
            return nil
        }
        return p
    }

}

