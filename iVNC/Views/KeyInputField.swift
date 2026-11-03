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
    /// 키보드 위 줄의 특수키 (keysym, 이름)
    var onKey: (UInt32, String) -> Void = { _, _ in }
    /// 키보드 위 줄의 메뉴 버튼이 띄울 메뉴 (떠 있는 버튼과 같은 것)
    var menu: UIMenu?

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
        f.onKey = onKey
        f.setMenu(menu)
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
    var onKey: (UInt32, String) -> Void = { _, _ in }
    private let menuButton = UIButton(type: .system)
    /// 메뉴는 기준 뷰를 덮으며 펼쳐진다: 메뉴 버튼 바로 위의 얇은 띠를 기준으로 띄워 버튼을 가리지 않게 한다
    private let menuAnchor = UIButton(type: .custom)
    /// 아이폰 키보드로 못 치는 키 (키보드 위 줄 왼쪽, 좌우로 스크롤). 시험으로 ESC 하나
    private static let specialKeys: [(title: String, keysym: UInt32, name: String)] = [
        ("esc", 0xFF1B, "Escape"),
    ]
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
        inputAccessoryView = makeAccessoryBar()
        NotificationCenter.default.addObserver(self, selector: #selector(inputModeChanged), name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inputModeChanged), name: Self.flushNotification, object: nil)
    }

    /// 조합 중인 글자를 지금 보내라는 알림 (마우스를 누르기 직전: 클릭으로 맥의 포커스가 옮겨 가기 전에 원래 입력창에 넣는다)
    static let flushNotification = Notification.Name("iVNC.flushComposition")

    /// 키보드를 바꾸거나 마우스를 누르기 직전: 조합 중이라 안 보낸 글자를 바로 보내고 비운다
    @objc private func inputModeChanged() {
        guard isFirstResponder else { return }
        flushPending()
    }

    private func flushPending() {
        guard !(text ?? "").isEmpty else { return }
        unmarkText()
        sync(final: true)
        reset()
    }

    func setMenu(_ menu: UIMenu?) { menuAnchor.menu = menu }

    required init?(coder: NSCoder) { fatalError() }

    /// 키보드 바로 위 버튼 줄 (배경 없이 버튼만): 왼쪽은 특수키(좌우 스크롤), 오른쪽 끝은 메뉴·키보드 숨기기
    private func makeAccessoryBar() -> UIView {
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 52))
        bar.backgroundColor = .clear

        func glass(_ symbol: String) -> UIButton.Configuration {
            var c = UIButton.Configuration.glass()
            c.cornerStyle = .capsule
            c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            return c
        }
        let hide = UIButton(configuration: glass("keyboard.chevron.compact.down"), primaryAction: UIAction { [weak self] _ in
            // 내리면 textFieldDidEndEditing 이 조합 중인 글자를 먼저 보낸다
            self?.resignFirstResponder()
        })
        hide.accessibilityLabel = "키보드 숨기기"
        menuButton.configuration = glass("circle.grid.2x2.fill")
        menuButton.addAction(UIAction { [weak self] _ in self?.menuAnchor.performPrimaryAction() }, for: .primaryActionTriggered)
        menuButton.accessibilityLabel = "메뉴"
        menuAnchor.showsMenuAsPrimaryAction = true
        menuAnchor.isUserInteractionEnabled = false

        let keys = UIStackView()
        keys.axis = .horizontal
        keys.spacing = 8
        for k in Self.specialKeys {
            var c = UIButton.Configuration.glass()
            c.cornerStyle = .capsule
            c.attributedTitle = AttributedString(k.title, attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.white]))
            c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
            let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in
                // 조합 중인 글자를 먼저 보내고 키를 보낸다
                self?.flushPending()
                self?.onKey(k.keysym, k.name)
            })
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            keys.addArrangedSubview(b)
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.clipsToBounds = false // 글래스 버튼 그림자가 잘리지 않게
        scroll.addSubview(keys)

        for v in [scroll, menuButton, hide, menuAnchor] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        keys.translatesAutoresizingMaskIntoConstraints = false
        let g = bar.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hide.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -10),
            hide.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            hide.widthAnchor.constraint(equalToConstant: 52),
            hide.heightAnchor.constraint(equalToConstant: 40),
            menuButton.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -8),
            menuButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 52),
            menuButton.heightAnchor.constraint(equalToConstant: 40),
            menuAnchor.leadingAnchor.constraint(equalTo: menuButton.leadingAnchor),
            menuAnchor.trailingAnchor.constraint(equalTo: menuButton.trailingAnchor),
            menuAnchor.bottomAnchor.constraint(equalTo: menuButton.topAnchor, constant: -6),
            menuAnchor.heightAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -8),
            scroll.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 40),
            keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            keys.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return bar
    }

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
    private func sync(final: Bool) {
        let c = Array(committed(final: final)), s = Array(sent), t = Array(text ?? "")
        // 지우기 때 아이폰 키보드는 조합 기록으로 이미 보낸 마지막 글자를 다시 조합 중으로 끌어온다 ("도레" 에서 지우면 "돌").
        // 맥은 바로 고치지 않는다: 보낸 것을 기억해 두고, 조합이 끝날 때 비교해서 필요한 만큼만 고친다.
        // "돌" 에 ㅏ 를 치면 "도라" 가 되어 확정된 "도" 는 이미 보냈으니 안 보내고, 다시 지워 "도" 가 되면 아래에서 조합을 끝낸다
        // 맥에 이미 보낸 것은 키보드에 따라 고치지 않는다: 보이는 표시와 보낼 것은 보낸 글자 뒤에 새로 생긴 받침 자음(ㄹ)뿐이다
        if !final, !s.isEmpty, t.count == s.count, c.count == s.count - 1, Array(s.prefix(c.count)) == c {
            onPending(Self.extra(t[c.count], over: s[c.count]) ?? String(t[c.count...]))
            return
        }
        var p = 0
        while p < min(c.count, s.count) && c[p] == s[p] { p += 1 }
        // 보낸 마지막 글자에 받침이 붙은 채 확정되면(돌 + 띄어쓰기) 맥의 "도" 는 두고 새 자음과 그 뒤만 보낸다
        if p == s.count - 1, p < c.count, let add = Self.extra(c[p], over: s[p]) {
            onText(add + String(c[(p + 1)...]))
        } else {
            if s.count > p { onBackspace(s.count - p) }
            if c.count > p { onText(String(c[p...])) }
        }
        sent = String(c)
        let all = Array(text ?? "")
        let pending = final || all.count <= c.count ? "" : String(all[c.count...])
        onPending(pending)
        // 조합 중인 글자가 없어지면(띄어쓰기, 다 지움 등) 입력창과 키보드 조합 기록까지 모두 초기화한다.
        // 입력창만 비우면 키보드가 기록에 남은 "도레" 로 다음 지우기 때 "돌" 을 만든다 (2026-11-02 실측).
        // 키보드가 글자를 넣는 도중에 바꾸면 모르고 지나가니, 처리가 끝난 뒤 비우고 바뀌었다고 알린다. 다음 지우기는 바로 맥으로 간다
        if pending.isEmpty && !final && markedTextRange == nil && !(text ?? "").isEmpty {
            let snapshot = text
            DispatchQueue.main.async { [weak self] in
                guard let self, self.text == snapshot else { return }
                self.inputDelegate?.textWillChange(self)
                self.text = ""
                self.sent = ""
                self.inputDelegate?.textDidChange(self)
            }
        }
    }

    /// 받침 → 자음들 (겹받침은 나눈다). 완성형 받침 순서
    private static let jongParts: [String] = ["", "ㄱ", "ㄲ", "ㄱㅅ", "ㄴ", "ㄴㅈ", "ㄴㅎ", "ㄷ", "ㄹ", "ㄹㄱ", "ㄹㅁ", "ㄹㅂ", "ㄹㅅ", "ㄹㅌ", "ㄹㅍ", "ㄹㅎ",
                                              "ㅁ", "ㅂ", "ㅂㅅ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]

    /// 키보드가 보낸 글자 sent 에 받침을 붙여 now 로 끌어왔을 때 새로 생긴 자음 ("도"→"돌" 이면 "ㄹ", "갈"→"갉" 이면 "ㄱ").
    /// 초성·중성이 다르거나 받침이 늘지 않았으면 nil
    static func extra(_ now: Character, over sent: Character) -> String? {
        guard let n = now.unicodeScalars.first?.value, let o = sent.unicodeScalars.first?.value,
              (0xAC00...0xD7A3).contains(n), (0xAC00...0xD7A3).contains(o),
              (n - 0xAC00) / 28 == (o - 0xAC00) / 28 else { return nil }
        let a = jongParts[Int((o - 0xAC00) % 28)], b = jongParts[Int((n - 0xAC00) % 28)]
        guard b.count > a.count, b.hasPrefix(a) else { return nil }
        return String(b.dropFirst(a.count))
    }

    static func isHangul(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: return true
        default: return false
        }
    }
}
