import Foundation

enum RFBError: LocalizedError {
    case connect(String)
    case closed
    case protocolError(String)
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .connect(let m): return "접속할 수 없습니다: \(m)"
        case .closed: return "서버가 연결을 끊었습니다."
        case .protocolError(let m): return "통신 오류: \(m)"
        case .authFailed(let m): return "인증에 실패했습니다. 계정 이름과 암호를 확인하세요. \(m)"
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
                var rcv: Int32 = 1 << 20 // 크게 잡으면 앱이 못 따라갈 때 화면이 수 초~수십 초 밀려 쌓인다
                setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { fd = s; return }
                lastErr = errno
                Darwin.close(s)
            }
            ai = a.pointee.ai_next
        }
        throw RFBError.connect(String(cString: strerror(lastErr)))
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
        if n <= 0 { throw RFBError.closed }
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
            if n <= 0 { throw RFBError.closed }
            got += n; received += n
        }
    }

    func skip(_ count: Int) throws {
        var left = count
        while left > 0 {
            if start == end { try fill() }
            let k = min(left, end - start)
            start += k; left -= k
        }
    }

    func u8() throws -> UInt8 {
        if start == end { try fill() }
        let v = buf[start]; start += 1
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
