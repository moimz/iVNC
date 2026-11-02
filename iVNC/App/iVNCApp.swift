import SwiftUI

@main
struct iVNCApp: App {
    @StateObject private var store = ComputerStore()

    init() {
        KeepAwake.installDebugSwitch()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
