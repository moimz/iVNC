import AppKit
import ApplicationServices

/// 시스템 단축키(⌘Tab, ⌘Space, ⌃방향키, ⌘⇧3 등)를 원격으로 보낼지.
/// macOS 가 앱보다 먼저 가져가는 키라, 켜면 앱 밖에서 키 이벤트를 가로채(CGEventTap) 앞에 있는 접속 창에 넘긴다.
/// 가로채기는 "기기 제어 및 데이터 접근"(macOS 27, 예전 손쉬운 사용) 권한이 있어야 한다 (사용자가 시스템 설정에서 직접 켠다. 앱은 안내와 화면 열기만).
/// 한/영 전환(Caps Lock, ⌃Space, ⌃⌥Space)은 가로채지 않는다: 이 맥 입력 소스가 바뀌어야 원격도 맞춰진다.
@MainActor
final class SystemKeyCapture {
    static let shared = SystemKeyCapture()
    static let defaultsKey = "mac.systemKeysToRemote"

    static var toRemote: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// 키를 받을 화면 (앞에 있는 접속 창의 화면 뷰)
    weak var target: MacScreenNSView?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// 가로채기를 켜거나 끈다. 권한이 없으면 false
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        if !on { stop(); return true }
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            SystemKeyCapture.handle(type, event)
        }, userInfo: nil) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        DebugLog.write("시스템 단축키 가로채기 켬")
        return true
    }

    private func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
        DebugLog.write("시스템 단축키 가로채기 끔")
    }

    /// 시스템 설정의 "기기 제어 및 데이터 접근"(예전 이름 손쉬운 사용) 화면을 연다. 켜는 건 사용자가 직접.
    /// 목록에 iVNC 가 나오도록 먼저 한 번 권한을 확인해 둔다 (허락 창은 띄우지 않음)
    static func openPrivacySettings() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: false] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 탭 콜백 (메인 런루프). nil 을 돌려주면 그 키는 이 맥에서 없어진다
    nonisolated private static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 시스템이 탭을 꺼 버리면(느리거나 사용자 입력) 다시 켠다
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { if let t = shared.tap { CGEvent.tapEnable(tap: t, enable: true) } }
            return Unmanaged.passUnretained(event)
        }
        return MainActor.assumeIsolated { () -> Unmanaged<CGEvent>? in
            guard let view = shared.target, let w = view.window, w.isKeyWindow, NSApp.isActive,
                  let e = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // 한/영 전환은 이 맥에서 (Caps Lock, ⌃Space, ⌃⌥Space)
            if code == 57 { return Unmanaged.passUnretained(event) }
            if code == 49, flags.contains(.control), !flags.contains(.command), !flags.contains(.shift) {
                return Unmanaged.passUnretained(event)
            }
            switch type {
            case .keyDown: view.keyDown(with: e)
            case .keyUp: view.keyUp(with: e)
            case .flagsChanged: view.flagsChanged(with: e)
            default: return Unmanaged.passUnretained(event)
            }
            return nil
        }
    }
}

/// 클립보드 공유 (맥 앱). 원격에서 복사하면 이 맥 클립보드에 넣고,
/// 접속 창으로 돌아올 때 이 맥 클립보드가 바뀌어 있으면 원격으로 보낸다 (원격에서 바로 ⌘V 하게)
@MainActor
enum MacClipboard {
    static let defaultsKey = "mac.clipboardSharing"
    /// 기본 켬
    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// 마지막으로 주고받은 때의 이 맥 클립보드 번호 (같은 걸 다시 보내지 않게)
    private static var handledChangeCount = NSPasteboard.general.changeCount

    static func setFromRemote(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        handledChangeCount = pb.changeCount
    }

    /// 이 맥에서 새로 복사한 게 있으면 원격으로 (force: 접속 처음엔 지금 것을 보낸다)
    static func pushIfChanged(_ model: SessionModel, force: Bool = false) {
        guard enabled else { return }
        let pb = NSPasteboard.general
        guard force || pb.changeCount != handledChangeCount else { return }
        handledChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        model.sendClipboard(text)
    }
}
