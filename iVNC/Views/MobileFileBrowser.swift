#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuickLook

// 아이패드 파인더 (2026-11-21 사용자): 서버 파일 목록 + 파일 앱과 주고받기.
// 맥처럼 "이 맥" 칸은 없고 — 올리기는 파일 앱에서 고르거나 끌어 놓고, 받기는 미리보기·"파일에 저장".
// 넓으면 터미널 옆에 나란히, 좁으면 [터미널 | 파인더] 로 바꿔 본다 (작업 공간이 정한다).

/// 한 탭의 서버 파일 (같은 SSH 접속에 SFTP 채널 하나)
@MainActor
final class MobileFileSession: ObservableObject {
    weak var terminal: MobileTerminalSession?
    private var client: SFTPClient?
    @Published private(set) var path = ""
    @Published private(set) var entries: [SFTPClient.Entry] = []
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var showHidden = false
    private var followed: String?

    init(terminal: MobileTerminalSession) { self.terminal = terminal }

    var visible: [SFTPClient.Entry] {
        // 폴더 먼저, 그다음 이름 (Finder 와 같은 정렬)
        entries.filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// 파인더를 볼 때마다: SFTP 를 열고(처음만) 터미널이 있는 폴더로
    func appear() async {
        guard let shell = terminal?.sshShell else { error = "접속돼 있지 않습니다."; return }
        do {
            if client == nil {
                loading = true
                client = try await shell.openSFTP()
            }
            var dir = await shell.currentDirectory()
            if dir == nil, path.isEmpty { dir = try? await client?.realpath(".") }
            if let dir, dir != followed { followed = dir; await open(dir) } else { await refresh() }
        } catch {
            loading = false
            self.error = (error as? LocalizedError)?.errorDescription ?? "파일 목록을 열 수 없습니다: \(error)"
        }
    }

    func open(_ p: String) async {
        guard let client else { return }
        loading = true
        do {
            let list = try await client.list(p)
            path = p
            entries = list
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loading = false
    }

    func refresh() async { if !path.isEmpty { await open(path) } }

    func close() { client?.close(); client = nil }

    /// 위 폴더들 (지금 폴더 → … → /)
    var ancestors: [String] {
        var out: [String] = []
        var p = path
        while !p.isEmpty {
            out.append(p)
            if p == "/" { break }
            let parent = (p as NSString).deletingLastPathComponent
            p = parent.isEmpty ? "/" : parent
        }
        return out
    }

    // MARK: 받기 · 올리기

    /// 서버 파일을 임시 폴더로 받아 주소를 준다 (미리보기·파일에 저장·공유)
    func fetch(_ e: SFTPClient.Entry) async -> URL? {
        guard let client else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ivnc-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(e.name)
        try? FileManager.default.removeItem(at: local)
        // 아래 상태 줄은 없앴다 (사용자: 진행은 ⇅ 배지·전송 내역으로) → 미리보기 받는 동안은 제목 줄 돌림표
        loading = true
        defer { loading = false }
        do {
            try await client.download(e.path, to: local, progress: { _ in }, isCancelled: { false })
            return local
        } catch {
            self.error = "다운로드 실패: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            return nil
        }
    }

    private var serverName: String { terminal?.computer.name ?? "" }

    /// 서버 파일·폴더를 이 iPad 폴더로 (폴더는 안까지). 전송 내역(⇅)에 한 묶음으로:
    /// 먼저 폴더 안을 훑어 파일 목록을 만들고(전체 크기를 알게), 그다음 차례로 받는다
    func download(_ items: [SFTPClient.Entry], into dir: URL) async {
        guard let client else { return }
        let g = TransferCenter.shared.begin(.download, names: items.map(\.name), server: serverName)
        for e in items { await planDownload(e, to: dir.appendingPathComponent(e.name), client: client, group: g) }
        g.preparing = false
        await TransferCenter.shared.run(g)
        report(g, verb: "다운로드")
    }

    private func planDownload(_ e: SFTPClient.Entry, to local: URL, client: SFTPClient, group g: TransferGroup) async {
        if e.isDirectory {
            try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            do {
                for c in try await client.list(e.path) {
                    await planDownload(c, to: local.appendingPathComponent(c.name), client: client, group: g)
                }
            } catch { self.error = "다운로드 실패: \(e.name) — \((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
        } else {
            let path = e.path
            g.add(Transfer(name: e.name, upload: false, total: Int64(e.attrs.size ?? 0)) { t in
                try? FileManager.default.removeItem(at: local)
                try await client.download(path, to: local, progress: t.add, isCancelled: t.isCancelled)
            })
        }
    }

    /// 실패가 있으면 아래 오류 글로도 알린다 (자세한 건 전송 내역)
    private func report(_ g: TransferGroup, verb: String) {
        let failed = g.items.filter(\.isFailed)
        guard let f = failed.first, case .failed(let msg) = f.state else { return }
        error = failed.count == 1 ? "\(verb) 실패: \(f.name) — \(msg)" : "\(verb) 실패 \(failed.count)개 (전송 내역에서 확인)"
    }

    /// 경로로 항목 찾기 (이 iPad 칸에 끌어 놓은 서버 항목)
    func entry(_ path: String) -> SFTPClient.Entry? { entries.first { $0.path == path } }

    /// 파일 앱에서 고른·끌어 온 파일들을 지금 폴더로 (폴더는 안까지)
    func upload(_ urls: [URL]) async {
        guard let client, !path.isEmpty else { return }
        let g = TransferCenter.shared.begin(.upload, names: urls.map(\.lastPathComponent), server: serverName)
        // 파일 앱에서 고른 것은 다 올릴 때까지 읽기 허락을 쥐고 있는다
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        for u in urls { await planUpload(u, to: SFTPClient.join(path, u.lastPathComponent), client: client, group: g) }
        g.preparing = false
        await TransferCenter.shared.run(g)
        report(g, verb: "업로드")
        await refresh()
    }

    private func planUpload(_ u: URL, to remote: String, client: SFTPClient, group g: TransferGroup) async {
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if v?.isDirectory == true {
            try? await client.mkdir(remote) // 이미 있으면 실패해도 그대로 쓴다
            for c in (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? [] {
                await planUpload(c, to: SFTPClient.join(remote, c.lastPathComponent), client: client, group: g)
            }
        } else {
            g.add(Transfer(name: u.lastPathComponent, upload: true, total: Int64(v?.fileSize ?? 0)) { t in
                try await client.upload(u, to: remote, progress: t.add, isCancelled: t.isCancelled)
            })
        }
    }

    func makeFolder(_ name: String) async {
        guard let client, !name.isEmpty else { return }
        do { try await client.mkdir(SFTPClient.join(path, name)) } catch { self.error = "새 폴더 실패: \(error.localizedDescription)" }
        await refresh()
    }

    func rename(_ e: SFTPClient.Entry, to name: String) async {
        guard let client, !name.isEmpty, name != e.name else { return }
        do { try await client.rename(e.path, to: SFTPClient.join(path, name)) } catch { self.error = "이름 바꾸기 실패: \(error.localizedDescription)" }
        await refresh()
    }

    func delete(_ e: SFTPClient.Entry) async {
        guard let client else { return }
        do { try await client.removeRecursive(e) } catch { self.error = "지우기 실패: \(error.localizedDescription)" }
        await refresh()
    }
}

/// 파인더 화면 (한 탭)
struct MobileFileBrowserView: View {
    @ObservedObject var files: MobileFileSession
    /// 터미널이 접속됐는지 (접속되면 그때 목록을 연다)
    var connected: Bool
    /// 이 iPad 칸 ("iPad로 받기" 의 받을 곳)
    var local: MobileLocalFiles?
    /// 좁을 때 위 줄 왼쪽의 [iPad | 서버] 전환 (파인더가 넣어 준다)
    var showServer: Binding<Bool>? = nil
    @State private var importing = false
    @State private var preview: URL?
    @State private var sharing: URL?
    @State private var naming: NameRequest?
    @State private var deleting: SFTPClient.Entry?
    @State private var dropTarget = false
    /// 선택 모드 (여러 개 골라 받기·지우기)
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var deletingMany = false
    /// 선택 모드 내내 아래 막대 (inPlayer 처럼, 고른 게 없으면 흐리게)
    private var barShown: Bool { selecting }

    struct NameRequest: Identifiable {
        let id = UUID()
        let entry: SFTPClient.Entry?
        var text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                List(files.visible, selection: $selection) { e in
                    row(e)
                        .contentShape(Rectangle())
                        // 선택 중이면 줄을 눌러도 고르기
                        .onTapGesture {
                            if selecting { if selection.contains(e.id) { selection.remove(e.id) } else { selection.insert(e.id) } } else { tap(e) }
                        }
                        .contextMenu { menu(e) }
                        // 이 iPad 칸으로 끌어 놓으면 받는다 (서버 경로를 글자로 실어 보낸다)
                        .onDrag { NSItemProvider(object: (MobileLocalFiles.remotePrefix + e.path) as NSString) }
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .environment(\.editMode, .constant(selecting ? .active : .inactive))
                .refreshable { await files.refresh() }
                // 아래 도구 막대에 마지막 줄이 가리지 않게
                .contentMargins(.bottom, barShown ? 90 : 0, for: .scrollContent)
                if let err = files.error {
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(3) } }
            .overlay(alignment: .bottom) { if barShown { actionBar } }
            .animation(.snappy(duration: 0.25), value: barShown)
            // 파일 앱에서 끌어 놓으면 지금 폴더로 올린다
            .onDrop(of: [.item], isTargeted: $dropTarget) { providers in drop(providers) }
        }
        .task(id: connected) { if connected { await files.appear() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await files.upload(urls) } }
        }
        .quickLookPreview($preview)
        .sheet(item: Binding(get: { sharing.map { ShareItem(url: $0) } }, set: { if $0 == nil { sharing = nil } })) { item in
            ShareSheet(url: item.url)
        }
        .alert(naming?.entry == nil ? "새 폴더" : "이름 바꾸기", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("이름", text: Binding(get: { naming?.text ?? "" }, set: { naming?.text = $0 }))
            Button(naming?.entry == nil ? "만들기" : "바꾸기") {
                guard let n = naming else { return }
                Task { if let e = n.entry { await files.rename(e, to: n.text) } else { await files.makeFolder(n.text) } }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("선택한 \(selection.count)개를 서버에서 지울까요?", isPresented: $deletingMany) {
            Button("삭제", role: .destructive) {
                let p = picked(); selection = []; selecting = false
                Task { for e in p { await files.delete(e) } }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("폴더면 안의 내용도 모두 지워지고, 되돌릴 수 없습니다.")
        }
        .alert("서버에서 지울까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("삭제", role: .destructive) { if let e = deleting { Task { await files.delete(e) } } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(deleting?.name ?? "") 을(를) 지웁니다. 폴더면 안의 내용도 모두 지워지고, 되돌릴 수 없습니다.")
        }
    }

    // MARK: 위 줄: 경로 메뉴 · 새로 고침 · 새 폴더 · 올리기

    // 제목 줄: ‹ 위 폴더 · 지금 경로(누르면 상위 폴더로) · 선택 · 올리기 · ⋯
    private var header: some View {
        PaneTitleBar(showServer: showServer, isServer: true,
                     title: files.path.isEmpty ? "서버" : (files.path == "/" ? "/" : (files.path as NSString).lastPathComponent),
                     subtitle: files.path.isEmpty ? "접속 중…" : files.path,
                     canGoUp: files.ancestors.count > 1,
                     goUp: { if files.ancestors.count > 1 { Task { await files.open(files.ancestors[1]) } } },
                     selecting: Binding(get: { selecting }, set: { selecting = $0; if !$0 { selection = [] } }),
                     loading: files.loading) {
            // 지금 폴더도 맨 위에 (맨 위 폴더에서도 메뉴가 열리게 — 비어 있으면 눌러도 아무 일 없어 씹힌 것처럼 보였다)
            ForEach(files.ancestors, id: \.self) { p in
                Button { Task { await files.open(p) } } label: {
                    Label(p == "/" ? "/" : (p as NSString).lastPathComponent, systemImage: p == files.path ? "folder.fill" : "folder")
                }
                .disabled(p == files.path)
            }
        } trailing: {
            if selecting {
                // 선택 중 위 줄엔 모두 선택만 (도구는 아래 막대)
                Button {
                    selection = selection.count == files.visible.count ? [] : Set(files.visible.map(\.id))
                } label: {
                    // 옆 아이콘 버튼과 같은 높이 (그림 20pt)
                    Text(selection.count == files.visible.count && !selection.isEmpty ? "선택 해제" : "모두 선택").frame(height: 20.5)
                }
                .buttonBorderShape(.capsule)
                .disabled(files.visible.isEmpty)
            } else {
                Menu {
                    Button("선택", systemImage: "checkmark.circle") { withAnimation { selecting = true } }
                    Divider()
                    Button("파일 앱에서 업로드…", systemImage: "square.and.arrow.up") { importing = true }
                        .disabled(files.path.isEmpty)
                    Divider()
                    Toggle("숨김 파일 보기", isOn: $files.showHidden)
                    Button("새 폴더", systemImage: "folder.badge.plus") { naming = NameRequest(entry: nil, text: "") }
                    Button("새로 고침", systemImage: "arrow.clockwise") { Task { await files.refresh() } }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
            }
        }
    }

    private func picked() -> [SFTPClient.Entry] { files.visible.filter { selection.contains($0.id) } }

    private func done() { selection = []; selecting = false }

    /// 고른 것들: iPad로 받기 · 이름 바꾸기(하나일 때) · 경로 복사 · 삭제
    private var actionBar: some View {
        PaneActionBar(deleteEnabled: !selection.isEmpty, onDelete: { deletingMany = true }) {
            if let local {
                PaneAction(title: "다운로드", systemImage: "square.and.arrow.down.on.square", enabled: !selection.isEmpty) {
                    let p = picked(); done()
                    Task { await files.download(p, into: local.dir); local.refresh() }
                }
            }
            PaneAction(title: "이름 바꾸기", systemImage: "pencil", enabled: selection.count == 1) {
                if let e = picked().first { done(); naming = NameRequest(entry: e, text: e.name) }
            }
            PaneAction(title: "경로 복사", systemImage: "doc.on.doc", enabled: !selection.isEmpty) {
                UIPasteboard.general.string = picked().map(\.path).joined(separator: "\n"); done()
            }
        }
    }

    private func row(_ e: SFTPClient.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.isDirectory ? "folder.fill" : Self.icon(e.name))
                .foregroundStyle(e.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 22)
            Text(e.name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(e.name.hasPrefix(".") ? .secondary : .primary)
            Spacer(minLength: 8)
            if !e.isDirectory, let size = e.attrs.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let d = e.attrs.modified {
                Text(Self.date.string(from: d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private func menu(_ e: SFTPClient.Entry) -> some View {
        // 길게 눌러 선택 모드로 (이 항목을 고른 채) — 사용자
        if !selecting {
            Button("선택", systemImage: "checkmark.circle") { withAnimation { selecting = true }; selection = [e.id] }
            Divider()
        }
        if let local {
            Button("다운로드", systemImage: "square.and.arrow.down.on.square") {
                Task { await files.download([e], into: local.dir); local.refresh() }
            }
        }
        if !e.isDirectory {
            Button("미리보기", systemImage: "eye") { Task { preview = await files.fetch(e) } }
            Button("파일에 저장 · 공유", systemImage: "square.and.arrow.down") { Task { sharing = await files.fetch(e) } }
        }
        Button("이름 바꾸기", systemImage: "pencil") { naming = NameRequest(entry: e, text: e.name) }
        Button("경로 복사", systemImage: "doc.on.doc") { UIPasteboard.general.string = e.path }
        Divider()
        Button("삭제", systemImage: "trash", role: .destructive) { deleting = e }
    }

    /// 폴더는 들어가고, 파일은 받아서 미리보기 (거기서 저장·공유)
    private func tap(_ e: SFTPClient.Entry) {
        if e.isDirectory { Task { await files.open(e.path) } } else { Task { preview = await files.fetch(e) } }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ivnc-drop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for p in providers {
            group.enter()
            // 끌어 온 파일은 잠깐만 읽을 수 있어서 임시 폴더로 복사해 둔다
            _ = p.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { u, _ in
                if let u {
                    let dst = dir.appendingPathComponent(u.lastPathComponent)
                    try? FileManager.default.copyItem(at: u, to: dst)
                    DispatchQueue.main.async { urls.append(dst) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { Task { await files.upload(urls) } }
        return true
    }

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func icon(_ name: String) -> String {
        guard let t = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if t.conforms(to: .image) { return "photo" }
        if t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) { return "film" }
        if t.conforms(to: .archive) { return "doc.zipper" }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) || t.conforms(to: .shellScript) { return "chevron.left.forwardslash.chevron.right" }
        if t.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

struct ShareItem: Identifiable { let url: URL; var id: URL { url } }
struct ShareItems: Identifiable { let id = UUID(); let urls: [URL] }

/// 공유 시트 ("파일에 저장" 포함)
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    init(url: URL) { urls = [url] }
    init(urls: [URL]) { self.urls = urls }
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
#endif
