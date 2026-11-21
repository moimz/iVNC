import SwiftUI
import AppKit

// 맥 26 메뉴는 항목 그림(NSMenuItem.image)을 그리지 않는다 (시험 앱으로 확인: 폴더 그림·SF 기호 모두 안 나옴).
// 그래서 아이콘이 필요한 메뉴는 항목을 SwiftUI 뷰로 직접 그린다 (iSQL 접속한 서버 메뉴와 같은 방식, 2026-11-21).

/// 닫는 블록을 가진 메뉴 항목 (iSQL MenuAction)
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }

    static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action   // target 은 약한 참조라 항목이 붙잡아 둔다
        return item
    }

    /// SwiftUI 로 그린 항목
    static func item<V: View>(_ title: String, view: V, minWidth: CGFloat = 220, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = self.item(title, run)
        item.view = MenuRowView(view, minWidth: minWidth)
        return item
    }
}

/// SwiftUI 로 그린 메뉴 항목: 마우스가 올라가면 둥근 강조, 누르면 메뉴를 닫고 항목 동작을 부른다 (iSQL MenuRowView)
final class MenuRowView: NSView {
    private let host: NSHostingView<AnyView>

    init<V: View>(_ content: V, minWidth: CGFloat) {
        host = NSHostingView(rootView: AnyView(content))
        let size = host.fittingSize
        super.init(frame: NSRect(x: 0, y: 0, width: max(size.width, minWidth), height: size.height))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    // 안의 SwiftUI 가 마우스를 먹지 않게
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func draw(_ dirtyRect: NSRect) {
        guard enclosingMenuItem?.isHighlighted == true else { return }
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }
}

/// 메뉴를 띄울 자리 (버튼 뒤에 깔린 빈 NSView): 마우스 자리와 상관없이 늘 버튼 바로 아래, 왼쪽 끝을 버튼에 맞춘다
final class MenuAnchorBox { weak var view: NSView? }

struct MenuAnchor: NSViewRepresentable {
    let box: MenuAnchorBox
    func makeNSView(context: Context) -> NSView { let v = NSView(); box.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

extension NSMenu {
    /// 기준 뷰 바로 아래에 띄운다
    func popUp(below box: MenuAnchorBox) {
        if let v = box.view, v.window != nil {
            popUp(positioning: nil, at: NSPoint(x: 0, y: v.isFlipped ? v.bounds.height + 4 : -4), in: v)
        } else {
            popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}
