import Foundation

/// 화면 보호기 막기 스위치. 기본은 켜짐.
/// Debug 빌드는 시뮬레이터 밖에서 켜고 끌 수 있다:
/// `xcrun simctl spawn <기기> notifyutil -p com.moimz.iVNC.debug.keepAwake.on` (또는 .off)
enum KeepAwake {
    private static let lock = NSLock()
    private static var value = true

    static var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }

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
            KeepAwake.enabled = true
            DebugLog.write("화면 보호기 막기: 켬 (디버그 신호)")
        }, "com.moimz.iVNC.debug.keepAwake.on" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            KeepAwake.enabled = false
            DebugLog.write("화면 보호기 막기: 끔 (디버그 신호)")
        }, "com.moimz.iVNC.debug.keepAwake.off" as CFString, nil, .deliverImmediately)
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
