#if os(iOS)
import SwiftUI
import UIKit
import SwiftTerm

// 아이폰·아이패드 SSH 터미널 1단계: 터미널 한 화면 (2026-11-21, 맥 다음 순서 — 공통 바탕 → 아이패드 → 아이폰 → 파인더).
// 접속은 맥과 같은 SSHShell. 키보드 위 특수 키 줄은 화면 공유 때 만든 `KeyBar` 를 같이 쓴다 (사용자: 새로 만들지 말고 그대로).

/// 터미널 접속 하나 = SSH 접속 하나 + SwiftTerm 화면 하나
@MainActor
final class MobileTerminalSession: NSObject, ObservableObject, TerminalViewDelegate, Identifiable {
    enum State: Equatable { case connecting, connected, closed(String?) }

    let id = UUID()

    let computer: Computer
    let jumps: [Computer]
    let view: TerminalView
    @Published private(set) var state: State = .connecting
    @Published private(set) var remoteTitle = ""
    /// 셸이 알려 준 지금 폴더 (OSC 7)
    @Published private(set) var directory: String?

    /// 탭에 작게 보일 지금 폴더: OSC 7 → 셸 창 제목의 ": /경로" (우분투 기본 bash). 홈은 ~
    var workingDirectory: String? {
        var path = directory.flatMap { URL(string: $0)?.path }.flatMap { $0.isEmpty ? nil : $0 }
        if path == nil, let r = remoteTitle.range(of: ": ", options: .backwards) {
            let p = String(remoteTitle[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("/") || p.hasPrefix("~") { path = p }
        }
        guard let path else { return nil }
        let home = computer.username == "root" ? "/root" : "/home/\(computer.username)"
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
    @Published var hostKeyQuestion: SSHShell.HostKeyQuestion?
    private var hostKeyAnswer: ((Bool) -> Void)?
    private var shell: SSHShell?
    /// 파인더가 같은 접속에 SFTP·명령 채널을 연다
    var sshShell: SSHShell? { state == .connected ? shell : nil }
    /// 이 탭의 파인더 (처음 볼 때 만든다)
    private(set) lazy var files = MobileFileSession(terminal: self)
    /// 좁은 화면에서 파인더를 보는 중 ([터미널 | 파인더])
    @Published var showFiles = false
    /// 화면 열×행 (접속 전에 바뀐 것도 기억해 접속할 때 서버에 알린다)
    private var size = (cols: 80, rows: 24)

    init(computer: Computer, jumps: [Computer]) {
        self.computer = computer
        self.jumps = jumps
        let d = UserDefaults.standard
        typealias K = TerminalSettings
        let limited = d.object(forKey: K.scrollbackLimited) as? Bool ?? true
        let lines = d.object(forKey: K.scrollbackLines) as? Int ?? 10_000
        let options = TerminalOptions(cols: 80, rows: 24,
                                      termName: d.string(forKey: K.termType) ?? "xterm-256color",
                                      scrollback: limited ? lines : 1_000_000)
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), font: Self.font(), options: options)
        super.init()
        view.terminalDelegate = self
        applySettings()
        installKeyBar()
        // 키보드가 뜨고 지면 아래 여백이 바뀐다 → 맨 아래를 보고 있었으면 다시 맨 아래로
        for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidHideNotification, UIResponder.keyboardDidChangeFrameNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.view.followBottomAfterLayout() }
            }
        }
    }

    // MARK: 키보드 위 줄 (화면 공유와 같은 KeyBar)

    private let menuButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    private let menuAnchor = UIButton(type: .custom)
    private var modifierButtons: [UInt32: UIButton] = [:]
    /// 키 줄 메뉴 (다시 접속 등, 화면이 정한다)
    var menu: UIMenu? { didSet { menuAnchor.menu = menu } }

    /// 터미널에 쓰는 조합키: ⌃ ⌥ (⌘ 은 터미널에 보낼 게 없고, ⇧ 는 키보드에 있다)
    private static let terminalModifiers: Set<UInt32> = [0xFFE3, 0xFFE7]

    private func installKeyBar() {
        menuButton.configuration = KeyBar.icon("ellipsis")
        menuButton.addAction(UIAction { [weak self] _ in self?.menuAnchor.performPrimaryAction() }, for: .primaryActionTriggered)
        menuButton.accessibilityLabel = "메뉴"
        menuAnchor.showsMenuAsPrimaryAction = true
        menuAnchor.isUserInteractionEnabled = false
        keyboardButton.configuration = KeyBar.icon("keyboard.chevron.compact.down")
        keyboardButton.addAction(UIAction { [weak self] _ in _ = self?.view.resignFirstResponder() }, for: .primaryActionTriggered)
        keyboardButton.accessibilityLabel = "키보드 숨기기"
        let mods = HangulInputField.modifierKeys.filter { Self.terminalModifiers.contains($0.keysym) }
            .map { KeyBar.Key(title: $0.title, id: $0.keysym, name: $0.name) }
        let specials = HangulInputField.specialKeys.map { KeyBar.Key(title: $0.title, id: $0.keysym, name: $0.name) }
        let (bar, buttons) = KeyBar.make(modifiers: mods, specials: specials, menuButton: menuButton, keyboardButton: keyboardButton,
                                         menuAnchor: menuAnchor,
                                         onModifier: { [weak self] k in self?.toggleModifier(k.id) },
                                         onSpecial: { [weak self] k in self?.sendSpecial(k.id) })
        modifierButtons = buttons
        view.inputAccessoryView = bar
    }

    /// ⌃ = 다음 글자를 컨트롤 문자로, ⌥ = 다음 글자 앞에 ESC (SwiftTerm 이 글자를 받을 때 처리하고 끈다)
    private func toggleModifier(_ id: UInt32) {
        if id == 0xFFE3 { view.controlModifier.toggle() } else { view.metaModifier.toggle() }
        refreshModifiers()
    }

    private func refreshModifiers() {
        for (id, b) in modifierButtons {
            let on = id == 0xFFE3 ? view.controlModifier : view.metaModifier
            b.configuration = HangulInputField.keyConfig(title: b.configuration?.title ?? "", on: on)
        }
    }

    /// 특수키 → 터미널 문자열 (xterm)
    private func sendSpecial(_ keysym: UInt32) {
        let esc = "\u{1b}"
        let seq: String
        switch keysym {
        case 0xFF1B: seq = esc
        case 0xFF09: seq = "\t"
        case 0xFF52: seq = esc + "[A"
        case 0xFF54: seq = esc + "[B"
        case 0xFF53: seq = esc + "[C"
        case 0xFF51: seq = esc + "[D"
        case 0xFFFF: seq = esc + "[3~"
        case 0xFF50: seq = esc + "[H"
        case 0xFF57: seq = esc + "[F"
        case 0xFF55: seq = esc + "[5~"
        case 0xFF56: seq = esc + "[6~"
        case 0xFFBE...0xFFC9:
            let n = Int(keysym - 0xFFBE) + 1
            let codes = [1: "OP", 2: "OQ", 3: "OR", 4: "OS", 5: "[15~", 6: "[17~", 7: "[18~", 8: "[19~", 9: "[20~", 10: "[21~", 11: "[23~", 12: "[24~"]
            seq = esc + (codes[n] ?? "")
        default: return
        }
        view.controlModifier = false
        view.metaModifier = false
        refreshModifiers()
        shell?.send(Array(seq.utf8)[...])
    }

    static func font() -> UIFont {
        _ = TerminalSettings.registerBundledFonts
        let d = UserDefaults.standard
        let size = CGFloat(d.object(forKey: TerminalSettings.fontSize) as? Double ?? 13)
        let family = d.string(forKey: TerminalSettings.fontFamily) ?? ""
        if !family.isEmpty, let f = UIFont(name: family, size: size) { return f }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func applySettings() {
        let d = UserDefaults.standard
        typealias K = TerminalSettings
        typealias D = TerminalSettings.Defaults
        func color(_ key: String, _ fallback: String) -> UIColor { UIColor(Color(hex: d.string(forKey: key) ?? fallback)) }
        view.font = Self.font()
        view.nativeBackgroundColor = color(K.backgroundColor, D.background)
        view.nativeForegroundColor = color(K.textColor, D.text)
        view.caretColor = color(K.cursorColor, D.cursor)
        view.selectedTextBackgroundColor = color(K.selectionColor, D.selection)
        view.useBrightColors = d.object(forKey: K.brightBold) as? Bool ?? false
        let palette = (0..<8).map { d.string(forKey: K.palette + "normal\($0)") ?? D.normal[$0] }
            + (0..<8).map { d.string(forKey: K.palette + "bright\($0)") ?? D.bright[$0] }
        view.installColors(palette.map { hex in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(Color(hex: hex)).getRed(&r, green: &g, blue: &b, alpha: &a)
            return SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
        })
    }

    // MARK: 접속

    private struct AuthError: Error { let text: String }

    private static func auth(for c: Computer) -> Result<SSHShell.Auth, AuthError> {
        if c.sshAuth == .key {
            guard let file = Keychain.sshKey(for: c.id) else { return .failure(.init(text: "\(c.name): 저장된 SSH 키가 없습니다. 서버 편집에서 키를 골라 주세요.")) }
            do { return .success(.key(try OpenSSHKey.ed25519(from: file, passphrase: Keychain.sshKeyPassphrase(for: c.id)))) }
            catch { return .failure(.init(text: "\(c.name): \(error.localizedDescription)")) }
        }
        guard let pw = Keychain.password(for: c.id) else { return .failure(.init(text: "\(c.name): 저장된 비밀번호가 없습니다. 서버 편집에서 비밀번호를 넣어 주세요.")) }
        return .success(.password(pw))
    }

    private var accessCheck = 0

    func connect() {
        state = .connecting
        accessCheck += 1
        // 접속 허용 IP (경유 서버가 있으면 맨 바깥 경유 서버의 목록): 아니면 접속하지 않고 VPN 을 켜라고 안내.
        // iOS 는 다른 앱의 VPN 을 켤 수 없어 안내만 하고, VPN 을 켠 뒤 [다시 접속] 하면 다시 확인한다
        if let list = NetworkAccess.gate(for: computer, jumps: jumps).allowedIPs, !list.isEmpty {
            let token = accessCheck
            view.feed(text: "\r\n\u{1b}[2m이 기기의 IP 확인 중…\u{1b}[0m")
            Task { [weak self] in
                guard let self, let r = await NetworkAccess.check(self.computer, jumps: self.jumps) else { return }
                guard token == self.accessCheck, self.state == .connecting else { return }
                self.view.feed(text: "\r\u{1b}[2K")
                if r.allowed { self.startShell() }
                else { self.fail(NetworkAccess.explain(r, server: self.computer.name).replacingOccurrences(of: "\n", with: "\r\n") + "\r\nVPN 을 켜고 다시 접속하세요.") }
            }
            return
        }
        startShell()
    }

    private func startShell() {
        var hops: [SSHShell.Hop] = []
        for j in jumps {
            switch Self.auth(for: j) {
            case .success(let a): hops.append(.init(host: j.host, port: j.port, username: j.username, auth: a, name: j.name))
            case .failure(let m): fail("경유 서버 " + m.text); return
            }
        }
        let auth: SSHShell.Auth
        switch Self.auth(for: computer) {
        case .success(let a): auth = a
        case .failure(let m): fail(m.text); return
        }
        let d = UserDefaults.standard
        let s = SSHShell(host: computer.host, port: computer.port, username: computer.username, auth: auth,
                         term: d.string(forKey: TerminalSettings.termType) ?? "xterm-256color",
                         startCommand: nil, jumps: hops)
        s.onHostKeyQuestion = { [weak self] q, answer in
            guard let self else { answer(false); return }
            self.hostKeyAnswer = answer
            self.hostKeyQuestion = q
        }
        s.onData = { [weak self] bytes in self?.view.feed(byteArray: bytes[...]) }
        s.onConnected = { [weak self] in
            guard let self else { return }
            self.state = .connected
            let cmd = (d.string(forKey: TerminalSettings.startupCommand) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty { self.shell?.send(Array((cmd + "\r").utf8)[...]) }
        }
        s.onClose = { [weak self] error, status in self?.closed(error: error, status: status) }
        shell = s
        s.connect(cols: size.cols, rows: size.rows, keepAlive: d.object(forKey: TerminalSettings.keepAlive) as? Bool ?? true)
    }

    func answerHostKey(_ ok: Bool) {
        hostKeyQuestion = nil
        hostKeyAnswer?(ok)
        hostKeyAnswer = nil
    }

    func disconnect() {
        accessCheck += 1
        files.close()
        shell?.onClose = nil
        shell?.close()
        shell = nil
    }

    private func fail(_ message: String) {
        state = .closed(message)
        view.feed(text: "\r\n\u{1b}[31m\(message)\u{1b}[0m\r\n")
    }

    private func closed(error: String?, status: Int?) {
        shell = nil
        if let error { fail(error); return }
        state = .closed(nil)
        view.feed(text: "\r\n\u{1b}[2m[접속이 끝났습니다\(status.map { " · 종료 코드 \($0)" } ?? "")]\u{1b}[0m\r\n")
    }

    // MARK: TerminalViewDelegate

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            size = (newCols, newRows)
            shell?.resize(cols: newCols, rows: newRows)
        }
    }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated { remoteTitle = title }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated { self.directory = directory }
    }
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            shell?.send(data)
            // 조합키는 글자 하나에 쓰이고 꺼진다 → 버튼 표시도 끈다
            refreshModifiers()
        }
    }
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        MainActor.assumeIsolated { if let u = URL(string: link) { UIApplication.shared.open(u) } }
    }
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        MainActor.assumeIsolated { if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s } }
    }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

extension TerminalView {
    /// 처음 접속할 때 가끔 맨 아래가 조금 덜 내려가 있던 것 (사용자 2026-11-21): 키보드·키 줄이 뜨며 높이가
    /// 한 줄이 안 되게 줄면 SwiftTerm 은 줄 수가 그대로라 스크롤 자리를 다시 안 맞춘다. 배치가 끝난 뒤
    /// 맨 아래를 보고 있었으면(또는 넘길 게 없으면) 다시 맨 아래에 붙인다 — 위로 올려 보던 중이면 그대로
    func followBottomAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            if !self.canScroll || self.scrollPosition >= 0.999 { self.scrollTo(row: Int.max, notifyAccessibility: false) }
        }
    }
}

#endif
