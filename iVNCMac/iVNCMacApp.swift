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
            SettingsView()
        }
    }
}

/// 보기 메뉴: 실제 크기·창에 맞춤 (지금 앞에 있는 접속 창에 알림으로 전한다)
struct SessionCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("실제 크기") { NotificationCenter.default.post(name: MacScreenNSView.actualSizeNotification, object: nil) }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}
