import Foundation

/// 디버그 스위치 모음. (화면 보호기 막기는 2026-11-07 뺐다: 맥 잠금을 못 막고 트래픽만 쓴다)
enum KeepAwake {
    private static let lock = NSLock()

    /// 키 입력 우선(키를 치는 동안 자동 화면 갱신 끄기). 기본 켜짐.
    /// Debug: `notifyutil -p com.moimz.iVNC.debug.typingPriority.on` (또는 .off)
    private static var typingValue = true
    static var typingPriority: Bool {
        get { lock.lock(); defer { lock.unlock() }; return typingValue }
        set { lock.lock(); typingValue = newValue; lock.unlock() }
    }

    static func installDebugSwitch() {
        #if DEBUG
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            KeepAwake.typingPriority = true
            DebugLog.write("키 입력 우선: 켬 (디버그 신호)")
        }, "com.moimz.iVNC.debug.typingPriority.on" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            KeepAwake.typingPriority = false
            DebugLog.write("키 입력 우선: 끔 (디버그 신호)")
        }, "com.moimz.iVNC.debug.typingPriority.off" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            RFBClient.current?.debugRequestFull()
        }, "com.moimz.iVNC.debug.requestFull" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            RFBClient.current?.debugMoveMouse()
        }, "com.moimz.iVNC.debug.moveMouse" as CFString, nil, .deliverImmediately)
        #endif
    }
}
