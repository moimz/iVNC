import SwiftUI

/// 맥 앱: 컴퓨터 목록 창 하나 + 접속마다 창 하나
@main
struct iVNCMacApp: App {
    @StateObject private var store = ComputerStore()

    var body: some Scene {
        Window("iVNC", id: "home") {
            MacHomeView()
                .environmentObject(store)
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
        .commands { SessionCommands() }

        Settings {
            SettingsForm().frame(width: 360, height: 420)
        }
    }
}

/// 보기 메뉴: 실제 크기·창에 맞춤 (지금 앞에 있는 접속 창에 알림으로 전한다)
struct SessionCommands: Commands {
    @AppStorage(MacScreenNSView.KeyMode.defaultsKey) private var keyMode = MacScreenNSView.KeyMode.remote.rawValue
    @AppStorage(MacClipboard.defaultsKey) private var clipboardSharing = true
    @AppStorage(MacScreenNSView.hpCursorKey) private var hpCursorInVideo = true

    var body: some Commands {
        // 한글 조합을 어디서 할지
        CommandMenu("입력") {
            Picker("키 보내는 방식", selection: $keyMode) {
                ForEach(MacScreenNSView.KeyMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("클립보드 공유 (다음 접속부터)", isOn: $clipboardSharing)
            Toggle("고성능: 원격 커서를 영상으로 보기 (다음 접속부터)", isOn: $hpCursorInVideo)
        }
        CommandGroup(after: .toolbar) {
            Button("실제 크기") { NotificationCenter.default.post(name: MacScreenNSView.actualSizeNotification, object: nil) }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}

