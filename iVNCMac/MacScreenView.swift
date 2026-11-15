import AppKit
import Carbon
import Combine
import SwiftUI

/// 원격 화면 (맥 앱). 창에 맞춰 비율을 지키며 그리고, 마우스·키보드를 원격으로 보낸다
struct MacScreenView: NSViewRepresentable {
    @ObservedObject var model: SessionModel
    /// 바뀌면 조합 중인 글자를 정리하고 입력 뷰 상태를 다시 잡는다
    var keyMode: String = ""

    func makeNSView(context: Context) -> MacScreenNSView {
        let v = MacScreenNSView(model: model)
        return v
    }

    func updateNSView(_ v: MacScreenNSView, context: Context) {
        v.updateCursor(model.cursorShape)
        v.keyModeChanged(keyMode)
    }
}

final class MacScreenNSView: NSView, NSTextInputClient {
    /// 보기 > 실제 크기 (앞에 있는 접속 창이 받는다)
    static let actualSizeNotification = Notification.Name("iVNC.actualSize")

    private let model: SessionModel
    private var renderer: ScreenRenderer { model.renderer }
    /// 원격 화면 픽셀 크기
    private var pixelSize = CGSize.zero
    private var cursor = NSCursor.arrow
    /// 조합 중인 글자 (한글)
    private var marked = NSMutableAttributedString()
    private var lastMove = Date.distantPast
    private var pressedButton: UInt8 = 0

    init(model: SessionModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(renderer.layer)
        renderer.onSizeChange = { [weak self] size in self?.sizeChanged(size) }
        if renderer.pixelSize != .zero { pixelSize = renderer.pixelSize }
        NotificationCenter.default.addObserver(self, selector: #selector(flushComposition), name: SessionModel.flushCompositionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(actualSize), name: Self.actualSizeNotification, object: nil)
        // 이 맥 입력 소스가 바뀌면(한영 전환) 원격도 맞춘다
        // 입력 소스 바뀜은 시스템 전체 알림으로 받는다 (이 뷰가 글자 입력 뷰가 아니어도 오게)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(localInputSourceChanged),
                                                            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        remoteSourceWatch = model.$remoteInputSource.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncInputSource(reason: "원격 알림") }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if let w = window {
            if w.isKeyWindow { SystemKeyCapture.shared.target = self }
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: w)
            NotificationCenter.default.addObserver(self, selector: #selector(releaseAll), name: NSWindow.didResignKeyNotification, object: w)
        }
        window?.acceptsMouseMovedEvents = true
        if pixelSize != .zero { fitWindow() }
    }

    // MARK: 그리기 자리: 비율을 지켜 가운데

    /// 원격 화면이 그려지는 사각형 (뷰 좌표)
    private var imageRect: CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return bounds }
        let s = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let w = pixelSize.width * s, h = pixelSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func layout() {
        super.layout()
        renderer.layout(bounds: imageRect)
        // 창이 원격 비율과 다르면(막대 높이를 잘못 잰 경우) 이 뷰 높이로 다시 맞춘다. 같은 크기에 두 번까지
        if let w = window, pixelSize.width > 0, bounds.height > 0, refits < 2, !inLiveResize,
           abs(bounds.width / bounds.height - pixelSize.width / pixelSize.height) > 0.01 {
            refits += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                SessionWindowSizer.of(w).fit(pixel: self.pixelSize, measuring: self)
            }
        }
    }
    private var refits = 0

    /// 원격 크기가 바뀌면(처음·모니터 바꿈) 창을 그 크기(1:1)와 비율로 맞춘다
    private func sizeChanged(_ size: CGSize) {
        guard size != pixelSize || window != nil else { return }
        pixelSize = size
        needsLayout = true
        fitWindow()
    }

    private func fitWindow() {
        guard let w = window, pixelSize.width > 0 else { return }
        refits = 0
        SessionWindowSizer.of(w).fit(pixel: pixelSize, measuring: self)
    }

    /// 이 창으로 돌아오면(다른 앱에서 입력 소스를 바꿨을 수 있다) 다시 맞춘다
    @objc private func windowBecameKey() {
        SystemKeyCapture.shared.target = self
        switchTries = 0
        DispatchQueue.main.async { [weak self] in self?.syncInputSource(reason: "창 돌아옴") }
    }

    // MARK: 한/영 맞추기
    // 원격 맥은 지금 입력 소스를 1109 로 알려 준다. 이 맥과 한/영이 다르면 원격에 ⌃Space(이전 입력 소스 선택)를 보낸다.
    // (2026-11-15 시험: Caps Lock·X Hangul 키는 원격에서 안 바뀌고 ⌃Space·⌃⌥Space 는 바뀜. 원격 맥에서 그 단축키가 켜져 있어야 한다)

    private var remoteSourceWatch: AnyCancellable?
    private var lastSwitchAt = Date.distantPast
    private var switchTries = 0

    private static func isKorean(_ id: String) -> Bool { id.contains("Korean") }

    /// 이 맥의 지금 입력 소스 ID (예: com.apple.inputmethod.Korean.2SetKorean)
    static func currentInputSourceID() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    // MARK: 키 보내는 방식 (시험)

    enum KeyMode: String, CaseIterable {
        /// 키를 누름·뗌 그대로 보내고 원격 맥 입력기가 조합한다 (기본).
        /// 원격이 한글이면 두벌식 그 자리의 자모를 유니코드 keysym 으로 보낸다: 서버는 받은 글자를 원격 자판에서 만드는 키를
        /// 찾아 누르므로 'ㅁ' 을 보내면 a 키가 눌려 입력기가 조합한다 ('a' 는 두벌식에 없어 글자 그대로 들어갔다).
        /// (2026-11-15 시험: 키 그대로(암호화·평문) 영어로만, 키 코드만 무시됨, X 한글 keysym 은 한글만 안 감, 유니코드 자모 성공)
        case remote
        /// 이 맥 입력기로 조합해 완성된 글자를 보낸다 (아이폰과 같은 방식)
        case local

        static let defaultsKey = "mac.keyMode"
        static var current: KeyMode { KeyMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .remote }
        var title: String {
            switch self {
            case .remote: return "키 입력을 원격 맥으로 바로 전송"
            case .local: return "키 조합 후 원격 맥으로 전송"
            }
        }
    }

    private var appliedKeyMode = ""

    /// 조합 위치를 바꾸면: 조합 중인 글자는 보내고, 눌린 키는 떼고, 글자 입력 뷰 여부를 다시 잡는다
    func keyModeChanged(_ mode: String) {
        guard mode != appliedKeyMode else { return }
        let first = appliedKeyMode.isEmpty
        appliedKeyMode = mode
        guard !first else { return }
        flushComposition()
        releaseAll()
        DebugLog.write("한글 조합 위치: \(KeyMode.current.title)")
        if let w = window, w.firstResponder === self {
            w.makeFirstResponder(nil)
            w.makeFirstResponder(self)
        }
    }

    /// 이 맥에서 조합하지 않을 때는 글자 입력 뷰가 아니게 한다 (입력 소스 바뀜 "A" 표시가 화면에 안 뜨게)
    override var inputContext: NSTextInputContext? {
        KeyMode.current == .local ? super.inputContext : nil
    }

    @objc private func localInputSourceChanged() {
        switchTries = 0
        syncInputSource(reason: "이 맥 전환")
    }

    private func syncInputSource(reason: String) {
        guard let w = window, w.isKeyWindow, w.firstResponder === self,
              let local = Self.currentInputSourceID(), let remote = model.remoteInputSource else { return }
        guard Self.isKorean(local) != Self.isKorean(remote) else { switchTries = 0; return }
        // 원격이 바뀌었다는 알림을 기다린다. 입력 소스가 셋 이상이면 한 번에 안 맞을 수 있어 세 번까지
        guard Date().timeIntervalSince(lastSwitchAt) > 0.8, switchTries < 3 else { return }
        switchTries += 1
        lastSwitchAt = Date()
        DebugLog.write("한/영 맞추기(\(reason)): 이 맥 \(local), 원격 \(remote) → 원격에 ⌃Space (\(switchTries)번째)")
        model.sendRawKey(0xFFE3, keycode: 59, down: true, name: "Control")
        model.sendRawKey(0x20, keycode: 49, down: true, name: "Space")
        model.sendRawKey(0x20, keycode: 49, down: false, name: "Space")
        model.sendRawKey(0xFFE3, keycode: 59, down: false, name: "Control")
        // 원격 알림이 안 오면(이미 같거나 단축키가 꺼짐) 1초 뒤 한 번 더 본다
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.syncInputSource(reason: "다시 확인") }
    }

    /// 보기 > 실제 크기: 원격 1픽셀 = 화면 1포인트 (화면에 안 들어가면 들어가는 만큼)
    @objc private func actualSize() {
        guard let w = window, w.isKeyWindow else { return }
        fitWindow()
    }

    // MARK: 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self))
    }

    /// 뷰 좌표 → 원격 픽셀 (그림 밖이면 가장자리로)
    private func pixel(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        let r = imageRect
        guard r.width > 0, pixelSize.width > 0 else { return .zero }
        // NSView 는 아래가 원점: 위에서부터로 뒤집는다
        let x = (p.x - r.minX) / r.width * pixelSize.width
        let y = (r.maxY - p.y) / r.height * pixelSize.height
        return CGPoint(x: min(max(x, 0), pixelSize.width - 1).rounded(.down), y: min(max(y, 0), pixelSize.height - 1).rounded(.down))
    }

    override func mouseMoved(with e: NSEvent) { move(e, force: false) }
    override func mouseDragged(with e: NSEvent) { move(e, force: false) }
    override func rightMouseDragged(with e: NSEvent) { move(e, force: false) }
    override func otherMouseDragged(with e: NSEvent) { move(e, force: false) }

    /// 이동은 초당 60번까지
    private func move(_ e: NSEvent, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastMove) >= 1.0 / 60 else { return }
        lastMove = now
        model.mouseMove(pixel(e))
    }

    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); press(e, button: 1) }
    override func rightMouseDown(with e: NSEvent) { press(e, button: 2) }
    override func otherMouseDown(with e: NSEvent) { press(e, button: 4) }
    override func mouseUp(with e: NSEvent) { release(e) }
    override func rightMouseUp(with e: NSEvent) { release(e) }
    override func otherMouseUp(with e: NSEvent) { release(e) }

    private func press(_ e: NSEvent, button: UInt8) {
        pressedButton = button
        model.mouseDown(pixel(e), button: button)
    }

    private func release(_ e: NSEvent) {
        guard pressedButton != 0 else { return }
        pressedButton = 0
        model.mouseUp(pixel(e))
    }

    /// 트랙패드·마우스 휠. 원격 맥 포인트 단위로 보낸다 (양수 dy = 아래로 = 내용이 위로)
    override func scrollWheel(with e: NSEvent) {
        let scale = CGFloat(max(model.selected?.scale ?? 1, 1))
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas { dx *= 10; dy *= 10 } // 휠 한 칸 = 줄 단위
        let phase: RFBClient.ScrollPhase
        switch e.phase {
        case .began, .mayBegin: phase = .began
        case .changed: phase = .changed
        case .ended, .cancelled: phase = .ended
        default: phase = .none
        }
        let momentum: RFBClient.MomentumPhase
        switch e.momentumPhase {
        case .began: momentum = .begin
        case .changed: momentum = .continue
        case .ended, .cancelled: momentum = .end
        default: momentum = .none
        }
        if dx == 0 && dy == 0 && phase == .none && momentum == .none { return }
        model.mouseScroll(-dx * scale, -dy * scale, phase: phase, momentum: momentum)
    }

    // MARK: 커서 모양 (원격이 알려 준 모양을 내 커서로)

    func updateCursor(_ shape: RFBClient.CursorShape?) {
        if let k = shape?.kind {
            cursor = Self.systemCursor(k)
        } else if let shape {
            let size = NSSize(width: CGFloat(shape.image.width) / shape.scale, height: CGFloat(shape.image.height) / shape.scale)
            let img = NSImage(cgImage: shape.image, size: size)
            cursor = NSCursor(image: img, hotSpot: NSPoint(x: shape.hotspot.x / shape.scale, y: shape.hotspot.y / shape.scale))
        } else {
            cursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
        if let w = window, w.isKeyWindow, let p = w.mouseLocationOutsideOfEventStream as NSPoint?, bounds.contains(convert(p, from: nil)) {
            cursor.set()
        }
    }

    /// 원격이 알려 준 미리 정해진 커서 번호 → 맥 기본 커서
    static func systemCursor(_ kind: UInt32) -> NSCursor {
        switch kind {
        case 1: return .iBeam
        case 2: return .crosshair
        case 3: return .openHand
        case 4: return .closedHand
        case 5: return .pointingHand
        case 8: return .operationNotAllowed
        case 9: return .closedHand // 이동 (맥에 따로 없음)
        case 10: return .resizeUpDown
        case 11: return .resizeLeftRight
        case 12: return .frameResize(position: .topRight, directions: .all)  // ⤢ 대각선 (앱 그림은 세로를 45° 돌린 것)
        case 13: return .frameResize(position: .topLeft, directions: .all)   // ⤡ 대각선
        default: return .arrow
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    // MARK: 키보드
    // 키를 이 맥 입력기에 거치지 않고 누름·뗌 그대로 보낸다 (키 자리 = 미국 자판 + 맥 키 코드).
    // 한글 조합은 원격 맥의 입력기가 한다 (한/영은 위 "한/영 맞추기"로 이 맥과 같게 둔다).

    /// 원격에 눌려 있다고 보낸 키 (keysym, 키 코드) — 창을 떠날 때 모두 뗀다
    private var held: [UInt16: UInt32] = [:]

    /// 조합키 키 코드 → keysym (애플 서버: Super_L = ⌘, Meta_L = ⌥)
    private static let modifierKeys: [UInt16: (keysym: UInt32, flag: NSEvent.ModifierFlags)] = [
        55: (0xFFEB, .command), 54: (0xFFEC, .command),
        56: (0xFFE1, .shift), 60: (0xFFE2, .shift),
        58: (0xFFE7, .option), 61: (0xFFE8, .option),
        59: (0xFFE3, .control), 62: (0xFFE4, .control),
    ]

    private func down(_ keysym: UInt32, _ code: UInt16, _ name: String) {
        held[code] = keysym
        model.sendRawKey(keysym, keycode: code, down: true, name: name)
    }

    private func up(_ keysym: UInt32, _ code: UInt16, _ name: String) {
        held[code] = nil
        model.sendRawKey(keysym, keycode: code, down: false, name: name)
    }

    /// 조합키 누름·뗌 (Caps Lock 은 보내지 않는다: 한/영은 입력 소스 맞추기로)
    override func flagsChanged(with e: NSEvent) {
        // 이 맥 조합 방식에서는 ⇧ 등을 원격에 눌러 두지 않는다 (완성 글자에 ⇧ 가 섞이지 않게). 조합은 ⌘·⌃ 키 때 함께 보낸다
        if KeyMode.current == .local {
            if held[e.keyCode] != nil, let m = Self.modifierKeys[e.keyCode] { up(m.keysym, e.keyCode, "조합키") }
            super.flagsChanged(with: e)
            return
        }
        if let m = Self.modifierKeys[e.keyCode] {
            let isDown = e.modifierFlags.contains(m.flag) && held[e.keyCode] == nil
            if isDown { down(m.keysym, e.keyCode, "조합키") } else if held[e.keyCode] != nil { up(m.keysym, e.keyCode, "조합키") }
        }
        super.flagsChanged(with: e)
    }

    /// ⌘·⌃ 조합은 메뉴보다 먼저 받아 원격으로 (⌘Q 도. 이 앱 끄기는 메뉴로). 조합키는 이미 눌려 있으니 키만 눌렀다 뗀다
    /// (⌘ 를 누른 동안의 keyUp 은 창에 안 올 때가 있어 바로 뗀다)
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown,
              e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) else { return super.performKeyEquivalent(with: e) }
        sendShortcut(e)
        return true
    }

    /// ⌘·⌃ 조합 키 하나 (메뉴 단축키 자리, 또는 시스템 단축키 가로채기에서)
    private func sendShortcut(_ e: NSEvent) {
        guard let ks = keysym(e) else { return }
        // 이 맥 조합 방식에서는 조합키를 미리 눌러 두지 않았으니 여기서 함께 누른다
        let mods = KeyMode.current == .local ? Self.modifierKeys.filter { $0.key == 55 || $0.key == 58 || $0.key == 59 || $0.key == 56 }
            .filter { e.modifierFlags.contains($0.value.flag) } : [:]
        for (code, m) in mods { down(m.keysym, code, "조합키") }
        down(ks, e.keyCode, "조합 키")
        up(ks, e.keyCode, "조합 키")
        for (code, m) in mods { up(m.keysym, code, "조합키") }
    }

    override func keyDown(with e: NSEvent) {
        // 시스템 단축키 가로채기로 온 ⌘·⌃ 조합 (보통은 performKeyEquivalent 로 온다)
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) {
            sendShortcut(e)
            return
        }
        let mode = KeyMode.current
        if mode == .local, Self.specialKeysym(e.keyCode) == nil || marked.length > 0 {
            // 이 맥 입력기로 조합 → insertText 로 완성 글자를 보낸다 (조합 중 특수 키도 입력기가 먼저)
            interpretKeyEvents([e])
            return
        }
        guard let ks = keysym(e) else { return }
        if mode == .local {
            // 특수 키(방향·엔터 등): ⇧·⌥ 와 함께 눌렀다 뗀다 (⇧ 방향키로 고르기 등)
            let mods = Self.modifierKeys.filter { [56, 58].contains($0.key) && e.modifierFlags.contains($0.value.flag) }
            for (code, m) in mods { down(m.keysym, code, "조합키") }
            down(ks, e.keyCode, "키"); up(ks, e.keyCode, "키")
            for (code, m) in mods { up(m.keysym, code, "조합키") }
            return
        }
        down(ks, e.keyCode, e.isARepeat ? "반복" : "키") // 길게 누르면 누름이 거듭 간다 (원격이 반복)
    }

    override func keyUp(with e: NSEvent) {
        guard let ks = held[e.keyCode] else { return } // 누름을 보낸 키만 뗀다 (이 맥 조합 글자는 누름·뗌 없이 완성 글자로 갔다)
        up(ks, e.keyCode, "키")
    }

    /// 창을 떠나면 눌린 채로 남지 않게 모두 뗀다
    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    @objc private func releaseAll() {
        for (code, ks) in held { up(ks, code, "떠나며 뗌") }
    }

    /// 키 → keysym: 특수 키, 아니면 미국 자판 자리의 글자 (⇧ 를 누르고 있으면 윗글자. X 관례)
    private func keysym(_ e: NSEvent) -> UInt32? {
        if let s = Self.specialKeysym(e.keyCode) { return s }
        guard let c = Self.usKey(e.keyCode) else {
            return e.charactersIgnoringModifiers?.unicodeScalars.first.map { $0.value < 0x100 ? $0.value : 0x0100_0000 | $0.value }
        }
        let ch = e.modifierFlags.contains(.shift) ? Self.usShifted(c) : c
        // 원격이 한글 입력이면 두벌식 그 자리의 자모 (유니코드 keysym). ⌘·⌃ 조합은 키 자리 그대로 (⌘C 등)
        if model.remoteInputSource?.contains("Korean") == true,
           !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control),
           let j = Self.dubeolsik[ch]?.unicodeScalars.first?.value {
            return 0x0100_0000 | j
        }
        return ch.unicodeScalars.first!.value
    }

    /// 두벌식: 미국 자판 글자 → 한글 자모 (⇧ 쌍자음·ㅒㅖ)
    static let dubeolsik: [String: String] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ", "O": "ㅒ", "P": "ㅖ",
        "Y": "ㅛ", "U": "ㅕ", "I": "ㅑ", "A": "ㅁ", "S": "ㄴ", "D": "ㅇ", "F": "ㄹ", "G": "ㅎ", "H": "ㅗ", "J": "ㅓ", "K": "ㅏ", "L": "ㅣ",
        "Z": "ㅋ", "X": "ㅌ", "C": "ㅊ", "V": "ㅍ", "B": "ㅠ", "N": "ㅜ", "M": "ㅡ",
    ]

    /// 미국 자판 ⇧ 윗글자
    static func usShifted(_ c: String) -> String {
        let map: [String: String] = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
                                     "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~"]
        return map[c] ?? c.uppercased()
    }

    /// 맥 키 코드 → 미국 자판 글자 (조합키와 함께 보낼 때. 입력 소스와 상관없이 키 자리 기준)
    static func usKey(_ code: UInt16) -> String? {
        let map: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "n", 46: "m", 47: ".", 49: " ", 50: "`",
        ]
        return map[code]
    }

    /// 맥 키 코드 → X keysym (글자가 아닌 키)
    static func specialKeysym(_ code: UInt16) -> UInt32? {
        switch code {
        case 36, 76: return 0xFF0D  // Return, Enter
        case 48: return 0xFF09      // Tab
        case 51: return 0xFF08      // Delete(BackSpace)
        case 117: return 0xFFFF     // Forward Delete
        case 53: return 0xFF1B      // Esc
        case 123: return 0xFF51     // ←
        case 126: return 0xFF52     // ↑
        case 124: return 0xFF53     // →
        case 125: return 0xFF54     // ↓
        case 115: return 0xFF50     // Home
        case 119: return 0xFF57     // End
        case 116: return 0xFF55     // Page Up
        case 121: return 0xFF56     // Page Down
        case 122: return 0xFFBE; case 120: return 0xFFBF; case 99: return 0xFFC0; case 118: return 0xFFC1 // F1~F4
        case 96: return 0xFFC2; case 97: return 0xFFC3; case 98: return 0xFFC4; case 100: return 0xFFC5   // F5~F8
        case 101: return 0xFFC6; case 109: return 0xFFC7; case 103: return 0xFFC8; case 111: return 0xFFC9 // F9~F12
        default: return nil
        }
    }

    /// 입력기가 조합을 끝내고 엔터·지우기 등을 넘길 때
    override func doCommand(by selector: Selector) {
        let map: [Selector: UInt32] = [
            #selector(insertNewline(_:)): 0xFF0D, #selector(insertTab(_:)): 0xFF09,
            #selector(deleteBackward(_:)): 0xFF08, #selector(deleteForward(_:)): 0xFFFF,
            #selector(cancelOperation(_:)): 0xFF1B,
            #selector(moveLeft(_:)): 0xFF51, #selector(moveUp(_:)): 0xFF52, #selector(moveRight(_:)): 0xFF53, #selector(moveDown(_:)): 0xFF54,
        ]
        if let ks = map[selector] { model.sendKey(ks, name: NSStringFromSelector(selector)) }
    }

    @objc private func flushComposition() {
        guard marked.length > 0 else { return }
        let text = marked.string
        unmarkText()
        inputContext?.discardMarkedText()
        model.sendText(text)
    }

    // MARK: NSTextInputClient (한글 조합)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSMutableAttributedString()
        model.composing = ""
        if !text.isEmpty { model.sendText(text) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSMutableAttributedString(string: s)
        model.composing = s
    }

    func unmarkText() {
        marked = NSMutableAttributedString()
        model.composing = ""
    }

    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// 입력기 후보 창 자리: 그림 아래쪽 가운데
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let r = imageRect
        let local = NSRect(x: r.midX, y: r.minY + 40, width: 1, height: 20)
        return window?.convertToScreen(convert(local, to: nil)) ?? .zero
    }
}
