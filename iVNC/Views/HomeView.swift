import SwiftUI

/// 첫 화면: 화면 공유(맥·윈도우)는 카드로, SSH 는 그 아래 한 줄 목록으로 묶는다. 묶음은 접었다 폈다.
/// 화면이 넓어지면(가로, 아이패드) 카드를 한 줄에 더 많이 놓는다.
struct HomeView: View {
    @EnvironmentObject private var store: ComputerStore
    @State private var editing: Computer?
    @State private var adding = false
    @State private var settings = false
    @State private var connecting: Computer?
    /// 정렬 모드 (☰): 목록으로 끌어서 순서 바꾸기
    @State private var reordering = false
    /// SSH 작업 공간: 아이패드는 맥 터미널 창처럼 사이드바 + 탭, 아이폰은 옆 메뉴(열린 탭 + 서버). 닫으면 모든 접속을 끊는다
    @StateObject private var workspace = MobileTerminalWorkspace()
    @State private var showWorkspace = false
    @AppStorage(ComputerGroupKeys.screens) private var screensExpanded = true
    @AppStorage(ComputerGroupKeys.ssh) private var sshExpanded = true
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 320), spacing: 16)]

    private var screens: [Computer] { store.computers.filter { $0.type.showsScreen } }
    private var servers: [Computer] { store.computers.filter { !$0.type.showsScreen } }

    var body: some View {
        NavigationStack {
            Group {
                if reordering { ComputerReorderList() } else { cards }
            }
            .navigationTitle(reordering ? "순서 바꾸기" : "컴퓨터")
            .toolbar {
                if reordering {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("완료", systemImage: "checkmark") { reordering = false }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("설정", systemImage: "gearshape") { settings = true }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("순서 바꾸기", systemImage: "line.3.horizontal") { reordering = true }
                            .disabled(store.computers.count < 2)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("추가", systemImage: "plus") { adding = true }
                    }
                }
            }
            .sheet(isPresented: $adding) { ComputerEditView(computer: nil) }
            .sheet(isPresented: $settings) { SettingsView() }
            .sheet(item: $editing) { ComputerEditView(computer: $0) }
            .fullScreenCover(item: $connecting) { SessionView(computer: $0) }
            .fullScreenCover(isPresented: $showWorkspace) { MobileTerminalWorkspaceView(workspace: workspace).environmentObject(store) }
        }
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
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        // SSH 가 없으면 묶음 머리 없이 예전처럼 카드만
                        if !screens.isEmpty {
                            if !servers.isEmpty {
                                ComputerGroupHeader(title: "화면 공유", count: screens.count, expanded: $screensExpanded)
                            }
                            if servers.isEmpty || screensExpanded {
                                LazyVGrid(columns: columns, spacing: 20) {
                                    ForEach(screens) { c in
                                        Button { connecting = c } label: { ComputerCard(computer: c) }
                                            .buttonStyle(.plain)
                                            .contextMenu { menu(c) }
                                    }
                                }
                            }
                        }
                        if !servers.isEmpty {
                            ComputerGroupHeader(title: "SSH", count: servers.count, expanded: $sshExpanded)
                                .padding(.top, screens.isEmpty ? 0 : 8)
                            if sshExpanded {
                                SSHList(computers: servers) { c in
                                    Button { openSSH(c) } label: { SSHRow(computer: c) }
                                        .buttonStyle(.plain)
                                        .contextMenu { menu(c) }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
    }

    /// SSH 서버 누름: 작업 공간에서 그 서버 탭으로 (없으면 새 탭). 화면 모양은 작업 공간이 크기에 따라 고른다
    private func openSSH(_ c: Computer) {
        workspace.show(c, jumps: store.jumpChain(for: c))
        showWorkspace = true
    }

    @ViewBuilder private func menu(_ c: Computer) -> some View {
        Button("편집", systemImage: "pencil") { editing = c }
        Button("삭제", systemImage: "trash", role: .destructive) { store.delete(c) }
    }
}
