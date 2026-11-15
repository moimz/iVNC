import SwiftUI

/// 맥 앱 첫 창: 컴퓨터 카드 목록. 카드를 누르면 접속 창이 열린다
struct MacHomeView: View {
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.openWindow) private var openWindow
    @State private var editing: Computer?
    @State private var adding = false
    /// 오른쪽 설정 패널
    @State private var showSettings = false
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 18)]

    var body: some View {
        ScrollView {
            if store.computers.isEmpty {
                ContentUnavailableView {
                    Label("컴퓨터가 없습니다", systemImage: "display.2")
                } description: {
                    Text("오른쪽 위 + 를 눌러 화면 공유가 켜진 맥을 추가하세요.")
                }
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(store.computers) { c in
                        Button { openWindow(id: "session", value: c.id) } label: { ComputerCard(computer: c) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("접속") { openWindow(id: "session", value: c.id) }
                                Button("편집") { editing = c }
                                Divider()
                                Button("삭제", role: .destructive) { store.delete(c) }
                            }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("컴퓨터")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("추가", systemImage: "plus") { adding = true }
                Button("설정", systemImage: "slider.horizontal.3") {
                    withAnimation(.snappy) { showSettings.toggle() }
                }
            }
        }
        // 설정 패널: 오른쪽 끝에 붙은 사이드바 모양 그대로, 목록 위에 덮는다 (목록 크기는 그대로)
        .overlay(alignment: .trailing) {
            if showSettings {
                HStack(spacing: 0) {
                    Divider()
                    SettingsForm()
                        .frame(width: 280)
                        .frame(maxHeight: .infinity)
                        .background(.background)
                }
                .transition(.move(edge: .trailing))
            }
        }
        .sheet(isPresented: $adding) { ComputerEditView(computer: nil).frame(minWidth: 460, minHeight: 520) }
        .sheet(item: $editing) { ComputerEditView(computer: $0).frame(minWidth: 460, minHeight: 520) }
    }
}
