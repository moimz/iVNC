import SwiftUI
import AppKit
import SwiftTerm

/// 터미널 창을 열어 달라는 값. 늘 새 창이 뜨게 id 를 새로 만든다 (같은 값이면 SwiftUI 가 있던 창을 앞으로 가져온다)
struct TerminalWindowRequest: Codable, Hashable {
    var id = UUID()
    var computer: UUID
}

/// 터미널 탭 하나 = SSH 접속 하나 + SwiftTerm 화면 하나 (탭을 옮기거나 숨겨도 화면은 살려 둔다)
@MainActor
final class TerminalTab: NSObject, ObservableObject, Identifiable, TerminalViewDelegate {
    enum State: Equatable {
        case connecting, connected
        case closed(String?)
    }

    let id = UUID()
    @Published var computer: Computer
    @Published private(set) var state: State = .connecting
    /// 서버가 알려 준 창 제목 (셸 프롬프트가 보내는 것)
    @Published private(set) var remoteTitle = ""
    @Published private(set) var directory: String?
    @Published private(set) var size = (cols: 80, rows: 24)
    /// 서버 지문 질문 (창이 알림으로 띄운다)
    @Published var hostKeyQuestion: SSHShell.HostKeyQuestion?
    private var hostKeyAnswer: ((Bool) -> Void)?

    let view: TerminalView
    private var shell: SSHShell?
    /// 셸이 끝나 설정대로 탭을 닫아야 할 때 (창 모델이 연결)
    var onRequestClose: ((TerminalTab) -> Void)?

    init(computer: Computer) {
        self.computer = computer
        let d = UserDefaults.standard
        typealias K = TerminalSettings
        let limited = d.object(forKey: K.scrollbackLimited) as? Bool ?? true
        let lines = d.object(forKey: K.scrollbackLines) as? Int ?? 10_000
        let options = TerminalOptions(cols: d.object(forKey: K.columns) as? Int ?? 80,
                                      rows: d.object(forKey: K.rows) as? Int ?? 24,
                                      termName: d.string(forKey: K.termType) ?? "xterm-256color",
                                      scrollback: limited ? lines : 1_000_000)
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 440), font: Self.font(), options: options)
        super.init()
        view.terminalDelegate = self
        applySettings()
    }

    // MARK: 설정 적용 (설정 > SSH)

    static func font() -> NSFont {
        let d = UserDefaults.standard
        let size = CGFloat(d.object(forKey: TerminalSettings.fontSize) as? Double ?? 13)
        let family = d.string(forKey: TerminalSettings.fontFamily) ?? ""
        if !family.isEmpty, let f = NSFont(name: family, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func applySettings() {
        let d = UserDefaults.standard
        typealias K = TerminalSettings
        typealias D = TerminalSettings.Defaults
        func color(_ key: String, _ fallback: String) -> NSColor { NSColor(Color(hex: d.string(forKey: key) ?? fallback)) }
        view.font = Self.font()
        view.nativeBackgroundColor = color(K.backgroundColor, D.background)
        view.nativeForegroundColor = color(K.textColor, D.text)
        view.backgroundOpacity = CGFloat(d.object(forKey: K.backgroundOpacity) as? Double ?? 1)
        view.caretColor = color(K.cursorColor, D.cursor)
        view.selectedTextBackgroundColor = color(K.selectionColor, D.selection)
        view.useBrightColors = d.object(forKey: K.brightBold) as? Bool ?? false
        view.optionAsMetaKey = d.object(forKey: K.optionAsMeta) as? Bool ?? false
        view.backspaceSendsControlH = d.object(forKey: K.deleteSendsCtrlH) as? Bool ?? false
        // ANSI 16색
        let palette = (0..<8).map { d.string(forKey: K.palette + "normal\($0)") ?? D.normal[$0] }
            + (0..<8).map { d.string(forKey: K.palette + "bright\($0)") ?? D.bright[$0] }
        view.installColors(palette.map { hex in
            let c = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .white
            return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535),
                                   blue: UInt16(c.blueComponent * 65535))
        })
        let blink = d.object(forKey: K.cursorBlink) as? Bool ?? true
        switch TerminalSettings.CursorShape(rawValue: d.string(forKey: K.cursorShape) ?? "") ?? .underline {
        case .block: view.setCursorStyle(blink ? .blinkBlock : .steadyBlock)
        case .underline: view.setCursorStyle(blink ? .blinkUnderline : .steadyUnderline)
        case .bar: view.setCursorStyle(blink ? .blinkBar : .steadyBar)
        }
    }

    // MARK: 접속

    func connect() {
        state = .connecting
        let auth: SSHShell.Auth
        if computer.sshAuth == .key {
            guard let file = Keychain.sshKey(for: computer.id) else {
                fail("저장된 SSH 키가 없습니다. 서버 편집에서 키를 골라 주세요.")
                return
            }
            do {
                auth = .key(try OpenSSHKey.ed25519(from: file, passphrase: Keychain.sshKeyPassphrase(for: computer.id)))
            } catch {
                fail(error.localizedDescription)
                return
            }
        } else {
            guard let pw = Keychain.password(for: computer.id) else {
                fail("저장된 비밀번호가 없습니다. 서버 편집에서 비밀번호를 넣어 주세요.")
                return
            }
            auth = .password(pw)
        }
        let d = UserDefaults.standard
        let s = SSHShell(host: computer.host, port: computer.port, username: computer.username, auth: auth,
                         term: d.string(forKey: TerminalSettings.termType) ?? "xterm-256color")
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
        if let error {
            fail(error)
            return
        }
        state = .closed(nil)
        view.feed(text: "\r\n\u{1b}[2m[접속이 끝났습니다\(status.map { " · 종료 코드 \($0)" } ?? "")]\u{1b}[0m\r\n")
        switch TerminalSettings.OnExit(rawValue: UserDefaults.standard.string(forKey: TerminalSettings.onExit) ?? "") ?? .keep {
        case .close: onRequestClose?(self)
        case .closeIfClean: if (status ?? 0) == 0 { onRequestClose?(self) }
        case .keep: break
        }
    }

    /// 탭·창 제목 (설정 > SSH > 윈도우 > 제목)
    var displayTitle: String {
        let d = UserDefaults.standard
        typealias K = TerminalSettings
        var parts: [String] = []
        if d.object(forKey: K.titleName) as? Bool ?? true { parts.append(computer.name) }
        if d.object(forKey: K.titleAddress) as? Bool ?? true { parts.append("\(computer.username)@\(computer.host)") }
        if d.object(forKey: K.titleDirectory) as? Bool ?? false, let dir = directory { parts.append(dir) }
        if d.object(forKey: K.titleSize) as? Bool ?? false { parts.append("\(size.cols)×\(size.rows)") }
        return parts.isEmpty ? computer.name : parts.joined(separator: " — ")
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
        MainActor.assumeIsolated { shell?.send(data) }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
    }

    nonisolated func bell(source: TerminalView) {
        DispatchQueue.main.async {
            if UserDefaults.standard.object(forKey: TerminalSettings.bellSound) as? Bool ?? true { NSSound.beep() }
        }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        DispatchQueue.main.async {
            guard let s = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
