import SwiftUI

/// 첫 화면: 등록한 컴퓨터를 카드로 보여 준다. 화면이 넓어지면(가로, 아이패드) 한 줄에 더 많이 놓는다.
struct HomeView: View {
    @EnvironmentObject private var store: ComputerStore
    @State private var editing: Computer?
    @State private var adding = false
    @State private var settings = false
    @State private var connecting: Computer?
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 320), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.computers.isEmpty {
                    ContentUnavailableView {
                        Label("컴퓨터가 없습니다", systemImage: "display.2")
                    } description: {
                        Text("오른쪽 위 + 를 눌러 화면 공유가 켜진 맥을 추가하세요.")
                    }
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(store.computers) { c in
                            Button { connecting = c } label: { ComputerCard(computer: c) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("편집", systemImage: "pencil") { editing = c }
                                    Button("삭제", systemImage: "trash", role: .destructive) { store.delete(c) }
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
        }
    }
}
