import SwiftUI
import AppKit

/// 메뉴 막대의 터미널 항목 (2026-11-21 사용자: iSQL 처럼 단축키가 있는 것은 모두 메뉴에).
/// 실제 일은 앞에 있는 터미널 창이 `focusedSceneValue(\.terminalCommands, …)` 로 넘긴다. 터미널 창이 아니면 nil → 흐려진다
struct TerminalCommands {
    var newTab: () -> Void
    var newWindow: () -> Void
    var closeTab: () -> Void
    var showTerminal: () -> Void
    var showFiles: () -> Void
    var moveTab: (Int) -> Void
    var reconnect: () -> Void
    var hasTab: Bool
    var tabCount: Int
}

extension FocusedValues {
    @Entry var terminalCommands: TerminalCommands?
    /// 파인더 모드에서 포커스가 있는 칸(이 맥 / 서버)의 목록 새로 고침. 칸에 포커스가 없으면 nil → 흐려진다
    @Entry var filePaneRefresh: (() -> Void)?
}

struct TerminalMenus: Commands {
    var body: some Commands {
        // 파일: 새 탭 ⌘T · 새 창 ⌘N (같은 서버를 지금 폴더에서)
        CommandGroup(replacing: .newItem) { FileNewItems() }
        // 탭 닫기 ⌘W (터미널 창이 아니면 창 닫기) · 창 닫기 ⌘⇧W
        CommandGroup(replacing: .saveItem) { FileCloseItems() }
        CommandGroup(before: .toolbar) { TerminalViewItems() }
        CommandGroup(before: .windowList) { TerminalWindowItems() }
    }
}

private struct FileNewItems: View {
    @FocusedValue(\.terminalCommands) private var c
    @ObservedObject private var closed = ClosedTabs.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("새 탭") { c?.newTab() }
            .keyboardShortcut("t")
            .disabled(c?.hasTab != true)
        Button("새 창") { c?.newWindow() }
            .keyboardShortcut("n")
            .disabled(c?.hasTab != true)
        // 브라우저·Finder 와 같은 ⌘⇧T (⌘Z 는 맥 전체 실행 취소라 겹쳐서 쓰지 않는다, 사용자와 정함)
        Button("닫은 탭 다시 열기") { closed.reopen(openWindow: openWindow) }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(closed.entries.isEmpty)
    }
}

private struct FileCloseItems: View {
    @FocusedValue(\.terminalCommands) private var c
    var body: some View {
        Button("탭 닫기") {
            if let c, c.hasTab { c.closeTab() } else { NSApp.keyWindow?.performClose(nil) }
        }
        .keyboardShortcut("w")
        Button("창 닫기") { NSApp.keyWindow?.performClose(nil) }
            .keyboardShortcut("w", modifiers: [.command, .shift])
    }
}

private struct TerminalViewItems: View {
    @FocusedValue(\.terminalCommands) private var c
    @FocusedValue(\.filePaneRefresh) private var refresh
    var body: some View {
        Button("터미널") { c?.showTerminal() }
            .keyboardShortcut("1")
            .disabled(c?.hasTab != true)
        Button("파인더") { c?.showFiles() }
            .keyboardShortcut("2")
            .disabled(c?.hasTab != true)
        Button("다시 접속") { c?.reconnect() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(c?.hasTab != true)
        Button("새로 고침") { refresh?() }
            .keyboardShortcut("r")
            .disabled(refresh == nil)
        Divider()
    }
}

private struct TerminalWindowItems: View {
    @FocusedValue(\.terminalCommands) private var c
    var body: some View {
        Button("이전 탭") { c?.moveTab(-1) }
            .keyboardShortcut("[")
            .disabled((c?.tabCount ?? 0) < 2)
        Button("다음 탭") { c?.moveTab(1) }
            .keyboardShortcut("]")
            .disabled((c?.tabCount ?? 0) < 2)
        Divider()
    }
}
