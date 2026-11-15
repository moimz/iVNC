import SwiftUI

@main
struct iVNCApp: App {
    @StateObject private var store = ComputerStore()

    init() {
        KeepAwake.installDebugSwitch()
        DebugLog.write("FreeRDP \(String(cString: ivnc_freerdp_version())) 링크됨")
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
