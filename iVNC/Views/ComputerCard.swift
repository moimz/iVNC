import SwiftUI

/// 컴퓨터 카드 (썸네일 + 이름 + 마지막 접속). 아이폰·아이패드·맥 공용
struct ComputerCard: View {
    @EnvironmentObject private var store: ComputerStore
    let computer: Computer
    /// 맥: 한 번 눌러 고른 카드 (파란 테두리)
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .aspectRatio(16 / 10, contentMode: .fit) // 맥 화면 비율
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                .padding(selected ? 3 : 0)
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0))
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
            Color.clear.overlay(Image(decorative: img, scale: 1).resizable().scaledToFill())
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "desktopcomputer").font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
