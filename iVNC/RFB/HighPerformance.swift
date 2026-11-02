import Foundation
import zlib

/// 고성능 화면 공유(가상 디스플레이 + HEVC over UDP/SRTP) 협상. 시험 중 (브랜치 hp-test).
///
/// 순서 (noVNC-ARD `ard/hp/*` 를 옮김, 값은 애플 뷰어가 보내는 것을 그대로 흉내):
/// 0x1d 가상 디스플레이 요청 → SetEncodings 맨 앞 1010·맨 뒤 1110
/// → 서버: 1010(종류 1) UDP 포트 알림, 1110 Message1 → 클라이언트: 0x1c 제안(SRTP 키 + 오퍼)
/// → 서버: 1010(종류 2) 답 → UDP 로 영상 시작
enum HP {
    // MARK: - 가상 디스플레이 (0x1d)

    /// width·height 는 포인트, 픽셀은 scale 배. 최대 크기(room)는 noVNC-ARD 처럼 8K 로 잡아 나중에 크기를 바꿀 수 있게 한다.
    static func virtualDisplayMessage(width: Int, height: Int, scale: Int = 2, refresh: Double = 60) -> [UInt8] {
        let name = Array("Screen Sharing Virtual Display".utf8)
        let pw = width * scale, ph = height * scale
        var r = [UInt8](repeating: 0, count: 2 + 128 + 26 + 28)
        r.replaceSubrange(0..<2, with: [UInt8].be16(r.count))
        r.replaceSubrange(2..<(2 + name.count), with: name)
        var o = 2 + 128
        r.replaceSubrange(o..<(o + 4), with: [UInt8].be32(Float(Double(width) * 25.4 / 132).bitPattern))
        r.replaceSubrange((o + 4)..<(o + 8), with: [UInt8].be32(Float(Double(height) * 25.4 / 132).bitPattern))
        r.replaceSubrange((o + 8)..<(o + 12), with: [UInt8].be32(7680))
        r.replaceSubrange((o + 12)..<(o + 16), with: [UInt8].be32(4320))
        r.replaceSubrange((o + 22)..<(o + 24), with: [UInt8].be16(7))
        r.replaceSubrange((o + 24)..<(o + 26), with: [UInt8].be16(1))
        o += 26
        r.replaceSubrange(o..<(o + 16), with: [UInt8].be32(UInt32(pw)) + [UInt8].be32(UInt32(ph)) + [UInt8].be32(UInt32(width)) + [UInt8].be32(UInt32(height)))
        let bits = refresh.bitPattern
        r.replaceSubrange((o + 16)..<(o + 24), with: [UInt8].be32(UInt32(bits >> 32)) + [UInt8].be32(UInt32(bits & 0xFFFF_FFFF)))
        var m: [UInt8] = [0x1D, 0] + [UInt8].be16(12 + r.count - 4) + [UInt8].be16(1) + [UInt8].be16(1) + [0, 0, 0, 0]
        m += r
        return m
    }

    // MARK: - protobuf (필요한 만큼만)

    indirect enum PB {
        case int(UInt64)
        case str(String)
        case data([UInt8])
        case msg([(Int, PB)])
    }

    static func encode(_ fields: [(Int, PB)]) -> [UInt8] {
        var out = [UInt8]()
        for (f, v) in fields {
            switch v {
            case .int(let n):
                varint(&out, UInt64(f) << 3); varint(&out, n)
            case .str(let s):
                let b = Array(s.utf8); varint(&out, UInt64(f) << 3 | 2); varint(&out, UInt64(b.count)); out += b
            case .data(let b):
                varint(&out, UInt64(f) << 3 | 2); varint(&out, UInt64(b.count)); out += b
            case .msg(let m):
                let b = encode(m); varint(&out, UInt64(f) << 3 | 2); varint(&out, UInt64(b.count)); out += b
            }
        }
        return out
    }

    private static func varint(_ out: inout [UInt8], _ v: UInt64) {
        var v = v
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
    }

    enum Field { case int(UInt64), bytes([UInt8]) }

    static func decode(_ b: [UInt8]) -> [(Int, Field)] {
        var out = [(Int, Field)]()
        var i = 0
        func readVarint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let c = b[i]; i += 1
                v |= UInt64(c & 0x7F) << shift
                if c & 0x80 == 0 { return v }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count, let key = readVarint() {
            let f = Int(key >> 3)
            switch key & 7 {
            case 0: guard let v = readVarint() else { return out }; out.append((f, .int(v)))
            case 2:
                guard let n = readVarint(), i + Int(n) <= b.count else { return out }
                out.append((f, .bytes(Array(b[i..<(i + Int(n))])))); i += Int(n)
            case 1: guard i + 8 <= b.count else { return out }; out.append((f, .bytes(Array(b[i..<(i + 8)])))); i += 8
            case 5: guard i + 4 <= b.count else { return out }; out.append((f, .bytes(Array(b[i..<(i + 4)])))); i += 4
            default: return out
            }
        }
        return out
    }

    static func int(_ fields: [(Int, Field)], _ n: Int) -> UInt64? {
        for (f, v) in fields where f == n { if case .int(let x) = v { return x } }
        return nil
    }

    static func bytes(_ fields: [(Int, Field)], _ n: Int) -> [UInt8]? {
        for (f, v) in fields where f == n { if case .bytes(let x) = v { return x } }
        return nil
    }

    // MARK: - 오퍼 (0x1c)

    struct Secrets {
        let sessionID: [UInt8] = { var u = UUID().uuid; return withUnsafeBytes(of: &u) { Array($0) } }()
        let audioKeys = RFBCrypto.random(92)
        let videoKeys = RFBCrypto.random(92)
        let audioSSRC = UInt32.random(in: 1...UInt32.max)
        let videoSSRC = UInt32.random(in: 1...UInt32.max)
        let callIDs = [UUID().uuidString, UUID().uuidString]
    }

    private static let mediaSoftware = "Viceroy 1.7.0"
    private static let table: [[UInt64]] = [
        [4074, 0, 16384], [1, 299], [4, 6500], [16, 4100],
        [0, 6_000_000, 131072], [0, 20_000_000, 98304], [0, 40_000_000, 12288],
        [0, 60_000_000, 262144], [0, 75_000_000, 524288], [0, 100_000_000, 1048576],
    ]

    private static func tableFields() -> [(Int, PB)] {
        table.map { row in (9, .msg(row.enumerated().map { ($0.offset + 1, .int($0.element)) })) }
    }

    private static func payloadEntry(_ pt: UInt64, _ variants: [UInt64], _ features: String, _ last: UInt64) -> PB {
        var f: [(Int, PB)] = [(1, .int(pt))]
        for n in variants { f.append((2, .msg([(1, .int(1)), (2, .int(n)), (3, .int(50115)), (4, .int(0))]))) }
        f.append((3, .str(features)))
        f.append((4, .int(last)))
        return .msg(f)
    }

    private static func ntpNow() -> UInt64 {
        let t = Date().timeIntervalSince1970
        let sec = UInt64(t) + 2_208_988_800
        let frac = UInt64((t - floor(t)) * 4_294_967_296)
        return sec << 32 | frac
    }

    private static func streamOffer(mode: Int, blob: [(Int, PB)], callID: String) throws -> [UInt8] {
        let endpoint = encode([(1, .int(0)), (2, .int(1)), (3, .str("Mac13,1")), (4, .str("2235.63.5.2")), (5, .str("26A428"))])
        let dict: [String: Any] = [
            "avcMediaStreamOptionRemoteEndpointInfo": Data(endpoint),
            "avcMediaStreamNegotiatorMode": mode,
            "avcMediaStreamNegotiatorMediaBlob": Data(try zlibCompress(encode(blob))),
            "avcMediaStreamOptionCallID": callID,
        ]
        return Array(try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0))
    }

    static func offerMessage(_ s: Secrets) throws -> [UInt8] {
        let ntp = ntpNow()
        let common: [(Int, PB)] = [(6, .str(mediaSoftware)), (8, .int(0))] + tableFields() + [(13, .int(ntp)), (14, .int(2)), (16, .int(0)), (18, .int(1))]
        let audioBlob: [(Int, PB)] = [(1, .int(1)), (2, .int(1)),
            (3, .msg([(1, .int(UInt64(s.audioSSRC))), (2, .int(0)), (3, .int(0)), (4, .int(7807)), (5, .int(0)), (6, .int(0))]))] + common
        let h264 = "FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;SW:4;AR:8/5,5/8;XR:8/5,5/8;"
        let hevc = "FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;SW:0;AR:8/5,5/8;XR:8/5,5/8;"
        let videoBlob: [(Int, PB)] = [(1, .int(1)), (2, .int(1)),
            (5, .msg([(1, .int(UInt64(s.videoSSRC))), (2, .int(0)),
                      (3, payloadEntry(123, [1, 2, 1, 2], h264, 1)),
                      (3, payloadEntry(100, [1, 2], hevc, 14)),
                      (6, .int(4)), (7, .int(1)), (8, .int(255)), (9, .int(1)), (12, .int(1))]))] + common
        let audio = try streamOffer(mode: 8, blob: audioBlob, callID: s.callIDs[0])
        let video = try streamOffer(mode: 7, blob: videoBlob, callID: s.callIDs[1])
        let total = 36 + 92 + audio.count + 92 + video.count
        var m = [UInt8](repeating: 0, count: 36)
        m[0] = 0x1C
        m.replaceSubrange(2..<4, with: [UInt8].be16(total - 4))
        m.replaceSubrange(4..<6, with: [UInt8].be16(3))
        m.replaceSubrange(6..<10, with: [UInt8].be32(0x0D))
        m.replaceSubrange(10..<12, with: [UInt8].be16(audio.count))
        m.replaceSubrange(12..<14, with: [UInt8].be16(video.count))
        m.replaceSubrange(20..<36, with: s.sessionID)
        m += s.audioKeys + audio + s.videoKeys + video
        return m
    }

    // MARK: - 서버 메시지 해석

    /// Message1 (1110): [u16 길이][본문], 본문 10·12·14 에 문자열 길이 셋, 16 부터 문자열
    static func message1Strings(_ body: [UInt8]) -> [String] {
        guard body.count >= 16 else { return [] }
        var out = [String](), o = 16
        for k in 0..<3 {
            let n = Int(body[10 + k * 2]) << 8 | Int(body[11 + k * 2])
            guard o + n <= body.count else { break }
            out.append(String(decoding: body[o..<(o + n)].prefix { $0 != 0 }, as: UTF8.self))
            o += n
        }
        return out
    }

    /// 1010 종류 1: 서버가 보낼 UDP 포트 (본문 기준: 0 종류=1, 8 오디오 포트, 14 비디오 포트)
    static func streamPorts(_ body: [UInt8]) -> (audio: UInt16, video: UInt16)? {
        guard body.count >= 18, body[0] == 0, body[1] == 1 else { return nil }
        return (UInt16(body[8]) << 8 | UInt16(body[9]), UInt16(body[14]) << 8 | UInt16(body[15]))
    }

    struct Answer { let audioSSRC: UInt32; let videoSSRC: UInt32; let width: Int; let height: Int; let stripes: Int }

    /// 1010 종류 2: 답. 본문 8 오디오 크기, 10 비디오 크기, 18 부터 bplist 둘
    static func answer(_ body: [UInt8]) throws -> Answer {
        guard body.count >= 18 else { throw RFBError.protocolError("HP 답이 짧음") }
        let a = Int(body[8]) << 8 | Int(body[9]), v = Int(body[10]) << 8 | Int(body[11])
        guard a > 0, v > 0, 18 + a + v <= body.count else { throw RFBError.protocolError("HP 답 크기 이상") }
        func blob(_ b: ArraySlice<UInt8>) throws -> [(Int, Field)] {
            let dict = try PropertyListSerialization.propertyList(from: Data(b), format: nil) as? [String: Any]
            guard let d = dict?["avcMediaStreamNegotiatorMediaBlob"] as? Data else { throw RFBError.protocolError("HP 답에 blob 없음") }
            return decode(try Inflater().inflate(Array(d)))
        }
        let audio = decode(bytes(try blob(body[18..<(18 + a)]), 3) ?? [])
        let video = decode(bytes(try blob(body[(18 + a)..<(18 + a + v)]), 5) ?? [])
        return Answer(audioSSRC: UInt32(truncatingIfNeeded: int(audio, 1) ?? 0), videoSSRC: UInt32(truncatingIfNeeded: int(video, 1) ?? 0),
                      width: Int(int(video, 4) ?? 0), height: Int(int(video, 5) ?? 0), stripes: Int(int(video, 6) ?? 0))
    }

    private static func zlibCompress(_ b: [UInt8]) throws -> [UInt8] {
        var len = compressBound(uLong(b.count))
        var out = [UInt8](repeating: 0, count: Int(len))
        let rc = compress2(&out, &len, b, uLong(b.count), Z_DEFAULT_COMPRESSION)
        guard rc == Z_OK else { throw RFBError.protocolError("zlib compress \(rc)") }
        return Array(out[0..<Int(len)])
    }
}

/// 고성능 영상·소리 UDP 수신. SRTP 를 검증·해독해 개수를 세고, 1초마다 SRTCP 수신 보고를 보낸다 (시험용).
/// 0 = 소리, 1 = 영상. RTP 와 RTCP 가 같은 포트로 온다.
final class HPUDPReceiver {
    struct Stream {
        let fd: Int32
        let localPort: UInt16
        var inbound: SRTPContext?
        var outbound: SRTPContext?
        var mySSRC: UInt32 = 0
        var serverSSRC: UInt32 = 0
        var remotePort: UInt16 = 0
        var raw = 0, rawBytes = 0, ok = 0, bad = 0, rtcpIn = 0, sentReports = 0
        var payloadTypes: Set<UInt8> = []
        var ssrcs: Set<UInt32> = []
        var naluTypes: [Int: Int] = [:]
    }

    private var streams: [Stream] = []
    private var serverIP: in_addr_t = 0
    private var stopped = false
    private let lock = NSLock()

    /// 각 포트에 UDP 소켓을 연다. 실패하면 그 이유를 돌려준다.
    func bind(ports: [UInt16]) -> String? {
        for p in ports {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            var rcv: Int32 = 8 << 20
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = p.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if rc != 0 {
                let err = String(cString: strerror(errno))
                Darwin.close(fd)
                return "UDP \(p) 열기 실패: \(err)"
            }
            streams.append(Stream(fd: fd, localPort: p))
        }
        let t = Thread { [weak self] in self?.loop() }
        t.name = "HPUDP"
        t.start()
        return nil
    }

    /// 답을 받은 뒤: 키와 SSRC 를 넣는다. keys 는 0x1c 에 실은 92바이트 키 블록
    /// ([0,32) 클라이언트→서버 키, [32,46) 그 소금, [46,78) 서버→클라이언트 키, [78,92) 그 소금)
    func configure(index: Int, keys: [UInt8], mySSRC: UInt32, serverSSRC: UInt32, serverIP: in_addr_t, remotePort: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard index < streams.count else { return }
        streams[index].outbound = SRTPContext(masterKey: Array(keys[0..<32]), masterSalt: Array(keys[32..<46]))
        streams[index].inbound = SRTPContext(masterKey: Array(keys[46..<78]), masterSalt: Array(keys[78..<92]))
        streams[index].mySSRC = mySSRC
        streams[index].serverSSRC = serverSSRC
        streams[index].remotePort = remotePort
        self.serverIP = serverIP
    }

    /// 서버가 영상을 보내기 전에 각 로컬 포트에서 서버 포트로 작은 패킷을 먼저 내보낸다.
    /// 우리 쪽 공유기·통신사 NAT 에 "이 포트의 답장은 이 기기로" 기록을 만들어 두려는 것 (맥은 늘 같은 번호 포트로 보낸다)
    func punch(serverIP: in_addr_t, ports: [UInt16]) {
        lock.lock(); let fds = streams.map(\.fd); lock.unlock()
        let pkt: [UInt8] = [0x80, 0xC9, 0x00, 0x01, 0, 0, 0, 0]
        for (fd, port) in zip(fds, ports) {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = serverIP
            _ = withUnsafePointer(to: &addr) { a in
                a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    /// 1초마다 부른다: 스트림마다 SRTCP 수신 보고를 서버로 보낸다
    func sendReports() {
        lock.lock()
        var packets: [(Int32, UInt16, [UInt8])] = []
        for i in streams.indices {
            guard let out = streams[i].outbound, let inb = streams[i].inbound else { continue }
            let highest = inb.highestIndex[streams[i].serverSSRC] ?? 0
            let rr = SRTPContext.receiverReport(ssrc: streams[i].mySSRC, sourceSSRC: streams[i].serverSSRC, highestSeq: UInt32(truncatingIfNeeded: highest))
            packets.append((streams[i].fd, streams[i].remotePort, out.protectRTCP(rr)))
            streams[i].sentReports += 1
        }
        let ip = serverIP
        lock.unlock()
        for (fd, port, pkt) in packets {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = ip
            _ = withUnsafePointer(to: &addr) { a in
                a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return streams.enumerated().map { i, s in
            let name = i == 0 ? "소리" : "영상"
            return "\(name)(\(s.localPort)) 받음 \(s.raw)개 \(s.rawBytes / 1000)KB, 검증 성공 \(s.ok) 실패 \(s.bad), RTCP \(s.rtcpIn), 보고 보냄 \(s.sentReports), PT \(s.payloadTypes.sorted()), SSRC \(s.ssrcs.count)개"
                + (i == 1 && !s.naluTypes.isEmpty ? ", NAL 종류 \(s.naluTypes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))" : "")
        }.joined(separator: " / ")
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        for s in streams { Darwin.close(s.fd) }
    }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            lock.lock(); let s = stopped; let fds = streams.map(\.fd); lock.unlock()
            if s { return }
            var pfds = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            if poll(&pfds, nfds_t(pfds.count), 500) <= 0 { continue }
            for (i, p) in pfds.enumerated() where p.revents & Int16(POLLIN) != 0 {
                var from = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { f in
                    f.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(p.fd, &buf, buf.count, 0, $0, &len) }
                }
                guard n > 0 else { continue }
                let pkt = Array(buf[0..<n])
                lock.lock()
                let first = streams[i].raw == 0
                streams[i].raw += 1; streams[i].rawBytes += n
                // RTP/RTCP 구분 (RFC 5761): 두 번째 바이트가 192~223 이면 RTCP
                if n >= 2, (192...223).contains(pkt[1]) {
                    if let inb = streams[i].inbound, inb.unprotectRTCP(pkt) != nil { streams[i].rtcpIn += 1 }
                } else if let inb = streams[i].inbound {
                    if let rtp = inb.unprotectRTP(pkt) {
                        streams[i].ok += 1
                        streams[i].payloadTypes.insert(rtp.payloadType)
                        streams[i].ssrcs.insert(rtp.ssrc)
                        // HEVC RTP 페이로드 머리 2바이트의 NAL 종류 (48 = 묶음, 49 = 조각)
                        if i == 1, rtp.payload.count >= 2 { streams[i].naluTypes[Int(rtp.payload[0] >> 1) & 0x3F, default: 0] += 1 }
                    } else {
                        streams[i].bad += 1
                    }
                }
                lock.unlock()
                if first {
                    let fromIP = String(cString: inet_ntoa(from.sin_addr)), fromPort = UInt16(bigEndian: from.sin_port)
                    DebugLog.write("HP UDP 첫 패킷: 포트 \(streams[i].localPort) ← \(fromIP):\(fromPort), \(n)바이트")
                }
            }
        }
    }
}
