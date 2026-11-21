#if os(iOS)
import SwiftUI
import UIKit

// 아이폰 SSH (2026-11-21 사용자): 탭 줄을 둘 자리가 없어 Claude 앱처럼 왼쪽 옆 메뉴.
// 터미널 화면 왼쪽 위 사이드바 버튼 (또는 왼쪽 끝에서 밀기) → 옆 메뉴: 위에 열린 탭, 아래 SSH 서버 목록.
// 서버를 누르면 새 탭이 생겨 위에 보이고, 열린 탭을 누르면 그 탭으로, 꾹 누르면 다시 접속·연결 종료.
// 메뉴 제목 줄 왼쪽 ✕ = 모든 접속을 끊고 컴퓨터 목록으로, 오른쪽 = 검색. (처음 생각했던 좌우로 밀어 탭 넘기기는 접음)

/// 아이폰(좁은 창) 작업 공간: 터미널 한 화면 + 옆 메뉴
struct PhoneWorkspaceLayout: View {
    @ObservedObject var workspace: MobileTerminalWorkspace
    let requestClose: () -> Void
    let edit: (Computer) -> Void
    @State private var menuOpen = false
    /// 끄는 중인 만큼 (열 때 +, 닫을 때 -)
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // Claude 앱처럼 화면의 3/4 남짓 (0.84 는 넓어 보였다, 사용자)
            let width = min(geo.size.width * 0.77, 320)
            let shown = max(0, min(width, (menuOpen ? width : 0) + drag))
            ZStack(alignment: .leading) {
                PhoneSideMenu(workspace: workspace, requestClose: requestClose, edit: edit, close: { setMenu(false) })
                    .frame(width: width)
                    .offset(x: (shown - width) * 0.25) // 메뉴는 조금만 따라 들어온다 (Claude 앱처럼)
                    // 닫혀 있을 땐 숨긴다: 메뉴가 본문 뒤 왼쪽에 일부 걸쳐 있어 상태 줄·키보드 자리로 비쳐 보였다
                    .opacity(shown > 0 ? 1 : 0)
                    // 메뉴 위에는 끌기 제스처를 걸지 않는다: 걸면 열린 탭 길게 누름 메뉴가 안 떴다. 닫기는 오른쪽 터미널을 누르거나 밀어서

                main
                    .frame(width: geo.size.width)
                    // 둥글게 자르는 건 메뉴가 열려 있을 때만 (닫혀 있을 때 자르면 상태 줄·키보드 뒤 바탕까지 잘린다)
                    // 늘 같은 clipShape 를 건다 (조건으로 붙였다 뗐다 하면 뷰가 새로 만들어져 터미널 글자가 안 보였다).
                    // 닫혀 있으면 아주 큰 사각형이라 상태 줄·키보드 뒤로 번지는 바탕을 자르지 않는다
                    .clipShape(MenuClip(open: shown > 0))
                    .overlay {
                        // 메뉴와 본문을 가르는 얇은 선: 둥근 모서리까지 따라간다 (Claude 앱처럼, 사용자)
                        if shown > 0 {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14 * shown / width), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        // 메뉴가 열려 있으면 본문을 어둡게 하고, 누르거나 왼쪽으로 밀면 닫힌다
                        if shown > 0 {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(.black.opacity(0.35 * shown / width))
                                .contentShape(Rectangle())
                                .onTapGesture { setMenu(false) }
                                .gesture(closeDrag(width: width))
                        }
                    }
                    .overlay(alignment: .leading) {
                        // 왼쪽 끝에서 밀어 열기 (터미널 글자 고르기를 덜 방해하게 좁게)
                        if !menuOpen {
                            Color.clear.frame(width: 16).contentShape(Rectangle()).gesture(openDrag(width: width))
                        }
                    }
                    .offset(x: shown)
                    .ignoresSafeArea(edges: shown > 0 ? .vertical : [])
            }
        }
        // 바탕은 터미널 색: 본문을 둥글게 자르면(clipShape) 상태 줄·키보드 뒤로 번지던 터미널 바탕도 잘려서
        // 그 자리에 이 바탕이 보였다 (사용자: 제목 줄·키보드 자리 배경이 이상함). 옆 메뉴는 자기 바탕이 따로 있다
        // 메뉴가 열리면 둥근 모서리 뒤는 옆 메뉴 색 (사용자), 닫혀 있으면 터미널 색
        .background((menuOpen || drag != 0 ? PhoneSideMenu.background : Color(uiColor: workspace.activeTab?.view.nativeBackgroundColor ?? .black)).ignoresSafeArea())
        .onAppear { if workspace.tabs.isEmpty { menuOpen = true } }
        // 마지막 탭을 닫으면 메뉴를 연다 (고를 서버가 거기 있다)
        .onChange(of: workspace.tabs.isEmpty) { _, empty in if empty { setMenu(true) } }
    }

    private func setMenu(_ open: Bool) {
        // 메뉴를 열면 키보드를 내린다 (터미널이 키보드를 쥐고 있으면 메뉴 위로 키보드·글자 메뉴가 떴다)
        if open {
            for t in workspace.tabs where t.view.isFirstResponder { _ = t.view.resignFirstResponder() }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        withAnimation(.snappy(duration: 0.28)) { menuOpen = open; drag = 0 }
    }

    private func openDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag = max(0, $0.translation.width) }
            .onEnded { v in setMenu(v.translation.width > width * 0.3 || v.predictedEndTranslation.width > width * 0.5) }
    }

    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard menuOpen, abs(v.translation.width) > abs(v.translation.height) else { return }
                drag = min(0, v.translation.width)
            }
            .onEnded { v in
                guard menuOpen else { return }
                setMenu(!(v.translation.width < -width * 0.3 || v.predictedEndTranslation.width < -width * 0.5))
            }
    }

    // MARK: 터미널 한 화면

    private var main: some View {
        NavigationStack {
            ZStack {
                if let t = workspace.activeTab, t.showFiles {
                    // 파인더: 이 iPhone | 서버 를 [전환] 으로 (좁아서 늘 한 칸)
                    MobileFinderView(files: t.files, local: workspace.local, connected: t.state == .connected)
                        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
                        .id(t.id)
                        .allowsHitTesting(!menuOpen)
                }
                WorkspaceTerminalHost(tabs: workspace.tabs, active: workspace.activeTab?.id, focus: !menuOpen && !(workspace.activeTab?.showFiles ?? false))
                    .opacity(workspace.activeTab?.showFiles == true ? 0 : 1)
                    .padding(.horizontal, 2)
                    // 메뉴가 열려 있으면 터미널은 터치를 안 받는다 (길게 누름이 터미널 글자 메뉴로 갔다)
                    // 파인더를 볼 땐 투명한 터미널이 위에서 터치를 가로채지 않게
                    .allowsHitTesting(!menuOpen && !(workspace.activeTab?.showFiles ?? false))
                if let t = workspace.activeTab, !t.showFiles { WorkspaceStatus(session: t) }
                if workspace.tabs.isEmpty {
                    ContentUnavailableView("열린 터미널이 없습니다", systemImage: "apple.terminal",
                                           description: Text("☰ 에서 서버를 고르세요."))
                }
            }
            // 키 줄(투명 유리) 뒤까지 터미널 바탕색
            .background { Color(uiColor: workspace.activeTab?.view.nativeBackgroundColor ?? .black).ignoresSafeArea() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { setMenu(true) } label: { Image(systemName: "sidebar.leading") }
                        .accessibilityLabel("서버 · 탭 목록")
                }
                ToolbarItem(placement: .principal) {
                    if let t = workspace.activeTab {
                        HStack(spacing: 6) {
                            Circle().fill(t.computer.sshColor?.color ?? .secondary).frame(width: 8, height: 8)
                            Text(t.computer.name).font(.headline).lineLimit(1)
                            if workspace.tabs.count > 1 {
                                Text("\(workspace.tabs.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                // 키보드 버튼은 뺐다: 터미널을 누르면 키보드가 올라온다 (사용자). 그 자리에 [터미널 | 파인더]
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
            }
        }
    }
}

/// 옆 메뉴: 제목 줄(✕ · SSH · 검색) · 열린 탭 · SSH 서버
private struct PhoneSideMenu: View {
    /// 옆 메뉴 바탕: Claude 앱처럼 조금 더 진한 검정 (사용자)
    static let background = Color(white: 0.04)
    @ObservedObject var workspace: MobileTerminalWorkspace
    @EnvironmentObject private var store: ComputerStore
    let requestClose: () -> Void
    let edit: (Computer) -> Void
    let close: () -> Void
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var servers: [Computer] { store.computers.filter { $0.type == .ssh && $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                if !workspace.tabs.isEmpty {
                    Section("열린 탭") {
                        ForEach(workspace.tabs) { t in
                            PhoneTabRow(computer: t.computer, subtitle: t.workingDirectory ?? MobileTerminalWorkspaceView.address(t.computer),
                                        state: t.state, active: t.id == workspace.activeTab?.id)
                                .padding(.horizontal, 10)
                                // 지금 탭 강조는 줄 안에서 그린다 (listRowBackground 로 그리면 길게 누름 메뉴가 안 떴다)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(t.id == workspace.activeTab?.id ? Color.white.opacity(0.12) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { workspace.select(t); close() }
                                // 꾹 누르면 다시 접속 · 연결 종료
                                .contextMenu {
                                    Button("다시 접속", systemImage: "arrow.clockwise") { t.disconnect(); t.connect() }
                                    Button("연결 종료", systemImage: "xmark.circle", role: .destructive) { workspace.close(t) }
                                } preview: {
                                    // 미리보기를 따로: 줄을 그대로 띄우면 옆 메뉴 밖(터미널 쪽)까지 넓게 떴다 (사용자)
                                    PhoneTabRow(computer: t.computer, subtitle: t.workingDirectory ?? MobileTerminalWorkspaceView.address(t.computer),
                                                state: t.state, active: true)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .frame(width: 280, alignment: .leading)
                                        .background(Color(white: 0.16))
                                        .environment(\.colorScheme, .dark) // 미리보기는 작업 공간의 어두운 모양을 안 물려받는다
                                }
                                // 왼쪽으로 밀면 닫기 (사용자)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { workspace.close(t) } label: { Label("닫기", systemImage: "xmark") }
                                }
                                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                Section("SSH 서버") {
                    ForEach(servers) { c in
                        let open = workspace.tabs.filter { $0.computer.id == c.id }.count
                        PhoneServerRow(computer: c, openCount: open)
                            // 열린 탭 줄과 같은 여백 → 초록 점이 같은 세로줄에 (사용자)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                            // 서버를 누르면 늘 새 탭 (위 열린 탭에 생긴다)
                            .onTapGesture { workspace.open(c, jumps: store.jumpChain(for: c)); close() }
                            .contextMenu { Button("편집", systemImage: "pencil") { edit(c) } } preview: {
                                PhoneServerRow(computer: c, openCount: open)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .frame(width: 280, alignment: .leading)
                                    .background(Color(white: 0.16))
                                    .environment(\.colorScheme, .dark)
                            }
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            // 줄 사이는 좁게: 기본 최소 줄 높이(44)를 없애고 줄 안 위아래 여백으로 높이를 정한다 (사용자)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
        }
        .background(PhoneSideMenu.background.ignoresSafeArea())
    }

    /// 제목 줄. 높이·위치는 오른쪽 본문 제목 줄(내비게이션 막대 44pt)과 같게 (사용자: Claude 앱처럼 같은 줄에)
    private var header: some View {
        Group {
            if searching {
                // 검색: 제목 줄 자리를 검색 칸이 다 차지하고 오른쪽에 ✕ (사용자: Claude 앱처럼)
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                        TextField("검색", text: $query).focused($searchFocused).submitLabel(.search)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    Button { setSearching(false) } label: { Image(systemName: "xmark").font(.system(size: 19, weight: .medium)).frame(width: 30, height: 30) }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                        .accessibilityLabel("검색 닫기")
                }
                .transition(.opacity)
            } else {
                ZStack {
                    Text("SSH").font(.title3.weight(.semibold))
                    HStack {
                        // 모든 접속을 끊고 컴퓨터 목록으로
                        Button(action: requestClose) { Image(systemName: "xmark").font(.system(size: 19, weight: .medium)).frame(width: 30, height: 30) }
                            .accessibilityLabel("모두 닫기")
                        Spacer()
                        Button { setSearching(true) } label: { Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .medium)).frame(width: 30, height: 30) }
                            .accessibilityLabel("검색")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                }
                .transition(.opacity)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func setSearching(_ on: Bool) {
        withAnimation(.snappy(duration: 0.2)) { searching = on }
        if on { searchFocused = true } else { query = ""; searchFocused = false }
    }

}

/// 서버 한 줄 (아이폰: 아이콘을 조금 크게, 사용자)
private struct PhoneServerRow: View {
    let computer: Computer
    let openCount: Int

    var body: some View {
        HStack(spacing: 10) {
            ServerIcon(color: computer.sshColor ?? .none, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(computer.name).lineLimit(1)
                Text(MobileTerminalWorkspaceView.address(computer)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if openCount > 0 {
                HStack(spacing: 3) {
                    if openCount > 1 { Text("\(openCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    Circle().fill(.green).frame(width: 7, height: 7)
                }
            }
        }
        .padding(.vertical, 9) // 강조 배경의 위아래 여백을 좌우와 비슷하게 (사용자)
    }
}

/// 열린 탭 한 줄: 색 아이콘 · 서버 이름 · 지금 폴더 · 상태.
/// 세션을 @ObservedObject 로 받으면 길게 누름 메뉴가 안 떴다 (작업 공간이 세션 변화에 다시 그리므로 값만 받는다)
private struct PhoneTabRow: View {
    let computer: Computer
    let subtitle: String
    let state: MobileTerminalSession.State
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            // 서버 목록과 같은 아이콘 (사용자)
            ServerIcon(color: computer.sshColor ?? .none, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(computer.name).fontWeight(active ? .semibold : .regular).lineLimit(1)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            switch state {
            case .connected: Circle().fill(.green).frame(width: 7, height: 7)
            case .connecting: ProgressView().controlSize(.mini)
            case .closed: Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(.vertical, 9) // 강조 배경의 위아래 여백을 좌우와 비슷하게 (사용자)
    }
}
/// 본문 자르기: 메뉴가 열리면 둥근 모서리, 닫혀 있으면 사실상 자르지 않는 큰 사각형
private struct MenuClip: Shape {
    var open: Bool
    func path(in rect: CGRect) -> Path {
        open ? RoundedRectangle(cornerRadius: 28, style: .continuous).path(in: rect) : Path(rect.insetBy(dx: -4000, dy: -4000))
    }
}
#endif
