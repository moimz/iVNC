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
    var body: some Commands {
        // 시험: 원격 맥 입력 소스(한영) 바꾸는 신호 후보. 앞에 있는 접속 창이 받는다
        CommandMenu("한영 시험") {
            ForEach(InputSwitchTest.allCases, id: \.self) { t in
                Button(t.title) { NotificationCenter.default.post(name: MacScreenNSView.inputSwitchTestNotification, object: t) }
            }
        }
        CommandGroup(after: .toolbar) {
            Button("실제 크기") { NotificationCenter.default.post(name: MacScreenNSView.actualSizeNotification, object: nil) }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}

/// 원격 입력 소스를 바꾸는 신호 후보 (시험용)
enum InputSwitchTest: CaseIterable {
    case hangulKeysym, ctrlSpace, ctrlOptSpace, capsTap, capsLong, fnGlobe

    var title: String {
        switch self {
        case .hangulKeysym: return "1. 한/영 키 (X Hangul 0xFF31)"
        case .ctrlSpace: return "2. ⌃Space (이전 입력 소스)"
        case .ctrlOptSpace: return "3. ⌃⌥Space (다음 입력 소스)"
        case .capsTap: return "4. Caps Lock 짧게 (키코드 57)"
        case .capsLong: return "5. Caps Lock 길게 1초 (키코드 57)"
        case .fnGlobe: return "6. fn/지구본 키 (키코드 63)"
        }
    }
}
