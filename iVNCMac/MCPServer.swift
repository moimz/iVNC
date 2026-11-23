import Foundation
import AppKit
import Network

/// MCP 가 열어 줄 SSH 서버 범위 (설정 > MCP)
enum MCPScope: String, CaseIterable, Identifiable {
    /// 등록된 모든 SSH 서버 (열린 탭이 없으면 저장된 암호·키로 MCP 가 따로 접속)
    case all
    /// 터미널 탭이 열려 있는 서버
    case open
    /// 지금 앞에 있는 터미널 창의 활성 탭 서버 하나
    case active
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "모든 서버"
        case .open: return "열린 탭의 서버"
        case .active: return "지금 활성 탭의 서버만"
        }
    }
}

/// MCP 권한 (설정 > MCP, 사용자 2026-11-20)
enum MCPPermission: String, CaseIterable, Identifiable {
    /// 목록·파일 읽기·터미널 화면 읽기·화면 그림만 (명령 실행 없음)
    case readOnly
    /// 안전한 명령은 확인 없이, 그 밖은 거절
    case safeOnly
    /// 안전한 명령은 확인 없이, 그 밖은 앱에서 확인한 뒤
    case confirm
    /// 모두 확인 없이
    case full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .readOnly: return "읽기만"
        case .safeOnly: return "안전한 명령만"
        case .confirm: return "위험한 명령은 확인 후 실행"
        case .full: return "모든 명령 자동 실행"
        }
    }
    var detail: String {
        switch self {
        case .readOnly: return "서버·파일 목록, 파일 내용, 터미널 화면, 원격 화면 그림만 봅니다. 명령은 실행하지 않습니다."
        case .safeOnly: return "조회 명령(ls·cat·grep·df·ps·git status 등)은 바로 실행하고, 그 밖의 명령·파일 쓰기·지우기는 거절합니다."
        case .confirm: return "조회 명령은 바로 실행하고, 그 밖의 명령·파일 쓰기·지우기·터미널 입력은 iVNC 에서 허락해야 실행합니다."
        case .full: return "모든 명령·파일 쓰기·지우기·터미널 입력을 확인 없이 실행합니다."
        }
    }
}

/// 셸 명령이 안전한(읽기만 하는) 것인지. 허용 목록 방식: 아는 조회 명령만 안전, 모르면 위험
enum CommandSafety {
    /// 안전한 명령 (첫 낱말)
    private static let safe: Set<String> = [
        "ls", "ll", "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "find", "wc", "stat", "file",
        "du", "df", "free", "ps", "pgrep", "uptime", "uname", "whoami", "id", "pwd", "date", "hostname", "which", "whereis",
        "type", "echo", "printf", "env", "printenv", "sort", "uniq", "cut", "tr", "column", "nl", "diff", "cmp", "md5sum",
        "sha1sum", "sha256sum", "base64", "realpath", "readlink", "dirname", "basename", "tree", "lsblk", "lscpu", "lsof",
        "ss", "netstat", "ip", "ifconfig", "ping", "dig", "nslookup", "host", "w", "who", "last", "groups", "getent",
        "journalctl", "dmesg", "top", "vmstat", "iostat", "mount", "nproc", "arch", "locale", "test", "true", "false",
        "jq", "zcat", "zgrep", "xxd", "od", "hexdump", "strings", "sleep", "timeout", "nice", "time",
        "a2query", "lastb", "lastlog", "lsb_release", "lsmod", "lspci", "lsusb",
    ]
    /// 옵션으로 동작이 갈리는 명령: need 중 하나는 꼭 있고, '-' 로 시작하는 낱말은 모두 allowed 안에 있어야 안전.
    /// freeArgs 가 false 면 '-' 없는 낱말도 allowed 안에 있어야 한다
    private struct FlagRule { let need: Set<String>; let allowed: Set<String>; var freeArgs = true }
    private static let flagRules: [String: FlagRule] = {
        let ipt = FlagRule(need: ["-S", "-L", "--list", "--list-rules", "-nL", "-nvL", "-vnL", "-Ln", "-Lnv"],
                           allowed: ["-S", "-L", "--list", "--list-rules", "-n", "-v", "-x", "-t", "-w", "--line-numbers",
                                     "--numeric", "--verbose", "--exact", "--table", "-nL", "-nvL", "-vnL", "-Ln", "-Lnv"])
        let apache = FlagRule(need: ["-S", "-M", "-t", "-v", "-V", "-l", "-L", "configtest"],
                              allowed: ["-S", "-M", "-t", "-v", "-V", "-l", "-L", "configtest", "-D",
                                        "DUMP_VHOSTS", "DUMP_MODULES", "DUMP_RUN_CFG", "DUMP_INCLUDES"], freeArgs: false)
        let dpkgQ: Set<String> = ["-l", "-L", "-s", "-S", "-p", "--list", "--status", "--search", "--listfiles", "--print-avail"]
        return [
            "dpkg": FlagRule(need: dpkgQ, allowed: dpkgQ),
            "dpkg-query": FlagRule(need: dpkgQ.union(["-W", "--show"]),
                                   allowed: dpkgQ.union(["-W", "--show", "-f", "--showformat"])),
            "rpm": FlagRule(need: ["-q", "-qa", "-qi", "-ql", "-qf", "-qc", "--query"],
                            allowed: ["-q", "-qa", "-qi", "-ql", "-qf", "-qc", "--query", "-a", "-i", "-l", "-f", "-c", "--qf", "--queryformat", "--changelog"]),
            "nginx": FlagRule(need: ["-t", "-T", "-v", "-V"], allowed: ["-t", "-T", "-v", "-V", "-q", "-c", "-p", "-e"]),
            "crontab": FlagRule(need: ["-l"], allowed: ["-l", "-u"]),
            "sshd": FlagRule(need: ["-T"], allowed: ["-T", "-C", "-f"]),
            "iptables": ipt, "ip6tables": ipt,
            "iptables-save": FlagRule(need: [], allowed: ["-t", "-c", "--table", "--counters"]),
            "ip6tables-save": FlagRule(need: [], allowed: ["-t", "-c", "--table", "--counters"]),
            "apache2ctl": apache, "apachectl": apache, "httpd": apache,
        ]
    }()
    /// 하위 명령까지 봐야 하는 것: 명령 → 안전한 하위 명령
    private static let safeSub: [String: Set<String>] = [
        "systemctl": ["status", "list-units", "list-unit-files", "is-active", "is-enabled", "is-failed", "show", "cat"],
        "docker": ["ps", "logs", "images", "inspect", "stats", "version", "info", "top", "port", "events"],
        "git": ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "describe", "blame", "ls-files", "tag", "shortlog"],
        "apt": ["list", "show", "search", "policy"], "apt-cache": ["show", "search", "policy", "depends"],
        "npm": ["ls", "list", "view", "outdated"],
        "pip": ["list", "show", "freeze"], "pip3": ["list", "show", "freeze"],
        "kubectl": ["get", "describe", "logs", "top", "version"],
        "ufw": ["status"], "service": ["--status-all"],
        "fail2ban-client": ["status", "ping", "version", "banned", "get"],
        "ipsec": ["--version", "version", "status", "trafficstatus", "showstates", "globalstatus"],
        "nft": ["list"], "snap": ["list", "info", "version", "changes"],
        "certbot": ["certificates"], "openssl": ["version"],
        "timedatectl": ["status", "show"], "hostnamectl": ["status"], "loginctl": ["list-sessions", "list-users", "show-session"],
    ]

    /// 위험하면 그 이유, 안전하면 nil
    static func check(_ command: String) -> String? {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { return "빈 명령" }
        // 파일로 쓰기·명령 바꿔치기는 어디에 있든 위험 (따옴표 안이어도 보수적으로)
        if c.contains("$(") || c.contains("`") { return "명령 바꿔치기($( ) · `)" }
        if c.contains("<(") || c.contains(">(") { return "프로세스 치환" }
        // 출력 돌리기 중 쓰기가 아닌 것(2>&1, >/dev/null)만 빼고, 남은 > 는 파일로 쓰기
        var probe = c
        for pat in [#"[0-9]?>&[0-9]"#, #"&?[0-9]?>{1,2}\s*/dev/null"#] {
            probe = probe.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
        }
        if probe.contains(">") { return "파일로 쓰기(>)" }
        // ; && || | & 로 나눈 조각마다
        let parts = probe.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for p in parts {
            if let why = checkSimple(p) { return why }
        }
        return nil
    }

    private static func checkSimple(_ part: String) -> String? {
        var words = part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // 앞의 VAR=값 은 건너뛴다
        while let w = words.first, w.contains("="), !w.hasPrefix("-"), w.first?.isLetter == true { words.removeFirst() }
        // 감싸는 명령은 그 뒤 명령으로
        while let w = words.first, ["nice", "time", "timeout"].contains(w) {
            words.removeFirst()
            while let n = words.first, n.hasPrefix("-") || Int(n) != nil || n.hasSuffix("s") && Int(n.dropLast()) != nil { words.removeFirst() }
        }
        guard let cmd = words.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        if cmd == "sudo" || cmd == "su" || cmd == "doas" { return "\(cmd) (권한 올리기)" }
        // --output=파일 처럼 파일로 내보내는 옵션 (git log --output 등)
        if words.dropFirst().contains(where: { $0.hasPrefix("--output") || $0.hasPrefix("--log-file") }) { return "\(cmd) 의 파일 쓰기 옵션" }
        if let rule = flagRules[cmd] {
            let args = Array(words.dropFirst())
            for arg in args {
                // -f=값, --format=값 은 = 앞만 본다
                let w = arg.hasPrefix("-") ? String(arg.split(separator: "=", maxSplits: 1).first ?? "") : arg
                if w.hasPrefix("-") ? !rule.allowed.contains(w) : (!rule.freeArgs && !rule.allowed.contains(w)) { return "\(cmd) \(w)" }
            }
            if !rule.need.isEmpty && !args.contains(where: { rule.need.contains($0) }) { return "\(cmd) (조회 옵션 없음)" }
            return nil
        }
        if let subs = safeSub[cmd] {
            let sub = words.dropFirst().first { !$0.hasPrefix("-") || subs.contains($0) } ?? ""
            return subs.contains(sub) ? nil : "\(cmd) \(sub)"
        }
        guard safe.contains(cmd) else { return cmd }
        let args = words.dropFirst()
        if cmd == "find", args.contains(where: { ["-exec", "-execdir", "-delete", "-ok", "-okdir", "-fprint", "-fprintf", "-fls"].contains($0) }) {
            return "find 의 실행·지우기·파일 쓰기 옵션"
        }
        if cmd == "top", !args.contains("-b") && !args.contains("-n") { return nil }
        return nil
    }
}

/// iVNC MCP 서버 (이 맥 안에서만, Streamable HTTP POST /mcp). iSQL MCP 와 같은 방식
@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer()

    enum Status: Equatable { case stopped, running(Int), failed(String) }
    @Published private(set) var status: Status = .stopped

    /// 컴퓨터 목록 (앱이 시작할 때 넣어 준다)
    weak var store: ComputerStore?

    // MARK: 설정 (UserDefaults, 이 맥에만)

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "mcp.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "mcp.enabled"); restart() }
    }
    @Published var port: Int = UserDefaults.standard.object(forKey: "mcp.port") as? Int ?? 8767 {
        didSet { UserDefaults.standard.set(port, forKey: "mcp.port"); if oldValue != port { restart() } }
    }
    @Published var scope: MCPScope = MCPScope(rawValue: UserDefaults.standard.string(forKey: "mcp.scope") ?? "") ?? .open {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "mcp.scope") }
    }
    @Published var permission: MCPPermission = MCPPermission(rawValue: UserDefaults.standard.string(forKey: "mcp.permission") ?? "") ?? .confirm {
        didSet { UserDefaults.standard.set(permission.rawValue, forKey: "mcp.permission") }
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
        let ok: Bool
    }
    @Published private(set) var log: [LogEntry] = []
    private func note(_ text: String, ok: Bool = true) {
        log.insert(LogEntry(text: text, ok: ok), at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }

    // MARK: 듣기

    private var listener: NWListener?

    func startIfEnabled() { if enabled && listener == nil { start() } }

    private func restart() {
        stop()
        if enabled { start() }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        status = .stopped
    }

    private func start() {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port >= 1024 else {
            status = .failed("포트는 1024~65535")
            return
        }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    guard let self else { return }
                    switch st {
                    case .ready: self.status = .running(self.port)
                    case .failed(let e): self.status = .failed(e.localizedDescription); self.listener = nil
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: HTTP (요청 하나 받고 답하고 닫는다)

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = HTTPRequest(buf) {
                    await self.respond(c, req)
                } else if done || error != nil || buf.count > 64 << 20 {
                    c.cancel()
                } else {
                    self.receive(c, buffer: buf)
                }
            }
        }
    }

    private func respond(_ c: NWConnection, _ req: HTTPRequest) async {
        // 브라우저가 이 포트로 몰래 요청하는 것(DNS 리바인딩) 막기: Origin 이 있으면 localhost 만
        if let origin = req.headers["origin"], !(origin.contains("://127.0.0.1") || origin.contains("://localhost")) {
            send(c, status: "403 Forbidden", body: Data())
            return
        }
        guard req.path.hasPrefix("/mcp") else { send(c, status: "404 Not Found", body: Data()); return }
        switch req.method {
        case "POST": break
        case "DELETE": send(c, status: "200 OK", body: Data()); return
        default: send(c, status: "405 Method Not Allowed", body: Data()); return
        }
        guard let json = try? JSONSerialization.jsonObject(with: req.body) else {
            send(c, status: "400 Bad Request", json: rpcError(nil, -32700, "JSON 을 읽지 못했습니다"))
            return
        }
        if let batch = json as? [[String: Any]] {
            var out: [[String: Any]] = []
            for m in batch { if let r = await handle(m) { out.append(r) } }
            if out.isEmpty { send(c, status: "202 Accepted", body: Data()) } else { send(c, status: "200 OK", json: out) }
        } else if let m = json as? [String: Any] {
            if let r = await handle(m) { send(c, status: "200 OK", json: r) } else { send(c, status: "202 Accepted", body: Data()) }
        } else {
            send(c, status: "400 Bad Request", json: rpcError(nil, -32600, "잘못된 요청"))
        }
    }

    private func send(_ c: NWConnection, status: String, json: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])) ?? Data()
        send(c, status: status, body: body, type: "application/json")
    }

    private func send(_ c: NWConnection, status: String, body: Data, type: String? = nil) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: JSON-RPC

    private func rpcError(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func handle(_ m: [String: Any]) async -> [String: Any]? {
        let id = m["id"]
        let method = m["method"] as? String ?? ""
        let params = m["params"] as? [String: Any] ?? [:]
        guard id != nil else { return nil }
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id!, "result": result] }
        switch method {
        case "initialize":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            return ok([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "iVNC", "version": version],
                "instructions": "iVNC 앱으로 SSH 서버에 명령을 실행하고 파일을 다루며, 열린 터미널 화면을 읽는다. 먼저 list_servers 로 쓸 수 있는 서버와 권한을 확인한다. 위험한 명령은 사용자가 iVNC 에서 허락해야 실행될 수 있다.",
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let content = try await call(name, args)
                return ok(["content": content, "isError": false])
            } catch {
                note("\(name): \(error.localizedDescription)", ok: false)
                return ok(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return rpcError(id, -32601, "모르는 메서드: \(method)")
        }
    }

    // MARK: 도구 목록

    private static let serverArg: [String: Any] = ["type": "string", "description": "서버 이름 또는 id (list_servers). 범위가 '지금 활성 탭의 서버만' 이면 생략 가능"]
    private static let rootArg: [String: Any] = ["type": "boolean", "description": "true 면 root 로. 방법은 iVNC 가 고른다: root 로 접속하는 서버면 그대로, 아니면 열린 터미널의 root 셸(sudo su 해 둔 것)을 빌리고, 그것도 없으면 암호 없는 sudo. 다 안 되면 root 를 쓸 수 없다고 거절한다(로그인 계정으로 대신 하지 않음). 먼저 list_servers 의 root 를 본다"]

    /// server_info 가 돌리는 조회 묶음. 명령은 앱이 만든 고정된 읽기 명령뿐이라 권한·확인 없이 실행한다
    private static let infoTopics: [(key: String, title: String, command: String)] = [
        ("os", "운영체제·가동 시간",
         "grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>/dev/null || sw_vers 2>/dev/null; uname -srm; uptime; hostname -f 2>/dev/null || hostname"),
        ("resources", "CPU·메모리·디스크",
         "echo \"CPU $(nproc 2>/dev/null)개\"; free -h 2>/dev/null; df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null || df -h"),
        ("updates", "밀린 업데이트·재부팅 필요",
         "if command -v apt >/dev/null 2>&1; then apt list --upgradable 2>/dev/null; elif command -v dnf >/dev/null 2>&1; then dnf -q --cacheonly check-update 2>&1; elif command -v yum >/dev/null 2>&1; then yum -q -C check-update 2>&1; fi; if [ -f /var/run/reboot-required ]; then echo '--- 재부팅 필요'; cat /var/run/reboot-required.pkgs 2>/dev/null; fi"),
        ("ports", "열린 포트",
         "ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null"),
        ("services", "도는 서비스·실패한 서비스",
         "systemctl list-units --type=service --state=running --no-pager --no-legend 2>&1; echo '--- 실패한 서비스'; systemctl --failed --no-pager --no-legend 2>&1"),
        ("firewall", "방화벽",
         "ufw status verbose 2>&1; echo '--- iptables'; iptables -S 2>&1 | head -200; echo '--- nftables'; nft list ruleset 2>&1 | head -200"),
        ("ssh", "SSH 서버 설정",
         "(sshd -T 2>/dev/null || grep -hEiv '^[[:space:]]*(#|$)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null) | grep -Ei '^[[:space:]]*(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitemptypasswords|usepam|maxauthtries|logingracetime|x11forwarding|allowtcpforwarding|allowusers|allowgroups|denyusers|clientaliveinterval)[[:space:]]'"),
        ("logins", "접속자·로그인 기록",
         "echo '--- 지금 접속'; who; echo '--- 최근 로그인'; last -n 20 -i 2>/dev/null | head -22; echo '--- 암호 실패 횟수'; grep -c 'Failed password' /var/log/auth.log 2>/dev/null || grep -c 'Failed password' /var/log/secure 2>/dev/null; fail2ban-client status 2>/dev/null"),
        ("processes", "CPU 많이 쓰는 프로세스",
         "ps aux --sort=-%cpu 2>/dev/null | head -20 || ps aux | head -20"),
        ("docker", "도커 컨테이너",
         "docker ps -a --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}' 2>&1"),
        ("cron", "예약 작업",
         "crontab -l 2>&1; echo '--- /etc/cron.d'; ls /etc/cron.d 2>/dev/null; echo '--- 타이머'; systemctl list-timers --no-pager 2>/dev/null | head -30"),
        ("web", "웹 서버 가상 호스트",
         "apache2ctl -S 2>/dev/null || httpd -S 2>/dev/null; nginx -T 2>/dev/null | grep -E '^[[:space:]]*(server_name|listen)[[:space:]]' | sort -u"),
    ]
    private static let defaultTopics = ["os", "resources", "updates", "ports"]

    private static let tools: [[String: Any]] = [
        ["name": "server_info",
         "description": "서버 상태를 안전하게 조회한다. 앱이 정해 둔 읽기 명령만 돌려서 확인 창이 안 뜨고 '읽기만' 권한에서도 된다. 서버 점검·현황 파악에는 run_command 보다 이것을 먼저 쓴다. "
            + "topics: " + infoTopics.map { "\($0.key)(\($0.title))" }.joined(separator: ", ")
            + ", packages(packages 에 준 패키지 버전), logs(unit 의 journal 마지막 lines 줄, unit 없으면 경고 이상). 생략하면 " + defaultTopics.joined(separator: ","),
         "inputSchema": ["type": "object", "properties": [
            "server": serverArg,
            "topics": ["type": "array", "items": ["type": "string", "enum": infoTopics.map(\.key) + ["packages", "logs", "all"]],
                       "description": "all = packages·logs 를 뺀 전부"],
            "packages": ["type": "array", "items": ["type": "string"], "description": "packages 주제: 버전을 볼 패키지 이름 (예: openssh-server, nginx)"],
            "unit": ["type": "string", "description": "logs 주제: systemd 유닛 이름 (예: nginx, sshd)"],
            "lines": ["type": "integer", "description": "logs 주제: 줄 수 (기본 100, 최대 1000)"],
         ]]],
        ["name": "list_servers",
         "description": "iVNC 가 MCP 에 열어 준 SSH 서버 목록(열린 터미널 탭·활성 탭 표시), 원격 화면 세션 목록, 지금 설정(접근 범위·권한). 서버마다 root 상태: root = direct(root 로 접속) · root_shell(열린 터미널에 바로 빌릴 수 있는 root 셸) · root_shell_busy(root 셸이 있지만 지금은 못 씀) · sudo(암호 없는 sudo) · none(root 못 씀: 사용자에게 터미널에서 sudo su 해 달라고 한다) · unknown(접속 안 돼 모름). root 가 필요한 일은 이걸 보고 as_root 로 부른다",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "run_command",
         "description": "서버에서 셸 명령 하나 실행 (사용자 터미널과 별도 채널, 화면에 안 보임). 조회 명령(ls·cat·grep·df·ps·git status 등)은 바로, 그 밖은 권한에 따라 거절되거나 사용자 확인 뒤 실행. 결과: 종료 코드·표준 출력·표준 오류. 서버 현황 조회는 server_info 를 먼저 쓴다",
         "inputSchema": ["type": "object", "properties": [
            "server": serverArg,
            "command": ["type": "string"],
            "cwd": ["type": "string", "description": "이 폴더에서 실행"],
            "timeout_seconds": ["type": "integer", "description": "기본 60, 최대 600"],
            "as_root": rootArg,
         ], "required": ["command"]]],
        ["name": "read_terminal",
         "description": "열린 터미널 탭에 보이는 화면과 스크롤백의 마지막 lines 줄 (기본 120, 최대 3000). '이 에러 뭐야?' 처럼 사용자가 보고 있는 화면을 볼 때",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "lines": ["type": "integer"]]]],
        ["name": "send_to_terminal",
         "description": "열린 터미널 탭(그 서버의 활성 탭)에 글자를 입력한다. 사용자가 보는 화면에 그대로 쳐진다. enter=true 면 끝에 엔터. 늘 위험한 동작으로 본다",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "text": ["type": "string"], "enter": ["type": "boolean"]], "required": ["text"]]],
        ["name": "list_files",
         "description": "서버 폴더의 파일 목록 (SFTP): 이름·종류·크기·수정 시각·권한·소유자",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "path": ["type": "string", "description": "없으면 홈"], "as_root": rootArg]]],
        ["name": "read_file",
         "description": "서버 파일 내용 (SFTP, UTF-8 글자). max_bytes 기본 200000, 최대 2000000",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "path": ["type": "string"], "max_bytes": ["type": "integer"], "as_root": rootArg], "required": ["path"]]],
        ["name": "write_file",
         "description": "서버 파일에 내용을 쓴다 (있으면 덮어씀). 위험한 동작",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "path": ["type": "string"], "content": ["type": "string"]], "required": ["path", "content"]]],
        ["name": "delete_path",
         "description": "서버 파일이나 폴더(안쪽까지)를 지운다. 위험한 동작",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "path": ["type": "string"]], "required": ["path"]]],
        ["name": "upload",
         "description": "이 맥 파일이나 폴더(안쪽까지)를 서버로 올린다. 위험한 동작이지만 아래 일을 모두 묶어 한 번만 허락받는다: "
            + "임시 이름으로 올린 뒤 한 번에 바꿔치기(도중에 실패해도 원래 파일은 그대로), 바꾸는 파일의 권한·소유자 유지(mode·owner 로 바꿀 수 있음), "
            + "원래 파일을 서버에 '이름.bak-날짜시각' 으로 남기기(backup, 기본 켬), 원래 파일을 먼저 이 맥으로 받아 두기(backup_to_mac). "
            + "인증서 갱신처럼 root 파일을 바꿀 때는 as_root=true. 서비스 다시 읽기(nginx -t && systemctl reload nginx 등)는 run_command 에 as_root=true 로",
         "inputSchema": ["type": "object", "properties": [
            "server": serverArg,
            "local_path": ["type": "string", "description": "이 맥 파일 또는 폴더"],
            "remote_path": ["type": "string", "description": "서버에 놓일 경로. 파일을 올릴 때 이미 있는 폴더를 주면 그 안에 같은 이름으로. 폴더를 올리면 그 폴더 자리(있으면 안에 합침)"],
            "mode": ["type": "string", "description": "권한 8진수 (예: 644, 600). 없으면 바꾸는 파일 것을 유지, 새 파일은 서버 기본"],
            "owner": ["type": "string", "description": "소유자 '사용자' 또는 '사용자:그룹' (root 셸에서만 바꿀 수 있음). 없으면 바꾸는 파일 것을 유지"],
            "backup": ["type": "boolean", "description": "원래 파일을 서버에 '이름.bak-날짜시각' 으로 남김 (기본 true)"],
            "backup_to_mac": ["type": "string", "description": "원래 파일을 바꾸기 전에 이 맥의 이 폴더로 받아 둔다 (없으면 만듦)"],
            "as_root": rootArg,
         ], "required": ["local_path", "remote_path"]]],
        ["name": "download",
         "description": "서버 파일이나 폴더(안쪽까지)를 이 맥으로 받는다. local_path 가 이미 있는 폴더면 그 안에 같은 이름으로. 이 맥 파일을 덮어쓰게 되면 위험한 동작으로 본다",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "remote_path": ["type": "string"], "local_path": ["type": "string"], "as_root": rootArg], "required": ["remote_path", "local_path"]]],
        ["name": "screenshot",
         "description": "열려 있는 원격 화면(맥 화면 공유·윈도우 원격 데스크톱) 창의 지금 화면 그림. computer 가 없으면 지금 앞에 있는 화면 창(없으면 첫 창)",
         "inputSchema": ["type": "object", "properties": ["computer": ["type": "string", "description": "컴퓨터 이름 또는 id"]]]],
    ]

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    // MARK: 도구 실행

    private func call(_ name: String, _ a: [String: Any]) async throws -> [[String: Any]] {
        func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }
        switch name {
        case "list_servers":
            return text(json(await listServers()))

        case "run_command":
            let cmd = try string(a, "command")
            let t = try target(a)
            let cwd = a["cwd"] as? String
            let full = cwd.map { "cd -- '\($0.replacingOccurrences(of: "'", with: "'\\''"))' && " + cmd } ?? cmd
            let timeout = min(max(a["timeout_seconds"] as? Int ?? 60, 1), 600)
            guard a["as_root"] as? Bool ?? false, t.computer.username != "root" else {
                try await allow(server: t, action: cmd, danger: CommandSafety.check(full))
                let shell = try await connection(t)
                let r = try await shell.execFull(full, timeout: timeout)
                note("\(t.name): \(cmd.prefix(60))")
                return text(json(Self.execOut(r)))
            }
            // root: 방법을 먼저 정하고(안 되면 여기서 거절) 묻는다
            let runner = try await rootRunner(t, try await rootRoute(t))
            try await allow(server: t, action: "(\(runner.how)) " + cmd, danger: CommandSafety.check(full).map { "\($0), root 로 실행" })
            let r = try await runner.run(full, timeout)
            note("\(t.name): (\(runner.how)) \(cmd.prefix(60))")
            var out = Self.execOut(r)
            out["as"] = runner.how
            return text(json(out))

        case "server_info":
            let t = try target(a)
            var keys = (a["topics"] as? [String]) ?? []
            if keys.isEmpty { keys = Self.defaultTopics }
            if keys.contains("all") { keys = Self.infoTopics.map(\.key) + keys.filter { $0 == "packages" || $0 == "logs" } }
            var jobs: [(String, String)] = []
            for k in keys {
                if let topic = Self.infoTopics.first(where: { $0.key == k }) {
                    jobs.append(("\(k) — \(topic.title)", topic.command))
                } else if k == "packages" {
                    let names = (a["packages"] as? [String] ?? []).filter { $0.range(of: #"^[A-Za-z0-9.+_:*-]+$"#, options: .regularExpression) != nil }
                    guard !names.isEmpty else { throw Failure("packages 주제에는 packages 에 패키지 이름을 주세요.") }
                    let list = names.map { "'\($0)'" }.joined(separator: " ")
                    jobs.append(("packages — 패키지 버전",
                                 "if command -v dpkg-query >/dev/null 2>&1; then dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\\n' \(list) 2>&1; else rpm -q \(list) 2>&1; fi"))
                } else if k == "logs" {
                    let lines = min(max(a["lines"] as? Int ?? 100, 1), 1000)
                    if let unit = a["unit"] as? String, !unit.isEmpty {
                        guard unit.range(of: #"^[A-Za-z0-9@._:-]+$"#, options: .regularExpression) != nil else { throw Failure("unit 이름이 이상합니다: \(unit)") }
                        jobs.append(("logs — \(unit) 마지막 \(lines)줄", "journalctl -u '\(unit)' -n \(lines) --no-pager 2>&1"))
                    } else {
                        jobs.append(("logs — 경고 이상 마지막 \(lines)줄", "journalctl -p warning -n \(lines) --no-pager 2>&1"))
                    }
                } else {
                    throw Failure("모르는 주제: \(k)")
                }
            }
            let shell = try await connection(t)
            var out = ""
            for (title, cmd) in jobs {
                let r = try await shell.execFull("LC_ALL=C; export LC_ALL; " + cmd, timeout: 60)
                let body = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                out += "## \(title)\n" + (body.isEmpty ? "(없음)" : Self.clip(body, max: 40_000)) + (r.timedOut ? "\n(시간 초과)" : "") + "\n\n"
            }
            note("\(t.name): 서버 정보 \(keys.joined(separator: ","))")
            return text(out)

        case "read_terminal":
            let tab = try terminalTab(a)
            let lines = min(max(a["lines"] as? Int ?? 120, 1), 3000)
            let data = tab.view.getBufferAsData(kind: .active, encoding: .utf8)
            var all = String(decoding: data, as: UTF8.self).components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\u{0}", with: " ") }
            while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
            note("\(tab.computer.name): 터미널 읽기")
            return text(all.suffix(lines).joined(separator: "\n"))

        case "send_to_terminal":
            let tab = try terminalTab(a)
            let s = try string(a, "text") + ((a["enter"] as? Bool ?? false) ? "\r" : "")
            try await allow(server: Target(computer: tab.computer, tab: tab), action: "터미널에 입력: \(s)", danger: "터미널 입력")
            guard let shell = tab.sshShell else { throw Failure("그 탭은 접속돼 있지 않습니다.") }
            shell.send(Array(s.utf8)[...])
            note("\(tab.computer.name): 터미널 입력")
            return text("입력했습니다. 결과는 read_terminal 로 보세요.")

        case "list_files":
            let t = try target(a)
            if let root = try await stagedRoot(t, a) {
                let path = (a["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/root"
                let out = try await rootOK(root, "ls -la -- \(Self.q(path))")
                note("\(t.name): (\(root.how)) 목록 \(path)")
                return text(json(["path": path, "as_user": "root", "via": root.how, "listing": Self.clip(out)]))
            }
            let fc = try await fileClient(t, a)
            defer { fc.finish() }
            let sftp = fc.client
            var path = a["path"] as? String ?? ""
            if path.isEmpty { path = try await sftp.realpath(".") }
            let list = try await sftp.list(path)
            let names = await Owners.load(sftp)
            let f = ISO8601DateFormatter()
            var out: [String: Any] = ["path": path, "entries": list.sorted { $0.name < $1.name }.map { e -> [String: Any] in
                ["name": e.name, "type": e.isDirectory ? "dir" : e.attrs.isSymlink ? "link" : "file",
                 "size": e.attrs.size.map { $0 as Any } ?? NSNull(),
                 "modified": e.attrs.modified.map { f.string(from: $0) as Any } ?? NSNull(),
                 "permissions": FileLook.permissions(e.attrs.permissions),
                 "owner": names.describe(e.attrs)]
            }]
            if let who = fc.user { out["as_user"] = who }
            return text(json(out))

        case "read_file":
            let t = try target(a)
            let path = try string(a, "path")
            let max = min(max(a["max_bytes"] as? Int ?? 200_000, 1), 2_000_000)
            if let root = try await stagedRoot(t, a) {
                let out = try await rootOK(root, "f=\(Self.q(path)); [ -f \"$f\" ] || { echo \"파일이 아닙니다: $f\" >&2; exit 1; }; head -c \(max) -- \"$f\"")
                note("\(t.name): (\(root.how)) 읽기 \(path)")
                return text(out)
            }
            let fc = try await fileClient(t, a)
            defer { fc.finish() }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await fc.client.download(path, to: tmp, progress: { _ in }, isCancelled: { false })
            let data = try Data(contentsOf: tmp)
            note("\(t.name): 읽기 \(path)")
            let body = String(decoding: data.prefix(max), as: UTF8.self)
            return text(data.count > max ? body + "\n… (전체 \(data.count)바이트 중 \(max)바이트)" : body)

        case "write_file":
            let t = try target(a)
            let path = try string(a, "path")
            let content = try string(a, "content")
            try await allow(server: t, action: "파일 쓰기: \(path) (\(content.utf8.count)바이트)", danger: "파일 쓰기")
            let sftp = try await sftp(t)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try Data(content.utf8).write(to: tmp)
            try await sftp.upload(tmp, to: path, progress: { _ in }, isCancelled: { false })
            note("\(t.name): 쓰기 \(path)")
            return text("썼습니다: \(path)")

        case "delete_path":
            let t = try target(a)
            let path = try string(a, "path")
            try await allow(server: t, action: "지우기: \(path)", danger: "지우기")
            let sftp = try await sftp(t)
            let attrs = try await sftp.stat(path)
            try await sftp.removeRecursive(.init(name: (path as NSString).lastPathComponent, path: path, attrs: attrs))
            note("\(t.name): 지우기 \(path)")
            return text("지웠습니다: \(path)")

        case "upload":
            return text(try await upload(a))

        case "download":
            return text(try await download(a))

        case "screenshot":
            let s = try screenSession(a)
            guard let img = s.snapshotImage() else { throw Failure("\(s.computer.name) 화면이 아직 없습니다.") }
            let rep = NSBitmapImageRep(cgImage: img)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw Failure("그림을 만들지 못했습니다.") }
            note("\(s.computer.name): 화면 그림")
            return [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"],
                    ["type": "text", "text": "\(s.computer.name) 화면 \(img.width)×\(img.height)"]]

        default:
            throw Failure("모르는 도구: \(name)")
        }
    }

    // MARK: 파일 올리기·받기

    /// 파일 도구가 쓸 SFTP. as_root 면 root 로 연 것 (따로 연 것은 다 쓰면 닫는다)
    private struct FileClient {
        let client: SFTPClient
        /// root 로 연 경우 "root"
        let user: String?
        let temporary: Bool
        func finish() { if temporary { client.close() } }
    }

    /// 로그인 계정 SFTP (as_root 이고 root 로 접속하는 서버면 그게 곧 root). 다른 root 방법은 stagedRoot 로
    private func fileClient(_ t: Target, _ a: [String: Any]) async throws -> FileClient {
        let root = (a["as_root"] as? Bool ?? false) && t.computer.username == "root"
        return FileClient(client: try await sftp(t), user: root ? "root" : nil, temporary: false)
    }

    /// as_root 인데 로그인 계정이 root 가 아니면: root 를 얻는 방법(없으면 여기서 거절). 아니면 nil
    private func stagedRoot(_ t: Target, _ a: [String: Any]) async throws -> RootRunner? {
        guard a["as_root"] as? Bool ?? false, t.computer.username != "root" else { return nil }
        return try await rootRunner(t, try await rootRoute(t))
    }

    /// root 로 셸 스크립트를 돌리는 방법 하나 (root 셸 빌리기 · sudo -n · root 접속)
    private struct RootRunner {
        let how: String
        let run: (_ script: String, _ timeout: Int) async throws -> SSHShell.ExecResult
    }

    private func rootRunner(_ t: Target, _ route: RootRoute) async throws -> RootRunner {
        switch route {
        case .direct:
            let shell = try await connection(t)
            return RootRunner(how: "root") { script, timeout in try await shell.execFull(script, timeout: timeout) }
        case .sudo:
            let shell = try await connection(t)
            return RootRunner(how: "sudo") { script, timeout in try await shell.execFull("sudo -n sh -c \(Self.q(script))", timeout: timeout) }
        case .shell(let tab):
            return RootRunner(how: "root 셸") { script, timeout in
                var r = try await tab.rootExec("{\n\(script)\n} </dev/null\nprintf '\\n__IVNC_RC=%s\\n' \"$?\" >&2\n", timeout: timeout)
                // 끝 줄의 종료 코드를 꺼낸다
                if let m = r.stderr.range(of: #"\n?__IVNC_RC=(\d+)\n?$"#, options: .regularExpression) {
                    r = .init(stdout: r.stdout, stderr: String(r.stderr[..<m.lowerBound]), exitStatus: Int(r.stderr[m].filter(\.isNumber)), timedOut: r.timedOut)
                } else {
                    r = .init(stdout: r.stdout, stderr: r.stderr, exitStatus: nil, timedOut: r.timedOut)
                }
                return r
            }
        }
    }

    /// 셸 따옴표 ('…')
    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// root 스크립트를 돌려 실패하면 던진다
    private func rootOK(_ r: RootRunner, _ script: String, timeout: Int = 60) async throws -> String {
        let out = try await r.run(script, timeout)
        if out.timedOut { throw Failure("root 명령이 시간 안에 끝나지 않았습니다.") }
        guard out.exitStatus == 0 else {
            throw Failure(out.stderr.split(separator: "\n").filter { !$0.hasPrefix("Could not chdir") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "root 명령이 실패했습니다 (종료 코드 \(out.exitStatus.map(String.init) ?? "?")).")
        }
        return out.stdout
    }

    /// 로그인 계정으로 서버 파일 쓰기·읽기. 보통 SFTP, SFTP 가 응답하지 않는 서버(시놀로지에서 SFTP 를 꺼 둔 경우 등)만 명령 채널 cat
    private struct LoginIO {
        let put: (_ local: URL, _ remote: String, _ transfer: Transfer) async throws -> Void
        let get: (_ remote: String, _ local: URL) async throws -> Void
    }

    /// SFTP 가 응답하지 않았던 접속 (같은 접속에서는 다시 10초 기다리지 않는다)
    private var sftpDead: Set<ObjectIdentifier> = []

    private func loginIO(_ t: Target) async throws -> LoginIO {
        let shell = try await connection(t)
        let key = ObjectIdentifier(shell)
        if !sftpDead.contains(key) {
            do {
                let c = try await sftp(t)
                return LoginIO(put: { local, remote, tr in
                    try await c.upload(local, to: remote, createMode: 0o600, progress: tr.add, isCancelled: tr.isCancelled)
                }, get: { remote, local in
                    try await c.download(remote, to: local, progress: { _ in }, isCancelled: { false })
                })
            } catch {
                sftpDead.insert(key)
                note("\(t.name): SFTP 응답 없음 → 명령 채널로 주고받음", ok: false)
            }
        }
        return LoginIO(put: { local, remote, tr in
            let data = try Data(contentsOf: local)
            let r = try await shell.execFull("umask 077; cat > \(Self.q(remote))", input: data, timeout: 600)
            guard r.exitStatus == 0, !r.timedOut else { throw Failure("서버에 쓰지 못했습니다: \(r.stderr.prefix(200))") }
            tr.add(data.count)
        }, get: { remote, local in
            let r = try await shell.execFull("cat -- \(Self.q(remote))", timeout: 600)
            guard r.exitStatus == 0, !r.timedOut else { throw Failure("읽지 못했습니다: \(r.stderr.prefix(200))") }
            try r.data.write(to: local)
        })
    }

    /// 로그인 계정의 남이 못 보는 임시 폴더 (서버 /tmp)
    private func loginStage(_ t: Target) async throws -> String {
        let r = try await connection(t).execFull("umask 077; mktemp -d /tmp/.ivnc-stage-XXXXXXXX", timeout: 20)
        guard let d = r.stdout.split(separator: "\n").last.map(String.init), d.hasPrefix("/tmp/.ivnc-stage-") else { throw Failure("서버에 임시 폴더를 만들지 못했습니다.") }
        return d
    }

    // MARK: root

    /// root 를 얻는 방법 (iVNC 가 고른다)
    private enum RootRoute {
        /// root 로 접속하는 서버
        case direct
        /// 열린 터미널의 root 셸을 빌림
        case shell(TerminalTab)
        /// 암호 없는 sudo
        case sudo
    }

    /// 그 서버의 열린 탭 (활성 탭 먼저)
    private func tabs(of c: Computer) -> [TerminalTab] {
        let reg = TerminalRegistry.shared
        let all = reg.openTabs.filter { $0.computer.id == c.id && $0.sshShell != nil }
        guard let act = reg.activeTab, act.computer.id == c.id else { return all }
        return [act] + all.filter { $0 !== act }
    }

    /// 열린 탭들의 root 셸 상태
    private func rootShells(_ c: Computer) async -> [(tab: TerminalTab, state: TerminalTab.RootShellState)] {
        var out: [(TerminalTab, TerminalTab.RootShellState)] = []
        for tab in tabs(of: c) {
            let st = await tab.rootShellState()
            if st == .ready || { if case .busy = st { return true } else { return false } }() { out.append((tab, st)) }
        }
        return out
    }

    /// 지금 있는 접속으로 암호 없는 sudo 가 되는지 (접속이 없고 connect 가 false 면 nil: 이것 때문에 새로 접속하지 않는다).
    /// connect 가 true 인데 접속·응답이 안 되면 그 이유를 던진다 (VPN 이 꺼진 경우 등을 "sudo 안 됨"으로 잘못 알리지 않게)
    private func sudoWorks(_ t: Target, connect: Bool) async throws -> Bool? {
        let open = (t.tab?.sshShell?.isOpen ?? false) || (background[t.computer.id]?.isOpen ?? false)
        guard open || connect else { return nil }
        let shell: SSHShell
        do { shell = try await connection(t) } catch { if connect { throw error } else { return nil } }
        do {
            let r = try await shell.execFull("sudo -n true 2>/dev/null && echo ok", timeout: 10)
            if r.timedOut { throw SSHShell.ExecTimeout() }
            return r.stdout.contains("ok")
        } catch {
            if !connect { return nil }
            throw Failure("\(t.name) 가 답하지 않습니다 (\(error.localizedDescription)). 네트워크(VPN 등)가 연결돼 있는지 사용자에게 확인해 달라고 하세요.")
        }
    }

    private func rootRoute(_ t: Target) async throws -> RootRoute {
        if t.computer.username == "root" { return .direct }
        let shells = await rootShells(t.computer)
        if let ready = shells.first(where: { $0.state == .ready }) { return .shell(ready.tab) }
        if try await sudoWorks(t, connect: true) == true { return .sudo }
        let busy = shells.compactMap { s -> String? in if case .busy(let why) = s.state { return why } else { return nil } }
        if !busy.isEmpty {
            throw Failure("\(t.name) 의 root 셸을 지금 쓸 수 없습니다 (\(busy.joined(separator: ", "))). 그 터미널을 셸 프롬프트로 돌려 달라고 사용자에게 부탁하세요.")
        }
        throw Failure("\(t.name) 에서 root 를 쓸 수 없습니다: \(t.computer.username) 로 접속하고, 열린 터미널에 root 셸이 없고, 암호 없는 sudo 도 안 됩니다. 사용자에게 \(t.name) 터미널에서 sudo su 해 달라고 부탁하세요.")
    }

    /// list_servers 에 붙일 root 상태
    private func rootInfo(_ c: Computer) async -> [String: Any] {
        if c.username == "root" { return ["root": "direct", "root_hint": "root 로 접속하는 서버. as_root 로 바로 된다"] }
        let shells = await rootShells(c)
        var d: [String: Any] = ["root_shells": shells.map { s -> [String: Any] in
            if case .busy(let why) = s.state { return ["ready": false, "reason": why] }
            return ["ready": true]
        }]
        let reg = TerminalRegistry.shared
        let tab = (reg.activeTab?.computer.id == c.id ? reg.activeTab : nil) ?? reg.openTabs.first { $0.computer.id == c.id && $0.sshShell != nil }
        let sudo = (try? await sudoWorks(Target(computer: c, tab: tab), connect: false)) ?? nil
        d["sudo_nopasswd"] = sudo.map { $0 as Any } ?? NSNull()
        if shells.contains(where: { $0.state == .ready }) {
            d["root"] = "root_shell"; d["root_hint"] = "열린 터미널의 root 셸을 빌린다. as_root 로 된다"
        } else if sudo == true {
            d["root"] = "sudo"; d["root_hint"] = "암호 없는 sudo. as_root 로 된다"
        } else if !shells.isEmpty {
            d["root"] = "root_shell_busy"; d["root_hint"] = "root 셸이 있지만 지금은 못 씀. 사용자에게 그 터미널을 셸 프롬프트로 돌려 달라고 한다"
        } else if sudo == nil {
            d["root"] = "unknown"; d["root_hint"] = "접속돼 있지 않아 모름. as_root 로 부르면 접속해서 확인한다"
        } else {
            d["root"] = "none"; d["root_hint"] = "root 못 씀. 사용자에게 터미널에서 sudo su 해 달라고 한다"
        }
        return d
    }

    /// 서버의 사용자·그룹 이름 (/etc/passwd · /etc/group 을 SFTP 로 읽음: root 셸 SFTP 에서도 된다)
    private struct Owners {
        var users: [UInt32: String] = [:]
        var groups: [UInt32: String] = [:]

        static func load(_ c: SFTPClient) async -> Owners {
            var o = Owners()
            for (path, isUser) in [("/etc/passwd", true), ("/etc/group", false)] {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard (try? await c.download(path, to: tmp, progress: { _ in }, isCancelled: { false })) != nil,
                      let s = try? String(contentsOf: tmp, encoding: .utf8) else { continue }
                for line in s.split(separator: "\n") {
                    let f = line.split(separator: ":", omittingEmptySubsequences: false)
                    guard f.count >= 3, let id = UInt32(f[2]) else { continue }
                    if isUser { o.users[id] = String(f[0]) } else { o.groups[id] = String(f[0]) }
                }
            }
            return o
        }

        func describe(_ a: SFTPClient.Attrs) -> Any {
            guard let u = a.uid else { return NSNull() }
            return "\(users[u] ?? String(u)):\(a.gid.map { groups[$0] ?? String($0) } ?? "?")"
        }

        /// "사용자" · "사용자:그룹" · ":그룹" · 숫자 → uid, gid (nil = 그대로)
        func resolve(_ text: String) throws -> (uid: UInt32?, gid: UInt32?) {
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            func id(_ name: String, _ map: [UInt32: String], _ what: String) throws -> UInt32? {
                if name.isEmpty { return nil }
                if let n = UInt32(name) { return n }
                guard let k = map.first(where: { $0.value == name })?.key else { throw Failure("서버에 '\(name)' \(what)가 없습니다.") }
                return k
            }
            return (try id(parts[0], users, "사용자"), parts.count > 1 ? try id(parts[1], groups, "그룹") : nil)
        }
    }

    private static func parseMode(_ s: String) throws -> UInt32 {
        guard let v = UInt32(s.trimmingCharacters(in: .whitespaces), radix: 8), v <= 0o7777 else { throw Failure("mode 는 644 같은 8진수여야 합니다: \(s)") }
        return v
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// 올릴 파일 하나
    private struct Placement {
        let local: URL
        let remote: String
        let size: Int64
        /// 바꿀 원래 파일 (없으면 새 파일)
        let existing: SFTPClient.Attrs?
        /// 원래 파일을 받아 둘 이 맥 경로
        let macCopy: URL?
    }

    private func upload(_ a: [String: Any]) async throws -> String {
        let t = try target(a)
        let local = URL(fileURLWithPath: (try string(a, "local_path") as NSString).expandingTildeInPath).standardizedFileURL
        var remote = try string(a, "remote_path")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) else { throw Failure("이 맥에 없습니다: \(local.path)") }
        let mode = try (a["mode"] as? String).flatMap { $0.isEmpty ? nil : $0 }.map(Self.parseMode)
        let ownerText = (a["owner"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let keepBackup = a["backup"] as? Bool ?? true
        let macFolder = (a["backup_to_mac"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if let root = try await stagedRoot(t, a) {
            return try await uploadStaged(t, root: root, local: local, isDir: isDir.boolValue, remote: remote, mode: mode, owner: ownerText, keepBackup: keepBackup, macFolder: macFolder)
        }

        let fc = try await fileClient(t, a)
        defer { fc.finish() }
        let sftp = fc.client
        let names = await Owners.load(sftp)
        let owner = try ownerText.map { try names.resolve($0) }

        // 파일 하나를 이미 있는 폴더에 주면 그 안에
        if !isDir.boolValue, let st = try? await sftp.stat(remote), st.isDirectory {
            remote = SFTPClient.join(remote, local.lastPathComponent)
        }
        let stamp = Self.stamp()
        let macRoot = macFolder?.appendingPathComponent("\(t.name) \(stamp)")

        // 올릴 목록 (폴더면 안쪽까지)과 만들 폴더
        var files: [(URL, String)] = []
        var dirs: [String] = []
        if isDir.boolValue {
            dirs.append(remote)
            let base = local.path
            let e = FileManager.default.enumerator(at: local, includingPropertiesForKeys: [.isDirectoryKey])
            while let u = e?.nextObject() as? URL {
                let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
                if rel.split(separator: "/").contains(where: { $0 == ".DS_Store" }) { continue }
                let r = SFTPClient.join(remote, rel)
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(r) } else { files.append((u, r)) }
            }
        } else {
            files.append((local, remote))
        }
        guard !files.isEmpty else { throw Failure("올릴 파일이 없습니다.") }

        var plan: [Placement] = []
        for (u, r) in files {
            let existing = try? await sftp.stat(r)
            if existing?.isDirectory == true { throw Failure("서버에 같은 이름의 폴더가 있습니다: \(r)") }
            let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var mac: URL?
            if existing != nil, let macRoot {
                let rel = isDir.boolValue ? String(r.dropFirst(remote.count + 1)) : (r as NSString).lastPathComponent
                mac = macRoot.appendingPathComponent(rel)
            }
            plan.append(Placement(local: u, remote: r, size: size, existing: existing, macCopy: mac))
        }

        // 한 번에 묻기
        let replaced = plan.filter { $0.existing != nil }.count
        var lines = ["올리기\(fc.user.map { " (\($0) 권한)" } ?? ""): \(Self.short(local.path)) → \(remote)"
                     + (isDir.boolValue ? " (파일 \(plan.count)개)" : "")]
        if replaced > 0 {
            var r = "바꾸는 파일 \(replaced)개"
            if keepBackup { r += " · 서버에 .bak-\(stamp) 로 남김" }
            if let macRoot { r += " · 먼저 이 맥 \(Self.short(macRoot.path)) 로 받아 둠" }
            if !keepBackup && macRoot == nil { r += " · 백업 없음" }
            lines.append(r)
        }
        lines.append("권한: " + (mode.map { String($0, radix: 8) } ?? (replaced > 0 ? "원래 파일 것 유지" : "서버 기본"))
                     + " · 소유자: " + (ownerText ?? (replaced > 0 ? "원래 파일 것 유지" : "그대로")))
        try await allow(server: t, action: lines.joined(separator: "\n"),
                        danger: replaced > 0 ? "서버 파일 \(replaced)개 바꾸기" : "서버에 쓰기")

        for d in dirs { try? await sftp.mkdir(d) } // 이미 있으면 그대로
        if owner != nil { for d in dirs { try? await sftp.setstat(d, uid: owner?.uid, gid: owner?.gid) } }

        let g = TransferCenter.shared.begin(.upload, names: [local.lastPathComponent], server: t.name)
        for p in plan {
            let backupPath = keepBackup && p.existing != nil ? p.remote + ".bak-\(stamp)" : nil
            g.add(Transfer(name: (p.remote as NSString).lastPathComponent, upload: true, total: p.size) { tr in
                try await Self.place(p, sftp: sftp, mode: mode, owner: owner, backupPath: backupPath, ownerText: ownerText, transfer: tr)
            })
        }
        g.preparing = false
        await TransferCenter.shared.run(g, parallel: 2)

        // 결과
        var out: [String] = []
        for (p, tr) in zip(plan, g.items) {
            if case .failed(let why) = tr.state { out.append("실패 \(p.remote): \(why)"); continue }
            guard tr.state == .done else { out.append("취소 \(p.remote)"); continue }
            let st = try? await sftp.stat(p.remote)
            var l = "\(p.existing != nil ? "바꿈" : "새로") \(p.remote) \(FileLook.permissions(st?.permissions)) \(st.map { "\(names.describe($0))" } ?? "")"
            if keepBackup && p.existing != nil { l += " (원래 파일: \(p.remote).bak-\(stamp))" }
            out.append(l)
        }
        if let macRoot, replaced > 0 { out.append("원래 파일을 이 맥에 받아 둠: \(macRoot.path)") }
        let failed = g.failedCount
        note("\(t.name): 올리기 \(remote)\(failed > 0 ? " (실패 \(failed))" : "")", ok: failed == 0)
        if out.count > 40 { out = Array(out.prefix(40)) + ["… 외 \(out.count - 40)개"] }
        let head = failed == 0 ? "올렸습니다." : "일부 실패했습니다 (\(failed)개). 실패한 파일의 원래 파일은 그대로입니다."
        return head + "\n" + out.joined(separator: "\n")
    }

    /// 파일 하나 놓기: (이 맥으로 원래 파일 받기) → 임시 이름으로 올리기(처음부터 600) → 소유자·권한 → 원래 파일을 .bak 로 → 임시를 제 이름으로.
    /// 도중에 실패하면 임시 파일을 지우고 원래 파일은 그대로 둔다
    nonisolated private static func place(_ p: Placement, sftp: SFTPClient, mode: UInt32?, owner: (uid: UInt32?, gid: UInt32?)?,
                                          backupPath: String?, ownerText: String?, transfer tr: Transfer) async throws {
        if let mac = p.macCopy {
            try FileManager.default.createDirectory(at: mac.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await sftp.download(p.remote, to: mac, progress: { _ in }, isCancelled: { false })
            if (p.existing?.permissions ?? 0) & 0o004 == 0 { chmod(mac.path, 0o600) } // 남이 못 읽던 파일(개인 키 등)은 이 맥에서도
        }
        let dir = (p.remote as NSString).deletingLastPathComponent
        let tmp = SFTPClient.join(dir.isEmpty ? "." : dir, "." + (p.remote as NSString).lastPathComponent + ".ivnc-" + UUID().uuidString.prefix(8).lowercased())
        do {
            try await sftp.upload(p.local, to: tmp, createMode: 0o600, progress: tr.add, isCancelled: tr.isCancelled)
            // 소유자 먼저 (chown 이 setuid 비트를 지울 수 있어 권한은 뒤에)
            let wantUID = owner?.uid ?? p.existing?.uid, wantGID = owner?.gid ?? p.existing?.gid
            if wantUID != nil || wantGID != nil {
                let now = try await sftp.stat(tmp)
                if (wantUID != nil && wantUID != now.uid) || (wantGID != nil && wantGID != now.gid) {
                    do { try await sftp.setstat(tmp, uid: wantUID, gid: wantGID) } catch {
                        throw Failure("소유자를 \(ownerText ?? "원래 파일 것")으로 바꾸지 못했습니다. as_root=true 로 해 보세요.")
                    }
                }
            }
            // 권한: 준 것 → 원래 파일 것 → 새 파일은 보통 644
            let perm = mode ?? p.existing?.permissions.map { $0 & 0o7777 } ?? 0o644
            try await sftp.setstat(tmp, permissions: perm)
            if let backupPath {
                try await sftp.rename(p.remote, to: backupPath)
                do { try await sftp.rename(tmp, to: p.remote) } catch {
                    try? await sftp.rename(backupPath, to: p.remote) // 되돌리기
                    throw error
                }
            } else {
                try await sftp.replace(tmp, to: p.remote)
            }
        } catch {
            try? await sftp.remove(tmp)
            throw error
        }
    }

    /// root 올리기 (로그인 계정이 root 가 아닐 때): 로그인 계정 SFTP 로 남이 못 보는 임시 폴더에 올리고, root 가 명령으로
    /// 원래 파일 백업·이 맥으로 줄 복사·소유자·권한·제자리 바꿔치기를 한다. sftp-server 가 없는 서버(시놀로지 등)에서도 된다
    private func uploadStaged(_ t: Target, root: RootRunner, local: URL, isDir: Bool, remote: String, mode: UInt32?, owner: String?,
                              keepBackup: Bool, macFolder: URL?) async throws -> String {
        let q = Self.q
        if let owner, owner.range(of: #"^[A-Za-z0-9._-]*(:[A-Za-z0-9._-]*)?$"#, options: .regularExpression) == nil {
            throw Failure("owner 가 이상합니다: \(owner)")
        }
        var remote = remote
        // 올릴 목록
        var files: [(local: URL, remote: String)] = []
        var dirs: [String] = []
        if isDir {
            dirs.append(remote)
            let e = FileManager.default.enumerator(at: local, includingPropertiesForKeys: [.isDirectoryKey])
            while let u = e?.nextObject() as? URL {
                let rel = String(u.standardizedFileURL.path.dropFirst(local.path.count + 1))
                if rel.split(separator: "/").contains(where: { $0 == ".DS_Store" }) { continue }
                let r = SFTPClient.join(remote, rel)
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(r) } else { files.append((u, r)) }
            }
        } else {
            files.append((local, remote))
        }
        guard !files.isEmpty else { throw Failure("올릴 파일이 없습니다.") }

        // 원래 파일 (root 로 stat: uid gid 권한 종류). 파일 하나를 이미 있는 폴더에 주면 그 안에 → 한 번에 묻는다
        var statScript = files.map { "stat -c '%u %g %a %F' -- \(q($0.remote)) 2>/dev/null || echo none" }.joined(separator: "\n")
        if !isDir {
            let inside = SFTPClient.join(remote, local.lastPathComponent)
            statScript = "if [ -d \(q(remote)) ]; then echo D; stat -c '%u %g %a %F' -- \(q(inside)) 2>/dev/null || echo none; else echo F; \(statScript); fi"
        }
        var lines = try await rootOK(root, statScript).split(separator: "\n").map(String.init)
        if !isDir, let first = lines.first {
            if first == "D" { remote = SFTPClient.join(remote, local.lastPathComponent); files = [(local, remote)] }
            lines.removeFirst()
        }
        guard lines.count == files.count else { throw Failure("원래 파일 정보를 읽지 못했습니다.") }
        var existing: [(uid: String, gid: String, mode: String)?] = []
        for (i, l) in lines.enumerated() {
            let f = l.split(separator: " ", maxSplits: 3).map(String.init)
            if f.count >= 4 {
                if f[3].contains("directory") { throw Failure("서버에 같은 이름의 폴더가 있습니다: \(files[i].remote)") }
                existing.append((f[0], f[1], f[2]))
            } else {
                existing.append(nil)
            }
        }

        // 한 번에 묻기
        let stamp = Self.stamp()
        let macRoot = macFolder?.appendingPathComponent("\(t.name) \(stamp)")
        let replaced = existing.compactMap { $0 }.count
        var ask = ["올리기 (\(root.how)): \(Self.short(local.path)) → \(remote)" + (isDir ? " (파일 \(files.count)개)" : "")]
        if replaced > 0 {
            var r = "바꾸는 파일 \(replaced)개"
            if keepBackup { r += " · 서버에 .bak-\(stamp) 로 남김" }
            if let macRoot { r += " · 먼저 이 맥 \(Self.short(macRoot.path)) 로 받아 둠" }
            if !keepBackup && macRoot == nil { r += " · 백업 없음" }
            ask.append(r)
        }
        ask.append("권한: " + (mode.map { String($0, radix: 8) } ?? (replaced > 0 ? "원래 파일 것 유지" : "644"))
                   + " · 소유자: " + (owner ?? (replaced > 0 ? "원래 파일 것 유지" : "root")))
        try await allow(server: t, action: ask.joined(separator: "\n"), danger: replaced > 0 ? "서버 파일 \(replaced)개 바꾸기 (root)" : "서버에 쓰기 (root)")

        // 1) 로그인 계정 임시 폴더에 올리기 (⇅ 전송 내역)
        let stage = try await loginStage(t)
        let login = t.computer.username
        let shell = try await connection(t)
        defer { Task { _ = try? await shell.execFull("rm -rf -- \(q(stage))", timeout: 30) } }
        let io = try await loginIO(t)
        let g = TransferCenter.shared.begin(.upload, names: [local.lastPathComponent], server: t.name)
        for (i, f) in files.enumerated() {
            let size = Int64((try? f.local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let dst = SFTPClient.join(stage, "f\(i)")
            g.add(Transfer(name: (f.remote as NSString).lastPathComponent, upload: true, total: size) { tr in
                try await io.put(f.local, dst, tr)
            })
        }
        g.preparing = false
        await TransferCenter.shared.run(g, parallel: 2)
        if g.failedCount > 0 || g.items.contains(where: { $0.state != .done }) {
            let why = g.items.compactMap { tr -> String? in if case .failed(let w) = tr.state { return "\(tr.name): \(w)" } else { return nil } }
            throw Failure("임시 폴더에 올리지 못해 서버 파일은 그대로입니다.\n" + why.prefix(10).joined(separator: "\n"))
        }

        // 2) 원래 파일을 이 맥으로 (root 가 임시 폴더에 복사해 로그인 계정에게 넘김)
        if let macRoot, replaced > 0 {
            let cp = files.indices.compactMap { i -> String? in
                existing[i] == nil ? nil : "cp -p -- \(q(files[i].remote)) \(q(stage))/o\(i) && chown \(q(login)) \(q(stage))/o\(i)"
            }.joined(separator: " &&\n")
            _ = try await rootOK(root, cp, timeout: 600)
            for i in files.indices where existing[i] != nil {
                let rel = isDir ? String(files[i].remote.dropFirst(remote.count + 1)) : (files[i].remote as NSString).lastPathComponent
                let dst = macRoot.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try await io.get(SFTPClient.join(stage, "o\(i)"), dst) }
                catch { throw Failure("원래 파일을 이 맥으로 받지 못해 바꾸지 않았습니다: \(files[i].remote)") }
                if let m = existing[i].flatMap({ UInt32($0.mode, radix: 8) }), m & 0o004 == 0 { chmod(dst.path, 0o600) }
            }
        }

        // 3) root 가 제자리에 놓기: 같은 폴더 임시 이름에 600 으로 복사 → 소유자·권한 → (원래 파일 .bak) → 바꿔치기. 실패하면 원래 그대로
        var script = """
        place() {
          src=$1; dst=$2; own=$3; mod=$4; bak=$5
          tmp="$(dirname -- "$dst")/.$(basename -- "$dst").ivnc-$$"
          ( umask 077; cp -- "$src" "$tmp" ) || return 1
          if [ -n "$own" ]; then chown -- "$own" "$tmp" || { rm -f -- "$tmp"; return 1; }; fi
          chmod -- "$mod" "$tmp" || { rm -f -- "$tmp"; return 1; }
          if [ -n "$bak" ]; then
            mv -- "$dst" "$bak" || { rm -f -- "$tmp"; return 1; }
            mv -- "$tmp" "$dst" || { mv -- "$bak" "$dst"; rm -f -- "$tmp"; return 1; }
          else
            mv -f -- "$tmp" "$dst" || { rm -f -- "$tmp"; return 1; }
          fi
        }

        """
        for d in dirs {
            script += "mkdir -p -- \(q(d))" + (owner.map { " && chown -- \(q($0)) \(q(d))" } ?? "") + "\n"
        }
        for (i, f) in files.enumerated() {
            let ex = existing[i]
            let own = owner ?? ex.map { "\($0.uid):\($0.gid)" } ?? ""
            let mod = mode.map { String($0, radix: 8) } ?? ex?.mode ?? "644"
            let bak = keepBackup && ex != nil ? f.remote + ".bak-\(stamp)" : ""
            script += "if e=$(place \(q(stage))/f\(i) \(q(f.remote)) \(q(own)) \(q(mod)) \(q(bak)) 2>&1); then echo \"ok \(i) $(stat -c '%A %U:%G' -- \(q(f.remote)))\"; else echo \"fail \(i) $e\" | tr '\\n' ' '; echo; fi\n"
        }
        let placed = try await root.run(script, 600)
        var out: [String] = []
        var failed = 0
        for line in placed.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let i = Int(parts[1]), i < files.count else { continue }
            let f = files[i]
            if parts[0] == "ok" {
                var l = "\(existing[i] != nil ? "바꿈" : "새로") \(f.remote) \(parts.count > 2 ? parts[2] : "")"
                if keepBackup && existing[i] != nil { l += " (원래 파일: \(f.remote).bak-\(stamp))" }
                out.append(l)
            } else {
                failed += 1
                out.append("실패 \(f.remote): \(parts.count > 2 ? parts[2] : "")")
            }
        }
        if out.isEmpty { throw Failure("root 로 놓는 단계 결과를 받지 못했습니다. " + placed.stderr.prefix(500)) }
        if let macRoot, replaced > 0 { out.append("원래 파일을 이 맥에 받아 둠: \(macRoot.path)") }
        note("\(t.name): (\(root.how)) 올리기 \(remote)\(failed > 0 ? " (실패 \(failed))" : "")", ok: failed == 0)
        if out.count > 40 { out = Array(out.prefix(40)) + ["… 외 \(out.count - 40)개"] }
        return (failed == 0 ? "올렸습니다 (\(root.how))." : "일부 실패했습니다 (\(failed)개). 실패한 파일의 원래 파일은 그대로입니다.") + "\n" + out.joined(separator: "\n")
    }

    /// root 받기 (로그인 계정이 root 가 아닐 때): root 가 남이 못 보는 임시 폴더에 cp -a 하고 로그인 계정에게 넘김 →
    /// 명령 채널 cat 으로 받고(SFTP 없이) 임시 폴더를 지운다
    private func downloadStaged(_ t: Target, root: RootRunner, remote: String, local: URL) async throws -> String {
        let q = Self.q
        let login = t.computer.username
        let s = try await rootOK(root, "umask 077; s=$(mktemp -d /tmp/.ivnc-dl-XXXXXXXX) && cp -a -- \(q(remote)) \"$s/\" && chown -R \(q(login)) \"$s\" && echo \"$s\"", timeout: 600)
            .split(separator: "\n").last.map(String.init) ?? ""
        guard s.hasPrefix("/tmp/.ivnc-dl-") else { throw Failure("root 로 임시 복사를 하지 못했습니다.") }
        let shell = try await connection(t)
        defer { Task { _ = try? await shell.execFull("rm -rf -- \(q(s))", timeout: 30) } }
        // 받을 목록: 권한(8진) 크기 상대 경로
        let name = (remote as NSString).lastPathComponent
        let list = try await shell.execFull("cd \(q(s)) && find \(q(name)) -type f -exec stat -c '%a %s %n' {} +", timeout: 120)
        guard list.exitStatus == 0 else { throw Failure("받을 목록을 읽지 못했습니다: \(list.stderr.prefix(200))") }
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir)
        // local 이 있는 폴더면 그 안에 name 으로, 아니면 local 자체가 받을 이름
        let into = isDir.boolValue
        var files: [(rel: String, mode: UInt32, size: Int64, dst: URL)] = []
        for line in list.stdout.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard f.count == 3, let m = UInt32(f[0], radix: 8) else { continue }
            let rel = f[2]
            let dst: URL
            if into { dst = local.appendingPathComponent(rel) }
            else { dst = rel == name ? local : local.appendingPathComponent(String(rel.dropFirst(name.count + 1))) }
            files.append((rel, m, Int64(f[1]) ?? 0, dst))
        }
        guard !files.isEmpty else { throw Failure("받을 파일이 없습니다: \(remote)") }
        let overwrite = files.filter { FileManager.default.fileExists(atPath: $0.dst.path) }.count
        try await allow(server: t, action: "받기 (\(root.how)): \(remote) → \(Self.short((into ? local.appendingPathComponent(name) : local).path))" + (files.count > 1 ? " (파일 \(files.count)개)" : ""),
                        danger: overwrite > 0 ? "이 맥 파일 \(overwrite)개 덮어쓰기" : nil)
        let io = try await loginIO(t)
        let g = TransferCenter.shared.begin(.download, names: [name], server: t.name)
        for f in files {
            g.add(Transfer(name: f.dst.lastPathComponent, upload: false, total: f.size) { tr in
                try FileManager.default.createDirectory(at: f.dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await io.get(SFTPClient.join(s, f.rel), f.dst)
                if f.mode & 0o004 == 0 { chmod(f.dst.path, 0o600) } // 남이 못 읽던 파일은 이 맥에서도
                tr.add(Int(f.size))
            })
        }
        g.preparing = false
        await TransferCenter.shared.run(g, parallel: 2)
        let failed = g.items.compactMap { tr -> String? in if case .failed(let why) = tr.state { return "실패 \(tr.name): \(why)" } else { return nil } }
        note("\(t.name): (\(root.how)) 받기 \(remote)\(failed.isEmpty ? "" : " (실패 \(failed.count))")", ok: failed.isEmpty)
        let shown = into ? local.appendingPathComponent(name) : local
        return failed.isEmpty ? "받았습니다 (\(root.how)): \(shown.path)" + (files.count > 1 ? " (파일 \(files.count)개)" : "")
                              : "일부 실패했습니다: \(shown.path)\n" + failed.prefix(30).joined(separator: "\n")
    }

    private func download(_ a: [String: Any]) async throws -> String {
        let t = try target(a)
        let remote = try string(a, "remote_path")
        var local = URL(fileURLWithPath: (try string(a, "local_path") as NSString).expandingTildeInPath)
        if let root = try await stagedRoot(t, a) { return try await downloadStaged(t, root: root, remote: remote, local: local) }
        let fc = try await fileClient(t, a)
        defer { fc.finish() }
        let sftp = fc.client
        let source = remote
        let st = try await sftp.stat(source)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir), isDir.boolValue {
            local = local.appendingPathComponent((remote as NSString).lastPathComponent)
        }
        // 받을 목록 (폴더면 안쪽까지)
        var files: [(remote: String, local: URL, attrs: SFTPClient.Attrs)] = []
        var dirs: [URL] = []
        func walk(_ r: String, _ l: URL) async throws {
            dirs.append(l)
            for e in try await sftp.list(r) {
                if e.attrs.isSymlink { continue }
                if e.isDirectory { try await walk(e.path, l.appendingPathComponent(e.name)) }
                else { files.append((e.path, l.appendingPathComponent(e.name), e.attrs)) }
            }
        }
        if st.isDirectory { try await walk(source, local) } else { files.append((source, local, st)) }
        let overwrite = files.filter { FileManager.default.fileExists(atPath: $0.local.path) }.count
        try await allow(server: t, action: "받기\(fc.user.map { " (\($0) 권한)" } ?? ""): \(remote) → \(Self.short(local.path))"
                        + (st.isDirectory ? " (파일 \(files.count)개)" : ""),
                        danger: overwrite > 0 ? "이 맥 파일 \(overwrite)개 덮어쓰기" : nil)
        for d in dirs { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        if !st.isDirectory { try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true) }

        let g = TransferCenter.shared.begin(.download, names: [(remote as NSString).lastPathComponent], server: t.name)
        for f in files {
            g.add(Transfer(name: f.local.lastPathComponent, upload: false, total: Int64(f.attrs.size ?? 0)) { tr in
                try await sftp.download(f.remote, to: f.local, progress: tr.add, isCancelled: tr.isCancelled)
                if (f.attrs.permissions ?? 0) & 0o004 == 0 { chmod(f.local.path, 0o600) } // 남이 못 읽던 파일은 이 맥에서도
            })
        }
        g.preparing = false
        await TransferCenter.shared.run(g, parallel: 2)
        let failed = g.items.compactMap { tr -> String? in if case .failed(let why) = tr.state { return "실패 \(tr.name): \(why)" } else { return nil } }
        note("\(t.name): 받기 \(remote)\(failed.isEmpty ? "" : " (실패 \(failed.count))")", ok: failed.isEmpty)
        return (failed.isEmpty ? "받았습니다: \(local.path)" + (st.isDirectory ? " (파일 \(files.count)개)" : "")
                               : "일부 실패했습니다: \(local.path)\n" + failed.prefix(30).joined(separator: "\n"))
    }

    // MARK: 권한·확인

    /// 위험(danger != nil)이면 권한에 따라 거절하거나 사용자에게 묻는다
    private func allow(server t: Target, action: String, danger: String?) async throws {
        switch permission {
        case .readOnly:
            throw Failure("MCP 권한이 '읽기만'이라 실행하지 않았습니다. (iVNC 설정 > MCP)")
        case .safeOnly:
            if let d = danger { throw Failure("안전한 명령이 아니라 실행하지 않았습니다: \(d). (권한: 안전한 명령만)") }
        case .confirm:
            if let d = danger {
                let ok = await MCPConfirm.ask(server: t.name, action: action, reason: d)
                if !ok { note("\(t.name): 거절 \(action.prefix(60))", ok: false); throw Failure("사용자가 허락하지 않았습니다 (또는 2분 안에 답이 없었습니다).") }
            }
        case .full:
            break
        }
    }

    // MARK: 대상 서버

    private struct Target {
        let computer: Computer
        /// 열린 탭 (있으면 그 접속을 쓴다)
        let tab: TerminalTab?
        var name: String { computer.name }
    }

    private var sshServers: [Computer] { store?.computers.filter { $0.type == .ssh } ?? [] }

    /// 범위 안의 서버
    private func allowedServers() -> [Computer] {
        let reg = TerminalRegistry.shared
        switch scope {
        case .all: return sshServers
        case .open:
            let ids = Set(reg.openTabs.map(\.computer.id))
            return sshServers.filter { ids.contains($0.id) }
        case .active:
            guard let t = reg.activeTab else { return [] }
            return sshServers.filter { $0.id == t.computer.id }
        }
    }

    private func target(_ a: [String: Any]) throws -> Target {
        let allowed = allowedServers()
        let c: Computer
        if let key = a["server"] as? String, !key.isEmpty {
            guard let found = sshServers.first(where: { $0.id.uuidString == key || $0.name == key }) ?? sshServers.first(where: { $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }) else {
                throw Failure("'\(key)' 라는 SSH 서버가 없습니다. list_servers 를 보세요.")
            }
            guard allowed.contains(where: { $0.id == found.id }) else {
                throw Failure("\(found.name) 은(는) MCP 범위(\(scope.label)) 밖입니다.")
            }
            c = found
        } else {
            if scope == .active, let only = allowed.first { c = only }
            else if allowed.count == 1 { c = allowed[0] }
            else { throw Failure(allowed.isEmpty ? "MCP 범위(\(scope.label))에 서버가 없습니다." : "server 를 지정하세요. list_servers 를 보세요.") }
        }
        let reg = TerminalRegistry.shared
        let tab = (reg.activeTab?.computer.id == c.id ? reg.activeTab : nil)
            ?? reg.openTabs.first { $0.computer.id == c.id && $0.sshShell != nil }
        return Target(computer: c, tab: tab)
    }

    /// 터미널 도구용: 그 서버의 열린 탭 (활성 탭 먼저). 서버를 안 주면 활성 탭
    private func terminalTab(_ a: [String: Any]) throws -> TerminalTab {
        let reg = TerminalRegistry.shared
        if (a["server"] as? String ?? "").isEmpty {
            guard let t = reg.activeTab ?? reg.openTabs.first else { throw Failure("열린 터미널 탭이 없습니다.") }
            guard allowedServers().contains(where: { $0.id == t.computer.id }) else { throw Failure("\(t.computer.name) 은(는) MCP 범위 밖입니다.") }
            return t
        }
        let t = try target(a)
        guard let tab = t.tab ?? reg.openTabs.first(where: { $0.computer.id == t.computer.id }) else {
            throw Failure("\(t.name) 의 열린 터미널 탭이 없습니다.")
        }
        return tab
    }

    // MARK: 접속 (열린 탭의 접속을 빌리거나, 범위가 '모든 서버'면 MCP 가 따로 접속)

    private var background: [UUID: SSHShell] = [:]
    private var sftpClients: [ObjectIdentifier: SFTPClient] = [:]

    private func connection(_ t: Target) async throws -> SSHShell {
        if let s = t.tab?.sshShell, s.isOpen { return s }
        if let s = background[t.computer.id], s.isOpen { return s }
        // 지문을 모르는 서버는 MCP 가 묻지 않는다 (앱에서 한 번 접속해 확인)
        var hops: [SSHShell.Hop] = []
        for j in store?.jumpChain(for: t.computer) ?? [] {
            switch TerminalTab.auth(for: j) {
            case .success(let a): hops.append(.init(host: j.host, port: j.port, username: j.username, auth: a, name: j.name))
            case .failure(let m): throw Failure("경유 서버 " + m.text)
            }
        }
        let auth: SSHShell.Auth
        switch TerminalTab.auth(for: t.computer) {
        case .success(let a): auth = a
        case .failure(let m): throw Failure(m.text)
        }
        // 접속 허용 IP 가 있고 이 맥이 그 IP 가 아니면 접속하지 않고 VPN 을 켜라고 알려 준다 (앱 화면과 같은 검사)
        if let r = await NetworkAccess.check(t.computer, jumps: store?.jumpChain(for: t.computer) ?? []), !r.allowed {
            throw Failure(NetworkAccess.explain(r, server: t.name) + "\n" + (await NetworkAccess.vpnSummary())
                          + "\n사용자에게 VPN 을 켜 달라고 안내한 뒤 다시 시도한다. iVNC 에서 이 서버를 열면 VPN 을 고르는 화면이 뜬다.")
        }
        let c = t.computer
        let s = SSHShell(host: c.host, port: c.port, username: c.username, auth: auth, term: "xterm-256color", jumps: hops)
        s.interactive = false
        s.onHostKeyQuestion = { _, answer in answer(false) }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            var done = false
            // 로그인·경유 통로가 30초 안에 안 되면 그만둔다 (끝없이 기다리지 않게. VPN 이 꺼져 배스천에 닿지 않는 경우 등, 사용자)
            let via = hops.isEmpty ? "" : " (경유: \(hops.map(\.name).joined(separator: " → ")))"
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if !done { done = true; s.onClose = nil; s.close(); k.resume(throwing: Failure("\(t.name) 에 30초 안에 접속하지 못했습니다\(via). 네트워크(VPN 등)가 연결돼 있는지 사용자에게 확인해 달라고 하세요.")) }
            }
            s.onConnected = { if !done { done = true; k.resume() } }
            s.onClose = { err, _ in
                if !done { done = true; k.resume(throwing: Failure("\(t.name)\(via): " + (err ?? "접속하지 못했습니다.") + " 네트워크(VPN 등)가 연결돼 있는지 사용자에게 확인해 달라고 하세요. 처음 접속하는 서버면 iVNC 에서 한 번 열어 서버 지문을 확인해야 합니다.")) }
            }
            s.connect(cols: 80, rows: 24, keepAlive: true)
        }
        s.onClose = { [weak self] _, _ in self?.background[c.id] = nil }
        background[c.id] = s
        return s
    }

    private func sftp(_ t: Target) async throws -> SFTPClient {
        let shell = try await connection(t)
        let key = ObjectIdentifier(shell)
        if let c = sftpClients[key], c.channel.isActive { return c }
        let c = try await shell.openSFTP()
        sftpClients[key] = c
        return c
    }

    // MARK: 원격 화면

    private func screenSession(_ a: [String: Any]) throws -> SessionModel {
        let sessions = SessionModel.openSessions.filter { $0.hasImage }
        if let key = a["computer"] as? String, !key.isEmpty {
            guard let s = sessions.first(where: { $0.computer.id.uuidString == key || $0.computer.name.localizedCaseInsensitiveCompare(key) == .orderedSame }) else {
                throw Failure("'\(key)' 의 열린 원격 화면이 없습니다.")
            }
            return s
        }
        guard let s = SessionModel.frontSession.flatMap({ f in sessions.first { $0 === f } }) ?? sessions.first else {
            throw Failure("열린 원격 화면 창이 없습니다.")
        }
        return s
    }

    // MARK: 도우미

    private func listServers() async -> [String: Any] {
        let reg = TerminalRegistry.shared
        let allowed = Set(allowedServers().map(\.id))
        let active = reg.activeTab?.computer.id
        var servers: [[String: Any]] = []
        for c in sshServers where allowed.contains(c.id) {
            var d: [String: Any] = ["name": c.name, "id": c.id.uuidString, "user": c.username, "host": c.host, "port": c.port,
                                    "open_tabs": reg.openTabs.filter { $0.computer.id == c.id }.count,
                                    "connected": reg.openTabs.contains { $0.computer.id == c.id && $0.sshShell != nil } || (background[c.id]?.isOpen ?? false),
                                    "active": c.id == active]
            if let via = store?.jumpChain(for: c), !via.isEmpty { d["via"] = via.map(\.name) }
            if let a = NetworkAccess.gate(for: c, jumps: store?.jumpChain(for: c) ?? []).allowedIPs, !a.isEmpty { d["allowed_ips"] = a }
            d.merge(await rootInfo(c)) { a, _ in a }
            servers.append(d)
        }
        return [
            "scope": scope.label,
            "permission": permission.label,
            "permission_detail": permission.detail,
            "servers": servers,
            "screens": SessionModel.openSessions.map { ["name": $0.computer.name, "id": $0.computer.id.uuidString] },
        ]
    }

    private func string(_ a: [String: Any], _ key: String) throws -> String {
        guard let v = a[key] as? String else { throw Failure("\(key) 가 필요합니다.") }
        return v
    }

    private static func execOut(_ r: SSHShell.ExecResult) -> [String: Any] {
        var out: [String: Any] = ["exit_code": r.exitStatus.map { $0 as Any } ?? NSNull(),
                                  "stdout": clip(r.stdout), "stderr": clip(r.stderr)]
        if r.timedOut { out["timed_out"] = true }
        return out
    }

    private static func clip(_ s: String, max: Int = 100_000) -> String {
        s.utf8.count > max ? String(decoding: Data(s.utf8).prefix(max), as: UTF8.self) + "\n… (잘림)" : s
    }

    private func json(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return "\(v)" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// 위험한 MCP 동작을 사용자에게 묻는다 (앱을 앞으로, Dock 튕기기, 2분 지나면 거절)
@MainActor
enum MCPConfirm {
    static func ask(server: String, action: String, reason: String) async -> Bool {
        NSApp.requestUserAttention(.criticalRequest)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MCP 가 \(server) 에서 실행하려고 합니다"
        alert.informativeText = "\(action)\n\n확인이 필요한 이유: \(reason)\n2분 안에 답이 없으면 거절합니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "실행")
        alert.addButton(withTitle: "거절")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let timer = Timer(timeInterval: 120, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let r = alert.runModal()
        timer.invalidate()
        return r == .alertFirstButtonReturn
    }
}

/// 열린 터미널 창들 (MCP 가 탭을 찾는다)
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var models: [WeakModel] = []
    private struct WeakModel { weak var model: TerminalWindowModel? }

    func add(_ m: TerminalWindowModel) {
        models = models.filter { $0.model != nil }
        models.append(WeakModel(model: m))
    }

    var openTabs: [TerminalTab] { models.compactMap(\.model).flatMap(\.allTabs) }

    /// 떼어 낸 탭이 놓일 창·칸에 강조 표시 (nil = 모두 끔)
    func highlightDrop(atScreen p: NSPoint?) {
        let hit = p.flatMap { target(atScreen: $0) }
        for m in models.compactMap(\.model) {
            let want = (hit?.0 === m) ? hit?.1 : nil
            if m.dropHighlight != want { m.dropHighlight = want }
        }
    }

    /// 화면 좌표 점 밑에 있는 터미널 창과 그 칸 (맨 앞 창부터)
    func target(atScreen p: NSPoint) -> (TerminalWindowModel, Int)? {
        let number = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        let live = models.compactMap(\.model)
        guard let m = live.first(where: { $0.window?.windowNumber == number }), let i = m.pane(atScreen: p) else { return nil }
        return (m, i)
    }

    /// 앞에 있는 터미널 창의 활성 탭 (없으면 마지막으로 쓴 창)
    var activeTab: TerminalTab? {
        let live = models.compactMap(\.model)
        if let key = NSApp.keyWindow ?? NSApp.mainWindow,
           let m = live.first(where: { $0.allTabs.contains { $0.view.window === key } }) { return m.activeTab }
        return live.max { $0.lastUsed < $1.lastUsed }?.activeTab
    }
}

/// HTTP 요청 하나 (다 받았을 때만 만들어진다)
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var h: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(h["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        method = String(first[0])
        path = String(first[1])
        headers = h
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
