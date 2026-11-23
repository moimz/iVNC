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
    /// 마지막으로 쓴 때 (MCP 가 활성 탭을 고를 때)
    private(set) var lastUsed = Date()

    init() { TerminalRegistry.shared.add(self) }
    /// 이 모델의 창 (탭을 다른 창으로 옮길 때 마우스 밑 창 찾기)
    weak var window: NSWindow?
    /// 칸마다 창 안 자리 (SwiftUI .global = 창 안, 위가 0). 떼어 낸 탭을 놓을 칸 찾기
    var paneFrames: [UUID: CGRect] = [:]
    /// 떼어 낸 탭이 지금 놓일 칸 (강조 테두리)
    @Published var dropHighlight: Int?

    /// 탭을 이 창에서 빼낸다 (접속은 끊지 않는다). 칸이 비면 분할을 풀고, 창이 비면 닫는다
    func detach(_ tab: TerminalTab) {
        guard let i = paneIndex(of: tab), let j = panes[i].tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabWatchers[tab.id] = nil
        panes[i].tabs.remove(at: j)
        if panes[i].active == tab.id {
            panes[i].active = panes[i].tabs.indices.contains(j) ? panes[i].tabs[j].id : panes[i].tabs.last?.id
        }
        if panes[i].tabs.isEmpty && panes.count > 1 { panes.remove(at: i); focused = 0 }
        if allTabs.isEmpty { onEmpty?() } else if let t = activeTab { focus(t) }
    }

    /// 다른 창에서 온 탭을 받는다 (접속·화면은 그대로)
    func adopt(_ tab: TerminalTab, pane: Int? = nil) {
        let i = min(pane ?? focused, panes.count - 1)
        tab.jumps = jumpChain?(tab.computer) ?? tab.jumps
        tab.onRequestClose = { [weak self] t in self?.close(t) }
        tabWatchers[tab.id] = tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        panes[i].tabs.append(tab)
        panes[i].active = tab.id
        focused = i
        lastUsed = Date()
        focus(tab)
    }

    /// 화면 좌표 점이 이 창의 몇 번째 칸 위인지 (창 밖이면 nil)
    func pane(atScreen p: NSPoint) -> Int? {
        guard let w = window, w.frame.contains(p), let content = w.contentView else { return nil }
        let inWindow = content.convert(w.convertPoint(fromScreen: p), from: nil)
        let y = content.isFlipped ? inWindow.y : content.bounds.height - inWindow.y
        let pt = CGPoint(x: inWindow.x, y: y)
        if let hit = panes.firstIndex(where: { paneFrames[$0.id]?.contains(pt) ?? false }) { return hit }
        return focused
    }
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
        lastUsed = Date()
        tab.connect()
        focus(tab)
    }

    func select(_ tab: TerminalTab) {
        lastUsed = Date()
        guard let i = paneIndex(of: tab) else { return }
        panes[i].active = tab.id
        focused = i
        focus(tab)
    }

    func close(_ tab: TerminalTab) {
        guard let i = paneIndex(of: tab), let j = panes[i].tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        ClosedTabs.shared.remember(tab, in: self)
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
        // 창을 닫을 때도 그 탭들을 기억한다 (⌘⇧T 로 하나씩 다시 열기)
        for t in allTabs { ClosedTabs.shared.remember(t, in: self); t.disconnect() }
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

    /// 서버의 새 터미널을 다른 칸에 (사이드바 "분할로 열기"). 칸이 하나면 오른쪽 칸을 만든다
    func openInSplit(_ c: Computer) {
        if panes.count == 1 { panes.append(Pane()) }
        open(c, pane: focused == 0 ? 1 : 0)
    }

    /// 이 창에서 그 서버의 탭 (초점 칸의 활성 탭 → 초점 칸 → 아무 칸 순)
    func tab(for c: Computer) -> TerminalTab? {
        if let t = activeTab, t.computer.id == c.id { return t }
        if panes.indices.contains(focused), let t = panes[focused].tabs.first(where: { $0.computer.id == c.id }) { return t }
        return allTabs.first { $0.computer.id == c.id }
    }

    /// ⌘[ · ⌘]: 초점 칸에서 이전·다음 탭 (끝에서 돌아간다)
    func selectNeighbor(_ delta: Int) {
        guard panes.indices.contains(focused) else { return }
        let tabs = panes[focused].tabs
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == panes[focused].active }) else { return }
        select(tabs[(i + delta + tabs.count) % tabs.count])
    }

    func paneIndex(id: UUID) -> Int? { panes.firstIndex { $0.id == id } }

    func paneIndex(of tab: TerminalTab) -> Int? { panes.firstIndex { $0.tabs.contains { $0.id == tab.id } } }

    /// 같은 서버 탭이 여럿이면 탭 이름 뒤에 (2), (3)
    private func focus(_ tab: TerminalTab) {
        DispatchQueue.main.async { tab.view.window?.makeFirstResponder(tab.view) }
    }
}

/// 터미널 창
struct TerminalWindowView: View {
    let request: TerminalWindowRequest
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = TerminalWindowModel()
    /// 사이드바를 펼쳤는지 (창마다 기억, 새 창은 펼침)
    @SceneStorage("terminal.sidebar") private var sidebarShown = true

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { sidebarShown ? .all : .detailOnly },
                                                      set: { sidebarShown = $0 != .detailOnly })) {
            TerminalSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 220, max: 360)
        } detail: {
            HStack(spacing: 0) {
                // 칸은 번호가 아니라 id 로 (칸이 사라질 때 없는 번호를 읽어 앱이 죽었다)
                ForEach(model.panes) { pane in
                    if pane.id != model.panes.first?.id { Divider() }
                    TerminalPaneView(model: model, paneID: pane.id)
                }
            }
            .frame(minWidth: 480, minHeight: 260)
            // 본문은 숨기지 않는다: 위치를 기록해 보니 첫 배치 안에서 제자리를 잡았다 (2026-11-21, Ai.md 12번)
            // 오른쪽 버튼은 본문에 붙인다 (창 전체에 붙이면 사이드바가 있을 때 왼쪽으로 몰린다, iSQL 툴바 규칙)
            .toolbar {
                // 제목이자 서버 바꾸기 (iSQL ServerSwitcher 모양, 둥근 유리 배경 없이).
                // 창 전체 .toolbar 에 두면 창을 처음 열 때 사이드바 토글 밑에 깔렸다가 다시 그려질 때 옆으로 밀려 나왔다 (사용자 화면 기록) → 본문 쪽에
                ToolbarItem(placement: .navigation) {
                    ServerMenu(model: model, initial: store.computers.first { $0.id == request.computer })
                }
                .sharedBackgroundVisibility(.hidden)
                // 오른쪽 끝에 붙인다
                ToolbarSpacer(.flexible)
                // 받기·올리기 내역: 따로 떨어져 맨 앞 (아이패드와 같은 TransferHistoryButton·배지, 사용자)
                ToolbarItem(placement: .primaryAction) { TransferHistoryButton() }
                ToolbarSpacer(.fixed)
                // [터미널 | 파인더] (iSQL 의 데이터/구조처럼)
                ToolbarItem(placement: .primaryAction) {
                    Picker("보기", selection: Binding(get: { model.activeTab?.mode ?? .terminal },
                                                     set: { m in
                                                         guard let t = model.activeTab else { return }
                                                         if m == .files { Task { await t.requestFiles() } } else { t.setMode(m) }
                                                     })) {
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
                    .help("같은 서버 새 탭 (⌘T)")
                }
            }
        }
        .background(WindowGrabber { [weak model] w in model?.window = w })
        .navigationTitle(model.activeTab?.displayTitle ?? "SSH")
        .toolbar(removing: .title)
        // 단축키는 메뉴 막대에 (TerminalMenus.swift): 이 창이 앞에 있을 때 할 일을 넘긴다
        .focusedSceneValue(\.terminalCommands, commands)
        .alert("지금 셸에서는 파인더로 바꿀 수 없습니다", isPresented: Binding(get: { blockedTab != nil }, set: { if !$0 { blockedTab?.filesBlocked = nil } })) {
            Button("확인", role: .cancel) { blockedTab?.filesBlocked = nil }
        } message: {
            Text(blockedTab?.filesBlocked ?? "")
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
        // 접속 허용 IP 가 아닌 탭: 제목바 시트로 VPN 목록 (연결되면 그 탭을 다시 접속)
        .sheet(isPresented: Binding(get: { accessTab != nil }, set: { if !$0 { accessTab?.accessBlocked = nil } })) {
            if let t = accessTab, let r = t.accessBlocked {
                AccessSheet(server: t.computer.name, report: r,
                            retry: { t.accessBlocked = nil; t.connect() },
                            force: { t.accessBlocked = nil; t.skipAccessCheckOnce = true; t.connect() },
                            close: { t.accessBlocked = nil })
            }
        }
        .onAppear {
            model.onEmpty = { dismissWindow() }
            model.jumpChain = { [store] c in store.jumpChain(for: c) }
            if model.allTabs.isEmpty, let id = request.adopt, let tab = TabTransfer.pending.removeValue(forKey: id) {
                model.adopt(tab)
            } else if model.allTabs.isEmpty, let c = store.computers.first(where: { $0.id == request.computer }) {
                model.open(c, directory: request.directory, asRoot: request.asRoot)
            }
        }
        .onDisappear { model.closeAll() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // 설정 > SSH 를 바꾸면 열린 터미널에 바로
            for t in model.allTabs { t.applySettings() }
        }
    }

    private var commands: TerminalCommands {
        TerminalCommands(
            newTab: { if let t = model.activeTab { model.openLike(t) } },
            newWindow: { newWindow() },
            closeTab: { if let t = model.activeTab { model.close(t) } },
            showTerminal: { model.activeTab?.setMode(.terminal) },
            showFiles: { if let t = model.activeTab { Task { await t.requestFiles() } } },
            moveTab: { model.selectNeighbor($0) },
            reconnect: { if let t = model.activeTab { t.disconnect(); t.connect() } },
            hasTab: model.activeTab != nil,
            tabCount: model.panes.indices.contains(model.focused) ? model.panes[model.focused].tabs.count : 0)
    }

    /// ⌘N: 같은 서버를 새 창으로, 지금 폴더에서 (root 셸이면 sudo -s) — ⌘T 와 같은 규칙
    private func newWindow() {
        guard let t = model.activeTab else { return }
        let osc7 = t.directory.flatMap { URL(string: $0)?.path }.flatMap { $0.isEmpty ? nil : $0 }
        guard let shell = t.sshShell else {
            openWindow(id: "terminal", value: TerminalWindowRequest(computer: t.computer.id))
            return
        }
        Task {
            let st = await shell.currentState()
            openWindow(id: "terminal", value: TerminalWindowRequest(computer: t.computer.id, directory: osc7 ?? st.directory, asRoot: st.root))
        }
    }

    private var blockedTab: TerminalTab? { model.allTabs.first { $0.filesBlocked != nil } }

    private var questionTab: TerminalTab? { model.allTabs.first { $0.hostKeyQuestion != nil } }
    private var accessTab: TerminalTab? { model.allTabs.first { $0.accessBlocked != nil } }
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [weak model] r in
            model?.paneFrames[pane.id] = r
        }
        // 떼어 낸 탭이 여기 들어갈 것이라는 표시 (사용자)
        .overlay {
            if model.dropHighlight == index {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .padding(2)
                    .allowsHitTesting(false)
            }
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
    @State private var reorder = TabReorder<UUID>()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(pane.tabs) { t in
                    TabItemView(tab: t, active: t.id == pane.active,
                                focused: model.focused == index, model: model)
                        .reorderable(t.id, order: pane.tabs.map(\.id), state: $reorder) { id, before in
                            model.move(id, toPane: index, before: before)
                        } tearOff: { id in
                            tearOff(id)
                        } hover: { id in
                            TerminalRegistry.shared.highlightDrop(atScreen: id == nil ? nil : NSEvent.mouseLocation)
                        }
                }
            }
            .coordinateSpace(.named(TabReorderSpace.name))
            // 탭을 옮기면 탭 줄 안에서만 짧게 미끄러지게 (iSQL)
            .animation(.easeOut(duration: 0.18), value: pane.tabs.map(\.id))
        }
        // 끄는 탭이 탭 줄 밖으로 나가 그려질 수 있게
        .scrollClipDisabled()
        .frame(height: 36)
        // 제목바와 다른 색 (iSQL TabBar 와 같은 값). 안전 영역까지 번지지 않게
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
        .zIndex(1)
    }

    /// 탭 줄 밖에 놓았을 때: 마우스 밑이 다른 터미널 창이면 그 창으로, 같은 창 다른 칸이면 그 칸으로, 창이 없는 곳이면 새 창으로
    private func tearOff(_ id: UUID) {
        guard let tab = pane.tabs.first(where: { $0.id == id }) else { return }
        let p = NSEvent.mouseLocation
        if let (target, paneIndex) = TerminalRegistry.shared.target(atScreen: p) {
            if target === model {
                if paneIndex != index { model.move(id, toPane: paneIndex, before: nil) }
            } else {
                model.detach(tab)
                target.adopt(tab, pane: paneIndex)
                target.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        // 창이 없는 곳: 하나뿐인 탭이면 창을 그대로 두고, 아니면 새 창으로 떼어 낸다
        guard model.allTabs.count > 1 else { return }
        TabTransfer.pending[id] = tab
        model.detach(tab)
        openWindow(id: "terminal", value: TerminalWindowRequest(computer: tab.computer.id, adopt: id))
    }
}

/// 새 창으로 떼어 낸 탭을 그 창이 뜰 때까지 맡아 둔다
@MainActor
enum TabTransfer {
    static var pending: [UUID: TerminalTab] = [:]
}

private struct TabItemView: View {
    @ObservedObject var tab: TerminalTab
    let active: Bool
    let focused: Bool
    @ObservedObject var model: TerminalWindowModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            // 탭에는 아이콘 대신 서버 색 점만 (사용자)
            Circle().fill(tab.computer.sshColor?.color ?? Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            // 같은 서버 탭 번호는 달지 않는다: 지금 폴더·프로그램 이름으로 구분된다 (사용자)
            Text(tab.computer.name)
                .lineLimit(1)
                .fontWeight(active && focused ? .semibold : .regular)
                .foregroundStyle(tab.state == .connected ? .primary : .secondary)
                .layoutPriority(1)
            // 셸이면 지금 폴더, 아니면 앞에서 돌고 있는 프로그램(vim·mysql·top …)을 작게 (사용자). 길면 앞을 줄인다
            if let label = tab.frontLabel {
                let program = tab.foreground.map { !$0.isShell } ?? false
                Text(label).font(.caption).foregroundStyle(program ? Color.orange : Color.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            // 이름은 왼쪽, 닫기는 오른쪽 끝 (가운데 정렬 대신)
            Spacer(minLength: 8)
            Button { model.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hover || active ? 1 : 0)
                .help("탭 닫기 (⌘W)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 36)
        .frame(minWidth: 110, maxWidth: 280)
        // 고른 탭은 창 바탕색으로 떠 보이게 (iSQL TabItem). 색 배경이 제목바까지 번지지 않게
        .background(active ? Color(nsColor: .windowBackgroundColor) : (hover ? Color.primary.opacity(0.05) : .clear), ignoresSafeAreaEdges: [])
        .overlay(alignment: .top) {
            if active && focused { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1) }
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

/// 제목바의 서버 이름 (iSQL ServerSwitcher 와 같은 모양): 색 점 · 이름 · 계정@주소 · ⌄.
/// 누르면 이 창에 열린 서버(고르면 그 탭으로)와 탭 동작. 전체 서버 목록은 왼쪽 사이드바에.
/// SwiftUI Menu 는 라벨 모양을 마음대로 못 해서 글자 버튼 + AppKit 메뉴로
private struct ServerMenu: View {
    @ObservedObject var model: TerminalWindowModel
    @State private var hover = false
    /// 창을 연 서버: 탭이 열리기 전 첫 그림부터 같은 글자를 보여 준다.
    /// 처음에 "SSH" 로 짧게 자리를 잡았다가 탭이 열려 길어지면, 툴바가 자리를 다시 안 잡아
    /// 늘어난 부분이 사이드바 토글 밑으로 삐져나갔다가 나중에 밀려 나왔다 (사용자, 위치 기록으로 본문은 안 밀리는 것 확인)
    var initial: Computer?
    @State private var anchor = MenuAnchorBox()

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 7) {
                if let c = model.activeTab?.computer ?? initial {
                    let jumps = model.activeTab?.jumps ?? []
                    Circle().fill(c.sshColor?.color ?? .secondary).frame(width: 9, height: 9)
                    Text(c.name).font(.system(size: 15, weight: .semibold))
                    Text(Self.address(c)).font(.caption).foregroundStyle(.secondary)
                    if let t = model.activeTab, !jumps.isEmpty {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(.secondary)
                            .help(t.jumps.map(\.name).joined(separator: " → ") + " 경유")
                    }
                } else {
                    Text("SSH").font(.system(size: 15, weight: .semibold))
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .background(MenuAnchor(box: anchor))
            .padding(.leading, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
        .help("서버 변경")
    }

    static func address(_ c: Computer) -> String {
        let user = c.username.isEmpty ? "" : c.username + "@"
        let port = c.port == Computer.Kind.ssh.defaultPort ? "" : ":\(c.port)"
        return user + c.host + port
    }

    private func showMenu() {
        let menu = NSMenu()
        // 이 창에 열린 서버 (탭 순서, 같은 서버는 한 번). 줄은 iSQL 접속한 서버 메뉴처럼: 서버 아이콘 · 이름 · 계정@주소, 보고 있는 서버에 초록 점
        var seen = Set<UUID>()
        let open = model.allTabs.filter { seen.insert($0.computer.id).inserted }
        if !open.isEmpty {
            menu.addItem(.sectionHeader(title: "열린 서버"))
            for t in open {
                let c = t.computer
                let row = ServerMenuRow(computer: c, current: model.activeTab?.computer.id == c.id, connected: t.state == .connected)
                menu.addItem(MenuAction.item(c.name, view: row, minWidth: 300) { [model] in if let tab = model.tab(for: c) { model.select(tab) } })
            }
        }
        if let t = model.activeTab {
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("같은 서버 새 탭") { [model] in model.openLike(t) })
            menu.addItem(MenuAction.item("다시 접속") { t.disconnect(); t.connect() })
            menu.addItem(MenuAction.item("탭 닫기") { [model] in model.close(t) })
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "열린 서버 없음", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.popUp(below: anchor)
    }
}

/// 제목바 서버 메뉴의 한 줄 (iSQL ServerMenuRow)
private struct ServerMenuRow: View {
    let computer: Computer
    let current: Bool
    let connected: Bool

    var body: some View {
        HStack(spacing: 9) {
            ServerIcon(color: computer.sshColor ?? .none, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(computer.name).font(.system(size: 13))
                Text(ServerMenu.address(computer)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 16)
            if current && connected {
                Circle().fill(Color.green).frame(width: 8, height: 8).padding(.trailing, 4)
            } else if !connected {
                Text("끊김").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.2))).foregroundStyle(.secondary)
            }
        }
        // 왼쪽 끝을 "열린 서버" 머리글·아래 글자 항목과 맞춘다
        .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 4)
    }
}

/// 터미널 창 왼쪽 SSH 서버 목록 (iSQL 사이드바처럼). 한 번 = 이 창의 그 서버 탭으로, 두 번·엔터 = 새 탭
private struct TerminalSidebar: View {
    @ObservedObject var model: TerminalWindowModel
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var selection: UUID?
    @State private var editing: Computer?

    private var servers: [Computer] { store.computers.filter { $0.type == .ssh } }
    private var shown: [Computer] { servers.filter { $0.matches(query) } }

    var body: some View {
        List(selection: $selection) {
            Section("SSH 서버") {
                ForEach(shown) { c in
                    SidebarRow(computer: c, jump: c.sshJump.flatMap { id in store.computers.first { $0.id == id }?.name },
                               openCount: model.allTabs.filter { $0.computer.id == c.id }.count)
                        .tag(c.id)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "검색")
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(servers.isEmpty ? "SSH 서버가 없습니다" : "찾는 서버가 없습니다",
                                       systemImage: servers.isEmpty ? "server.rack" : "magnifyingglass")
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let c = server(ids.first) {
                Button("새 탭으로 열기", systemImage: "plus.square.on.square") { model.open(c) }
                Button("분할로 열기", systemImage: "rectangle.split.2x1") { model.openInSplit(c) }
                Button("새 창으로 열기", systemImage: "macwindow.badge.plus") {
                    openWindow(id: "terminal", value: TerminalWindowRequest(computer: c.id))
                }
                Divider()
                Button("편집…", systemImage: "pencil") { editing = c }
            }
        } primaryAction: { ids in
            if let c = server(ids.first) { model.open(c) }
        }
        // 한 번 누르면 이 창에 그 서버 탭이 있을 때 그리로
        .onChange(of: selection) { _, id in
            if let c = server(id), let t = model.tab(for: c), t.id != model.activeTab?.id { model.select(t) }
        }
        // 탭을 바꾸면 사이드바도 그 서버를 고른다
        .onChange(of: model.activeTab?.computer.id, initial: true) { _, id in
            if let id, selection != id { selection = id }
        }
        .sheet(item: $editing) { ComputerEditView(computer: $0).frame(minWidth: 460, minHeight: 520) }
    }

    private func server(_ id: UUID?) -> Computer? { id.flatMap { id in servers.first { $0.id == id } } }
}

private struct SidebarRow: View {
    let computer: Computer
    let jump: String?
    let openCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ServerIcon(color: computer.sshColor ?? .none, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(computer.name).lineLimit(1)
                Text(jump.map { "\($0) 경유 · \(address)" } ?? address)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if openCount > 0 {
                HStack(spacing: 3) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    if openCount > 1 { Text("\(openCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                }
                .help("이 창에 열린 탭 \(openCount)개")
            }
        }
        .padding(.vertical, 2)
    }

    private var address: String {
        let user = computer.username.isEmpty ? "" : computer.username + "@"
        let port = computer.port == Computer.Kind.ssh.defaultPort ? "" : ":\(computer.port)"
        return user + computer.host + port
    }
}

/// 최근 닫은 탭 (⌘⇧T 로 마지막 것부터 다시 연다, 사용자 2026-11-21).
/// 셸은 닫으면 서버에서 끝나서 되살릴 수 없다 → 같은 서버를 그 폴더에서 새로 연다 (root 셸이었으면 sudo -s, ⌘T 와 같은 규칙)
@MainActor
final class ClosedTabs: ObservableObject {
    static let shared = ClosedTabs()
    struct Entry {
        let computer: Computer
        let directory: String?
        let asRoot: Bool
        weak var window: TerminalWindowModel?
    }
    @Published private(set) var entries: [Entry] = []
    static let limit = 10

    func remember(_ tab: TerminalTab, in model: TerminalWindowModel) {
        let p = tab.restorePoint
        entries.append(Entry(computer: tab.computer, directory: p.directory, asRoot: p.asRoot, window: model))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// 마지막에 닫은 탭을 다시 연다. 그 창이 살아 있으면 그 창에, 아니면 새 창으로
    func reopen(openWindow: OpenWindowAction) {
        guard let e = entries.popLast() else { return }
        if let m = e.window, !m.allTabs.isEmpty, let w = m.window, w.isVisible {
            m.open(e.computer, directory: e.directory, asRoot: e.asRoot)
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "terminal", value: TerminalWindowRequest(computer: e.computer.id, directory: e.directory, asRoot: e.asRoot))
        }
    }
}
