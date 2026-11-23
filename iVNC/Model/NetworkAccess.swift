import Foundation
import Darwin
import Network

/// 컴퓨터의 "접속 허용 IP" 검사 (iSQL NetworkAccess 를 옮김, 사용자 2026-11-23).
/// 1) 이 기기의 인터페이스에 공인 IP 가 붙어 있으면 그것으로 비교 (바깥에 묻지 않음)
/// 2) 아니면 내부망(사설 IP)을 쓰는 인터페이스마다 api.ipify.org 에 그 인터페이스로 묻는다 (Wi-Fi · 이더넷 · VPN 이 다른 공인 IP 일 수 있어서)
/// 3) 그래도 없으면 접속하지 않고 VPN 을 켜라고 안내한다 (맥은 시스템 설정의 VPN 목록에서 바로 켠다, iOS 는 안내만)
/// 경유 서버(배스천)로 가는 SSH 는 이 기기의 IP 를 보는 첫 서버(맨 바깥 경유 서버)의 목록으로 검사한다
enum NetworkAccess {
    /// 검사 결과 (화면 · MCP 에 보인다)
    struct Report: Equatable {
        var allowed: Bool
        /// 허용된 IP (어느 인터페이스의 무엇으로 통과했는지)
        var matched: String?
        /// 본 IP 들: "Wi-Fi(en0) 192.168.0.5 → 공인 211.x" 같은 줄
        var seen: [Seen]
        var allowedList: [String]
        /// 목록을 가진 컴퓨터 이름 (경유 서버면 그 서버)
        var owner = ""
    }
    struct Seen: Equatable, Hashable {
        var interface: String
        var local: String
        /// 공인 IP (인터페이스에 붙은 것이면 local 과 같음, 물어서 못 알아내면 nil)
        var publicIP: String?
        var asked: Bool
    }

    /// 칸에 적은 글을 목록으로 (쉼표 · 공백 · 줄바꿈으로 나눔)
    static func parseList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace || $0 == ";" }).map(String.init).filter { !$0.isEmpty }
    }

    /// 이 접속에서 검사할 컴퓨터: 경유 서버가 있으면 맨 바깥 경유 서버 (그 서버만 이 기기의 IP 를 본다)
    static func gate(for c: Computer, jumps: [Computer]) -> Computer { jumps.first ?? c }

    /// 검사할 목록이 있으면 검사 (없으면 nil = 검사 안 함)
    static func check(_ c: Computer, jumps: [Computer] = []) async -> Report? {
        let g = gate(for: c, jumps: jumps)
        guard let list = g.allowedIPs, !list.isEmpty else { return nil }
        var r = await check(list)
        r.owner = g.name
        return r
    }

    // MARK: 검사

    static func check(_ allowed: [String]) async -> Report {
        let rules = allowed.compactMap(CIDR.init)
        var seen: [Seen] = []
        let locals = localAddresses()
        // 1) 인터페이스에 붙은 공인 IP
        for a in locals where !isPrivate(a.ip) {
            seen.append(Seen(interface: a.interface, local: a.ip, publicIP: a.ip, asked: false))
            if rules.contains(where: { $0.contains(a.ip) }) {
                return Report(allowed: true, matched: "\(a.interface) \(a.ip)", seen: seen, allowedList: allowed)
            }
        }
        // 2) 사설 IPv4 를 쓰는 인터페이스마다 그 인터페이스로 바깥에 묻는다 (동시에)
        let privates = Dictionary(grouping: locals.filter { isPrivate($0.ip) && !$0.ip.contains(":") }, by: \.interface).compactMap { $0.value.first }
        let answers = await withTaskGroup(of: (String, String, String?).self) { g in
            for a in privates { g.addTask { (a.interface, a.ip, await publicIP(via: a.interface)) } }
            var out: [(String, String, String?)] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        }
        var matched: String?
        for (iface, local, pub) in answers {
            seen.append(Seen(interface: iface, local: local, publicIP: pub, asked: true))
            if matched == nil, let pub, rules.contains(where: { $0.contains(pub) }) { matched = "\(iface) \(pub)" }
            // 내부망 주소 자체를 허용한 경우 (사설 IP 로 허용한 회사 내부망)
            if matched == nil, rules.contains(where: { $0.contains(local) }) { matched = "\(iface) \(local)" }
        }
        return Report(allowed: matched != nil, matched: matched, seen: seen, allowedList: allowed)
    }

    #if os(macOS)
    /// 그 인터페이스로만 나가서 공인 IPv4 를 묻는다 (3초). iSQL 과 같은 curl
    static func publicIP(via interface: String) async -> String? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "-4", "--max-time", "3", "--interface", interface, "https://api.ipify.org"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return p.terminationStatus == 0 && CIDR(s) != nil ? s : nil
        }.value
    }
    #else
    /// iOS 는 curl 이 없어 Network 프레임워크로: 그 인터페이스만 쓰는 TLS 연결로 https://api.ipify.org 를 묻는다 (3초)
    static func publicIP(via interface: String) async -> String? {
        guard let nw = await nwInterface(named: interface) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let q = DispatchQueue(label: "iVNC.ipify")
            let params = NWParameters(tls: NWProtocolTLS.Options())
            params.requiredInterface = nw
            let conn = NWConnection(host: "api.ipify.org", port: 443, using: params)
            var done = false
            var buffer = Data()
            // 모두 q 위에서 돈다
            func finish(_ s: String?) {
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: s)
            }
            func parse() -> String? {
                let text = String(decoding: buffer, as: UTF8.self)
                guard let r = text.range(of: "\r\n\r\n") else { return nil }
                let body = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                return CIDR(body) != nil ? body : nil
            }
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    if complete || error != nil { finish(parse()) } else { receive() }
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET / HTTP/1.1\r\nHost: api.ipify.org\r\nUser-Agent: iVNC\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in receive() })
                case .failed, .cancelled: finish(parse())
                case .waiting: finish(nil)
                default: break
                }
            }
            q.asyncAfter(deadline: .now() + 3) { finish(nil) }
            conn.start(queue: q)
        }
    }

    /// 이름(en0 · utun3 …)으로 NWInterface 찾기 (지금 경로가 쓸 수 있는 인터페이스 중)
    private static func nwInterface(named name: String) async -> NWInterface? {
        await withCheckedContinuation { (cont: CheckedContinuation<NWInterface?, Never>) in
            let q = DispatchQueue(label: "iVNC.nwpath")
            let m = NWPathMonitor()
            var done = false
            m.pathUpdateHandler = { path in
                guard !done else { return }
                done = true
                m.cancel()
                cont.resume(returning: path.availableInterfaces.first { $0.name == name })
            }
            q.asyncAfter(deadline: .now() + 1) {
                guard !done else { return }
                done = true
                m.cancel()
                cont.resume(returning: nil)
            }
            m.start(queue: q)
        }
    }
    #endif

    /// 켜져 있는 인터페이스의 주소 (루프백 · 링크 로컬 · AirDrop 같은 것 빼고)
    static func localAddresses() -> [(interface: String, ip: String)] {
        var out: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        let skip = ["lo", "awdl", "llw", "anpi", "ap", "bridge", "gif", "stf"]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = cur.pointee.ifa_addr else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            if skip.contains(where: { name.hasPrefix($0) }) { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var ip = String(cString: host)
            if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
            if ip.lowercased().hasPrefix("fe80") { continue }
            out.append((name, ip))
        }
        return out
    }

    /// 사설 · 내부 주소인지 (공인 IP 가 아님)
    static func isPrivate(_ ip: String) -> Bool {
        let privateRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
                             "fc00::/7", "fe80::/10", "::1/128"]
        return privateRanges.compactMap(CIDR.init).contains { $0.contains(ip) }
    }

    /// 인터페이스 이름을 사람이 읽게 (utun · ppp · ipsec 만 VPN 으로)
    static func label(_ interface: String) -> String {
        interface.hasPrefix("utun") || interface.hasPrefix("ppp") || interface.hasPrefix("ipsec") ? "VPN(\(interface))" : interface
    }

    /// 안내 글 (MCP · 화면)
    static func explain(_ r: Report, server: String) -> String {
        let via = !r.owner.isEmpty && r.owner != server ? " (경유 서버 \(r.owner) 기준)" : ""
        var lines = ["지금 이 기기의 IP 가 \(server) 의 접속 허용 IP(\(r.allowedList.joined(separator: ", ")))\(via) 가 아닙니다."]
        for s in r.seen {
            lines.append("- \(label(s.interface)): \(s.local)" + (s.asked ? " → 공인 \(s.publicIP ?? "알 수 없음")" : " (공인)"))
        }
        return lines.joined(separator: "\n")
    }

    #if os(macOS)
    // MARK: VPN (macOS 시스템 설정 > VPN 에 등록된 것)

    struct VPN: Identifiable, Equatable {
        var id: String
        var name: String
        var status: String
        /// 끝의 [PPP:L2TP] · [IPSec] · [VPN:…]
        var kind = ""
        /// L2TP · PPTP 같은 PPP 방식: scutil 로 켜면 키체인의 공유 암호를 못 읽어 networksetup 으로 켠다
        var isPPP: Bool { kind.hasPrefix("PPP") }
        var connected: Bool { status == "Connected" }
        var connecting: Bool { status == "Connecting" }
    }

    /// `scutil --nc list`
    static func vpnList() async -> [VPN] {
        let text = await run("/usr/sbin/scutil", ["--nc", "list"])
        var out: [VPN] = []
        // 예: * (Disconnected)   1A2B-…  IPSec   "회사 VPN"   [IPSec]
        for line in text.split(separator: "\n") where line.contains("\"") {
            let s = String(line)
            guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")"), open < close,
                  let q1 = s.firstIndex(of: "\""), let q2 = s[s.index(after: q1)...].firstIndex(of: "\"") else { continue }
            let status = String(s[s.index(after: open)..<close])
            let after = s[s.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
            let id = after.first.map(String.init) ?? ""
            var kind = ""
            if let b1 = s.lastIndex(of: "["), let b2 = s.lastIndex(of: "]"), b1 < b2 { kind = String(s[s.index(after: b1)..<b2]) }
            out.append(VPN(id: id, name: String(s[s.index(after: q1)..<q2]), status: status, kind: kind))
        }
        return out
    }

    /// 켜기. L2TP 같은 PPP 방식을 `scutil --nc start` 로 켜면 "IPSec 공유 비밀이 없습니다" 가 뜬다 (키체인의 공유 암호를 못 읽음) →
    /// `networksetup -connectpppoeservice` 는 시스템 설정에서 켤 때처럼 저장된 암호를 쓴다 (iSQL 에서 사용자 확인)
    static func start(_ vpn: VPN) async {
        if vpn.isPPP { _ = await run("/usr/sbin/networksetup", ["-connectpppoeservice", vpn.name]) }
        else { _ = await run("/usr/sbin/scutil", ["--nc", "start", vpn.id]) }
    }

    static func stop(_ vpn: VPN) async {
        if vpn.isPPP { _ = await run("/usr/sbin/networksetup", ["-disconnectpppoeservice", vpn.name]) }
        else { _ = await run("/usr/sbin/scutil", ["--nc", "stop", vpn.id]) }
    }

    /// MCP 안내용 한 줄
    static func vpnSummary() async -> String {
        let vpns = await vpnList()
        return vpns.isEmpty ? "이 맥에 등록된 VPN 이 없습니다 (VPN 앱을 직접 켜야 함)."
            : "이 맥의 VPN: " + vpns.map { "\($0.name)(\($0.connected ? "연결됨" : "꺼짐"))" }.joined(separator: ", ")
    }

    private static func run(_ path: String, _ args: [String]) async -> String {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return "" }
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
    }
    #endif
}

/// IP 범위 (203.0.113.10, 10.0.0.0/8, 2001:db8::/32)
struct CIDR {
    let bytes: [UInt8]
    let prefix: Int

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1).map(String.init)
        guard let ip = parts.first, let b = CIDR.parse(ip) else { return nil }
        bytes = b
        if parts.count == 2 {
            guard let p = Int(parts[1]), p >= 0, p <= b.count * 8 else { return nil }
            prefix = p
        } else {
            prefix = b.count * 8
        }
    }

    func contains(_ ip: String) -> Bool {
        guard let b = CIDR.parse(ip), b.count == bytes.count else { return false }
        var left = prefix
        for i in 0..<bytes.count {
            guard left > 0 else { return true }
            let bits = min(8, left)
            // UInt8 끼리 밀어야 한다: Int 로 0xFF << n 을 UInt8 로 바꾸면 넘쳐서 앱이 죽는다 (/7 · /10 · /12, iSQL 2.7 에서 고친 것)
            let mask: UInt8 = UInt8.max << UInt8(8 - bits)
            if b[i] & mask != bytes[i] & mask { return false }
            left -= bits
        }
        return true
    }

    static func parse(_ ip: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
