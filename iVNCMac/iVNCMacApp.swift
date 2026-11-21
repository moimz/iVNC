import SwiftUI

/// 맥 앱: 컴퓨터 목록 창 하나 + 접속마다 창 하나
@main
struct iVNCMacApp: App {
    @StateObject private var store = ComputerStore()
    @NSApplicationDelegateAdaptor private var appDelegate: MacAppDelegate

    init() {
        DebugLog.write("FreeRDP \(String(cString: ivnc_freerdp_version())) 링크됨")
        _ = Updater.shared // 자동 업데이트 시작 (하루 한 번 확인)
    }

    var body: some Scene {
        Window("iVNC", id: "home") {
            MacHomeView()
                .environmentObject(store)
                // MCP 서버 (설정 > MCP 에서 켰으면)
                .onAppear { MCPServer.shared.store = store; MCPServer.shared.startIfEnabled() }
        }
        .defaultSize(width: 760, height: 520)

        // 접속 창: 컴퓨터 id 로 연다 (같은 컴퓨터는 이미 열린 창으로 간다)
        WindowGroup("접속", id: "session", for: UUID.self) { $id in
            if let id, let computer = store.computers.first(where: { $0.id == id }) {
                MacSessionView(computer: computer)
                    .environmentObject(store)
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            SessionCommands()
            CommandGroup(after: .appInfo) { UpdateMenuButton() }
        }

        // SSH 터미널 창: 열 때마다 새 창 (창마다 탭·분할)
        WindowGroup("SSH", id: "terminal", for: TerminalWindowRequest.self) { $req in
            if let req {
                TerminalWindowView(request: req)
                    .environmentObject(store)
            }
        }
        .defaultSize(width: 760, height: 480)
        .commands { TerminalMenus() }

        Settings {
            MacSettingsView()
        }
    }
}

/// 컴퓨터 목록 창 다시 열기. 열린 창(목록·접속)이 SwiftUI 의 openWindow 를 여기에 맡겨 둔다
@MainActor enum HomeWindow {
    static var open: (() -> Void)?
    /// 목록 창이 보임 (닫혔거나 Dock 으로 내렸으면 아님). inPlayer 와 같은 방식: SwiftUI 창 식별자는 장면 id 로 시작한다
    static var isVisible: Bool {
        NSApp.windows.contains { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("home") ?? false) }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Dock 아이콘을 누름: 접속 창만 떠 있으면 macOS 는 목록 창을 다시 열어 주지 않으므로 직접 연다
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !HomeWindow.isVisible { HomeWindow.open?() }
        return true
    }
}

/// 보기 메뉴: 실제 크기·창에 맞춤 (지금 앞에 있는 접속 창에 알림으로 전한다)
struct SessionCommands: Commands {
    @AppStorage(MacScreenNSView.KeyMode.defaultsKey) private var keyMode = MacScreenNSView.KeyMode.remote.rawValue
    @AppStorage(MacClipboard.defaultsKey) private var clipboardSharing = true

    var body: some Commands {
        // 한글 조합을 어디서 할지
        CommandMenu("입력") {
            Picker("키 보내는 방식", selection: $keyMode) {
                ForEach(MacScreenNSView.KeyMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("클립보드 공유 (다음 접속부터)", isOn: $clipboardSharing)
        }
        CommandGroup(after: .toolbar) {
            Button("실제 크기") { NotificationCenter.default.post(name: MacScreenNSView.actualSizeNotification, object: nil) }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}

