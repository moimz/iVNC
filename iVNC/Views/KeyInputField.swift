import SwiftUI
import UIKit
import GameController

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
    /// 조합키를 켜 둔 채 누른 키 (조합키들, 키, 이름)
    var onCombo: ([UInt32], UInt32, String) -> Void = { _, _, _ in }
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
        f.onCombo = onCombo
        f.setMenu(menu)
        if active && (!f.isFirstResponder || f.keyboardStuck) {
            DispatchQueue.main.async { f.showKeyboard() }
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
    var onCombo: ([UInt32], UInt32, String) -> Void = { _, _, _ in }
    private let menuButton = UIButton(type: .system)
    /// 키보드 숨기기 버튼. 물리 키보드 때문에 화면 키보드가 숨어 특수키 줄만 보일 땐 "화면 키보드 보기" 버튼이 된다
    private let keyboardButton = UIButton(type: .system)
    private var keyboardIcon: ((String) -> UIButton.Configuration)?
    private var accessoryBar: UIView?
    /// 화면 키보드 없이 특수키 줄만 떠 있다 (물리 키보드가 연결된 아이패드)
    private var softwareKeyboardHidden = false
    /// 이번 입력 동안 화면 키보드가 한 번이라도 떠 있었다
    private var softwareKeyboardShown = false
    /// 마지막으로 물리 키보드 키를 누른 때
    private var lastHardwarePress = Date.distantPast
    /// 메뉴는 기준 뷰를 덮으며 펼쳐진다: 메뉴 버튼 바로 위의 얇은 띠를 기준으로 띄워 버튼을 가리지 않게 한다
    private let menuAnchor = UIButton(type: .custom)
    /// 조합키 (맥 기호). 누르면 켜져 있다가 다음 키와 함께 보내고 꺼진다. ⌘ 는 Super_L 로 보낸다
    private static let modifierKeys: [(title: String, keysym: UInt32, name: String)] = [
        ("⌘", 0xFFEB, "Command"), // 애플 서버는 Super_L 을 ⌘, Meta_L 을 ⌥ 로 받는다 (Meta_L 로 ⌘V 를 보내면 붙여넣기가 안 됐다)
        ("⌥", 0xFFE7, "Option"),
        ("⌃", 0xFFE3, "Control"),
        ("⇧", 0xFFE1, "Shift"),
    ]
    /// 아이폰 키보드로 못 치는 키 (키보드 위 줄 왼쪽, 좌우로 스크롤). keysym 은 X11 값, 이름은 맥 기호
    private static let specialKeys: [(title: String, keysym: UInt32, name: String)] = [
        ("⎋", 0xFF1B, "Escape"),
        ("⇥", 0xFF09, "Tab"),
        ("←", 0xFF51, "Left"),
        ("↑", 0xFF52, "Up"),
        ("↓", 0xFF54, "Down"),
        ("→", 0xFF53, "Right"),
        ("⌦", 0xFFFF, "Delete"),
        ("↖", 0xFF50, "Home"),
        ("↘", 0xFF57, "End"),
        ("⇞", 0xFF55, "Page_Up"),
        ("⇟", 0xFF56, "Page_Down"),
    ] + (1...12).map { ("F\($0)", 0xFFBE + UInt32($0 - 1), "F\($0)") }
    /// 켜 둔 조합키 (keysym) 와 그 버튼
    private var latched: [UInt32] = []
    private var modifierButtons: [UInt32: UIButton] = [:]
    /// 조합키를 켜는 동안 영어 키보드를 쓰고, 다 끄면 원래 키보드로 돌린다
    private var forcedInputMode: UITextInputMode?
    private var inputModeBeforeLatch: UITextInputMode?
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
        accessoryBar = makeAccessoryBar()
        inputAccessoryView = accessoryBar
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inputModeChanged), name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification, UIResponder.keyboardWillHideNotification,
                     UIResponder.keyboardDidHideNotification, UIResponder.keyboardDidChangeFrameNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let self else { return }
                let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .null
                DebugLog.write("키보드 \(n.name.rawValue.replacingOccurrences(of: "UIKeyboard", with: "").replacingOccurrences(of: "Notification", with: "")) 끝 \(Int(end.minX)),\(Int(end.minY)) \(Int(end.width))x\(Int(end.height)) 창 \(Int(self.window?.bounds.height ?? -1)) 입력잡음 \(self.isFirstResponder) 물리 \(self.hasHardwareKeyboard) 줄 \(self.inputAccessoryView != nil) 줄자리 \(self.barPlace())")
            }
        }
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

    /// 물리 키보드가 연결돼 있다 (아이패드 매직 키보드·블루투스 키보드)
    private var hasHardwareKeyboard: Bool { GCKeyboard.coalesced != nil }

    /// 입력은 잡고 있는데 물리 키보드도 없이 화면 키보드만 숨은 상태 (이 상태에선 다시 잡아도 키보드가 안 뜬다)
    var keyboardStuck: Bool { isFirstResponder && softwareKeyboardHidden && !hasHardwareKeyboard }

    /// 키보드를 띄운다. 숨은 채 입력을 잡고 있으면 놓았다가 다시 잡아 키보드를 올린다
    func showKeyboard() {
        if keyboardStuck { resignFirstResponder() }
        if !isFirstResponder { becomeFirstResponder() }
    }

    // MARK: 물리 키보드

    /// 키보드 높이로 화면 키보드가 떠 있는지 본다. 물리 키보드가 연결되면 iOS 는 화면 키보드를 숨기고 특수키 줄만 띄운다
    @objc private func keyboardFrameChanged(_ n: Notification) {
        guard isFirstResponder, let window, let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let visible = max(0, window.bounds.maxY - window.convert(end, from: nil).minY)
        let barHeight = accessoryBar?.bounds.height ?? 56
        // 물리 키보드가 있는 아이패드는 화면 키보드가 떠 있어도 높이 0 으로 알려 줄 때가 있다(2026-11-06 실측 "0,1217 1600x0").
        // 그래서 특수키 줄이 실제로 그려진 자리도 본다. 다만 키보드가 움직이는 도중엔 줄이 화면 밖에 있기도 해서
        // 입력을 놓는 건 알림의 높이와 줄 자리가 둘 다 "화면 키보드 없음" 일 때만 한다
        let barHidden = barShowsKeyboardHidden()
        // 물리 키보드가 있으면 내린 뒤에도 애플 막대 자리(약 80)를 비워 둔다(실측 줄자리 1119/1200, 높이 137). 진짜 화면 키보드는 200 이 넘으니 150 으로 가른다
        let hidden = (visible < barHeight + 150) && (barHidden ?? true)
        // 떠 있던 화면 키보드가 특수키 줄만 남기고 내려갔다 = 아이패드 키보드의 '키보드 내리기' 키.
        // iOS 는 입력을 놓지 않아 특수키 줄만 화면 아래에 남고, 물리 키보드가 있으면 다시 열어도 화면 키보드가 안 뜬다.
        // 우리 숨기기 버튼처럼 입력을 놓는다. 물리 키보드를 치면 iOS 가 화면 키보드를 스스로 내리는데, 그때는 놓지 않는다
        let typedOnHardware = Date().timeIntervalSince(lastHardwarePress) < 1
        // 애플 막대를 띄운 동안(특수키 줄을 뺀 동안)은 막대만 남는 게 정상이라 놓지 않는다
        if hidden && inputAccessoryView != nil && (softwareKeyboardShown || !hasHardwareKeyboard) && !typedOnHardware {
            DebugLog.write("키보드 내리기 키로 닫음 → 입력 놓음 (물리 키보드 \(hasHardwareKeyboard))")
            softwareKeyboardShown = false
            resignFirstResponder()
            return
        }
        if !hidden { softwareKeyboardShown = true }
        if barHidden == nil && !hidden && inputAccessoryView == nil {
            // 애플 막대로 화면 키보드를 띄웠다: 특수키 줄을 되돌린다
            restoreAccessoryBar()
        }
        setKeyboardHidden(barHidden ?? hidden)
        // 알림 뒤에 자리가 바뀌기도 해서 조금 뒤 다시 본다 (버튼 모양만 맞춘다)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshKeyboardButton() }
    }

    /// 특수키 줄이 화면 아래 끝에 붙어 있으면 화면 키보드가 없는 것이다. 줄이 안 붙어 있으면 nil
    private func barShowsKeyboardHidden() -> Bool? {
        guard let bar = accessoryBar, inputAccessoryView === bar, let w = bar.window, bar.bounds.height > 0 else { return nil }
        let r = bar.convert(bar.bounds, to: w)
        return r.maxY > w.bounds.height - 150
    }

    /// 로그용: 특수키 줄 아래 끝 / 그 창 높이
    private func barPlace() -> String {
        guard let bar = accessoryBar, let w = bar.window else { return "-" }
        return "\(Int(bar.convert(bar.bounds, to: w).maxY))/\(Int(w.bounds.height))"
    }

    private func refreshKeyboardButton() {
        guard isFirstResponder, let hidden = barShowsKeyboardHidden() else { return }
        if !hidden { softwareKeyboardShown = true }
        setKeyboardHidden(hidden)
    }

    private func setKeyboardHidden(_ hidden: Bool) {
        guard hidden != softwareKeyboardHidden else { return }
        softwareKeyboardHidden = hidden
        keyboardButton.configuration = keyboardIcon?(hidden ? "keyboard" : "keyboard.chevron.compact.down")
        keyboardButton.accessibilityLabel = hidden ? "화면 키보드 보기" : "키보드 숨기기"
    }

    private var savedTrailingGroups: [UIBarButtonItemGroup]?

    /// 애플 막대 대신 특수키 줄을 다시 붙인다
    private func restoreAccessoryBar(reload: Bool = true) {
        if let g = savedTrailingGroups { inputAssistantItem.trailingBarButtonGroups = g; savedTrailingGroups = nil }
        guard inputAccessoryView == nil else { return }
        inputAccessoryView = accessoryBar
        if reload { reloadInputViews() }
    }

    /// 앱이 화면 키보드를 직접 띄우는 공개 방법은 없다. 특수키 줄을 잠깐 빼면 iOS 가 자기 막대(화면 키보드 보기 버튼 포함)를 띄운다.
    /// 화면 키보드가 올라오면 keyboardFrameChanged 가 특수키 줄을 되돌린다
    private func revealSystemBar() {
        // 우리 입력창은 자동 고침·추천을 꺼 둬서 애플 막대에 보일 게 없으면 막대 자체가 안 뜬다(2026-11-06 실기기: 자리만 비고 아무것도 없음).
        // 막대에 "특수키 줄로 돌아가기" 버튼을 하나 넣어 막대가 뜨게 한다. 애플은 그 막대 왼쪽에 키보드 메뉴(키보드 보기 포함)를 붙인다
        if savedTrailingGroups == nil { savedTrailingGroups = inputAssistantItem.trailingBarButtonGroups }
        let back = UIBarButtonItem(image: UIImage(systemName: "command"), primaryAction: UIAction { [weak self] _ in self?.restoreAccessoryBar() })
        back.accessibilityLabel = "특수키 줄"
        inputAssistantItem.trailingBarButtonGroups = [UIBarButtonItemGroup(barButtonItems: [back], representativeItem: nil)]
        DebugLog.write("애플 막대 띄우기 (특수키 줄 빼고 막대에 버튼 넣음)")
        softwareKeyboardShown = false
        inputAccessoryView = nil
        reloadInputViews()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        lastHardwarePress = Date()
        super.pressesBegan(presses, with: event)
    }

    // MARK: 조합키

    override var textInputMode: UITextInputMode? { forcedInputMode ?? super.textInputMode }

    private func toggleModifier(_ keysym: UInt32) {
        if let i = latched.firstIndex(of: keysym) { latched.remove(at: i) } else { latched.append(keysym) }
        modifiersChanged()
    }

    private func clearModifiers() {
        guard !latched.isEmpty else { return }
        latched = []
        modifiersChanged()
    }

    private func modifiersChanged() {
        for (k, b) in modifierButtons { b.configuration = Self.keyConfig(title: b.configuration?.title ?? "", on: latched.contains(k)) }
        if !latched.isEmpty && forcedInputMode == nil {
            // 영어 키보드가 추가돼 있으면 그걸로 (⌘C 처럼 영어 글자와 함께 쓴다)
            inputModeBeforeLatch = super.textInputMode
            if let en = UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage?.hasPrefix("en") == true }),
               en.primaryLanguage != inputModeBeforeLatch?.primaryLanguage {
                flushPending()
                forcedInputMode = en
                reloadInputViews()
            }
        } else if latched.isEmpty, forcedInputMode != nil {
            forcedInputMode = inputModeBeforeLatch
            reloadInputViews()
            forcedInputMode = nil
        }
    }

    /// 켜 둔 조합키와 함께 키 하나를 보내고 조합키를 끈다
    private func sendWithModifiers(_ keysym: UInt32, name: String) {
        flushPending()
        onCombo(latched, keysym, name)
        clearModifiers()
    }

    /// 키보드로 친 글자의 keysym (조합키와 함께 보낼 때). 영문 대문자는 소문자로 (⇧ 는 조합키로 따로 켠다)
    private static func keysym(for c: Character) -> UInt32? {
        guard let u = String(c).lowercased().unicodeScalars.first else { return nil }
        switch u.value {
        case 0x20...0x7E, 0xA0...0xFF: return u.value
        default: return 0x0100_0000 | u.value
        }
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard !latched.isEmpty, let c = string.first, let k = Self.keysym(for: c) else { return true }
        sendWithModifiers(k, name: String(c))
        return false
    }

    static func keyConfig(title: String, on: Bool = false) -> UIButton.Configuration {
        var c = UIButton.Configuration.filled()
        c.cornerStyle = .capsule
        c.baseBackgroundColor = on ? .systemBlue : UIColor.white.withAlphaComponent(0.14)
        c.title = title
        c.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.white]))
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 9)
        return c
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 키보드 바로 위 버튼 줄: 왼쪽은 꽉 찬 글래스 캡슐 안에서 좌우로 스크롤되는 특수키, 오른쪽은 메뉴·키보드 숨기기 묶음
    private func makeAccessoryBar() -> UIView {
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 56))
        bar.backgroundColor = .clear

        func capsule() -> UIVisualEffectView {
            let v = UIVisualEffectView(effect: UIGlassEffect())
            v.cornerConfiguration = .capsule()
            v.clipsToBounds = true
            return v
        }
        func icon(_ symbol: String) -> UIButton.Configuration {
            var c = UIButton.Configuration.plain()
            c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            return c
        }

        // 오른쪽 묶음: [메뉴][숨기기]
        let group = capsule()
        menuButton.configuration = icon("ellipsis")
        menuButton.addAction(UIAction { [weak self] _ in self?.menuAnchor.performPrimaryAction() }, for: .primaryActionTriggered)
        menuButton.accessibilityLabel = "메뉴"
        menuAnchor.showsMenuAsPrimaryAction = true
        menuAnchor.isUserInteractionEnabled = false
        let hide = keyboardButton
        hide.configuration = icon("keyboard.chevron.compact.down")
        hide.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // 누를 때 특수키 줄의 실제 자리로 다시 본다 (버튼 모양이 늦게 바뀌었어도 화면 키보드가 보이면 숨긴다)
            self.refreshKeyboardButton()
            DebugLog.write("키보드 버튼: 화면 키보드 \(self.softwareKeyboardHidden ? "없음 → 애플 막대 띄움" : "있음 → 숨김") (물리 \(self.hasHardwareKeyboard))")
            if self.softwareKeyboardHidden && self.hasHardwareKeyboard {
                self.revealSystemBar()
            } else {
                // 내리면 textFieldDidEndEditing 이 조합 중인 글자를 먼저 보낸다
                self.resignFirstResponder()
            }
        }, for: .primaryActionTriggered)
        hide.accessibilityLabel = "키보드 숨기기"
        keyboardIcon = icon
        let pair = UIStackView(arrangedSubviews: [menuButton, hide])
        pair.axis = .horizontal
        pair.distribution = .fillEqually
        group.contentView.addSubview(pair)

        // 왼쪽: 특수키
        let keysBox = capsule()
        let keys = UIStackView()
        keys.axis = .horizontal
        keys.spacing = 6
        for k in Self.modifierKeys {
            let b = UIButton(configuration: Self.keyConfig(title: k.title), primaryAction: UIAction { [weak self] _ in
                self?.toggleModifier(k.keysym)
            })
            b.accessibilityLabel = k.name
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
            modifierButtons[k.keysym] = b
            keys.addArrangedSubview(b)
        }
        for k in Self.specialKeys {
            let b = UIButton(configuration: Self.keyConfig(title: k.title), primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                if !self.latched.isEmpty { self.sendWithModifiers(k.keysym, name: k.name); return }
                // 조합 중인 글자를 먼저 보내고 키를 보낸다
                self.flushPending()
                self.onKey(k.keysym, k.name)
            })
            b.accessibilityLabel = k.name
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
            keys.addArrangedSubview(b)
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.addSubview(keys)
        keysBox.contentView.addSubview(scroll)

        for v in [keysBox, group, menuAnchor, pair, scroll, keys] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        bar.addSubview(keysBox)
        bar.addSubview(group)
        bar.addSubview(menuAnchor)
        let g = bar.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            group.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -10),
            group.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            group.heightAnchor.constraint(equalToConstant: 44),
            group.widthAnchor.constraint(equalToConstant: 104),
            pair.leadingAnchor.constraint(equalTo: group.contentView.leadingAnchor, constant: 2),
            pair.trailingAnchor.constraint(equalTo: group.contentView.trailingAnchor, constant: -2),
            pair.topAnchor.constraint(equalTo: group.contentView.topAnchor),
            pair.bottomAnchor.constraint(equalTo: group.contentView.bottomAnchor),
            menuAnchor.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            menuAnchor.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            menuAnchor.bottomAnchor.constraint(equalTo: group.topAnchor, constant: -6),
            menuAnchor.heightAnchor.constraint(equalToConstant: 1),
            keysBox.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 10),
            keysBox.trailingAnchor.constraint(equalTo: group.leadingAnchor, constant: -8),
            keysBox.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            keysBox.heightAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: keysBox.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: keysBox.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: keysBox.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: keysBox.contentView.bottomAnchor),
            keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 5),
            keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -5),
            keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 5),
            keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -5),
            keys.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10),
        ])
        return bar
    }

    /// 입력창이 비어 있을 때 지우기: 맥 쪽 글자를 지운다
    override func deleteBackward() {
        if !latched.isEmpty { sendWithModifiers(0xFF08, name: "BackSpace"); return }
        if (text ?? "").isEmpty { onBackspace(1) }
        super.deleteBackward()
    }

    @objc private func changed() { sync(final: false) }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if !latched.isEmpty { sendWithModifiers(0xFF0D, name: "Return"); return false }
        sync(final: true)
        onReturn()
        reset()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        restoreAccessoryBar(reload: false)
        softwareKeyboardHidden = false
        softwareKeyboardShown = false
        keyboardButton.configuration = keyboardIcon?("keyboard.chevron.compact.down")
        sync(final: true)
        reset()
        clearModifiers()
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
