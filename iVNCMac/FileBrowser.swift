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
                let c = try await shell.openSFTP()
                client = c
                remote.loader = { p in try await c.list(p).map(Self.item) }
                remoteHome = try? await c.realpath(".")
            }
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
        Task {
            for u in urls {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    await uploadFolder(u, to: SFTPClient.join(dir, u.lastPathComponent), client: client)
                } else {
                    enqueue(Transfer(name: u.lastPathComponent, upload: true, total: Self.fileSize(u)) { t in
                        try await client.upload(u, to: SFTPClient.join(dir, u.lastPathComponent), progress: t.add, isCancelled: t.isCancelled)
                    })
                }
            }
        }
    }

    private func uploadFolder(_ u: URL, to remotePath: String, client: SFTPClient) async {
        try? await client.mkdir(remotePath) // 이미 있으면 실패해도 그대로 쓴다
        let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for c in items {
            if (try? c.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                await uploadFolder(c, to: SFTPClient.join(remotePath, c.lastPathComponent), client: client)
            } else {
                enqueue(Transfer(name: c.lastPathComponent, upload: true, total: Self.fileSize(c)) { t in
                    try await client.upload(c, to: SFTPClient.join(remotePath, c.lastPathComponent), progress: t.add, isCancelled: t.isCancelled)
                })
            }
        }
    }

    /// 서버 파일·폴더를 이 맥 폴더로
    func download(_ items: [FileItem], to dir: URL) {
        guard let client else { return }
        Task {
            for e in items {
                if e.isDirectory {
                    await downloadFolder(e.id, to: dir.appendingPathComponent(e.name), client: client)
                } else {
                    enqueueDownload(e.id, name: e.name, size: e.size ?? 0, to: dir.appendingPathComponent(e.name), client: client)
                }
            }
        }
    }

    private func downloadFolder(_ path: String, to local: URL, client: SFTPClient) async {
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        guard let items = try? await client.list(path) else { return }
        for c in items {
            if c.isDirectory {
                await downloadFolder(c.path, to: local.appendingPathComponent(c.name), client: client)
            } else {
                enqueueDownload(c.path, name: c.name, size: Int64(c.attrs.size ?? 0), to: local.appendingPathComponent(c.name), client: client)
            }
        }
    }

    /// 다른 탭(서버)의 항목을 이 서버 폴더로 (폴더째, 이 맥 디스크를 거치지 않음)
    func relay(_ items: [FileItem], from source: FileSession, to dir: String) {
        guard let dst = client, let src = source.client, source !== self else { return }
        Task {
            for e in items {
                if e.isDirectory {
                    await relayFolder(e.id, name: e.name, src: src, dst: dst, to: dir)
                } else {
                    enqueueRelay(e.id, name: e.name, size: e.size ?? 0, src: src, dst: dst, to: SFTPClient.join(dir, e.name))
                }
            }
        }
    }

    private func relayFolder(_ path: String, name: String, src: SFTPClient, dst: SFTPClient, to dir: String) async {
        let target = SFTPClient.join(dir, name)
        try? await dst.mkdir(target)
        guard let items = try? await src.list(path) else { return }
        for c in items {
            if c.isDirectory {
                await relayFolder(c.path, name: c.name, src: src, dst: dst, to: target)
            } else {
                enqueueRelay(c.path, name: c.name, size: Int64(c.attrs.size ?? 0), src: src, dst: dst, to: SFTPClient.join(target, c.name))
            }
        }
    }

    private func enqueueRelay(_ path: String, name: String, size: Int64, src: SFTPClient, dst: SFTPClient, to target: String) {
        enqueue(Transfer(name: name, upload: true, total: size, relay: true) { t in
            try await SFTPClient.relay(from: src, path, size: UInt64(size), to: dst, target, progress: t.add, isCancelled: t.isCancelled)
        })
    }

    private func enqueueDownload(_ path: String, name: String, size: Int64, to local: URL, client: SFTPClient) {
        enqueue(Transfer(name: name, upload: false, total: size) { t in
            try await client.download(path, to: local, progress: t.add, isCancelled: t.isCancelled)
        })
    }

    private func enqueue(_ t: Transfer) {
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

    func close() {
        cancelAll()
        client?.close()
        client = nil
    }

    static func fileSize(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
}

/// 파일 하나 옮기기. 받은 바이트는 이벤트 루프에서 늘고 화면은 타이머로 읽는다
final class Transfer: Identifiable, @unchecked Sendable {
    enum State: Equatable { case waiting, running, done, cancelled, failed(String) }
    let id = UUID()
    let name: String
    let upload: Bool
    /// 서버 → 서버
    let relay: Bool
    let total: Int64
    let work: (Transfer) async throws -> Void
    var state: State = .waiting
    var startedAt: Date?
    var finishedAt: Date?
    private let lock = NSLock()
    private var _done: Int64 = 0
    private var _cancelled = false

    init(name: String, upload: Bool, total: Int64, relay: Bool = false, work: @escaping (Transfer) async throws -> Void) {
        self.name = name; self.upload = upload; self.relay = relay; self.total = total; self.work = work
    }

    var done: Int64 { lock.lock(); defer { lock.unlock() }; return _done }
    func add(_ n: Int) { lock.lock(); _done += Int64(n); lock.unlock() }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : (state == .done ? 1 : 0) }
}

// MARK: - 보기 옵션 (두 칸 공용, 이 맥에 저장)

enum FileViewOptions {
    static let showHidden = "files.showHidden"
    static let foldersFirst = "files.foldersFirst"
    static let textSize = "files.textSize"
    static let dateStyle = "files.dateStyle"
    static let showSize = "files.column.size"
    static let showDate = "files.column.date"
    static let showKind = "files.column.kind"
    static let showPermissions = "files.column.permissions"

    enum TextSize: String, CaseIterable, Identifiable {
        case small, regular, large
        var id: String { rawValue }
        var title: String { self == .small ? "작게" : self == .regular ? "보통" : "크게" }
        var font: Font { .system(size: self == .small ? 11 : self == .regular ? 13 : 15) }
        var icon: CGFloat { self == .small ? 14 : self == .regular ? 16 : 20 }
    }

    enum DateStyle: String, CaseIterable, Identifiable {
        case relative, dateTime, date
        var id: String { rawValue }
        var title: String {
            switch self {
            case .relative: return "오늘·어제로"
            case .dateTime: return "날짜와 시간"
            case .date: return "날짜만"
            }
        }
    }
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

    private static let relative: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .short; f.doesRelativeDateFormatting = true
        return f
    }()

    static func date(_ d: Date?, style: FileViewOptions.DateStyle) -> String {
        guard let d else { return "" }
        switch style {
        case .relative: return relative.string(from: d)
        case .dateTime: return d.formatted(date: .numeric, time: .shortened)
        case .date: return d.formatted(date: .numeric, time: .omitted)
        }
    }
}

// MARK: - 화면

/// 서버 항목을 끌 때 쓰는 우리 앱 안 형식 (서버 경로)
private let remoteDragType = UTType(exportedAs: "com.moimz.ivnc.remote-files")

struct FileBrowserView: View {
    @ObservedObject var session: FileSession
    let serverName: String

    /// 이보다 좁으면(분할 칸 등) 한 칸만 보이고 [이 맥 | 서버] 로 바꾼다
    static let twoPaneWidth: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                if geo.size.width >= Self.twoPaneWidth {
                    HSplitView {
                        FilePaneView(session: session, pane: session.local, title: "이 맥").frame(minWidth: 260)
                        FilePaneView(session: session, pane: session.remote, title: serverName).frame(minWidth: 260)
                    }
                } else if session.compactShowsLocal {
                    FilePaneView(session: session, pane: session.local, title: "이 맥", compact: true)
                } else {
                    FilePaneView(session: session, pane: session.remote, title: serverName, compact: true)
                }
            }
            if !session.transfers.isEmpty {
                Divider()
                TransferBar(session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
    @AppStorage(FileViewOptions.textSize) private var textSize = FileViewOptions.TextSize.regular.rawValue
    @AppStorage(FileViewOptions.dateStyle) private var dateStyle = FileViewOptions.DateStyle.relative.rawValue
    @AppStorage(FileViewOptions.showSize) private var showSize = true
    @AppStorage(FileViewOptions.showDate) private var showDate = true
    @AppStorage(FileViewOptions.showKind) private var showKind = false
    @AppStorage(FileViewOptions.showPermissions) private var showPermissions = false

    @State private var selection = Set<String>()
    @State private var order = [KeyPathComparator(\FileRowItem.name, comparator: .localizedStandard)]
    @State private var columns = TableColumnCustomization<FileRowItem>()
    @State private var showOptions = false
    @State private var dropTarget = false
    @State private var newFolder = false
    @State private var renaming: FileItem?
    @State private var deleting: [FileItem] = []
    @State private var nameInput = ""

    private var size: FileViewOptions.TextSize { .init(rawValue: textSize) ?? .regular }
    private var style: FileViewOptions.DateStyle { .init(rawValue: dateStyle) ?? .relative }

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
        .onAppear(perform: applyColumns)
        .onChange(of: [showSize, showDate, showKind, showPermissions]) { applyColumns() }
    }

    // 위 줄: [장치 아이콘 | 폴더 이름 ⌄] ··· [새로 고침] [보기 옵션]
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
                Image(systemName: pane.isRemote ? "server.rack" : "internaldrive")
                    .foregroundStyle(.secondary)
                    .help(title)
            }
            Divider().frame(height: 14)
            PathMenu(session: session, pane: pane, title: title)
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
        return Table(of: FileRowItem.self, selection: $selection, sortOrder: $order, columnCustomization: $columns) {
            // 제목은 줄의 ▸ 자리만큼 띄운다 (열 제목에는 여백을 줄 수 없어 앞에 빈칸 글자: 전각 공백 + 가는 공백 ≈ 16pt)
            TableColumn(Text("\u{2003}\u{2009}이름"), value: \.name, comparator: .localizedStandard) { r in nameCell(r) }
                .width(min: 160, ideal: 300)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("크기", value: \.sizeValue) { r in
                Text(r.item.isDirectory ? "•" : ByteCountFormatter.string(fromByteCount: r.item.size ?? 0, countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 56, max: 110)
            .customizationID("size")
            TableColumn("날짜", value: \.dateValue) { r in
                Text(FileLook.date(r.item.modified, style: style)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .width(min: 80, ideal: 150)
            .customizationID("date")
            TableColumn("종류", value: \.kindValue) { r in
                Text(r.kindValue).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 110)
            .customizationID("kind")
            TableColumn("권한") { r in
                Text(FileLook.permissions(r.item.permissions)).foregroundStyle(.secondary).font(size.font.monospaced())
            }
            .width(min: 70, ideal: 86)
            .customizationID("permissions")
        } rows: {
            ForEach(rows) { r in
                TableRow(r).itemProvider { provider(for: r.item) }
            }
        }
        .font(size.font)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .background(TableLinesRemover())
        .contextMenu(forSelectionType: String.self) { ids in menu(ids) } primaryAction: { ids in open(ids) }
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
                .resizable().frame(width: size.icon, height: size.icon)
                .opacity(r.item.isHidden ? 0.55 : 1)
            Text(r.item.name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(r.item.isHidden ? .secondary : .primary)
        }
    }

    private func applyColumns() {
        columns[visibility: "size"] = showSize ? .visible : .hidden
        columns[visibility: "date"] = showDate ? .visible : .hidden
        columns[visibility: "kind"] = showKind ? .visible : .hidden
        columns[visibility: "permissions"] = showPermissions ? .visible : .hidden
    }

    private func items(_ ids: Set<String>) -> [FileItem] { ids.compactMap { pane.item($0) } }

    /// 두 번 클릭: 폴더는 열고, 파일은 반대쪽으로
    private func open(_ ids: Set<String>) {
        let picked = items(ids)
        if picked.count == 1, let f = picked.first, f.isDirectory { Task { await pane.open(f.id) }; return }
        transfer(picked)
    }

    private func transfer(_ picked: [FileItem]) {
        if pane.isRemote { session.download(picked, to: URL(fileURLWithPath: session.local.path)) }
        else { session.upload(picked.map(\.url), to: session.remote.path) }
    }

    @ViewBuilder private func menu(_ ids: Set<String>) -> some View {
        let picked = items(ids)
        Button(pane.isRemote ? "이 맥으로 받기" : "서버로 올리기") { transfer(picked) }.disabled(picked.isEmpty)
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
        if pane.isRemote {
            Divider()
            Button("삭제…", role: .destructive) { deleting = picked }.disabled(picked.isEmpty)
        }
    }

    private func provider(for item: FileItem) -> NSItemProvider {
        if pane.isRemote { return RemoteDrag.provider(for: item, session: session) }
        return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
    }

    private func drop(_ items: [NSItemProvider]) -> Bool {
        // 서버 항목 (이 탭 또는 다른 탭): 서버 칸이면 서버 ↔ 서버, 이 맥 칸이면 받기
        let remoteItems = items.filter { $0.hasItemConformingToTypeIdentifier(remoteDragType.identifier) }
        if !remoteItems.isEmpty {
            RemoteDrag.load(remoteItems) { refs in
                for (tabID, paths) in Dictionary(grouping: refs, by: \.0) {
                    guard let source = FileSession.session(for: tabID) else { continue }
                    let picked = paths.compactMap { source.remote.item($0.1) }
                    if pane.isRemote {
                        if source !== session { session.relay(picked, from: source, to: session.remote.path) }
                    } else {
                        source.download(picked, to: URL(fileURLWithPath: session.local.path))
                    }
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

/// SwiftUI 표 밑의 NSTableView 에서 줄 사이 선을 끈다 (SwiftUI 에는 이 옵션이 없다)
private struct TableLinesRemover: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.apply() }
        }
        func apply() {
            guard let root = window?.contentView else { return }
            func walk(_ v: NSView) {
                if let t = v as? NSTableView, t.gridStyleMask != [] { t.gridStyleMask = [] }
                v.subviews.forEach(walk)
            }
            walk(root)
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) { DispatchQueue.main.async { v.apply() } }
}

/// 폴더 이름 ⌄ → 위 폴더들 (Finder 제목 경로 메뉴처럼) + 자주 가는 곳
private struct PathMenu: View {
    @ObservedObject var session: FileSession
    @ObservedObject var pane: FilePane
    let title: String

    var body: some View {
        Menu {
            ForEach(ancestors, id: \.self) { p in
                Button { Task { await pane.open(p) } } label: {
                    Label { Text(display(p)) } icon: { Image(nsImage: folderIcon(p)) }
                }
            }
            Divider()
            if pane.isRemote {
                if let home = session.remoteHome { Button("홈 (\(home))") { Task { await pane.open(home) } } }
                Button("루트 (/)") { Task { await pane.open("/") } }
            } else {
                ForEach(places, id: \.0) { name, url in
                    Button(name) { Task { await pane.open(url.path) } }
                }
                Divider()
                Button("다른 폴더…") { pickLocal() }
            }
        } label: {
            HStack(spacing: 3) {
                Text(pane.path.isEmpty ? title : display(pane.path)).fontWeight(.semibold).foregroundStyle(.primary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(pane.path)
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
        if p == "/" { return pane.isRemote ? "/" : "Macintosh HD" }
        return (p as NSString).lastPathComponent
    }

    private func folderIcon(_ p: String) -> NSImage {
        let i = pane.isRemote ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(forFile: p)
        i.size = NSSize(width: 16, height: 16)
        return i
    }

    private var places: [(String, URL)] {
        let fm = FileManager.default
        return [("홈", fm.homeDirectoryForCurrentUser),
                ("데스크탑", fm.urls(for: .desktopDirectory, in: .userDomainMask).first!),
                ("문서", fm.urls(for: .documentDirectory, in: .userDomainMask).first!),
                ("다운로드", fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!)]
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
    @AppStorage(FileViewOptions.textSize) private var textSize = FileViewOptions.TextSize.regular.rawValue
    @AppStorage(FileViewOptions.dateStyle) private var dateStyle = FileViewOptions.DateStyle.relative.rawValue
    @AppStorage(FileViewOptions.showSize) private var showSize = true
    @AppStorage(FileViewOptions.showDate) private var showDate = true
    @AppStorage(FileViewOptions.showKind) private var showKind = false
    @AppStorage(FileViewOptions.showPermissions) private var showPermissions = false

    var body: some View {
        Form {
            Section {
                Toggle("숨김 파일 보기", isOn: $showHidden)
                Toggle("폴더를 위에", isOn: $foldersFirst)
            }
            Section {
                Picker("글자 크기", selection: $textSize) {
                    ForEach(FileViewOptions.TextSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("날짜", selection: $dateStyle) {
                    ForEach(FileViewOptions.DateStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("보일 열") {
                Toggle("크기", isOn: $showSize)
                Toggle("날짜", isOn: $showDate)
                Toggle("종류", isOn: $showKind)
                Toggle("권한", isOn: $showPermissions)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 서버 항목 끌기: 우리 앱 안에서는 경로를, Finder 에 놓으면 그때 받아서 파일로 넘긴다
@MainActor
private enum RemoteDrag {
    static func provider(for e: FileItem, session: FileSession) -> NSItemProvider {
        let p = NSItemProvider()
        p.suggestedName = e.name
        let path = e.id
        // 우리 앱 안: "탭 id \n 경로" (다른 탭의 서버로 옮길 때 보낸 쪽을 찾는다)
        let ref = session.tabID.uuidString + "\n" + path
        p.registerDataRepresentation(forTypeIdentifier: remoteDragType.identifier, visibility: .ownProcess) { done in
            done(ref.data(using: .utf8), nil)
            return nil
        }
        // Finder·데스크탑에 놓으면 임시 폴더로 받아 넘긴다 (파일만)
        if !e.isDirectory, let client = session.client {
            p.registerFileRepresentation(forTypeIdentifier: (UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data).identifier,
                                         fileOptions: [], visibility: .all) { done in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let local = dir.appendingPathComponent(e.name)
                let progress = Progress(totalUnitCount: e.size ?? 0)
                Task {
                    do {
                        try await client.download(path, to: local, progress: { progress.completedUnitCount += Int64($0) }, isCancelled: { progress.isCancelled })
                        done(local, false, nil)
                    } catch {
                        done(nil, false, error)
                    }
                }
                return progress
            }
        }
        return p
    }

    /// (보낸 탭 id, 서버 경로) 들
    static func load(_ items: [NSItemProvider], done: @escaping ([(UUID, String)]) -> Void) {
        var refs: [(UUID, String)] = []
        let group = DispatchGroup()
        for p in items {
            group.enter()
            p.loadDataRepresentation(forTypeIdentifier: remoteDragType.identifier) { d, _ in
                if let d, let s = String(data: d, encoding: .utf8) {
                    let parts = s.split(separator: "\n", maxSplits: 1).map(String.init)
                    if parts.count == 2, let id = UUID(uuidString: parts[0]) { DispatchQueue.main.async { refs.append((id, parts[1])) } }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(refs) }
    }
}

/// 아래 진행 줄: 지금 옮기는 것들 · 전체 속도 · 모두 취소 / 끝난 것 지우기 (다 끝나면 잠시 뒤 걷힌다)
private struct TransferBar: View {
    @ObservedObject var session: FileSession

    var body: some View {
        let running = session.transfers.filter { $0.state == .running }
        let waiting = session.transfers.filter { $0.state == .waiting }.count
        let failed = session.transfers.filter { if case .failed = $0.state { return true } else { return false } }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(running.prefix(Self.shown)) { t in
                HStack(spacing: 8) {
                    Image(systemName: t.relay ? "arrow.left.arrow.right.circle.fill" : t.upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(t.relay ? Color.purple : t.upload ? Color.orange : Color.accentColor)
                    Text(t.name).lineLimit(1).truncationMode(.middle).frame(width: 220, alignment: .leading)
                    ProgressView(value: t.fraction).controlSize(.small)
                    Text("\(ByteCountFormatter.string(fromByteCount: t.done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: t.total, countStyle: .file))")
                        .foregroundStyle(.secondary).monospacedDigit().frame(width: 150, alignment: .trailing)
                }
            }
            HStack(spacing: 12) {
                Text(summary(running: running, waiting: waiting, failed: failed.count)).foregroundStyle(.secondary)
                if let f = failed.last, case .failed(let msg) = f.state {
                    Label("\(f.name): \(msg)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).lineLimit(1).help(msg)
                }
                Spacer()
                if !running.isEmpty || waiting > 0 { Button("모두 취소") { session.cancelAll() }.controlSize(.small) }
                if !failed.isEmpty { Button("닫기") { session.clearFinished() }.controlSize(.small) }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    static let shown = 3

    private func summary(running: [Transfer], waiting: Int, failed: Int) -> String {
        let speed = running.reduce(0.0) { s, t in
            guard let start = t.startedAt else { return s }
            return s + Double(t.done) / max(Date().timeIntervalSince(start), 0.1)
        }
        let done = session.transfers.filter { $0.state == .done }.count
        var parts: [String] = []
        if !running.isEmpty { parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s") }
        if running.count > Self.shown { parts.append("그 밖에 \(running.count - Self.shown)개 진행 중") }
        if waiting > 0 { parts.append("대기 \(waiting)") }
        if done > 0 { parts.append("완료 \(done)") }
        if failed > 0 { parts.append("실패 \(failed)") }
        return parts.joined(separator: " · ")
    }
}
