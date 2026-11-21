#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuickLook

// 아이패드 파인더의 "이 iPad" 칸 (2026-11-21 사용자: 파인더 안에서 아이패드 파일 | 서버 파일, 넓으면 나란히·좁으면 전환).
// 앱 문서 폴더에서 시작한다 (파일 앱 "나의 iPad › iVNC" 에도 보임). "다른 폴더 열기…" 로 파일 앱의 다른 폴더(iCloud Drive 등)도.

/// 파인더 글자에 쓰는 기기 이름·그림 (아이폰에서는 "iPhone", 사용자)
enum Device {
    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    static var name: String { isPhone ? "iPhone" : "iPad" }
    static var symbol: String { isPhone ? "iphone" : "ipad" }
}

/// 이 iPad 쪽 파일 (작업 공간에 하나, 탭끼리 같이 쓴다)
@MainActor
final class MobileLocalFiles: ObservableObject {
    struct Entry: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: Int64?
        let modified: Date?
    }

    /// 서버 칸에서 끌어 온 항목 표시 (글자 "ivnc-remote:<경로>")
    static let remotePrefix = "ivnc-remote:"
    private static let bookmarkKey = "ios.files.localBookmark"

    /// 맨 위 폴더 (문서 폴더 또는 고른 폴더). 이 위로는 못 올라간다
    @Published private(set) var root: URL
    @Published private(set) var dir: URL
    @Published private(set) var entries: [Entry] = []
    @Published var error: String?
    @Published var showHidden = false
    private var scoped: URL?

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    init() {
        var start = Self.documents
        // 지난번에 고른 폴더 (보안 북마크)
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale), u.startAccessingSecurityScopedResource() {
                scoped = u
                start = u
            }
        }
        root = start
        dir = start
        refresh()
    }

    var visible: [Entry] {
        entries.filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    var isDocuments: Bool { root.standardizedFileURL == Self.documents.standardizedFileURL }

    func open(_ u: URL) {
        dir = u
        refresh()
    }

    func refresh() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
            entries = urls.map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return Entry(url: u, name: u.lastPathComponent,
                             isDirectory: (v?.isDirectory ?? false) && !(v?.isPackage ?? false),
                             size: v?.fileSize.map(Int64.init), modified: v?.contentModificationDate)
            }
            error = nil
        } catch {
            entries = []
            self.error = "폴더를 읽을 수 없습니다: \(error.localizedDescription)"
        }
    }

    /// 지금 폴더 → … → 맨 위 폴더
    var ancestors: [URL] {
        var out: [URL] = [dir]
        var u = dir
        while u.standardizedFileURL.path != root.standardizedFileURL.path, u.pathComponents.count > 1 {
            u = u.deletingLastPathComponent()
            out.append(u)
        }
        return out
    }

    func title(_ u: URL) -> String {
        if u.standardizedFileURL.path == root.standardizedFileURL.path { return isDocuments ? "나의 \(Device.name) › iVNC" : rootName }
        return u.lastPathComponent
    }

    /// 맨 위 폴더의 보이는 이름. SMB 처럼 파일 앱에서 연결한 폴더는 실제 경로가 마구잡이 글자
    /// (…/LiveFiles/com.apple.filesystems.smbclientd/AbC123…) 라서 파일 앱이 보여 주는 이름을 쓴다 (사용자 2026-11-21)
    var rootName: String {
        let v = try? root.resourceValues(forKeys: [.localizedNameKey, .isVolumeKey, .volumeLocalizedNameKey])
        if v?.isVolume == true, let n = v?.volumeLocalizedName, !n.isEmpty { return n }
        return v?.localizedName ?? root.lastPathComponent
    }

    /// 제목 줄 경로: 맨 위 이름 › 하위 › 폴더 (파일 앱처럼)
    var displayPath: String {
        let rootComps = root.standardizedFileURL.pathComponents
        let comps = dir.standardizedFileURL.pathComponents
        let rest = comps.count > rootComps.count ? Array(comps[rootComps.count...]) : []
        return ([title(root)] + rest).joined(separator: " › ")
    }

    /// 파일 앱에서 고른 폴더를 맨 위로 (다음에 앱을 열어도 기억)
    func useFolder(_ u: URL) {
        scoped?.stopAccessingSecurityScopedResource()
        guard u.startAccessingSecurityScopedResource() else { error = "그 폴더를 열 수 없습니다."; return }
        scoped = u
        if let data = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        root = u
        open(u)
    }

    func useDocuments() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        root = Self.documents
        open(Self.documents)
    }

    func makeFolder(_ name: String) {
        guard !name.isEmpty else { return }
        do { try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: false) }
        catch { self.error = "새 폴더 실패: \(error.localizedDescription)" }
        refresh()
    }

    func rename(_ e: Entry, to name: String) {
        guard !name.isEmpty, name != e.name else { return }
        do { try FileManager.default.moveItem(at: e.url, to: e.url.deletingLastPathComponent().appendingPathComponent(name)) }
        catch { self.error = "이름 바꾸기 실패: \(error.localizedDescription)" }
        refresh()
    }

    func delete(_ e: Entry) {
        do { try FileManager.default.removeItem(at: e.url) } catch { self.error = "지우기 실패: \(error.localizedDescription)" }
        refresh()
    }

    /// 다른 앱에서 끌어 온 파일을 지금 폴더로 복사
    func copyIn(_ urls: [URL]) {
        for u in urls {
            let dst = dir.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            do { try FileManager.default.copyItem(at: u, to: dst) } catch { self.error = "복사 실패: \(error.localizedDescription)" }
        }
        refresh()
    }
}

/// 파인더 칸 하나의 제목 줄 (사용자: 칸마다 제목 줄 — 왼쪽 ‹ 위 폴더, 가운데 지금 경로(누르면 상위 폴더로), 오른쪽 선택·올리기·⋯)
struct PaneTitleBar<Ancestors: View, Trailing: View>: View {
    /// 좁을 때 [이 iPhone | 서버] 전환 (제목 메뉴 아래쪽에, 사용자). nil 이면 두 칸이 나란히라 전환 없음
    var showServer: Binding<Bool>?
    /// 이 칸이 서버 칸인지 (제목 앞 아이콘·메뉴 체크)
    var isServer = false
    let title: String
    let subtitle: String
    let canGoUp: Bool
    let goUp: () -> Void
    @Binding var selecting: Bool
    var loading = false
    @ViewBuilder let ancestors: Ancestors
    @ViewBuilder let trailing: Trailing
    /// ‹ 유리 버튼의 실제 높이. [iPad|서버] 전환을 같은 높이로 (창 크기에 따라 시스템이 유리 버튼 높이를 바꾼다)
    @State private var buttonHeight: CGFloat = 34
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    var body: some View {
        ZStack {
            // 가운데: 전체 경로 한 줄, 길면 가운데를 … 로 (사용자). 누르면 상위 폴더 목록
            Menu {
                ancestors
                if let showServer {
                    Divider()
                    // 다른 쪽 파일로 (지금 보는 쪽에 체크)
                    Picker("보기", selection: showServer) {
                        Label("\(Device.name) 파일 보기", systemImage: Device.symbol).tag(false)
                        Label("서버 파일 보기", systemImage: "server.rack").tag(true)
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                HStack(spacing: 4) {
                    // 전환할 수 있을 때는 지금 어느 쪽인지 제목 앞 아이콘으로
                    if showServer != nil {
                        Image(systemName: isServer ? "server.rack" : Device.symbol)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(subtitle).font(.headline).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(maxWidth: 340, minHeight: 44)
                // 글자 사이·옆 빈 곳을 눌러도 메뉴가 열리게 (사용자: 경로 터치가 가끔 씹힘)
                .contentShape(Rectangle())
            }
            // 메뉴 글자가 강조색(파랑)으로 물들지 않게 — 제목은 보통 글자색
            .tint(.primary)
            // 제목은 양옆 버튼 묶음 사이 빈 곳의 가운데 (겹치지 않게, 좁은 아이폰에서도 그 사이를 다 쓴다)
            .padding(.leading, leadingWidth + 4)
            .padding(.trailing, trailingWidth + 4)
            HStack(spacing: 8) {
              HStack(spacing: 8) {
                Button(action: goUp) { Image(systemName: "chevron.backward").frame(width: 20, height: 20) }
                    .buttonBorderShape(.circle)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { buttonHeight = $0 }
                    .disabled(!canGoUp)
                    .accessibilityLabel("위 폴더")
                if loading { ProgressView().controlSize(.small) }
              }
              .onGeometryChange(for: CGFloat.self, of: \.size.width) { leadingWidth = $0 }
                Spacer()
              HStack(spacing: 8) {
                if selecting {
                    // 선택 중: [모두 선택] [완료] — 완료가 맨 오른쪽 파란 강조 버튼 (inPlayer·사진 앱처럼)
                    trailing
                    // 글자 버튼도 아이콘 버튼(그림 20pt)과 같은 높이로 — 알약은 원보다 위아래 여백이 1pt 작아 글자 칸을 20.5pt (재어 보니 글자만이면 1.5pt 낮았다) (사용자)
                    Button { withAnimation { selecting = false } } label: { Text("완료").frame(height: 20.5) }
                        .fontWeight(.semibold)
                        .buttonStyle(.glassProminent)
                        .tint(.accentColor)
                        .buttonBorderShape(.capsule)
                } else {
                    // 선택은 ⋯ 메뉴 안으로 (사용자: 좁아서)
                    trailing
                        .buttonBorderShape(.circle)
                }
              }
              .onGeometryChange(for: CGFloat.self, of: \.size.width) { trailingWidth = $0 }
            }
            // 앱 제목 줄의 시스템 버튼과 같은 유리 버튼, 흰 글자
            .buttonStyle(.glass)
            .tint(.primary)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar, ignoresSafeAreaEdges: [])
    }
}

/// 선택 모드의 칸 아래 도구 막대 (사용자 2026-11-21: inPlayer 처럼). 왼쪽 유리 캡슐에 동작들(아이콘 + 작은 글자),
/// 오른쪽 유리 동그라미에 삭제. 위 제목 줄엔 모두 선택·완료만 남아 공간이 넉넉해진다. inPlayer `BrowseView.swift` SelectionBar 와 같은 모양
struct PaneActionBar<Content: View>: View {
    let deleteEnabled: Bool
    let onDelete: () -> Void
    @ViewBuilder let content: Content
    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .center) {
                HStack(spacing: 0) { content }
                    .padding(6)
                    .glassEffect(.regular.interactive(), in: .capsule)
                Spacer(minLength: 8)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundStyle(deleteEnabled ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .frame(width: 62, height: 62)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(!deleteEnabled)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("삭제")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// 도구 막대의 동작 하나 (아이콘 위 · 글자 아래)
struct PaneAction: View {
    let title: String
    let systemImage: String
    var enabled = true
    let perform: () -> Void
    var body: some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.title3).frame(height: 24)
                Text(title).font(.caption2).lineLimit(1)
            }
            .frame(width: 76, height: 50)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
    }
}

/// 안전 영역을 받지 않는 호스팅. iPadOS 26 은 사이드바 너비만큼(320) 왼쪽 안전 영역을 상세 칸 안의 뷰에까지 주고,
/// List(UICollectionView) 는 그 밑까지 늘어나 길게 누른 미리보기가 사이드바 위에 뜬다 (사용자 2026-11-21).
/// SwiftUI 의 ignoresSafeArea·padding 으로는 안 없어져 UIHostingController.safeAreaRegions = [] 로 끊는다
struct NoSafeAreaHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let h = UIHostingController(rootView: content)
        h.safeAreaRegions = []
        h.view.backgroundColor = .clear
        return h
    }
    func updateUIViewController(_ h: UIHostingController<Content>, context: Context) { h.rootView = content }
}

/// 파인더: 이 iPad | 서버. 넓으면 나란히, 좁으면 [iPad | 서버] 로 바꿔 본다
struct MobileFinderView: View {
    @ObservedObject var files: MobileFileSession
    @ObservedObject var local: MobileLocalFiles
    let connected: Bool
    /// 좁을 때 서버를 보는지 (아니면 이 iPad)
    @State private var showServer = true
    static let twoPaneWidth: CGFloat = 700

    var body: some View {
        content
            .background(Color(uiColor: .systemBackground))
    }

    /// 폭은 onGeometryChange 로 잰다: GeometryReader 안에서 [iPad|서버] 를 바꾸면 버튼만 바뀌고 칸이 안 바뀌었다 (아이폰)
    @State private var width: CGFloat = 0

    private var content: some View {
        Group {
            if width >= Self.twoPaneWidth {
                HStack(spacing: 0) {
                    MobileLocalPaneView(local: local, files: files).frame(maxWidth: .infinity)
                    Divider()
                    MobileFileBrowserView(files: files, connected: connected, local: local).frame(maxWidth: .infinity)
                }
            } else if showServer {
                MobileFileBrowserView(files: files, connected: connected, local: local, showServer: $showServer)
            } else {
                MobileLocalPaneView(local: local, files: files, showServer: $showServer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}

/// 이 iPad 칸
struct MobileLocalPaneView: View {
    @ObservedObject var local: MobileLocalFiles
    let files: MobileFileSession
    var showServer: Binding<Bool>? = nil
    @State private var picking = false
    @State private var preview: URL?
    @State private var sharing: URL?
    @State private var newFolder = false
    @State private var nameInput = ""
    @State private var deleting: MobileLocalFiles.Entry?
    @State private var dropTarget = false
    @State private var selecting = false
    @State private var selection = Set<URL>()
    @State private var deletingMany = false
    @State private var renaming: MobileLocalFiles.Entry?
    @State private var sharingMany: [URL]?

    private var picked: [MobileLocalFiles.Entry] { local.visible.filter { selection.contains($0.url) } }
    /// 선택 모드 내내 아래 막대 (inPlayer 처럼, 고른 게 없으면 흐리게)
    private var barShown: Bool { selecting }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                List(local.visible, selection: $selection) { e in
                    row(e)
                        .contentShape(Rectangle())
                        // 선택 중이면 줄을 눌러도 고르기 (탭 제스처가 List 선택을 먹어서 동그라미만 눌렸다)
                        .onTapGesture {
                            if selecting { if selection.contains(e.url) { selection.remove(e.url) } else { selection.insert(e.url) } }
                            else if e.isDirectory { local.open(e.url) } else { preview = e.url }
                        }
                        .contextMenu { menu(e) }
                        // 서버 칸으로 끌어 놓으면 올린다
                        .onDrag { NSItemProvider(contentsOf: e.url) ?? NSItemProvider() }
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .environment(\.editMode, .constant(selecting ? .active : .inactive))
                .refreshable { local.refresh() }
                // 아래 도구 막대에 마지막 줄이 가리지 않게
                .contentMargins(.bottom, barShown ? 90 : 0, for: .scrollContent)
                if let err = local.error {
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if local.visible.isEmpty {
                    Text("비어 있습니다").foregroundStyle(.secondary)
                }
            }
            .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(3) } }
            .overlay(alignment: .bottom) { if barShown { actionBar } }
            .animation(.snappy(duration: 0.25), value: barShown)
            .onDrop(of: [.text, .item], isTargeted: $dropTarget) { providers in drop(providers) }
        }
        .sheet(item: Binding(get: { sharingMany.map { ShareItems(urls: $0) } }, set: { if $0 == nil { sharingMany = nil } })) { ShareSheet(urls: $0.urls) }
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $nameInput)
            Button("바꾸기") { if let e = renaming { local.rename(e, to: nameInput) } }
            Button("취소", role: .cancel) {}
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { local.useFolder(u) }
        }
        .quickLookPreview($preview)
        .sheet(item: Binding(get: { sharing.map { ShareItem(url: $0) } }, set: { if $0 == nil { sharing = nil } })) { ShareSheet(url: $0.url) }
        .alert("새 폴더", isPresented: $newFolder) {
            TextField("이름", text: $nameInput)
            Button("만들기") { local.makeFolder(nameInput) }
            Button("취소", role: .cancel) {}
        }
        .alert("선택한 \(selection.count)개를 이 \(Device.name) 에서 지울까요?", isPresented: $deletingMany) {
            Button("삭제", role: .destructive) {
                for u in selection { try? FileManager.default.removeItem(at: u) }
                selection = []; selecting = false; local.refresh()
            }
            Button("취소", role: .cancel) {}
        } message: { Text("되돌릴 수 없습니다.") }
        .alert("이 \(Device.name) 에서 지울까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("삭제", role: .destructive) { if let e = deleting { local.delete(e) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(deleting?.name ?? "") 을(를) 지웁니다. 되돌릴 수 없습니다.")
        }
    }

    // 제목 줄: ‹ 위 폴더 · 지금 경로(누르면 상위 폴더로) · 선택 · ⋯
    private var header: some View {
        PaneTitleBar(showServer: showServer, isServer: false,
                     title: local.title(local.dir),
                     subtitle: local.displayPath,
                     canGoUp: local.ancestors.count > 1,
                     goUp: { if local.ancestors.count > 1 { local.open(local.ancestors[1]) } },
                     selecting: Binding(get: { selecting }, set: { selecting = $0; if !$0 { selection = [] } })) {
            // 지금 폴더도 맨 위에 (맨 위 폴더에서도 메뉴가 열리게)
            ForEach(local.ancestors, id: \.self) { u in
                Button { local.open(u) } label: { Label(local.title(u), systemImage: u == local.dir ? "folder.fill" : "folder") }
                    .disabled(u == local.dir)
            }
        } trailing: {
            if selecting {
                // 선택 중 위 줄엔 모두 선택만 (도구는 아래 막대)
                Button {
                    selection = selection.count == local.visible.count ? [] : Set(local.visible.map(\.url))
                } label: {
                    Text(selection.count == local.visible.count && !selection.isEmpty ? "선택 해제" : "모두 선택").frame(height: 20.5)
                }
                .buttonBorderShape(.capsule)
                .disabled(local.visible.isEmpty)
            } else {
                Menu {
                    Button("선택", systemImage: "checkmark.circle") { withAnimation { selecting = true } }
                    Divider()
                    Toggle("숨김 파일 보기", isOn: $local.showHidden)
                    Button("새 폴더", systemImage: "folder.badge.plus") { nameInput = ""; newFolder = true }
                    Button("새로 고침", systemImage: "arrow.clockwise") { local.refresh() }
                    Divider()
                    Button("다른 폴더 열기…", systemImage: "folder") { picking = true }
                    if !local.isDocuments { Button("나의 \(Device.name) › iVNC 로", systemImage: Device.symbol) { local.useDocuments() } }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
            }
        }
    }

    /// 고른 것들: 서버로 올리기 · 공유 · 이름 바꾸기(하나일 때) · 삭제
    private var actionBar: some View {
        PaneActionBar(deleteEnabled: !selection.isEmpty, onDelete: { deletingMany = true }) {
            PaneAction(title: "업로드", systemImage: "square.and.arrow.up.on.square", enabled: !selection.isEmpty && !files.path.isEmpty) {
                let urls = picked.map(\.url); done()
                Task { await files.upload(urls) }
            }
            PaneAction(title: "공유", systemImage: "square.and.arrow.up", enabled: !selection.isEmpty && !picked.contains(where: \.isDirectory)) {
                let urls = picked.map(\.url); done(); sharingMany = urls
            }
            PaneAction(title: "이름 바꾸기", systemImage: "pencil", enabled: picked.count == 1) {
                if let e = picked.first { nameInput = e.name; renaming = e; done() }
            }
        }
    }

    private func done() { selection = []; selecting = false }

    private func row(_ e: MobileLocalFiles.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(e.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 22)
            Text(e.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if !e.isDirectory, let size = e.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func menu(_ e: MobileLocalFiles.Entry) -> some View {
        // 길게 눌러 선택 모드로 (이 항목을 고른 채) — 사용자
        if !selecting {
            Button("선택", systemImage: "checkmark.circle") { withAnimation { selecting = true }; selection = [e.url] }
            Divider()
        }
        Button("업로드", systemImage: "square.and.arrow.up.on.square") {
            Task { await files.upload([e.url]) }
        }
        .disabled(files.path.isEmpty)
        if !e.isDirectory {
            Button("미리보기", systemImage: "eye") { preview = e.url }
            Button("공유", systemImage: "square.and.arrow.up") { sharing = e.url }
        }
        Divider()
        Button("삭제", systemImage: "trash", role: .destructive) { deleting = e }
    }

    /// 서버 칸에서 끌어 온 것 → 받기, 다른 앱에서 끌어 온 파일 → 복사
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    guard let s = s as? String, s.hasPrefix(MobileLocalFiles.remotePrefix) else { return }
                    let path = String(s.dropFirst(MobileLocalFiles.remotePrefix.count))
                    DispatchQueue.main.async {
                        guard let e = files.entry(path) else { return }
                        let dir = local.dir
                        Task { await files.download([e], into: dir); local.refresh() }
                    }
                }
            } else {
                _ = p.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { u, _ in
                    guard let u else { return }
                    // 끌어 온 파일은 잠깐만 읽을 수 있어 이름 그대로 임시 폴더에 먼저 복사
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let tmp = dir.appendingPathComponent(u.lastPathComponent)
                    try? FileManager.default.copyItem(at: u, to: tmp)
                    DispatchQueue.main.async { local.copyIn([tmp]) }
                }
            }
        }
        return true
    }
}
#endif
