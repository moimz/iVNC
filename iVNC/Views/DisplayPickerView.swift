import SwiftUI

/// 맥의 디스플레이 설정처럼 모니터 배치를 그리고, 하나를 고르게 한다.
struct DisplayPickerView: View {
    let computer: Computer
    let displays: [RemoteDisplay]
    /// 팝업 안에서 쓸 때: 제목과 지금 보는 모니터 표시, 배치 그림 높이 고정
    var title = "볼 모니터를 고르세요"
    var current: RemoteDisplay?
    var compact = false
    let onSelect: (RemoteDisplay) -> Void

    /// 왼쪽에서 오른쪽, 위에서 아래 순서 (모니터 번호)
    static func order(_ a: RemoteDisplay, _ b: RemoteDisplay) -> Bool {
        a.desktop.minX != b.desktop.minX ? a.desktop.minX < b.desktop.minX : a.desktop.minY < b.desktop.minY
    }

    var body: some View {
        let sorted = displays.sorted(by: Self.order)
        let all = sorted.reduce(CGRect.null) { $0.union($1.desktop) }
        VStack(spacing: 24) {
            Text(title).font(compact ? .headline : .title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
            GeometryReader { geo in
                let union = sorted.reduce(CGRect.null) { $0.union($1.desktop) }
                let gap: CGFloat = 4
                let scale = min(geo.size.width / union.width, geo.size.height / union.height)
                let offX = (geo.size.width - union.width * scale) / 2
                let offY = (geo.size.height - union.height * scale) / 2
                ZStack(alignment: .topLeading) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { i, d in
                        let r = CGRect(x: offX + (d.desktop.minX - union.minX) * scale + gap / 2,
                                       y: offY + (d.desktop.minY - union.minY) * scale + gap / 2,
                                       width: d.desktop.width * scale - gap, height: d.desktop.height * scale - gap)
                        Button { onSelect(d) } label: {
                            MonitorTile(computer: computer, display: d, number: i + 1)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: d == current ? 3 : 0))
                        }
                        .buttonStyle(MonitorButtonStyle())
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .animation(.easeInOut(duration: 0.25), value: sorted)
            }
            // 팝업에서는 배치 그림의 가로세로 비율대로 높이를 잡아 위아래가 비지 않게 한다
            .aspectRatio(compact && all.height > 0 ? all.width / all.height : nil, contentMode: .fit)
            .frame(maxHeight: compact ? 260 : nil)
            .padding(.horizontal, compact ? 0 : 24)
            .padding(.bottom, compact ? 0 : 40)
        }
        .padding(compact ? 20 : 0)
    }
}

private struct MonitorTile: View {
    let computer: Computer
    let display: RemoteDisplay
    let number: Int

    var body: some View {
        ZStack {
            if let img = Thumbnails.load(computer: computer.id, display: display.stableKey) {
                Color.clear.overlay(Image(decorative: img, scale: 1).resizable().scaledToFill())
            } else {
                LinearGradient(colors: [Color(red: 0.25, green: 0.36, blue: 0.55), Color(red: 0.12, green: 0.16, blue: 0.28)],
                               startPoint: .top, endPoint: .bottom)
            }
            VStack(spacing: 4) {
                Text("\(number)").font(.title.weight(.bold))
                Text(verbatim: "\(Int(display.framebuffer.width))×\(Int(display.framebuffer.height))").font(.caption2.monospacedDigit())
                if display.isMain { Text("주 모니터").font(.caption2) }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3)
            .padding(8)
            .minimumScaleFactor(0.5)
        }
        // 주 모니터는 맥처럼 위에 메뉴 막대 띠
        .overlay(alignment: .top) {
            if display.isMain { Rectangle().fill(.white.opacity(0.85)).frame(height: 6) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25)))
    }
}

private struct MonitorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? 0.1 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
