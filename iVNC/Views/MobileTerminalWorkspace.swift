#if os(iOS)
import SwiftUI
import UIKit
import Combine
import SwiftTerm

// 아이패드 SSH 2단계: 맥 터미널 창처럼 [사이드바 SSH 서버 목록 | 탭 줄 + 터미널] (2026-11-21 사용자).
// 컴퓨터 목록으로 돌아가도 이 작업 공간(접속·탭)은 살아 있다 — 홈이 들고 있다가 다시 보여 준다.

/// 열린 터미널 탭들
@MainActor
final class MobileTerminalWorkspace: ObservableObject {
    @Published private(set) var tabs: [MobileTerminalSession] = []
    @Published var active: UUID?
    /// 파인더의 "이 iPad" 칸 (탭끼리 같이 쓴다)
    let local = MobileLocalFiles()
    private var watchers: [UUID: AnyCancellable] = [:]

    var activeTab: MobileTerminalSession? { tabs.first { $0.id == active } ?? tabs.first }

    /// 서버의 새 터미널 탭 (지금 탭 오른쪽)
    func open(_ c: Computer, jumps: [Computer]) {
        let t = MobileTerminalSession(computer: c, jumps: jumps)
        t.menu = UIMenu(children: [
            UIAction(title: "다시 접속", image: UIImage(systemName: "arrow.clockwise")) { [weak t] _ in t?.disconnect(); t?.connect() },
        ])
        // 탭 상태(제목·폴더·지문 질문)가 바뀌면 작업 공간도 다시 그린다
        watchers[t.id] = t.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        let at = tabs.firstIndex { $0.id == active }.map { $0 + 1 } ?? tabs.count
        tabs.insert(t, at: at)
        active = t.id
        t.connect()
    }

    /// 사이드바에서 서버를 누름: 그 서버 탭이 있으면 그리로, 없으면 새로
    func show(_ c: Computer, jumps: [Computer]) {
        if let t = activeTab, t.computer.id == c.id { return }
        if let t = tabs.first(where: { $0.computer.id == c.id }) { active = t.id } else { open(c, jumps: jumps) }
    }

    func select(_ t: MobileTerminalSession) { active = t.id }

    func close(_ t: MobileTerminalSession) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        t.disconnect()
        watchers[t.id] = nil
        tabs.remove(at: i)
        if active == t.id { active = tabs.indices.contains(i) ? tabs[i].id : tabs.last?.id }
    }

    func closeAll() { for t in tabs { close(t) } }
}

/// 고른 탭의 터미널을 보여 주는 칸. 탭마다 화면을 살려 두고 고른 것만 보인다 (맥 PaneHost 와 같은 방식)
struct WorkspaceTerminalHost: UIViewRepresentable {
    let tabs: [MobileTerminalSession]
    let active: UUID?
    /// 고른 탭에 키보드를 올린다 (아이폰은 옆 메뉴가 열려 있는 동안 끈다)
    var focus = true

    final class Box: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            for v in subviews {
                v.frame = bounds.insetBy(dx: 4, dy: 2)
                // 높이가 조금 바뀌어도 맨 아래에 붙어 있게 (MobileTerminal.swift followBottomAfterLayout)
                (v as? TerminalView)?.followBottomAfterLayout()
            }
        }
    }

    /// 키보드를 올릴지 (async 로 미룬 요청이 메뉴를 다시 연 뒤에 실행돼 키보드가 올라오던 것 막기)
    final class Coordinator { var focus = true }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Box { Box() }

    func updateUIView(_ box: Box, context: Context) {
        let views = tabs.map(\.view)
        for v in box.subviews where !views.contains(where: { $0 === v }) { v.removeFromSuperview() }
        for t in tabs {
            if t.view.superview !== box { t.view.removeFromSuperview(); box.addSubview(t.view); box.setNeedsLayout() }
            t.view.isHidden = t.id != active
        }
        if let t = tabs.first(where: { $0.id == active }) {
            box.backgroundColor = t.view.nativeBackgroundColor
            context.coordinator.focus = focus
            let c = context.coordinator
            if focus { DispatchQueue.main.async { if c.focus, !t.view.isHidden, !t.view.isFirstResponder { _ = t.view.becomeFirstResponder() } } }
            else { for t in tabs where t.view.isFirstResponder { _ = t.view.resignFirstResponder() } }
        }
    }
}

/// 아이패드 터미널 작업 공간
struct MobileTerminalWorkspaceView: View {
    @ObservedObject var workspace: MobileTerminalWorkspace
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editing: Computer?
    @State private var confirmClose = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var servers: [Computer] { store.computers.filter { $0.type == .ssh && $0.matches(query) } }

    var body: some View {
        Group {
            if sizeClass == .compact {
                // 아이폰(좁은 창): 탭 줄 대신 옆 메뉴에 열린 탭 + 서버 목록 (MobilePhoneWorkspace.swift)
                PhoneWorkspaceLayout(workspace: workspace, requestClose: requestClose, edit: { editing = $0 })
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
            }
        }
        // 터미널 바탕이 어두워서 작업 공간 전체를 어두운 모양으로
        .preferredColorScheme(.dark)
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
        .sheet(item: $editing) { ComputerEditView(computer: $0) }
        // alert: 아이폰 confirmationDialog 는 취소 버튼을 숨겨(바깥을 눌러야 닫힘) 취소가 안 보였다 (사용자)
        .alert("열린 터미널 \(workspace.tabs.count)개의 접속을 모두 끊을까요?", isPresented: $confirmClose) {
            Button("취소", role: .cancel) {}
            Button("모두 끊고 닫기", role: .destructive) { workspace.closeAll(); dismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            for t in workspace.tabs { t.applySettings() }
        }
    }

    // MARK: 사이드바

    private var sidebar: some View {
        List(selection: Binding(get: { workspace.activeTab?.computer.id }, set: { id in
            if let id, let c = store.computers.first(where: { $0.id == id }) { workspace.show(c, jumps: store.jumpChain(for: c)) }
        })) {
            Section("SSH 서버") {
                ForEach(servers) { c in
                    WorkspaceServerRow(computer: c, openCount: workspace.tabs.filter { $0.computer.id == c.id }.count)
                        .tag(c.id)
                        .contextMenu {
                            Button("새 탭으로 열기", systemImage: "plus.square.on.square") { workspace.open(c, jumps: store.jumpChain(for: c)) }
                            Button("편집", systemImage: "pencil") { editing = c }
                        }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "검색")
        .navigationTitle("SSH")
        .toolbar {
            // 닫기 = 모든 터미널 접속을 끊고 컴퓨터 목록으로 (사용자: 뒤로 가기 대신 닫기)
            ToolbarItem(placement: .topBarLeading) {
                Button("닫기", systemImage: "xmark", action: requestClose)
            }
        }
    }

    // MARK: 탭 줄 + 터미널

    private var detail: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            // 제목 줄 [터미널 | 파인더] 로 바꿔 본다 (맥처럼). 파인더 안에서 이 iPad | 서버 가 넓으면 나란히, 좁으면 전환
            HStack(spacing: 0) {
                let filesShown = workspace.activeTab?.showFiles ?? false
                if !filesShown {
                    ZStack {
                        WorkspaceTerminalHost(tabs: workspace.tabs, active: workspace.activeTab?.id)
                        if let t = workspace.activeTab { WorkspaceStatus(session: t) }
                        if workspace.tabs.isEmpty {
                            ContentUnavailableView("열린 터미널이 없습니다", systemImage: "apple.terminal",
                                                   description: Text("왼쪽에서 서버를 고르세요."))
                        }
                    }
                }
                if let t = workspace.activeTab, filesShown {
                    NoSafeAreaHost(content: MobileFinderView(files: t.files, local: workspace.local, connected: t.state == .connected))
                        // 홈 막대 자리까지 파인더 바탕을 깐다 (안전 영역을 끊어서 그 아래가 비어 보였다)
                        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
                        .id(t.id)
                }
            }
        }

        // 터미널 바탕색을 키보드 위 키 줄 뒤까지 깐다: 키 줄은 투명한 글래스라, 안 깔면 그 뒤로 창 바탕(검정)이 보였다 (사용자)
        .background { Color(uiColor: workspace.activeTab?.view.nativeBackgroundColor ?? .black).ignoresSafeArea() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let t = workspace.activeTab {
                    HStack(spacing: 6) {
                        Circle().fill(t.computer.sshColor?.color ?? .secondary).frame(width: 8, height: 8)
                        Text(t.computer.name).font(.headline)
                        Text(Self.address(t.computer)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            // [터미널 | 파인더] (맥 제목 줄과 같은 자리). 분할 컨트롤은 다른 버튼보다 높아서(사용자) 같은 알약 안의 버튼 둘로, 고른 쪽은 강조색
            // 받기·올리기 내역: 따로 떨어져 맨 앞 (배지가 화면 둥근 모서리에 잘리지 않게, 사용자)
            ToolbarItem(placement: .topBarTrailing) { TransferHistoryButton() }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let t = workspace.activeTab {
                    Button { t.showFiles = false } label: { Image(systemName: "apple.terminal") }
                        .tint(t.showFiles ? .primary : .accentColor)
                        .accessibilityLabel("터미널")
                    Button { t.showFiles = true; _ = t.view.resignFirstResponder() } label: { Image(systemName: "folder") }
                        .tint(t.showFiles ? .accentColor : .primary)
                        .accessibilityLabel("파인더")
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("새 탭", systemImage: "plus") {
                    if let t = workspace.activeTab { workspace.open(t.computer, jumps: t.jumps) }
                }
                .disabled(workspace.activeTab == nil)
                Button("키보드", systemImage: "keyboard") {
                    guard let v = workspace.activeTab?.view else { return }
                    if v.isFirstResponder { _ = v.resignFirstResponder() } else { _ = v.becomeFirstResponder() }
                }
                .disabled(workspace.activeTab == nil)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.tabs) { t in
                    WorkspaceTabItem(session: t, active: t.id == workspace.activeTab?.id,
                                     select: { workspace.select(t) }, close: { workspace.close(t) })
                }
            }
        }
        .frame(height: 40)
        .background(Color(white: 0.12), ignoresSafeAreaEdges: [])
    }

    /// 닫기: 탭이 둘 이상이면 물어보고, 모든 접속을 끊고 컴퓨터 목록으로
    private func requestClose() {
        if workspace.tabs.count > 1 { confirmClose = true } else { workspace.closeAll(); dismiss() }
    }

    private var questionTab: MobileTerminalSession? { workspace.tabs.first { $0.hostKeyQuestion != nil } }
    private var hostKeyTitle: String { questionTab?.hostKeyQuestion?.changed == true ? "서버 지문이 바뀌었습니다" : "처음 접속하는 서버입니다" }

    static func address(_ c: Computer) -> String {
        let user = c.username.isEmpty ? "" : c.username + "@"
        let port = c.port == Computer.Kind.ssh.defaultPort ? "" : ":\(c.port)"
        return user + c.host + port
    }
}

/// 사이드바 한 줄 (맥 사이드바와 같은 모양)
struct WorkspaceServerRow: View {
    let computer: Computer
    let openCount: Int

    var body: some View {
        HStack(spacing: 10) {
            ServerIcon(color: computer.sshColor ?? .none, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(computer.name).lineLimit(1)
                Text(MobileTerminalWorkspaceView.address(computer)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if openCount > 0 {
                HStack(spacing: 3) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    if openCount > 1 { Text("\(openCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 탭 하나 (맥 탭과 같은 모양: 색 점 · 이름 · 지금 폴더 · ×)
private struct WorkspaceTabItem: View {
    @ObservedObject var session: MobileTerminalSession
    let active: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(session.computer.sshColor?.color ?? Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(session.computer.name)
                .lineLimit(1)
                .fontWeight(active ? .semibold : .regular)
                .foregroundStyle(session.state == .connected ? .primary : .secondary)
                .layoutPriority(1)
            if let dir = session.workingDirectory {
                Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(active ? 1 : 0.5)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 40)
        .frame(minWidth: 130, maxWidth: 280)
        // 색 배경은 기본으로 안전 영역(제목 줄)까지 번진다 → 탭 안에만 (맥 탭과 같은 문제)
        .background(active ? Color(white: 0.2) : .clear, ignoresSafeAreaEdges: [])
        .overlay(alignment: .top) { if active { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("다시 접속", systemImage: "arrow.clockwise") { session.disconnect(); session.connect() }
            Button("탭 닫기", systemImage: "xmark", role: .destructive, action: close)
        }
    }
}

/// 접속 중·끊김 표시
struct WorkspaceStatus: View {
    @ObservedObject var session: MobileTerminalSession
    var body: some View {
        switch session.state {
        case .connecting:
            Label("접속 중…", systemImage: "network").padding(10).background(.thinMaterial, in: Capsule())
        case .connected:
            EmptyView()
        case .closed:
            VStack {
                Spacer()
                Button("다시 접속", systemImage: "arrow.clockwise") { session.connect() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 24)
            }
        }
    }
}
#endif
