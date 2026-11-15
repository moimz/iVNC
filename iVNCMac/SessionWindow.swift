import AppKit
import SwiftUI

/// 접속 창 크기: 원격 화면(제목·도구 막대 아래 영역)이 원격 비율 그대로 되게 한다.
/// NSWindow.contentAspectRatio 는 제목 막대까지 포함한 비율이라 위아래가 남아 레터박스가 생겼다 →
/// 크기 바꿀 때마다 높이 = 너비 × 비율 + 막대 높이로 맞춘다 (SwiftUI 가 단 창 delegate 앞에 끼워 넣는다)
@MainActor
final class SessionWindowSizer: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var original: NSWindowDelegate?
    /// 원격 화면 픽셀 크기 (비율 기준)
    private var pixel = CGSize.zero

    /// 창마다 하나 (창이 살아 있는 동안 붙잡아 둔다)
    private static var sizers: [ObjectIdentifier: SessionWindowSizer] = [:]

    static func of(_ w: NSWindow) -> SessionWindowSizer {
        if let s = sizers[ObjectIdentifier(w)] { return s }
        let s = SessionWindowSizer(window: w)
        sizers[ObjectIdentifier(w)] = s
        return s
    }

    private init(window w: NSWindow) {
        window = w
        original = w.delegate
        super.init()
        w.delegate = self
    }

    /// 제목·도구 막대 높이
    private var chrome: CGFloat {
        guard let w = window else { return 0 }
        return w.frame.height - w.contentLayoutRect.height
    }

    /// 원격 크기(1픽셀 = 1포인트)로 창을 맞춘다. 화면보다 크면 비율대로 줄인다
    func fit(pixel size: CGSize) {
        guard let w = window, size.width > 0, size.height > 0 else { return }
        pixel = size
        let visible = (w.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let c = chrome
        let s = min(1, visible.width / size.width, (visible.height - c) / size.height)
        let width = (size.width * s).rounded(), height = (size.height * s).rounded() + c
        var frame = w.frame
        // 위 왼쪽을 그대로 두고 크기만 (화면 밖으로 나가면 안쪽으로)
        frame.origin.y += frame.height - height
        frame.size = CGSize(width: width, height: height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - height)
        w.setFrame(frame, display: true, animate: true)
    }

    // 크기 바꾸기: 비율 고정
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var size = original?.windowWillResize?(sender, to: frameSize) ?? frameSize
        guard pixel.width > 0 else { return size }
        size.height = (size.width * pixel.height / pixel.width).rounded() + chrome
        return size
    }

    // 나머지는 SwiftUI 의 delegate 로
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original?.responds(to: aSelector) == true { return original }
        return super.forwardingTarget(for: aSelector)
    }

    func windowWillClose(_ notification: Notification) {
        original?.windowWillClose?(notification)
        if let w = window { Self.sizers[ObjectIdentifier(w)] = nil }
    }
}

/// SwiftUI 뷰가 올라간 창을 알려 준다
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { DispatchQueue.main.async { self.onWindow(w) } }
        }
    }
}
