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
         "description": "iVNC 가 MCP 에 열어 준 SSH 서버 목록(열린 터미널 탭·활성 탭 표시), 원격 화면 세션 목록, 지금 설정(접근 범위·권한)",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "run_command",
         "description": "서버에서 셸 명령 하나 실행 (사용자 터미널과 별도 채널, 화면에 안 보임). 조회 명령(ls·cat·grep·df·ps·git status 등)은 바로, 그 밖은 권한에 따라 거절되거나 사용자 확인 뒤 실행. 결과: 종료 코드·표준 출력·표준 오류. 서버 현황 조회는 server_info 를 먼저 쓴다",
         "inputSchema": ["type": "object", "properties": [
            "server": serverArg,
            "command": ["type": "string"],
            "cwd": ["type": "string", "description": "이 폴더에서 실행"],
            "timeout_seconds": ["type": "integer", "description": "기본 60, 최대 600"],
         ], "required": ["command"]]],
        ["name": "read_terminal",
         "description": "열린 터미널 탭에 보이는 화면과 스크롤백의 마지막 lines 줄 (기본 120, 최대 3000). '이 에러 뭐야?' 처럼 사용자가 보고 있는 화면을 볼 때",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "lines": ["type": "integer"]]]],
        ["name": "send_to_terminal",
         "description": "열린 터미널 탭(그 서버의 활성 탭)에 글자를 입력한다. 사용자가 보는 화면에 그대로 쳐진다. enter=true 면 끝에 엔터. 늘 위험한 동작으로 본다",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "text": ["type": "string"], "enter": ["type": "boolean"]], "required": ["text"]]],
        ["name": "list_files",
         "description": "서버 폴더의 파일 목록 (SFTP): 이름·종류·크기·수정 시각·권한",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "path": ["type": "string", "description": "없으면 홈"]]]],
        ["name": "read_file",
         "description": "서버 파일 내용 (SFTP, UTF-8 글자). max_bytes 기본 200000, 최대 2000000",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "path": ["type": "string"], "max_bytes": ["type": "integer"]], "required": ["path"]]],
        ["name": "write_file",
         "description": "서버 파일에 내용을 쓴다 (있으면 덮어씀). 위험한 동작",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "path": ["type": "string"], "content": ["type": "string"]], "required": ["path", "content"]]],
        ["name": "delete_path",
         "description": "서버 파일이나 폴더(안쪽까지)를 지운다. 위험한 동작",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "path": ["type": "string"]], "required": ["path"]]],
        ["name": "upload",
         "description": "이 맥 파일을 서버로 올린다 (SFTP 파이프라이닝). 위험한 동작",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "local_path": ["type": "string"], "remote_path": ["type": "string"]], "required": ["local_path", "remote_path"]]],
        ["name": "download",
         "description": "서버 파일을 이 맥으로 받는다. 이 맥에 같은 파일이 있으면 덮어쓰기라 위험한 동작으로 본다",
         "inputSchema": ["type": "object", "properties": ["server": serverArg, "remote_path": ["type": "string"], "local_path": ["type": "string"]], "required": ["remote_path", "local_path"]]],
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
            return text(json(listServers()))

        case "run_command":
            let cmd = try string(a, "command")
            let t = try target(a)
            let full = (a["cwd"] as? String).map { "cd -- '\($0.replacingOccurrences(of: "'", with: "'\\''"))' && " + cmd } ?? cmd
            try await allow(server: t, action: cmd, danger: CommandSafety.check(full))
            let shell = try await connection(t)
            let timeout = min(max(a["timeout_seconds"] as? Int ?? 60, 1), 600)
            let r = try await shell.execFull(full, timeout: timeout)
            note("\(t.name): \(cmd.prefix(60))")
            var out: [String: Any] = ["exit_code": r.exitStatus.map { $0 as Any } ?? NSNull(),
                                      "stdout": Self.clip(r.stdout), "stderr": Self.clip(r.stderr)]
            if r.timedOut { out["timed_out"] = true }
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
            let sftp = try await sftp(t)
            var path = a["path"] as? String ?? ""
            if path.isEmpty { path = try await sftp.realpath(".") }
            let list = try await sftp.list(path)
            let f = ISO8601DateFormatter()
            return text(json(["path": path, "entries": list.sorted { $0.name < $1.name }.map { e -> [String: Any] in
                ["name": e.name, "type": e.isDirectory ? "dir" : e.attrs.isSymlink ? "link" : "file",
                 "size": e.attrs.size.map { $0 as Any } ?? NSNull(),
                 "modified": e.attrs.modified.map { f.string(from: $0) as Any } ?? NSNull(),
                 "permissions": FileLook.permissions(e.attrs.permissions)]
            }]))

        case "read_file":
            let t = try target(a)
            let path = try string(a, "path")
            let max = min(max(a["max_bytes"] as? Int ?? 200_000, 1), 2_000_000)
            let sftp = try await sftp(t)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await sftp.download(path, to: tmp, progress: { _ in }, isCancelled: { false })
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
            let t = try target(a)
            let local = URL(fileURLWithPath: (try string(a, "local_path") as NSString).expandingTildeInPath)
            let remote = try string(a, "remote_path")
            try await allow(server: t, action: "올리기: \(local.path) → \(remote)", danger: "서버에 쓰기")
            let sftp = try await sftp(t)
            try await sftp.upload(local, to: remote, progress: { _ in }, isCancelled: { false })
            note("\(t.name): 올리기 \(remote)")
            return text("올렸습니다: \(remote)")

        case "download":
            let t = try target(a)
            let remote = try string(a, "remote_path")
            let local = URL(fileURLWithPath: (try string(a, "local_path") as NSString).expandingTildeInPath)
            let exists = FileManager.default.fileExists(atPath: local.path)
            try await allow(server: t, action: "받기: \(remote) → \(local.path)", danger: exists ? "이 맥 파일 덮어쓰기" : nil)
            let sftp = try await sftp(t)
            try await sftp.download(remote, to: local, progress: { _ in }, isCancelled: { false })
            note("\(t.name): 받기 \(remote)")
            return text("받았습니다: \(local.path)")

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
        let c = t.computer
        let s = SSHShell(host: c.host, port: c.port, username: c.username, auth: auth, term: "xterm-256color", jumps: hops)
        s.interactive = false
        s.onHostKeyQuestion = { _, answer in answer(false) }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            var done = false
            s.onConnected = { if !done { done = true; k.resume() } }
            s.onClose = { err, _ in
                if !done { done = true; k.resume(throwing: Failure((err ?? "접속하지 못했습니다.") + " (처음 접속하는 서버면 iVNC 에서 한 번 열어 서버 지문을 확인하세요)")) }
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

    private func listServers() -> [String: Any] {
        let reg = TerminalRegistry.shared
        let allowed = Set(allowedServers().map(\.id))
        let active = reg.activeTab?.computer.id
        return [
            "scope": scope.label,
            "permission": permission.label,
            "permission_detail": permission.detail,
            "servers": sshServers.filter { allowed.contains($0.id) }.map { c -> [String: Any] in
                var d: [String: Any] = ["name": c.name, "id": c.id.uuidString, "user": c.username, "host": c.host, "port": c.port,
                                        "open_tabs": reg.openTabs.filter { $0.computer.id == c.id }.count,
                                        "active": c.id == active]
                if let via = store?.jumpChain(for: c), !via.isEmpty { d["via"] = via.map(\.name) }
                return d
            },
            "screens": SessionModel.openSessions.map { ["name": $0.computer.name, "id": $0.computer.id.uuidString] },
        ]
    }

    private func string(_ a: [String: Any], _ key: String) throws -> String {
        guard let v = a[key] as? String else { throw Failure("\(key) 가 필요합니다.") }
        return v
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
