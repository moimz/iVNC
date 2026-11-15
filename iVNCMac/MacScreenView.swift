import AppKit
import SwiftUI

/// 원격 화면 (맥 앱). 창에 맞춰 비율을 지키며 그리고, 마우스·키보드를 원격으로 보낸다
struct MacScreenView: NSViewRepresentable {
    @ObservedObject var model: SessionModel

    func makeNSView(context: Context) -> MacScreenNSView {
        let v = MacScreenNSView(model: model)
        return v
    }

    func updateNSView(_ v: MacScreenNSView, context: Context) {
        v.updateCursor(model.cursorShape)
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
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
        if let shape {
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

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    // MARK: 키보드

    /// ⌘ 조합은 메뉴보다 먼저 받아 모두 원격으로 보낸다 (⌘Q 도. 이 앱 끄기는 메뉴로)
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown else { return super.performKeyEquivalent(with: e) }
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) {
            sendCombo(e)
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    /// 한영 전환(Caps Lock): 이 맥의 입력 소스가 바뀌는 것과 함께 원격에도 Caps Lock 을 눌렀다 뗀다
    /// (원격 맥도 Caps Lock 으로 입력 소스를 바꾸게 설정돼 있으면 같이 바뀐다)
    override func flagsChanged(with e: NSEvent) {
        if e.keyCode == 57 {
            // 한영 전환 모드에서는 한 번 누를 때 켬(누름)·끔(뗌)이 0.1초 간격으로 온다 → 누름/뗌으로 그대로 보낸다
            // (예전엔 매번 눌렀다 떼서 원격엔 두 번 눌린 셈이었다). 맥 키 코드 57 도 함께 싣는다
            let on = e.modifierFlags.contains(.capsLock)
            DebugLog.write("Caps Lock (한영) 이 맥 상태 \(on ? "켬" : "끔") → 원격 \(on ? "누름" : "뗌")")
            model.sendRawKey(0xFFE5, keycode: 57, down: on, name: "Caps_Lock")
        }
        super.flagsChanged(with: e)
    }

    override func keyDown(with e: NSEvent) {
        let flags = e.modifierFlags.intersection([.command, .control, .option, .shift])
        // 조합 중이 아니면 특수 키(방향·엔터·지우기 등)는 조합키와 함께 바로 보낸다
        if marked.length == 0, let ks = Self.specialKeysym(e.keyCode) {
            sendCombo(e, keysym: ks)
            return
        }
        if flags.contains(.command) || flags.contains(.control) {
            sendCombo(e)
            return
        }
        // 글자는 이 맥의 입력기(한글 등)를 거쳐 완성된 글자로 보낸다
        interpretKeyEvents([e])
    }

    private func modifierKeysyms(_ flags: NSEvent.ModifierFlags) -> [UInt32] {
        var m: [UInt32] = []
        if flags.contains(.command) { m.append(0xFFEB) } // Super_L = ⌘ (애플 서버)
        if flags.contains(.option) { m.append(0xFFE7) }  // Meta_L = ⌥
        if flags.contains(.control) { m.append(0xFFE3) }
        if flags.contains(.shift) { m.append(0xFFE1) }
        return m
    }

    private func sendCombo(_ e: NSEvent, keysym: UInt32? = nil) {
        let mods = modifierKeysyms(e.modifierFlags)
        let key: UInt32
        if let keysym { key = keysym }
        else if let s = Self.specialKeysym(e.keyCode) { key = s }
        // 조합은 키 자리(미국 자판)로: 한글 입력 중이면 글자가 "ㅂ"으로 나와 ⌘Q·⌘C 가 원격에서 안 들었다
        else if let c = Self.usKey(e.keyCode) { key = c.unicodeScalars.first!.value }
        else if let c = e.charactersIgnoringModifiers?.lowercased().unicodeScalars.first { key = c.value < 0x100 ? c.value : 0x0100_0000 | c.value }
        else { return }
        let name = Self.usKey(e.keyCode) ?? e.charactersIgnoringModifiers ?? ""
        if mods.isEmpty {
            model.sendKey(key, name: name)
        } else {
            model.sendCombo(mods, key, name: name)
        }
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
