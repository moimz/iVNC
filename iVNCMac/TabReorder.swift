import SwiftUI
import AppKit

// 탭 끌기 (iSQL TabStrip.swift 의 TabReorder 를 옮겨 옴, 2026-11-21 사용자: iSQL 과 같게).
// 탭을 끌면 마우스를 따라오고, 옆 탭 가운데를 넘으면 그 탭이 비켜나며 순서가 바뀐다.
// 더해서: 탭 줄 위아래로 크게 벗어나 놓으면 "떼어 내기" — 다른 창·다른 칸으로 옮기거나 새 창으로 (onTearOff).

enum TabReorderSpace { static let name = "tabstrip" }

/// 탭 끌어 순서 바꾸기 상태 (탭 줄 하나에 하나)
struct TabReorder<ID: Hashable> {
    var dragging: ID?
    /// 끄는 탭을 제자리에서 얼마나 옮겨 그릴지
    var offset: CGSize = .zero
    /// 끌기 시작할 때 그 탭의 왼쪽 끝 (탭 줄 안 좌표)
    var startX: CGFloat = 0
    var widths: [ID: CGFloat] = [:]
    /// 탭 줄 위아래로 벗어나 있는지 (놓으면 떼어 내기)
    var tornOff = false
}

extension View {
    func reorderable<ID: Hashable>(_ id: ID, order: [ID], state: Binding<TabReorder<ID>>,
                                   move: @escaping (ID, ID?) -> Void, tearOff: @escaping (ID) -> Void,
                                   hover: @escaping (ID?) -> Void = { _ in }) -> some View {
        modifier(TabReorderModifier(id: id, order: order, state: state, move: move, tearOff: tearOff, hover: hover))
    }
}

private struct TabReorderModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let order: [ID]
    @Binding var state: TabReorder<ID>
    let move: (ID, ID?) -> Void
    let tearOff: (ID) -> Void
    /// 떼어 내는 중 마우스가 움직일 때 (nil = 끝남): 들어갈 창·칸 표시
    let hover: (ID?) -> Void

    /// 탭 줄 위아래로 이만큼 벗어나면 떼어 내기
    private static var tearDistance: CGFloat { 28 }

    private var isDragging: Bool { state.dragging == id }

    private func left(of target: ID, in ids: [ID]) -> CGFloat {
        var x: CGFloat = 0
        for i in ids { if i == target { return x }; x += state.widths[i] ?? 0 }
        return x
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.widths[id] = $0 }
            .offset(isDragging ? state.offset : .zero)
            .opacity(isDragging && state.tornOff ? 0.75 : 1)
            .zIndex(isDragging ? 1 : 0)
            .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 6)
            .transaction { if isDragging { $0.animation = nil } }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(TabReorderSpace.name))
                    .onChanged { v in
                        if state.dragging != id {
                            state.dragging = id
                            state.startX = left(of: id, in: order)
                        }
                        let w = state.widths[id] ?? 0
                        state.tornOff = abs(v.translation.height) > Self.tearDistance
                        hover(state.tornOff ? id : nil)
                        // 떼어 내는 중이면 순서는 그대로, 탭만 마우스를 따라간다
                        if state.tornOff {
                            state.offset = v.translation
                            return
                        }
                        // 왼쪽 끝을 0 에 묶으면 탭 너비가 같을 때 끄는 탭 가운데가 첫 탭 가운데를 못 넘어
                        // 맨 앞으로 못 갔다 (사용자, iSQL 도 같았다) → 반 탭만큼 왼쪽 밖까지 허용
                        let wantX = max(-w / 2, state.startX + v.translation.width)
                        let others = order.filter { $0 != id }
                        var x: CGFloat = 0, target = others.count
                        for (i, o) in others.enumerated() {
                            let ow = state.widths[o] ?? 0
                            if wantX + w / 2 <= x + ow / 2 { target = i; break }
                            x += ow
                        }
                        var newOrder = others
                        newOrder.insert(id, at: target)
                        if newOrder != order { move(id, target < others.count ? others[target] : nil) }
                        state.offset = CGSize(width: wantX - left(of: id, in: newOrder), height: 0)
                    }
                    .onEnded { _ in
                        let torn = state.tornOff
                        state.tornOff = false
                        hover(nil)
                        state.dragging = nil
                        if torn {
                            state.offset = .zero
                            tearOff(id)
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) { state.offset = .zero }
                        }
                    }
            )
    }
}

/// 터미널 창의 NSWindow 를 모델에 알려 준다 (탭을 다른 창으로 옮길 때 마우스 밑 창을 찾으려고)
struct WindowGrabber: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    final class V: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.onWindow = onWindow; return v }
    func updateNSView(_ v: V, context: Context) { v.onWindow = onWindow; if v.window != nil { onWindow(v.window) } }
}
