import SwiftUI

/// 맥 앱 첫 창: 화면 공유(맥·윈도우)는 카드, SSH 는 그 아래 한 줄 목록. 묶음은 접었다 폈다.
/// 카드·줄을 두 번 누르면 접속 창이 열린다
struct MacHomeView: View {
    @EnvironmentObject private var store: ComputerStore
    @ObservedObject private var mcp = MCPServer.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var editing: Computer?
    @State private var adding = false
    /// 한 번 눌러 고른 컴퓨터 (두 번 누르거나 엔터로 접속)
    @State private var selected: UUID?
    /// 정렬 모드 (☰): 목록으로 끌어서 순서 바꾸기
    @State private var reordering = false
    @AppStorage(ComputerGroupKeys.screens) private var screensExpanded = true
    @AppStorage(ComputerGroupKeys.ssh) private var sshExpanded = true
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 18)]

    @State private var query = ""
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var screens: [Computer] { store.computers.filter { $0.type.showsScreen && $0.matches(query) } }
    private var servers: [Computer] { store.computers.filter { !$0.type.showsScreen && $0.matches(query) } }

    var body: some View {
        Group {
            if reordering {
                ComputerReorderList()
            } else {
                cards
            }
        }
        .navigationTitle("iVNC")
        .searchable(text: $query, placement: .toolbar, prompt: "이름·주소 검색")
        // Dock 을 눌렀을 때 이 창을 다시 열 수 있게 맡겨 둔다
        .onAppear { HomeWindow.open = { [openWindow] in openWindow(id: "home") } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if reordering {
                    Button("완료", systemImage: "checkmark") { reordering = false }
                        .buttonStyle(.borderedProminent)
                        .help("순서 바꾸기 끝내기")
                } else {
                    Button("순서 바꾸기", systemImage: "line.3.horizontal") { reordering = true }
                        .help("순서 바꾸기")
                        .disabled(store.computers.count < 2)
                    Button("추가", systemImage: "plus") { adding = true }
                    // 설정은 ⌘, 와 같은 설정 창 ([일반 | 화면 공유 | SSH])
                    Button("설정", systemImage: "gearshape") { openSettings() }
                }
            }
        }
        .sheet(isPresented: $adding) { ComputerEditView(computer: nil).frame(minWidth: 460, minHeight: 520) }
        .sheet(item: $editing) { ComputerEditView(computer: $0).frame(minWidth: 460, minHeight: 520) }
    }

    private var cards: some View {
        ScrollView {
            if store.computers.isEmpty {
                ContentUnavailableView {
                    Label("컴퓨터가 없습니다", systemImage: "display.2")
                } description: {
                    Text("오른쪽 위 + 를 눌러 맥·윈도우나 SSH 서버를 추가하세요.")
                }
                .padding(.top, 80)
            } else if screens.isEmpty && servers.isEmpty {
                ContentUnavailableView.search(text: query).padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    // SSH 가 없으면 묶음 머리 없이 예전처럼 카드만
                    if !screens.isEmpty {
                        if !servers.isEmpty {
                            ComputerGroupHeader(title: "화면 공유", count: screens.count, expanded: $screensExpanded)
                        }
                        if servers.isEmpty || screensExpanded || searching {
                            LazyVGrid(columns: columns, spacing: 22) {
                                ForEach(screens) { c in
                                    ComputerCard(computer: c, selected: selected == c.id)
                                        // 한 번 = 고르기(바로), 두 번 = 접속
                                        .onTapGesture(count: 2) { open(c) }
                                        .simultaneousGesture(TapGesture().onEnded { selected = c.id })
                                        .contextMenu { menu(c) }
                                }
                            }
                        }
                    }
                    if !servers.isEmpty {
                        ComputerGroupHeader(title: "SSH", count: servers.count, expanded: $sshExpanded)
                            .padding(.top, screens.isEmpty ? 0 : 8)
                        if sshExpanded || searching {
                            SSHList(computers: servers) { c in
                                SSHRow(computer: c, selected: selected == c.id, mcpConnected: mcp.backgroundConnected.contains(c.id))
                                    .onTapGesture(count: 2) { open(c) }
                                    .simultaneousGesture(TapGesture().onEnded { selected = c.id })
                                    .contextMenu { menu(c) }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        // 빈 곳을 누르면 고르기 풀기, 엔터로 고른 컴퓨터 접속
        .contentShape(Rectangle())
        .onTapGesture { selected = nil }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let id = selected, let c = store.computers.first(where: { $0.id == id }) else { return .ignored }
            open(c)
            return .handled
        }
    }

    /// 접속: 화면 공유는 접속 창, SSH 는 늘 새 터미널 창
    private func open(_ c: Computer) {
        if c.type.showsScreen { openWindow(id: "session", value: c.id) } else { openWindow(id: "terminal", value: TerminalWindowRequest(computer: c.id)) }
    }

    @ViewBuilder private func menu(_ c: Computer) -> some View {
        Button("접속", systemImage: c.type.showsScreen ? "play.display" : "terminal") { open(c) }
            .keyboardShortcut(.return, modifiers: [])
        Button("편집…", systemImage: "pencil") { editing = c }
            .keyboardShortcut("e")
        if mcp.backgroundConnected.contains(c.id) {
            Button("MCP 연결 끊기", systemImage: "bolt.horizontal.circle") { mcp.disconnectBackground(c.id) }
        }
        Divider()
        Button("삭제", systemImage: "trash", role: .destructive) { store.delete(c) }
            .keyboardShortcut(.delete)
    }
}
