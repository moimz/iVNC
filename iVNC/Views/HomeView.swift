import SwiftUI

/// 첫 화면: 등록한 컴퓨터를 카드로 보여 준다. 화면이 넓어지면(가로, 아이패드) 한 줄에 더 많이 놓는다.
struct HomeView: View {
    @EnvironmentObject private var store: ComputerStore
    @State private var editing: Computer?
    @State private var adding = false
    @State private var connecting: Computer?
    /// UI 시험: DEBUG 빌드에서는 카드를 누르면 접속 없이 화면 UI 만 띄운다. 길게 눌러 "실제 접속" 으로 진짜 접속 (임시)
    #if DEBUG
    static let uiPreview = true
    #else
    static let uiPreview = false
    #endif
    @State private var realConnect = false
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
                            Button { realConnect = false; connecting = c } label: { ComputerCard(computer: c) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if Self.uiPreview {
                                        Button("실제 접속", systemImage: "network") { realConnect = true; connecting = c }
                                    }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("추가", systemImage: "plus") { adding = true }
                }
            }
            .sheet(isPresented: $adding) { ComputerEditView(computer: nil) }
            .sheet(item: $editing) { ComputerEditView(computer: $0) }
            .fullScreenCover(item: $connecting) { SessionView(computer: $0, preview: Self.uiPreview && !realConnect) }
        }
    }
}

struct ComputerCard: View {
    @EnvironmentObject private var store: ComputerStore
    let computer: Computer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .aspectRatio(16 / 10, contentMode: .fit) // 맥 화면 비율
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            Text(computer.name).font(.headline).lineLimit(1)
            Text(computer.lastConnected.map { "마지막 접속 " + $0.formatted(.relative(presentation: .named)) } ?? computer.host)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var thumbnail: some View {
        // thumbnailVersion 이 바뀌면 다시 읽는다
        let _ = store.thumbnailVersion
        if let img = Thumbnails.load(computer: computer.id) {
            Color.clear.overlay(Image(uiImage: img).resizable().scaledToFill())
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "desktopcomputer").font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
