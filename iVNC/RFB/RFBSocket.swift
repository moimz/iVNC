import Foundation

enum RFBError: LocalizedError {
    case connect(String)
    case closed
    case protocolError(String)
    case authFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .connect(let m): return "접속할 수 없습니다: \(m)"
        case .closed: return "서버가 연결을 끊었습니다."
        case .protocolError(let m): return "통신 오류: \(m)"
        case .authFailed(let m): return "인증에 실패했습니다. 계정 이름과 암호를 확인하세요. \(m)"
        case .timeout: return "서버가 응답하지 않습니다."
        }
    }
}

/// 막히는(blocking) TCP 소켓. 읽기는 수신 스레드 하나에서만, 쓰기는 아무 스레드에서나 (잠금).
final class RFBSocket {
    private var fd: Int32 = -1
    private var buf = [UInt8](repeating: 0, count: 1 << 18)
    private var start = 0, end = 0
    private let writeLock = NSLock()
    private(set) var received = 0
    /// 최근에 읽어 간 바이트 (통신이 어긋났을 때 원인을 보려고)
    private var history = [UInt8](repeating: 0, count: 512)
    private var historyPos = 0

    private func remember(_ p: UnsafeRawBufferPointer) {
        for b in p.suffix(history.count) { history[historyPos] = b; historyPos = (historyPos + 1) % history.count }
    }

    /// 최근에 읽은 바이트 (오래된 것부터)
    var recentBytes: [UInt8] { Array(history[historyPos...] + history[..<historyPos]) }

    init(host: String, port: Int) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { throw RFBError.connect(String(cString: gai_strerror(rc))) }
        defer { freeaddrinfo(res) }
        var lastErr: Int32 = 0
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                var on: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                // 살아 있음 확인: 5분 동안 오간 게 없으면 빈 확인 패킷을 보내고, 30초 간격 3번 답이 없으면 끊긴 것으로 본다.
                // 맥 커널이 대신 답하므로 화면 공유 쪽에는 아무 일도 없다. 맥이 사라지면(잠듦·전원·네트워크) 약 6분 반 안에 안다
                setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
                var idle: Int32 = 300, interval: Int32 = 30, count: Int32 = 3
                setsockopt(s, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(s, IPPROTO_TCP, TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(s, IPPROTO_TCP, TCP_KEEPCNT, &count, socklen_t(MemoryLayout<Int32>.size))
                var rcv: Int32 = 1 << 20 // 크게 잡으면 앱이 못 따라갈 때 화면이 수 초~수십 초 밀려 쌓인다
                setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
                if Self.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen, timeout: 10) { fd = s; return }
                lastErr = errno
                Darwin.close(s)
            }
            ai = a.pointee.ai_next
        }
        throw RFBError.connect(String(cString: strerror(lastErr)))
    }

    /// 제한 시간 있는 connect (닿지 않는 주소는 막히는 connect 로 1분 넘게 걸린다). 실패하면 errno 를 남긴다
    private static func connect(_ s: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t, timeout: Int32) -> Bool {
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(s, F_SETFL, flags) }
        if Darwin.connect(s, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, timeout * 1000) > 0 else { errno = ETIMEDOUT; return false }
        var err: Int32 = 0, l = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &l)
        if err != 0 { errno = err; return false }
        return true
    }

    /// TCP 상대 주소를 IPv6 형태로 (IPv4 면 ::ffff:a.b.c.d). 고성능 UDP 를 보낼 곳.
    /// LTE 는 IPv6 전용이라 IPv4 서버도 통신사 NAT64 주소(64:ff9b::…)로 보인다.
    var peerAddress6: sockaddr_in6? {
        var storage = sockaddr_storage(), len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) } }
        guard rc == 0 else { return nil }
        if storage.ss_family == sa_family_t(AF_INET6) {
            return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee } }
        }
        guard storage.ss_family == sa_family_t(AF_INET) else { return nil }
        let v4 = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee } }
        var a = sockaddr_in6()
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        let ip = UInt32(bigEndian: v4.sin_addr.s_addr)
        a.sin6_addr = in6_addr(__u6_addr: .init(__u6_addr8: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF,
            UInt8(ip >> 24), UInt8(ip >> 16 & 0xFF), UInt8(ip >> 8 & 0xFF), UInt8(ip & 0xFF))))
        return a
    }

    /// 이 TCP 접속이 쓰는 내 쪽 네트워크 장치 (이름, 번호). 고성능 UDP 를 같은 장치에 묶으려고
    var localInterface: (name: String, index: UInt32)? {
        var storage = sockaddr_storage(), len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard rc == 0 else { return nil }
        // 비교할 주소: IPv4 4바이트 또는 IPv6 16바이트 (::ffff:a.b.c.d 는 IPv4 로)
        func key(_ sa: UnsafePointer<sockaddr>) -> [UInt8]? {
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                return withUnsafeBytes(of: &a) { Array($0) }
            case AF_INET6:
                var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let b = withUnsafeBytes(of: &a) { Array($0) }
                return b[0..<12] == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF][...] ? Array(b[12...]) : b
            default: return nil
            }
        }
        guard let mine = withUnsafePointer(to: &storage, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { key($0) } }) else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let i = p {
            if let sa = i.pointee.ifa_addr, key(sa) == mine {
                let name = String(cString: i.pointee.ifa_name)
                let index = if_nametoindex(i.pointee.ifa_name)
                return index > 0 ? (name, index) : nil
            }
            p = i.pointee.ifa_next
        }
        return nil
    }

    static func describe(_ a: sockaddr_in6) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &a.sin6_addr, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    /// 읽기 제한 시간. 0 이면 없음 (접속 과정에서 서버가 멈춰 있으면 끊고 다시 시도하려고)
    func setReadTimeout(_ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func readError() -> RFBError {
        errno == EAGAIN || errno == EWOULDBLOCK ? .timeout : .closed
    }

    func close() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
    }

    deinit { close() }

    // MARK: 쓰기

    func send(_ bytes: [UInt8]) {
        writeLock.lock(); defer { writeLock.unlock() }
        var off = 0
        while off < bytes.count && fd >= 0 {
            let n = bytes[off...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            off += n
        }
    }

    // MARK: 읽기

    private func fill() throws {
        if start == end { start = 0; end = 0 }
        if end == buf.count {
            if start > 0 {
                buf.replaceSubrange(0..<(end - start), with: buf[start..<end])
                end -= start; start = 0
            } else {
                buf += [UInt8](repeating: 0, count: buf.count)
            }
        }
        let n = buf[end...].withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
        if n < 0 { throw Self.readError() }
        if n == 0 { throw RFBError.closed }
        end += n
        received += n
    }

    func read(_ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            if start == end { try fill() }
            let k = min(count - out.count, end - start)
            out += buf[start..<(start + k)]
            start += k
        }
        out.withUnsafeBytes { remember($0) }
        return out
    }

    /// 큰 덩어리를 바로 지정한 메모리로 읽는다.
    func read(into p: UnsafeMutableRawPointer, count: Int) throws {
        var got = 0
        let k = min(count, end - start)
        if k > 0 {
            buf.withUnsafeBytes { p.copyMemory(from: $0.baseAddress! + start, byteCount: k) }
            start += k; got = k
        }
        while got < count {
            let n = Darwin.recv(fd, p + got, count - got, 0)
            if n < 0 { throw Self.readError() }
            if n == 0 { throw RFBError.closed }
            got += n; received += n
        }
    }

    func skip(_ count: Int) throws {
        var left = count
        while left > 0 {
            if start == end { try fill() }
            let k = min(left, end - start)
            buf[start..<(start + k)].withUnsafeBytes { remember($0) }
            start += k; left -= k
        }
    }

    func u8() throws -> UInt8 {
        if start == end { try fill() }
        let v = buf[start]; start += 1
        history[historyPos] = v; historyPos = (historyPos + 1) % history.count
        return v
    }

    func u16() throws -> Int {
        let b = try read(2)
        return Int(b[0]) << 8 | Int(b[1])
    }

    func u32() throws -> UInt32 {
        let b = try read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    func s32() throws -> Int32 { Int32(bitPattern: try u32()) }
}

extension Array where Element == UInt8 {
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
