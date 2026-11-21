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
    /// 터미널 앞에서 돌고 있는 것 (셸·vim·mysql …, 서버가 1초마다 바뀐 것만 알려 줌)
    @Published private(set) var foreground: SSHShell.Foreground?
    /// 파인더로 바꿀 수 없는 이유 (창이 경고로 띄운다)
    @Published var filesBlocked: String?
    /// 서버 지문 질문 (창이 알림으로 띄운다)
    @Published var hostKeyQuestion: SSHShell.HostKeyQuestion?
    private var hostKeyAnswer: ((Bool) -> Void)?

    /// 이 탭에서 보는 것: 터미널 / 파인더(SFTP)
    enum Mode: String { case terminal, files }
    @Published var mode: Mode = .terminal
    /// 파인더 (처음 볼 때 만든다)
    private(set) lazy var files = FileSession(tab: self)

    let view: IMETerminalView
    private var shell: SSHShell?
    /// 파인더가 같은 접속에 SFTP·명령 채널을 연다
    var sshShell: SSHShell? { state == .connected ? shell : nil }
    /// 셸이 끝나 설정대로 탭을 닫아야 할 때 (창 모델이 연결)
    var onRequestClose: ((TerminalTab) -> Void)?

    /// 이 폴더에서 시작 (복제·⌘T). root 면 sudo -s 로
    private let startDirectory: String?
    private let startAsRoot: Bool

    init(computer: Computer, directory: String? = nil, asRoot: Bool = false) {
        self.computer = computer
        startDirectory = directory
        startAsRoot = asRoot
        let d = UserDefaults.standard
        typealias K = TerminalSettings
        let limited = d.object(forKey: K.scrollbackLimited) as? Bool ?? true
        let lines = d.object(forKey: K.scrollbackLines) as? Int ?? 10_000
        // 열×행은 창 폭에서 계산된다 (설정의 "창 크기"는 지웠다: 분할·창 크기마다 바뀌어 고정 값이 안 맞는다)
        let options = TerminalOptions(cols: 80, rows: 24,
                                      termName: d.string(forKey: K.termType) ?? "xterm-256color",
                                      scrollback: limited ? lines : 1_000_000)
        view = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 440), font: Self.font(), options: options)
        super.init()
        view.terminalDelegate = self
        applySettings()
    }

    // MARK: 설정 적용 (설정 > SSH)

    static func font() -> NSFont {
        let d = UserDefaults.standard
        let size = CGFloat(d.object(forKey: TerminalSettings.fontSize) as? Double ?? 13)
        _ = TerminalSettings.registerBundledFonts
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

    struct AuthMessage: Error { let text: String }

    /// 경유 서버들 (바깥쪽부터). 창 모델이 목록에서 찾아 넣는다
    var jumps: [Computer] = []

    /// 키체인에서 이 서버의 로그인 수단 (실패하면 안내 글)
    static func auth(for c: Computer) -> Result<SSHShell.Auth, AuthMessage> {
        let who = c.name
        if c.sshAuth == .key {
            guard let file = Keychain.sshKey(for: c.id) else { return .failure(.init(text: "\(who): 저장된 SSH 키가 없습니다. 서버 편집에서 키를 골라 주세요.")) }
            do {
                return .success(.key(try OpenSSHKey.ed25519(from: file, passphrase: Keychain.sshKeyPassphrase(for: c.id))))
            } catch {
                return .failure(.init(text: "\(who): \(error.localizedDescription)"))
            }
        }
        guard let pw = Keychain.password(for: c.id) else { return .failure(.init(text: "\(who): 저장된 비밀번호가 없습니다. 서버 편집에서 비밀번호를 넣어 주세요.")) }
        return .success(.password(pw))
    }

    func connect() {
        state = .connecting
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
                         startCommand: SSHShell.startCommand(directory: startDirectory, asRoot: startAsRoot),
                         jumps: hops)
        s.onHostKeyQuestion = { [weak self] q, answer in
            guard let self else { answer(false); return }
            self.hostKeyAnswer = answer
            self.hostKeyQuestion = q
        }
        s.onData = { [weak self] bytes in
            self?.view.feed(byteArray: bytes[...])
            self?.view.echoArrived()
        }
        s.onConnected = { [weak self] in
            guard let self else { return }
            self.state = .connected
            self.shell?.watchForeground { [weak self] f in self?.foreground = f }
            let cmd = (d.string(forKey: TerminalSettings.startupCommand) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty { self.shell?.send(Array((cmd + "\r").utf8)[...]) }
        }
        s.onClose = { [weak self] error, status in self?.closed(error: error, status: status) }
        shell = s
        s.connect(cols: size.cols, rows: size.rows, keepAlive: d.object(forKey: TerminalSettings.keepAlive) as? Bool ?? true)
    }

    /// 파인더를 한 번이라도 열었는지 (닫을 때 SFTP 도 닫는다)
    private(set) var filesStarted = false

    /// 탭에 작게 보일 것: 셸이면 지금 폴더, 아니면 앞에서 돌고 있는 프로그램 이름 (vim·mysql·top …)
    var frontLabel: String? {
        if let f = foreground, !f.isShell { return f.comm }
        return workingDirectory
    }

    /// 파인더로 바꾸기 (⌘2·[터미널 | 파인더]). 지금 터미널 셸의 사용자 권한으로 연다 (사용자):
    /// 앞쪽이 셸이 아니거나(vim·mysql …) 프롬프트에 쳐 둔 명령이 있으면 바꾸지 않고 이유를 알린다.
    /// 앞쪽 셸이 로그인 계정이 아니면(sudo su, su - ubuntu) 그 셸에 sftp-server 를 띄워 파인더를 거기에 잇는다
    func requestFiles() async {
        guard mode != .files else { return }
        guard let shell = sshShell else { filesBlocked = "접속돼 있지 않습니다."; return }
        guard let f = await shell.foreground() else {
            // 리눅스가 아니라 앞쪽을 모르면 예전처럼 로그인 계정으로
            files.useIdentity(user: computer.username, bridge: nil)
            setMode(.files)
            return
        }
        foreground = f
        if !f.isShell {
            filesBlocked = "터미널 앞에서 \(f.comm) 이(가) 실행 중입니다.\n끝내고 셸 프롬프트로 돌아온 뒤 바꿔 주세요."
            return
        }
        if !promptIsEmpty() {
            filesBlocked = "프롬프트에 입력하다 만 명령이 있습니다.\n지우거나 실행한 뒤 바꿔 주세요."
            return
        }
        if !f.otherUser {
            files.useIdentity(user: f.user, bridge: nil)
        } else if files.viewer != f.user || !files.isOpen {
            // 그 셸에 한 줄 넣는 동안 사용자 입력을 막는다 (섞이지 않게)
            view.inputLocked = true
            let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
            shell.send(Array(Self.helperCommand(token: token, login: computer.username).utf8)[...])
            files.useIdentity(user: f.user, bridge: Self.bridgeCommand(token: token))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.view.inputLocked = false }
        }
        setMode(.files)
    }

    /// 다른 사용자 셸에 넣는 한 줄: 무작위 폴더에 통로(FIFO) 둘을 만들고 그 셸 사용자로 sftp-server 를 띄운다.
    /// 앞 공백 = bash 기록에 안 남김(ignorespace), 바깥 ( … & ) = 작업 번호 글이 안 뜸.
    /// root 면 통로 주인을 로그인 계정으로 바꿔 둘만 쓰고, 아니면 666 + 남이 목록을 못 보는 폴더(711) + 3초 뒤 이름 지움
    private static func helperCommand(token: String, login: String) -> String {
        let d = "/tmp/.ivnc-\(token)"
        let body = "d=\(d); mkdir -m 711 $d && mkfifo -m 600 $d/i $d/o && { chown '\(login)' $d/i $d/o 2>/dev/null || chmod 666 $d/i $d/o; } && "
            + "for s in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server /usr/libexec/sftp-server; do [ -x $s ] && break; done; "
            + "($s <$d/i >$d/o 2>/dev/null &); sleep 3; rm -rf $d"
        return " ( ( \(body) ) >/dev/null 2>&1 & )\r"
    }

    /// 로그인 계정 채널에서 그 통로에 잇는 명령 (sftp-server 표준 입출력 ↔ 이 채널)
    private static func bridgeCommand(token: String) -> String {
        let d = "/tmp/.ivnc-\(token)"
        return "d=\(d); i=0; while [ ! -p $d/o ] && [ $i -lt 25 ]; do sleep 0.1; i=$((i+1)); done; cat $d/o & exec cat > $d/i"
    }

    /// 커서 줄이 프롬프트로 끝나는지 (쳐 둔 명령이 없는지). 마지막 글자 줄이 $ # % > ❯ 로 끝나야 한다
    private func promptIsEmpty() -> Bool {
        let data = view.getBufferAsData(kind: .active, encoding: .utf8)
        let lines = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return true }
        let t = last.trimmingCharacters(in: .whitespaces)
        return t.range(of: #"[$#%>❯»]$"#, options: .regularExpression) != nil
    }

    func setMode(_ m: Mode) {
        if m == .files { filesStarted = true }
        mode = m
        if m == .terminal { DispatchQueue.main.async { self.view.window?.makeFirstResponder(self.view) } }
    }

    func answerHostKey(_ ok: Bool) {
        hostKeyQuestion = nil
        hostKeyAnswer?(ok)
        hostKeyAnswer = nil
    }

    func disconnect() {
        directoryPoll?.cancel()
        if mode == .files || filesStarted { files.close() }
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

    // MARK: 지금 폴더 (탭에 작게)

    /// 서버에 물어본 지금 폴더 (OSC 7·창 제목에 경로가 없는 셸일 때)
    @Published private(set) var polledDirectory: String?
    private var directoryPoll: Task<Void, Never>?

    /// 탭에 작게 보일 지금 폴더: OSC 7 → 셸이 붙인 창 제목("root@sun: /var/www", 우분투 기본) → 엔터 뒤 서버에 물어본 값.
    /// 홈은 ~ 로 줄인다
    var workingDirectory: String? {
        let shellDir = foreground.flatMap { $0.isShell ? $0.directory : nil }
        guard let path = osc7Path ?? titlePath ?? shellDir ?? polledDirectory else { return nil }
        let home = computer.username == "root" ? "/root" : "/home/\(computer.username)"
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var osc7Path: String? { directory.flatMap { URL(string: $0)?.path }.flatMap { $0.isEmpty ? nil : $0 } }

    private var titlePath: String? {
        guard let r = remoteTitle.range(of: ": ", options: .backwards) else { return nil }
        let p = String(remoteTitle[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return p.hasPrefix("/") || p.hasPrefix("~") ? p : nil
    }

    /// 잠깐 뒤 서버에 지금 폴더를 묻는다 (명령마다 묻지 않게 엔터 뒤 0.8초 모아서)
    private func refreshDirectory(after seconds: Double) {
        directoryPoll?.cancel()
        directoryPoll = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let shell = self?.sshShell else { return }
            let st = await shell.currentState()
            if !Task.isCancelled, let d = st.directory { self?.polledDirectory = d }
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
        MainActor.assumeIsolated {
            if view.inputLocked { NSSound.beep(); return }
            shell?.send(data)
        }
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
