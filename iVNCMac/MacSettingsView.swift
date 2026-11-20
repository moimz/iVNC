import SwiftUI
import AppKit

/// 맥 앱 설정 (⌘,, Settings 장면): 위 아이콘 탭 [일반 | 화면 공유 | SSH] (iSQL AppSettingsView 와 같은 방식).
/// 맥 설정창 규칙대로 폭은 탭마다 같고 높이만 바뀐다
struct MacSettingsView: View {
    static let width: CGFloat = 620
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("일반", systemImage: "gearshape", value: "general") {
                GeneralSettingsForm().frame(width: Self.width, height: 300)
            }
            Tab("화면 공유", systemImage: "display.2", value: "screen") {
                ScreenSettingsForm().frame(width: Self.width, height: 470)
            }
            Tab("SSH", systemImage: "terminal", value: "ssh") {
                MacTerminalSettings().frame(width: Self.width, height: 720)
            }
        }
        .background(SettingsWindowStyler())
    }
}

/// 설정 > SSH: 맥 터미널 프로필처럼 상자 탭 [텍스트 | 윈도우 | 셸 | 키보드 | 고급]
private struct MacTerminalSettings: View {
    @AppStorage("settingsTerminalTab") private var page = 0

    var body: some View {
        BoxTabView(titles: TerminalSettingsPage.allCases.map(\.title), selection: $page) { i in
            AnyView(TerminalSettingsPage(rawValue: i)?.form.scrollContentBackground(.hidden))
        }
        .padding(20)
    }
}

/// SwiftUI 설정 창(NSWindow)을 직접 다듬는다: 내용이 탭줄 밑으로 들어가지 않게 하고 탭줄 아래 구분선 (iSQL 과 같음).
/// 맥 26 SwiftUI 설정창은 내용이 탭줄 밑까지 깔려(fullSizeContentView) 마우스를 올리거나 창이 비활성일 때만 띠가 보인다
struct SettingsWindowStyler: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            DispatchQueue.main.async {
                w.styleMask.remove(.fullSizeContentView)
                w.titlebarAppearsTransparent = false
                w.titlebarSeparatorStyle = .line
                w.toolbarStyle = .preference
            }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) {}
}

/// AppKit 탭 상자 (NSTabView, 상자 위 테두리에 걸친 탭 — 맥 터미널·Mail 설정과 같은 것, iSQL 에서 가져옴).
/// 설정 창 안에서 SwiftUI TabView 를 쓰면 안쪽 탭이 창 위 아이콘 탭줄로 끌려 올라가서 AppKit 것을 쓴다
struct BoxTabView: NSViewRepresentable {
    let titles: [String]
    @Binding var selection: Int
    let content: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTabView {
        let t = RetilingTabView()
        t.tabViewType = .topTabsBezelBorder
        for (i, title) in titles.enumerated() {
            let item = NSTabViewItem(identifier: i)
            item.label = title
            let host = NSHostingView(rootView: content(i))
            // 탭 칸 크기를 따르게 (SwiftUI 내용 크기로 탭 상자가 늘어나지 않게)
            host.sizingOptions = []
            item.view = host
            t.addTabViewItem(item)
        }
        t.selectTabViewItem(at: min(max(selection, 0), titles.count - 1))
        t.delegate = context.coordinator
        return t
    }

    func updateNSView(_ t: NSTabView, context: Context) {
        context.coordinator.parent = self
        if let sel = t.selectedTabViewItem, t.indexOfTabViewItem(sel) != selection, selection >= 0, selection < t.numberOfTabViewItems {
            t.selectTabViewItem(at: selection)
        }
    }

    final class Coordinator: NSObject, NSTabViewDelegate {
        var parent: BoxTabView
        init(_ p: BoxTabView) { parent = p }
        func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
            guard let item else { return }
            let i = tabView.indexOfTabViewItem(item)
            if parent.selection != i { DispatchQueue.main.async { self.parent.selection = i } }
        }
    }
}

/// 탭 너비를 다시 재는 NSTabView. 설정 창에서 다른 탭을 봤다 오면 상자가 거의 0 크기로 줄었다 커지는데,
/// NSTabView 는 줄었을 때 잰 탭 너비("텍…")를 그대로 둔다 (iSQL 에서 사용자 지적) → 폭이 바뀌거나 다시 보이면 다시 깐다
final class RetilingTabView: NSTabView {
    private var tiledWidth: CGFloat = -1

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width >= 200, abs(newSize.width - tiledWidth) > 0.5 { retile() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { self.retile() } }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        retile()
    }

    func retile() {
        tiledWidth = frame.width
        let type = tabViewType
        let selected = selectedTabViewItem
        tabViewType = .noTabsNoBorder
        tabViewType = type
        for item in tabViewItems { let l = item.label; item.label = ""; item.label = l }
        if let selected { selectTabViewItem(selected) }
        needsLayout = true
        needsDisplay = true
    }
}
