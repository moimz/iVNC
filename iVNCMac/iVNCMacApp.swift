import SwiftUI

/// 맥 앱: 컴퓨터 목록 창 하나 + 접속마다 창 하나
@main
struct iVNCMacApp: App {
    @StateObject private var store = ComputerStore()
    @NSApplicationDelegateAdaptor private var appDelegate: MacAppDelegate

    init() {
        DebugLog.write("FreeRDP \(String(cString: ivnc_freerdp_version())) 링크됨")
        _ = Updater.shared // 자동 업데이트 시작 (하루 한 번 확인)
        // SSH 설정을 아이폰·아이패드와 맞춘다 (글자 크기 제외)
        TerminalSettingsSync.shared.start()
    }

    /// 새 이슈 화면, 본문에 앱 · macOS 버전만 미리 채운다 (개인 정보는 넣지 않는다)
    private static var issueURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var c = URLComponents(string: "https://github.com/moimz/iVNC/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: "\n\n---\niVNC \(SettingsForm.versionValue) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")]
        return c.url!
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
            // iVNC에 관하여: 기본 정보 창 그대로, 버전 줄만 Ai.md 모양 "2.6 (빌드 178 · 3fa9740)" (사용자 2026-11-26)
            CommandGroup(replacing: .appInfo) {
                Button("iVNC에 관하여") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: SettingsForm.versionValue,
                        .version: "",
                    ])
                    NSApp.activate(ignoringOtherApps: true)
                }
                UpdateMenuButton()
            }
            // 도움말: 저장소 · 문제 신고 (Ai.md "도움말 메뉴", 도움말 책이 없어 기본 "iVNC 도움말" 은 뺀다)
            CommandGroup(replacing: .help) {
                Button("iVNC GitHub 페이지") { NSWorkspace.shared.open(URL(string: "https://github.com/moimz/iVNC")!) }
                Button("문제 신고…") { NSWorkspace.shared.open(Self.issueURL) }
            }
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

    /// 꺼지기 직전(종료 알림보다 먼저): 끌기 약속을 채우려고 서버에서 받지 않게 한다 (RemoteDrag.terminating)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RemoteDrag.terminating = true
        return .terminateNow
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

