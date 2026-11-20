import SwiftUI

/// 첫 화면: 화면 공유(맥·윈도우)는 카드로, SSH 는 그 아래 한 줄 목록으로 묶는다. 묶음은 접었다 폈다.
/// 화면이 넓어지면(가로, 아이패드) 카드를 한 줄에 더 많이 놓는다.
struct HomeView: View {
    @EnvironmentObject private var store: ComputerStore
    @State private var editing: Computer?
    @State private var adding = false
    @State private var settings = false
    @State private var connecting: Computer?
    @State private var sshNotReady = false
    @AppStorage(ComputerGroupKeys.screens) private var screensExpanded = true
    @AppStorage(ComputerGroupKeys.ssh) private var sshExpanded = true
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 320), spacing: 16)]

    private var screens: [Computer] { store.computers.filter { $0.type.showsScreen } }
    private var servers: [Computer] { store.computers.filter { !$0.type.showsScreen } }

    var body: some View {
        NavigationStack {
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
                                    Button { sshNotReady = true } label: { SSHRow(computer: c) }
                                        .buttonStyle(.plain)
                                        .contextMenu { menu(c) }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("컴퓨터")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("설정", systemImage: "gearshape") { settings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("추가", systemImage: "plus") { adding = true }
                }
            }
            .sheet(isPresented: $adding) { ComputerEditView(computer: nil) }
            .sheet(isPresented: $settings) { SettingsView() }
            .sheet(item: $editing) { ComputerEditView(computer: $0) }
            .fullScreenCover(item: $connecting) { SessionView(computer: $0) }
            .alert("SSH 터미널은 곧 추가됩니다", isPresented: $sshNotReady) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("지금은 서버를 등록해 둘 수 있습니다. 길게 눌러 편집할 수 있습니다.")
            }
        }
    }

    @ViewBuilder private func menu(_ c: Computer) -> some View {
        Button("편집", systemImage: "pencil") { editing = c }
        Button("삭제", systemImage: "trash", role: .destructive) { store.delete(c) }
    }
}
