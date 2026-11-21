import AppKit
import SwiftTerm

/// 한글 조합을 맥 기본 터미널처럼 보이게 (2026-11-21 사용자 화면 기록 두 개).
///
/// SwiftTerm 은 조합 중인 글자를 칸과 상관없는 글상자(DictationOverlayTextView)로 그려서
/// ① 한글이 2칸 가운데가 아니라 앞 글자에 바짝 붙고 ② 밑줄 대신 회색 상자였다.
/// 또 원격이라 확정한 글자는 서버가 되돌려 보내야(에코) 찍히는데 조합 글자는 지금 커서에 바로 그려
/// ③ 에코가 오기 전에는 방금 확정한 글자 자리에 겹쳤다가 옆으로 뛰었다 ("동무" → "동해무").
///
/// → SwiftTerm 겹창은 숨기고 조합 글자를 직접 그린다: 글자마다 칸 너비(한글 2칸) 가운데, 밑줄.
///   자리는 커서 + "확정했지만 아직 에코가 안 온 칸 수" (예측 위치).
final class IMETerminalView: TerminalView {
    private let preedit = PreeditView()
    private var marked = ""
    /// 확정해서 보냈지만 아직 화면에 안 찍힌 글자 (앞에서부터 에코가 오면 지운다).
    /// 한글처럼 ASCII 가 아닌 글자는 에코가 올 때까지 대신 그려 준다 — "물" 을 확정하고 "고" 를 조합할 때
    /// "물" 이 사라졌다 나타나지 않게 (사용자). ASCII 는 그리지 않고 자리만 비운다 (비밀번호처럼 에코가 없는 입력이 보이면 안 되니까)
    private var pending: [Character] = []
    /// 지난번에 본 커서 자리 (에코로 몇 칸 나아갔는지 보려고)
    private var lastCaret: NSPoint?
    private var pendingReset: DispatchWorkItem?

    /// 파인더 도우미 한 줄을 셸에 넣는 동안 사용자 입력을 막는다 (TerminalTab.send 에서 버림. keyDown 은 밖에서 못 바꾼다)
    var inputLocked = false

    /// SwiftTerm 은 받은 글자를 화면 주기(디스플레이 링크)에 그리고 커서도 그때 옮긴다.
    /// 그래서 feed 바로 뒤에 커서를 읽으면 옛 자리라 "동" 이 두 번 보였다 ("동동해", 사용자) →
    /// 대신 그릴 글자나 조합 글자가 있는 동안 화면 주기마다 커서를 보고 맞춘다
    private var link: CADisplayLink?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if pending.isEmpty { lastCaret = caret?.origin }
        super.insertText(string, replacementRange: replacementRange)
        marked = ""
        // 줄바꿈·제어 문자는 커서를 엉뚱하게 옮기니 예측을 접는다
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            clearPending()
        } else {
            pending += Array(text)
            pendingReset?.cancel()
            // 에코가 영영 안 오는 경우(비밀번호 입력 등) 예측을 접는다
            let w = DispatchWorkItem { [weak self] in self?.clearPending(); self?.layoutPreedit() }
            pendingReset = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        }
        layoutPreedit()
        startLink()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        layoutPreedit()
        startLink()
    }

    override func unmarkText() {
        super.unmarkText()
        marked = ""
        layoutPreedit()
    }

    /// 서버에서 온 글자를 받은 뒤 부른다 (TerminalTab.onData). 실제 맞추기는 화면 주기에서
    func echoArrived() { startLink() }

    private func startLink() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        sync()
        if pending.isEmpty && marked.isEmpty { link?.invalidate(); link = nil }
    }

    /// 커서가 나아간 칸만큼 대신 그리던 글자를 앞에서 지운다
    private func sync() {
        guard !pending.isEmpty, let now = caret?.origin else { layoutPreedit(); return }
        if let before = lastCaret, abs(before.y - now.y) < 1, now.x >= before.x, let cw = cellWidth, cw > 0 {
            var advanced = Int(((now.x - before.x) / cw).rounded())
            while advanced > 0, let c = pending.first {
                advanced -= Self.cells(String(c))
                pending.removeFirst()
            }
            lastCaret = now
        } else {
            clearPending()   // 줄이 바뀌었거나 뒤로 갔으면 예측을 접는다
        }
        if pending.isEmpty { pendingReset?.cancel(); lastCaret = nil }
        layoutPreedit()
    }

    private func clearPending() {
        pending = []
        lastCaret = nil
        pendingReset?.cancel()
    }

    // MARK: 그리기

    private func layoutPreedit() {
        // SwiftTerm 겹창은 늘 숨긴다 (밖에서 못 보는 형식이라 이름으로 찾는다)
        for v in subviews where String(describing: type(of: v)).contains("DictationOverlay") { v.isHidden = true }
        // 대신 그릴 확정 글자: ASCII 아닌 것만 글자로, ASCII 는 빈칸 (자리만)
        let shown = pending.map { c -> PreeditView.Piece in
            c.unicodeScalars.allSatisfy({ $0.value >= 0x80 }) ? .init(text: String(c), underline: false) : .init(text: " ", underline: false, cells: Self.cells(String(c)))
        }
        let hasVisiblePending = pending.contains { $0.unicodeScalars.allSatisfy { $0.value >= 0x80 } }
        guard !marked.isEmpty || hasVisiblePending, let caret = caret, let cw = cellWidth else {
            preedit.isHidden = true
            return
        }
        if preedit.superview !== self { addSubview(preedit, positioned: .above, relativeTo: nil) }
        let pieces = shown + marked.map { PreeditView.Piece(text: String($0), underline: true) }
        let cells = pieces.reduce(0) { $0 + $1.cells }
        var x = caret.origin.x
        x = min(x, max(0, bounds.width - CGFloat(cells) * cw))
        preedit.pieces = pieces
        preedit.font = font
        preedit.cellWidth = cw
        preedit.foreground = nativeForegroundColor
        preedit.background = nativeBackgroundColor
        preedit.frame = NSRect(x: x, y: caret.origin.y, width: CGFloat(cells) * cw, height: caret.height)
        preedit.isHidden = false
        preedit.needsDisplay = true
    }

    /// 커서 자리 (SwiftTerm 의 공개 caretFrame, 높이 = 한 줄). 아직 없으면 nil
    private var caret: NSRect? {
        let f = caretFrame
        return f.height > 0 ? f : nil
    }

    /// 한 칸 너비: SwiftTerm 과 같은 식 ("W" 너비를 화면 픽셀에 맞춤)
    private var cellWidth: CGFloat? {
        let scale = window?.backingScaleFactor ?? 2
        let w = ("W" as NSString).size(withAttributes: [.font: font]).width
        return w > 0 ? (w * scale).rounded() / scale : nil
    }

    /// 글자가 차지하는 칸 수 (한글 2칸)
    static func cells(_ s: String) -> Int { TerminalSettings.cellCount(s) }
}

/// 에코를 기다리는 확정 글자 + 조합 중인 글자: 글자마다 칸 너비 가운데, 조합 글자만 밑줄 (맥 기본 터미널처럼)
private final class PreeditView: NSView {
    struct Piece {
        var text: String
        var underline: Bool
        var cells: Int
        init(text: String, underline: Bool, cells: Int? = nil) {
            self.text = text; self.underline = underline
            self.cells = cells ?? max(1, TerminalSettings.cellCount(text))
        }
    }
    var pieces: [Piece] = []
    var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    var cellWidth: CGFloat = 8
    var foreground = NSColor.textColor
    var background = NSColor.textBackgroundColor

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 아래 칸(커서·옛 글자)을 가린다
        background.setFill()
        bounds.fill()
        var x: CGFloat = 0
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        for p in pieces {
            let w = CGFloat(p.cells) * cellWidth
            let s = p.text as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: x + (w - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            if p.underline {
                foreground.withAlphaComponent(0.85).setFill()
                NSRect(x: x, y: bounds.height - 1.5, width: w, height: 1).fill()
            }
            x += w
        }
    }
}
