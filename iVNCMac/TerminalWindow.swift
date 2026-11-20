import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// 터미널 창 하나: 칸(분할) 1~2개, 칸마다 탭 줄. 탭은 끌어서 순서를 바꾸고 다른 칸으로도 옮긴다 (iSQL 탭과 같은 방식)
@MainActor
final class TerminalWindowModel: ObservableObject {
    struct Pane: Identifiable {
        let id = UUID()
        var tabs: [TerminalTab] = []
        var active: UUID?
    }

    @Published var panes: [Pane] = [Pane()]
    /// 초점이 있는 칸 (제목·서버 메뉴·⌘T 의 기준)
    @Published var focused = 0
    /// 마지막 탭이 닫히면 창을 닫는다
    var onEmpty: (() -> Void)?
    /// 서버의 경유 서버들 (창이 컴퓨터 목록으로 채운다)
    var jumpChain: ((Computer) -> [Computer])?
    /// 탭이 바뀌면(서버 지문 질문·상태·제목) 창도 다시 그린다. 안 그러면 지문 알림이 안 떠 "접속 중…" 에 멈춘다
    private var tabWatchers: [UUID: AnyCancellable] = [:]

    var activeTab: TerminalTab? {
        guard panes.indices.contains(focused) else { return nil }
        let p = panes[focused]
        return p.tabs.first { $0.id == p.active } ?? p.tabs.first
    }

    var allTabs: [TerminalTab] { panes.flatMap(\.tabs) }

    /// 서버의 새 터미널을 탭으로 연다 (지금 탭 오른쪽)
    /// 같은 서버 새 터미널을 그 탭의 지금 폴더에서 (⌘T·복제). root 셸이면 sudo -s 로
    func openLike(_ tab: TerminalTab, pane: Int? = nil) {
        let target = pane ?? paneIndex(of: tab) ?? focused
        let osc7 = tab.directory.flatMap { URL(string: $0)?.path }.flatMap { $0.isEmpty ? nil : $0 }
        guard let shell = tab.sshShell else { open(tab.computer, pane: target); return }
        Task {
            let st = await shell.currentState()
            open(tab.computer, pane: target, directory: osc7 ?? st.directory, asRoot: st.root)
        }
    }

    func open(_ c: Computer, pane: Int? = nil, directory: String? = nil, asRoot: Bool = false) {
        let i = pane ?? focused
        guard panes.indices.contains(i) else { return }
        let tab = TerminalTab(computer: c, directory: directory, asRoot: asRoot)
        tab.jumps = jumpChain?(c) ?? []
        tab.onRequestClose = { [weak self] t in self?.close(t) }
        tabWatchers[tab.id] = tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        let at = panes[i].tabs.firstIndex { $0.id == panes[i].active }.map { $0 + 1 } ?? panes[i].tabs.count
        panes[i].tabs.insert(tab, at: at)
        panes[i].active = tab.id
        focused = i
        tab.connect()
        focus(tab)
    }

    func select(_ tab: TerminalTab) {
        guard let i = paneIndex(of: tab) else { return }
        panes[i].active = tab.id
        focused = i
        focus(tab)
    }

    func close(_ tab: TerminalTab) {
        guard let i = paneIndex(of: tab), let j = panes[i].tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.disconnect()
        tabWatchers[tab.id] = nil
        panes[i].tabs.remove(at: j)
        if panes[i].active == tab.id {
            panes[i].active = panes[i].tabs.indices.contains(j) ? panes[i].tabs[j].id : panes[i].tabs.last?.id
        }
        // 빈 칸은 없앤다 (분할 풀기)
        if panes[i].tabs.isEmpty && panes.count > 1 {
            panes.remove(at: i)
            focused = 0
        }
        if allTabs.isEmpty { onEmpty?() } else if let t = activeTab { focus(t) }
    }

    func closeAll() {
        for t in allTabs { t.disconnect() }
    }

    /// 탭 옮기기: 같은 칸 안 순서 바꾸기, 또는 다른 칸으로 (before 앞에, 없으면 끝에)
    func move(_ tabID: UUID, toPane target: Int, before: UUID?) {
        guard tabID != before, panes.indices.contains(target),
              let from = panes.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let j = panes[from].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = panes[from].tabs.remove(at: j)
        if panes[from].active == tabID { panes[from].active = panes[from].tabs.first?.id }
        let at = before.flatMap { b in panes[target].tabs.firstIndex { $0.id == b } } ?? panes[target].tabs.count
        panes[target].tabs.insert(tab, at: at)
        panes[target].active = tab.id
        focused = target
        if panes[from].tabs.isEmpty && panes.count > 1 {
            panes.remove(at: from)
            focused = panes.firstIndex { $0.tabs.contains { $0.id == tabID } } ?? 0
        }
        focus(tab)
    }

    /// 분할은 탭 우클릭으로만 (iSQL 처럼): 다른 칸으로 옮기기. 칸이 하나면 오른쪽 칸을 만든다
    func moveToSplit(_ tab: TerminalTab) {
        guard let from = paneIndex(of: tab) else { return }
        if panes.count == 1 {
            guard panes[0].tabs.count > 1 else { return } // 하나뿐인 탭을 옮기면 왼쪽이 비어 분할이 안 된다
            panes.append(Pane())
        }
        move(tab.id, toPane: from == 0 ? 1 : 0, before: nil)
    }

    /// 같은 서버 새 터미널을 다른 칸에 연다. 칸이 하나면 오른쪽 칸을 만든다
    func duplicateToSplit(_ tab: TerminalTab) {
        guard let from = paneIndex(of: tab) else { return }
        if panes.count == 1 { panes.append(Pane()) }
        openLike(tab, pane: from == 0 ? 1 : 0)
    }

    func paneIndex(id: UUID) -> Int? { panes.firstIndex { $0.id == id } }

    func paneIndex(of tab: TerminalTab) -> Int? { panes.firstIndex { $0.tabs.contains { $0.id == tab.id } } }

    /// 같은 서버 탭이 여럿이면 탭 이름 뒤에 (2), (3)
    func number(of tab: TerminalTab) -> Int? {
        let same = allTabs.filter { $0.computer.id == tab.computer.id }
        guard same.count > 1, let i = same.firstIndex(where: { $0.id == tab.id }) else { return nil }
        return i + 1
    }

    private func focus(_ tab: TerminalTab) {
        DispatchQueue.main.async { tab.view.window?.makeFirstResponder(tab.view) }
    }
}

/// 터미널 창
struct TerminalWindowView: View {
    let request: TerminalWindowRequest
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var model = TerminalWindowModel()

    var body: some View {
        HStack(spacing: 0) {
            // 칸은 번호가 아니라 id 로 (칸이 사라질 때 없는 번호를 읽어 앱이 죽었다)
            ForEach(model.panes) { pane in
                if pane.id != model.panes.first?.id { Divider() }
                TerminalPaneView(model: model, paneID: pane.id)
            }
        }
        .frame(minWidth: 480, minHeight: 260)
        .navigationTitle(model.activeTab?.displayTitle ?? "SSH")
        .toolbar {
            // 서버 메뉴: 둥근 유리 배경 없이 (iSQL 툴바 규칙)
            ToolbarItem(placement: .navigation) {
                ServerMenu(model: model, servers: store.computers.filter { $0.type == .ssh })
            }
            .sharedBackgroundVisibility(.hidden)
            // 오른쪽 끝에 붙인다
            ToolbarSpacer(.flexible)
            // [터미널 | 파인더] (iSQL 의 데이터/구조처럼)
            ToolbarItem(placement: .primaryAction) {
                Picker("보기", selection: Binding(get: { model.activeTab?.mode ?? .terminal },
                                                 set: { model.activeTab?.setMode($0) })) {
                    Label("터미널", systemImage: "apple.terminal").tag(TerminalTab.Mode.terminal).help("터미널 (⌘1)")
                    Label("파인더", systemImage: "folder").tag(TerminalTab.Mode.files).help("파인더 · 파일 주고받기 (⌘2)")
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .disabled(model.activeTab == nil)
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup(placement: .primaryAction) {
                Button("새 탭", systemImage: "plus") {
                    if let t = model.activeTab { model.openLike(t) }
                }
                .keyboardShortcut("t")
                .help("같은 서버 새 탭 (⌘T)")
            }
        }
        // ⌘W = 지금 탭 닫기 (마지막 탭이면 창도 닫힌다). 도구 막대에 숨겨 두면 빈 칸이 생겨 버튼이 오른쪽 끝에 안 붙었다
        .background {
            Group {
                Button("탭 닫기") { if let t = model.activeTab { model.close(t) } }.keyboardShortcut("w")
                Button("터미널") { model.activeTab?.setMode(.terminal) }.keyboardShortcut("1")
                Button("파인더") { model.activeTab?.setMode(.files) }.keyboardShortcut("2")
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .alert(hostKeyTitle, isPresented: Binding(get: { questionTab != nil }, set: { if !$0 { questionTab?.answerHostKey(false) } })) {
            Button("접속") { questionTab?.answerHostKey(true) }
            Button("취소", role: .cancel) { questionTab?.answerHostKey(false) }
        } message: {
            if let q = questionTab?.hostKeyQuestion {
                Text(q.changed
                     ? "\(q.host) 의 서버 지문이 지난번과 다릅니다. 서버를 다시 설치했다면 괜찮지만, 아니라면 다른 컴퓨터가 중간에 끼어든 것일 수 있습니다.\n\n\(q.keyType)\n\(q.fingerprint)"
                     : "\(q.host) 에 처음 접속합니다. 서버 지문이 맞는지 확인하세요.\n\n\(q.keyType)\n\(q.fingerprint)")
            }
        }
        .onAppear {
            model.onEmpty = { dismissWindow() }
            model.jumpChain = { [store] c in store.jumpChain(for: c) }
            if model.allTabs.isEmpty, let c = store.computers.first(where: { $0.id == request.computer }) { model.open(c) }
        }
        .onDisappear { model.closeAll() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // 설정 > SSH 를 바꾸면 열린 터미널에 바로
            for t in model.allTabs { t.applySettings() }
        }
    }

    private var questionTab: TerminalTab? { model.allTabs.first { $0.hostKeyQuestion != nil } }
    private var hostKeyTitle: String { questionTab?.hostKeyQuestion?.changed == true ? "서버 지문이 바뀌었습니다" : "처음 접속하는 서버입니다" }
}

/// 칸 하나: 탭 줄 + 터미널 화면
private struct TerminalPaneView: View {
    @ObservedObject var model: TerminalWindowModel
    let paneID: UUID

    var body: some View {
        if let index = model.paneIndex(id: paneID) { content(model.panes[index], index: index) }
    }

    private func content(_ pane: TerminalWindowModel.Pane, index: Int) -> some View {
        VStack(spacing: 0) {
            TabStripView(model: model, pane: pane, index: index)
            Divider()
            ZStack {
                PaneHost(tabs: pane.tabs, active: pane.active)
                if let t = pane.tabs.first(where: { $0.id == pane.active }) {
                    if t.mode == .files {
                        FileBrowserView(session: t.files, serverName: t.computer.name).id(t.id)
                    } else {
                        StatusOverlay(tab: t)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { model.focused = index })
        }
    }
}

/// 접속 중·끊김 표시 (화면 가운데)
private struct StatusOverlay: View {
    @ObservedObject var tab: TerminalTab
    var body: some View {
        switch tab.state {
        case .connecting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("접속 중…") }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect()
        case .closed:
            VStack {
                Spacer()
                Button("다시 접속", systemImage: "arrow.clockwise") { tab.connect() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 16)
            }
        case .connected:
            EmptyView()
        }
    }
}

/// 탭들의 SwiftTerm 화면을 AppKit 에서 살려 두고 지금 탭만 보인다 (탭을 바꿔도 화면·스크롤백을 새로 만들지 않게)
private struct PaneHost: NSViewRepresentable {
    let tabs: [TerminalTab]
    let active: UUID?

    /// 터미널 둘레에 여백 (창 모서리가 둥글어 맨 가장자리 글자가 잘렸다). 여백은 터미널 배경색으로 칠한다
    final class Box: NSView {
        static let inset = NSSize(width: 8, height: 6)
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            let r = bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height)
            for v in subviews { v.frame = r.width > 0 && r.height > 0 ? r : bounds }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let b = Box()
        b.wantsLayer = true
        return b
    }

    func updateNSView(_ box: NSView, context: Context) {
        let views = tabs.map(\.view)
        for v in box.subviews where !views.contains(where: { $0 === v }) { v.removeFromSuperview() }
        for t in tabs {
            if t.view.superview !== box {
                t.view.removeFromSuperview()
                t.view.autoresizingMask = []
                box.addSubview(t.view)
                box.needsLayout = true
            }
            // 파인더를 보는 동안은 터미널을 숨긴다 (키 입력이 터미널로 가지 않게)
            t.view.isHidden = t.id != active || t.mode == .files
        }
        if let t = tabs.first(where: { $0.id == active }) {
            box.layer?.backgroundColor = t.view.nativeBackgroundColor.withAlphaComponent(t.view.backgroundOpacity).cgColor
        }
        if let t = tabs.first(where: { $0.id == active }), t.mode == .terminal {
            DispatchQueue.main.async { if t.view.window?.firstResponder !== t.view { t.view.window?.makeFirstResponder(t.view) } }
        }
    }
}

/// 탭 줄 (가로로 넘치면 스크롤). 끌어서 순서 바꾸기·다른 칸으로 옮기기
private struct TabStripView: View {
    @ObservedObject var model: TerminalWindowModel
    let pane: TerminalWindowModel.Pane
    let index: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(pane.tabs) { t in
                    TabItemView(tab: t, number: model.number(of: t), active: t.id == pane.active,
                                focused: model.focused == index, model: model)
                        .onDrag { NSItemProvider(object: t.id.uuidString as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { items in drop(items, before: t.id) }
                    Divider().frame(height: 16)
                }
                // 빈 곳에 놓으면 끝으로
                Color.clear.frame(width: 40, height: 30)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], isTargeted: nil) { items in drop(items, before: nil) }
            }
        }
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
    }

    private func drop(_ items: [NSItemProvider], before: UUID?) -> Bool {
        guard let p = items.first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { s, _ in
            guard let s = s as? String, let id = UUID(uuidString: s) else { return }
            DispatchQueue.main.async {
                guard let i = model.paneIndex(id: pane.id) else { return }
                model.move(id, toPane: i, before: before)
            }
        }
        return true
    }
}

private struct TabItemView: View {
    @ObservedObject var tab: TerminalTab
    let number: Int?
    let active: Bool
    let focused: Bool
    @ObservedObject var model: TerminalWindowModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            // 탭에는 아이콘 대신 서버 색 점만 (사용자)
            Circle().fill(tab.computer.sshColor?.color ?? Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(tab.computer.name + (number.map { " (\($0))" } ?? ""))
                .lineLimit(1)
                .fontWeight(active && focused ? .semibold : .regular)
                .foregroundStyle(tab.state == .connected ? .primary : .secondary)
            // 이름은 왼쪽, 닫기는 오른쪽 끝 (가운데 정렬 대신)
            Spacer(minLength: 8)
            Button { model.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hover || active ? 1 : 0)
                .help("탭 닫기 (⌘W)")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .frame(minWidth: 110, maxWidth: 220)
        // 색 배경은 기본으로 안전 영역(제목바)까지 칠한다 → 막는다 (iSQL 탭바와 같은 문제)
        .background(active ? Color.primary.opacity(0.08) : Color.clear, ignoresSafeAreaEdges: [])
        .overlay(alignment: .top) {
            if active && focused { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        .onHover { hover = $0 }
        .help(tab.displayTitle)
        .contextMenu {
            Button("같은 서버 새 탭") { model.select(tab); model.openLike(tab) }
            let side = model.panes.count > 1 && model.paneIndex(of: tab) == 1 ? "왼쪽" : "오른쪽"
            Button("\(side) 분할로 이동") { model.moveToSplit(tab) }
                .disabled(model.panes.count == 1 && (model.panes.first?.tabs.count ?? 0) < 2)
            Button("\(side) 분할로 복제") { model.duplicateToSplit(tab) }
            Divider()
            Button("다시 접속") { tab.disconnect(); tab.connect() }
            Button("탭 닫기") { model.close(tab) }
        }
    }
}

/// 제목바 왼쪽 서버 목록: 고른 서버의 새 터미널을 늘 새 탭으로
private struct ServerMenu: View {
    @ObservedObject var model: TerminalWindowModel
    let servers: [Computer]

    var body: some View {
        let current = model.activeTab?.computer
        Menu {
            Section("새 탭으로 열기") {
                ForEach(servers) { c in
                    Button { model.open(c) } label: {
                        Label { Text(c.name + (c.id == current?.id ? "  ✓" : "")) } icon: { Image(nsImage: dot(c.sshColor)) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                ServerIcon(color: current?.sshColor ?? .none, size: 18)
                Text(current?.name ?? "SSH").fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("서버를 고르면 새 탭으로 엽니다")
    }

    /// 메뉴에 그대로 보이는 서버 아이콘 (SwiftUI 메뉴는 그림을 단색 템플릿으로 바꾸므로 색이 남는 NSImage 로)
    private func dot(_ c: ServerColor?) -> NSImage {
        let r = ImageRenderer(content: ServerIcon(color: c ?? .none, size: 16))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = false
        return img
    }
}
