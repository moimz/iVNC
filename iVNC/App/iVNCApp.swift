import SwiftUI

@main
struct iVNCApp: App {
    @StateObject private var store = ComputerStore()

    init() {
        KeepAwake.installDebugSwitch()
        // SSH 설정을 맥·다른 기기와 맞춘다 (글자 크기 제외)
        TerminalSettingsSync.shared.start()
        DebugLog.write("FreeRDP \(String(cString: ivnc_freerdp_version())) 링크됨")
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
