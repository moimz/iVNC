import SwiftUI
import UIKit

/// 화면에 안 보이는 입력창. 아이폰 키보드로 친 글자를 원격 맥으로 보낸다.
///
/// 맥은 아이폰 키보드가 한글인지 모르므로 자모(ㅇ ㅏ ㄴ)를 보내면 그대로 찍힌다.
/// 그래서 여기서 글자를 조합하고, 조합이 끝난 글자만 완성형("안")으로 보낸다.
/// "안녕" 을 치면 ㅇ ㅏ ㄴ ㄴ 에서 "안" 이 끝났음을 알고 "안" 을 보내고, "녕" 은 다음 글자나 띄어쓰기·엔터 때 보낸다.
struct KeyInputField: UIViewRepresentable {
    @Binding var active: Bool
    let onText: (String) -> Void
    let onBackspace: (Int) -> Void
    let onReturn: () -> Void
    /// 아직 맥으로 안 보낸 조합 중 글자 (화면에 보여 주려고)
    var onPending: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> HangulInputField {
        let f = HangulInputField()
        f.onEnd = { DispatchQueue.main.async { active = false } }
        return f
    }

    func updateUIView(_ f: HangulInputField, context: Context) {
        f.onText = onText
        f.onBackspace = onBackspace
        f.onReturn = onReturn
        f.onPending = onPending
        if active && !f.isFirstResponder {
            DispatchQueue.main.async { f.becomeFirstResponder() }
        } else if !active && f.isFirstResponder {
            DispatchQueue.main.async { f.resignFirstResponder() }
        }
    }
}

final class HangulInputField: UITextField, UITextFieldDelegate {
    var onText: (String) -> Void = { _ in }
    var onBackspace: (Int) -> Void = { _ in }
    var onReturn: () -> Void = {}
    var onEnd: () -> Void = {}
    var onPending: (String) -> Void = { _ in }
    /// 입력창 안에서 이미 맥으로 보낸 부분
    private var sent = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        returnKeyType = .default
        tintColor = .clear
        textColor = .clear
        addTarget(self, action: #selector(changed), for: .editingChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(inputModeChanged), name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inputModeChanged), name: Self.flushNotification, object: nil)
    }

    /// 조합 중인 글자를 지금 보내라는 알림 (마우스를 누르기 직전: 클릭으로 맥의 포커스가 옮겨 가기 전에 원래 입력창에 넣는다)
    static let flushNotification = Notification.Name("iVNC.flushComposition")

    /// 키보드를 바꾸거나 마우스를 누르기 직전: 조합 중이라 안 보낸 글자를 바로 보내고 비운다
    @objc private func inputModeChanged() {
        guard isFirstResponder, !(text ?? "").isEmpty else { return }
        unmarkText()
        sync(final: true)
        reset()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 입력창이 비어 있을 때 지우기: 맥 쪽 글자를 지운다
    override func deleteBackward() {
        if (text ?? "").isEmpty { onBackspace(1) }
        super.deleteBackward()
    }

    @objc private func changed() { sync(final: false) }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sync(final: true)
        onReturn()
        reset()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        sync(final: true)
        reset()
        onEnd()
    }

    private func reset() {
        text = ""
        sent = ""
        lastText = ""
        onPending("")
    }

    /// 조합이 끝난 부분: 키보드가 조합 중(marked text)이라고 알려 주면 그 앞까지,
    /// 아니면 마지막 글자가 한글일 때 그 글자는 아직 받침·겹모음이 붙을 수 있으니 뺀다.
    private func committed(final: Bool) -> String {
        let t = text ?? ""
        if final { return t }
        if let marked = markedTextRange,
           let before = textRange(from: beginningOfDocument, to: marked.start) {
            return text(in: before) ?? ""
        }
        // 지우기만 했으면(지금 글이 보낸 글의 앞부분) 남은 글자는 이미 확정된 것이다
        if sent.hasPrefix(t) { return t }
        guard let last = t.unicodeScalars.last, Self.isHangul(last) else { return t }
        return String(t.dropLast())
    }

    /// 보낸 것과 지금 확정된 것을 비교해 다른 부분만 지우고 다시 보낸다 (자동 고침 등으로 앞 글자가 바뀌어도 맞춰진다)
    /// 직전 입력창 내용 (키보드가 보낸 글자를 끌어왔는지 보려고)
    private var lastText = ""

    private func sync(final: Bool) {
        let now = text ?? ""
        // 입력창에는 조합 중인 글자만 남기는데(아래), 아이폰 키보드는 자기 조합 기록으로 지우기 때 이미 보낸 앞 글자를 끌어온다
        // ("도레미파" 에서 파를 지우면 "밒": ㅁ 은 이미 보낸 "미" 의 것). 첫 자음이 바뀌면 그런 경우다:
        // 맥에서 그 글자를 지우고, 끌어온 글자를 조합 중으로 둔다. 결과는 메모 앱과 같다
        if !final, sent.isEmpty, now.count == 1, lastText.count == 1,
           let a = Self.initial(lastText.unicodeScalars.first!), let b = Self.initial(now.unicodeScalars.first!),
           a != b, now.unicodeScalars.first!.value >= 0xAC00 {
            onBackspace(1)
        }
        let c = Array(committed(final: final)), s = Array(sent)
        var p = 0
        while p < min(c.count, s.count) && c[p] == s[p] { p += 1 }
        if s.count > p { onBackspace(s.count - p) }
        if c.count > p { onText(String(c[p...])) }
        sent = String(c)
        let all = Array(now)
        let pending = final || all.count <= c.count ? "" : String(all[c.count...])
        onPending(pending)
        // 맥으로 보낸 글자는 입력창에서 바로 빼고 조합 중인 글자만 남긴다. 키보드의 조합 기록은 그대로 둬야 "레" 다음 ㅁ 이 "렘" 이 된다
        // (바꿨다고 키보드에 알리면 기록이 지워져 "렘" 이 안 된다). 조합 중 글자가 없으면 입력창이 비고, 다음 지우기는 바로 맥으로 간다
        if !final && markedTextRange == nil && all.count > pending.count {
            text = pending
            sent = ""
        }
        lastText = text ?? ""
    }

    /// 글자의 첫 자음 (완성형은 초성, 낱자 자음은 그 자음). 모음·그 밖은 nil
    static func initial(_ u: Unicode.Scalar) -> Character? {
        let choseong = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
        switch u.value {
        case 0xAC00...0xD7A3: return choseong[Int(u.value - 0xAC00) / 588]
        case 0x3131...0x314E: return Character(u)
        default: return nil
        }
    }

    static func isHangul(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: return true
        default: return false
        }
    }
}
