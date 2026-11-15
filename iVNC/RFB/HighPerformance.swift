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

    /// 가상 디스플레이 0개 (끊기 직전에 보내 원격이 가상 디스플레이를 내리게 한다).
    /// 2026-11-02 시험에서 이걸 보내면 서버가 1초 만에 접속을 끊었다 = 고성능 세션 끝내기 신호로 본다.
    /// 그냥 TCP 를 닫으면 원격에 가상 디스플레이가 남아 실제 모니터가 꺼진 채로 있고 다음 고성능이 실패했다 (2026-11-05·11-15)
    static func removeVirtualDisplaysMessage() -> [UInt8] {
        [0x1D, 0] + [UInt8].be16(8) + [UInt8].be16(1) + [UInt8].be16(0) + [0, 0, 0, 0]
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

/// 고성능 영상·소리 UDP 수신. SRTP 를 검증·해독해 영상은 조립기로 넘기고, 1초마다 SRTCP 수신 보고,
/// 그림마다 받음 확인, 0.05초마다 속도 조절 보고를 보낸다 (noVNC-ARD feedback.js). 소리는 아직 버린다.
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
        /// SSRC 별 순번 통계 (RFC 3550 A.3: 늦게 온 패킷은 빠진 것으로 세지 않는다). 수신 보고에 실제 손실을 실어 서버가 속도를 줄이게 한다
        var seqStats: [UInt32: SeqStats] = [:]
        /// 다시 제안으로 사라진 SSRC 들의 손실 합
        var lostRetired = 0
        var lost: Int { lostRetired + seqStats.values.reduce(0) { $0 + $1.lost } }
    }

    struct SeqStats {
        var base: Int
        var maxExt: Int
        var received = 1
        var expectedPrior = 0
        var receivedPrior = 0
        var lastAt: TimeInterval
        init(seq: UInt16, now: TimeInterval) { base = Int(seq); maxExt = Int(seq); lastAt = now }
        var expected: Int { maxExt - base + 1 }
        var lost: Int { max(0, expected - received) }
        mutating func add(_ seq: UInt16, now: TimeInterval) {
            let delta = Int(Int16(bitPattern: seq &- UInt16(truncatingIfNeeded: maxExt)))
            if delta > 3000 || delta < -3000 { self = SeqStats(seq: seq, now: now); return } // 순번이 크게 튀면 새로 센다
            if delta > 0 { maxExt += delta }
            received += 1
            lastAt = now
        }
        /// RR 보고 블록 (24바이트): SSRC, 이번 구간 손실 비율, 누적 손실, 가장 큰 확장 순번, 지터·LSR·DLSR 0
        mutating func reportBlock(ssrc: UInt32) -> [UInt8] {
            let expInt = expected - expectedPrior, recInt = received - receivedPrior
            expectedPrior = expected; receivedPrior = received
            let lostInt = expInt - recInt
            let fraction = expInt <= 0 || lostInt <= 0 ? 0 : min(255, (lostInt << 8) / expInt)
            let cum = min(lost, 0x7FFFFF)
            return [UInt8].be32(ssrc) + [UInt8(fraction), UInt8(cum >> 16 & 0xFF), UInt8(cum >> 8 & 0xFF), UInt8(cum & 0xFF)]
                + [UInt8].be32(UInt32(truncatingIfNeeded: maxExt)) + [UInt8].be32(0) + [UInt8].be32(0) + [UInt8].be32(0)
        }
    }

    private var streams: [Stream] = []
    private var server = sockaddr_in6()
    /// 영상 조립 (잠금 안에서만 만진다)
    private var assembler: HPVideoAssembler?
    private var readyPictures: [HPVideoAssembler.Picture] = []
    private var assemblerStalled = false
    private var pictures = 0
    private var lastVideoAt: TimeInterval?
    private var lastRateControl: TimeInterval = 0
    private(set) var lastPictureAt: TimeInterval?
    /// 조립된 그림 (수신 스레드에서 부른다)
    var onPicture: ((HPVideoAssembler.Picture) -> Void)?
    /// 조립이 막혀 키 그림부터 다시 받아야 할 때 (다시 제안)
    var onStall: (() -> Void)?

    // 빠진 영상 패킷 다시 보내 달라기 (RTCP Generic NACK, RFC 4585). 줄무늬 SSRC 마다 가장 큰 순번을 기억하고,
    // 건너뛴 순번을 바로 요청, 0.08초 뒤에도 안 오면 한 번 더. 0.5초 넘으면 포기 (조립기가 키 그림으로 넘어간다)
    private struct Gap { var highest: Int; var missing: [UInt16: (at: TimeInterval, retried: Bool)] = [:] }
    private var gaps: [UInt32: Gap] = [:]
    private var pendingNacks: [UInt32: [UInt16]] = [:]
    private(set) var nackSent = 0, nackSeqs = 0, nackRecovered = 0

    /// 영상 패킷 하나가 왔을 때 (잠근 채로 부른다)
    private func trackVideoSeq(_ ssrc: UInt32, _ seq: UInt16, now: TimeInterval) {
        guard var g = gaps[ssrc] else { gaps[ssrc] = Gap(highest: Int(seq)); return }
        let d = Int(Int16(bitPattern: seq &- UInt16(truncatingIfNeeded: g.highest)))
        if d > 0 {
            if d > 1 && d < 200 {
                for k in 1..<d {
                    let m = UInt16(truncatingIfNeeded: g.highest + k)
                    g.missing[m] = (now, false)
                    pendingNacks[ssrc, default: []].append(m)
                }
            }
            g.highest += d
        } else if g.missing.removeValue(forKey: seq) != nil {
            nackRecovered += 1
        }
        gaps[ssrc] = g
    }

    /// 다시 요청할 것·오래된 것 정리 (잠근 채로)
    private func ageGaps(now: TimeInterval) {
        for (ssrc, var g) in gaps {
            for (seq, m) in g.missing {
                if now - m.at > 0.5 { g.missing[seq] = nil }
                else if !m.retried && now - m.at > 0.08 {
                    g.missing[seq] = (m.at, true)
                    pendingNacks[ssrc, default: []].append(seq)
                }
            }
            gaps[ssrc] = g
        }
    }

    /// NACK 패킷들 (잠근 채로): FCI = [PID u16][BLP u16] — PID 뒤 16개 중 빠진 것은 BLP 비트로
    private func buildNacks(_ out: SRTPContext, me: UInt32) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        for (media, seqs) in pendingNacks where !seqs.isEmpty {
            var fci: [UInt8] = []
            var rest = Set(seqs)
            while let pid = rest.min(by: { Int16(bitPattern: $0 &- $1) < 0 }) {
                rest.remove(pid)
                var blp: UInt16 = 0
                for b in 0..<16 {
                    let s = pid &+ UInt16(b + 1)
                    if rest.remove(s) != nil { blp |= 1 << b }
                }
                fci += [UInt8].be16(Int(pid)) + [UInt8].be16(Int(blp))
            }
            let n = fci.count / 4
            let rr = [UInt8].be32(0x80C9_0001) + [UInt8].be32(me)
            let nack = [0x81, 205] + [UInt8].be16(2 + n) + [UInt8].be32(me) + [UInt8].be32(media) + fci
            packets.append(out.protectRTCP(rr + nack))
            nackSent += 1
            nackSeqs += seqs.count
        }
        pendingNacks.removeAll()
        return packets
    }
    private var stopped = false
    private let lock = NSLock()

    /// 각 포트에 UDP 소켓을 연다. 실패하면 그 이유를 돌려준다.
    func bind(ports: [UInt16]) -> String? {
        for p in ports {
            // IPv6 이중 스택: IPv4(::ffff:…)와 IPv6(LTE NAT64)를 함께 받는다
            let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
            // 받는 버퍼는 되는 만큼 크게 (키 그림이 한꺼번에 몰려온다). 너무 크면 거절되므로 줄여 가며
            for mb: Int32 in [8, 6, 4, 2, 1] {
                var rcv = mb << 20
                if setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size)) == 0 { break }
            }
            var got: Int32 = 0, gotLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &got, &gotLen)
            DebugLog.write("HP UDP \(p) 받는 버퍼 \(got / 1024)KB")
            var off: Int32 = 0
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_port = p.bigEndian
            addr.sin6_addr = in6addr_any
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
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
    func configure(index: Int, keys: [UInt8], mySSRC: UInt32, serverSSRC: UInt32, server: sockaddr_in6, remotePort: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard index < streams.count else { return }
        streams[index].outbound = SRTPContext(masterKey: Array(keys[0..<32]), masterSalt: Array(keys[32..<46]))
        streams[index].inbound = SRTPContext(masterKey: Array(keys[46..<78]), masterSalt: Array(keys[78..<92]))
        streams[index].mySSRC = mySSRC
        streams[index].serverSSRC = serverSSRC
        streams[index].remotePort = remotePort
        self.server = server
    }

    /// 새 답의 영상 SSRC·줄무늬 수로 조립기를 새로 만든다 (다시 제안한 뒤에도)
    func startVideo(baseSSRC: UInt32, stripes: Int) {
        lock.lock(); defer { lock.unlock() }
        videoBase = baseSSRC
        videoStripes = max(stripes, 1)
        gaps.removeAll(); pendingNacks.removeAll()
        let a = HPVideoAssembler(baseSSRC: baseSSRC, stripes: stripes)
        a.onPicture = { [unowned self] in self.readyPictures.append($0) }
        a.onStall = { [unowned self] in self.assemblerStalled = true }
        assembler = a
        lastPictureAt = ProcessInfo.processInfo.systemUptime
    }

    private var videoBase: UInt32 = 0
    private var videoStripes = 1
    private var firSeq: UInt8 = 0

    /// 마지막 영상 패킷을 받은 시각 (영상이 오는데 화면에 안 나오는지 가르려고)
    var lastVideoPacketAt: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastVideoAt
    }

    /// 키 그림을 달라고 서버에 RTCP 로 요청한다 (줄무늬 SSRC 마다 PLI + FIR, RFC 4585·5104).
    /// 서버가 따르는지는 확인 안 됨: 안 따르면 다시 제안으로 넘어간다
    func requestKeyPicture() {
        lock.lock()
        guard streams.count > 1, let out = streams[1].outbound else { lock.unlock(); return }
        let me = streams[1].mySSRC, fd = streams[1].fd, port = streams[1].remotePort, to = server
        var packets: [[UInt8]] = []
        firSeq &+= 1
        for i in 0..<videoStripes {
            let media = videoBase &+ UInt32(i)
            // RR(보고 블록 없음) 를 앞에 붙인 복합 RTCP
            let rr = [UInt8].be32(0x80C9_0001) + [UInt8].be32(me)
            let pli = [0x81, 206, 0x00, 0x02] + [UInt8].be32(me) + [UInt8].be32(media)
            let fir = [0x84, 206, 0x00, 0x04] + [UInt8].be32(me) + [UInt8].be32(0) + [UInt8].be32(media) + [firSeq, 0, 0, 0]
            packets.append(out.protectRTCP(rr + pli + fir))
        }
        lock.unlock()
        for p in packets { Self.send(fd, p, to: to, port: port) }
    }

    /// 지금까지 받은 UDP 바이트 (소리+영상)와 빠진 영상 패킷 수 (화면 구석 통신량 표시용)
    var traffic: (bytes: Int, lost: Int, packets: Int) {
        lock.lock(); defer { lock.unlock() }
        return (streams.reduce(0) { $0 + $1.rawBytes }, streams.count > 1 ? streams[1].lost : 0, streams.count > 1 ? streams[1].ok : 0)
    }

    var videoDiag: String {
        lock.lock(); defer { lock.unlock() }
        return "그림 \(pictures), 조립 \(assembler?.diag ?? "없음")"
    }

    private static func send(_ fd: Int32, _ pkt: [UInt8], to server: sockaddr_in6, port: UInt16) {
        var addr = server
        addr.sin6_port = port.bigEndian
        _ = withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }

    /// 서버가 영상을 보내기 전에 각 로컬 포트에서 서버 포트로 작은 패킷을 먼저 내보낸다.
    /// 우리 쪽 공유기·통신사 NAT 에 "이 포트의 답장은 이 기기로" 기록을 만들어 두려는 것 (맥은 늘 같은 번호 포트로 보낸다)
    func punch(server: sockaddr_in6, ports: [UInt16]) {
        lock.lock(); let fds = streams.map(\.fd); lock.unlock()
        let pkt: [UInt8] = [0x80, 0xC9, 0x00, 0x01, 0, 0, 0, 0]
        for (fd, port) in zip(fds, ports) {
            Self.send(fd, pkt, to: server, port: port)
            // 시험용: 서버 쪽 5902 에서 받는 프로그램이 "통신사가 바꾼 바깥 포트"를 볼 수 있게
            Self.send(fd, Array("iVNC probe from local \(port)".utf8), to: server, port: 5902)
        }
    }

    /// 1초마다 부른다: 스트림마다 SRTCP 수신 보고를 서버로 보낸다
    /// 앱이 백그라운드일 때 true: 해독·조립·보고(수신 보고, 그림 받음 확인, 속도 조절)를 모두 멈춘다.
    /// 보고가 끊기면 서버가 보내기를 줄이거나 멈추기를 기대한다 (실기기 로그로 확인할 것)
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }
    private var _paused = false

    func sendReports() {
        lock.lock()
        if _paused { lock.unlock(); return }
        var packets: [(Int32, UInt16, [UInt8])] = []
        for i in streams.indices {
            guard let out = streams[i].outbound else { continue }
            // 5초 넘게 안 온 SSRC (다시 제안 전 것) 는 보고에서 빼고 손실만 남긴다
            let now = ProcessInfo.processInfo.systemUptime
            for (ssrc, st) in streams[i].seqStats where now - st.lastAt > 5 {
                streams[i].lostRetired += st.lost
                streams[i].seqStats[ssrc] = nil
            }
            var blocks: [UInt8] = []
            var n = 0
            for ssrc in streams[i].seqStats.keys.sorted().prefix(31) {
                blocks += streams[i].seqStats[ssrc]!.reportBlock(ssrc: ssrc)
                n += 1
            }
            if n == 0 { blocks = SRTPContext.emptyBlock(streams[i].serverSSRC); n = 1 }
            let me = streams[i].mySSRC
            let rr = [0x80 | UInt8(n), 201] + [UInt8].be16(1 + 6 * n) + [UInt8].be32(me) + blocks
                + [UInt8].be32(0x81CA_0002) + [UInt8].be32(me) + [UInt8].be32(0x0100_0000)
            packets.append((streams[i].fd, streams[i].remotePort, out.protectRTCP(rr)))
            streams[i].sentReports += 1
        }
        let to = server
        lock.unlock()
        for (fd, port, pkt) in packets { Self.send(fd, pkt, to: to, port: port) }
    }

    /// 검증된 영상 패킷 수 (고성능이 실제로 오는지 판정)
    var verifiedVideo: Int {
        lock.lock(); defer { lock.unlock() }
        return streams.count > 1 ? streams[1].ok : 0
    }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return streams.enumerated().map { i, s in
            let name = i == 0 ? "소리" : "영상"
            return "\(name)(\(s.localPort)) 받음 \(s.raw)개 \(s.rawBytes / 1000)KB, 검증 성공 \(s.ok) 실패 \(s.bad), 빠짐 \(s.lost), RTCP \(s.rtcpIn), 보고 보냄 \(s.sentReports), PT \(s.payloadTypes.sorted()), SSRC \(s.ssrcs.count)개" + (i == 1 ? ", NACK \(nackSent)번 \(nackSeqs)개 → 되찾음 \(nackRecovered)" : "")
                + (i == 1 && !s.naluTypes.isEmpty ? ", NAL 종류 \(s.naluTypes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))" : "")
        }.joined(separator: " / ")
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        for s in streams { Darwin.close(s.fd) }
    }

    /// 패킷을 처리한 뒤 (또는 0.05초마다): 조립된 그림을 넘기고 받음 확인, 막힘 알림, 속도 조절 보고
    private func afterPackets() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if _paused { lock.unlock(); return }
        assembler?.tick(now: now)
        let pics = readyPictures
        readyPictures.removeAll()
        let stall = assemblerStalled
        assemblerStalled = false
        pictures += pics.count
        if !pics.isEmpty { lastPictureAt = now }
        var packets: [[UInt8]] = []
        var port: UInt16 = 0, fd: Int32 = -1
        if streams.count > 1, let out = streams[1].outbound {
            port = streams[1].remotePort; fd = streams[1].fd
            let me = streams[1].mySSRC
            ageGaps(now: now)
            packets += buildNacks(out, me: me)
            // 그림 받음 확인: APP(204), 이름 5, DON
            for p in pics {
                packets.append(out.protectRTCP([0x80, 0xCC, 0x00, 0x03] + [UInt8].be32(me) + [UInt8].be32(5) + [UInt8].be32(UInt32(p.don & 0xFFFF))))
            }
            // 속도 조절 "RCTL": 그림 수, 마지막 영상 뒤 ms, 영상 패킷 수, 60000kbit
            if now - lastRateControl >= 0.05 {
                lastRateControl = now
                let since = lastVideoAt.map { min(Int((now - $0) * 1000), 0xFFFF) } ?? 0
                var r = [UInt8].be32(0x80CC_0007) + [UInt8].be32(me) + [UInt8].be32(0x5243_544C) + [UInt8].be32(0x8500_0004)
                r += [UInt8].be16(pictures & 0xFFFF) + [UInt8].be32(0) + [UInt8].be16(since) + [0xFF, 0xFF]
                r += [UInt8].be32(UInt32(truncatingIfNeeded: streams[1].ok)) + [UInt8].be16(60000)
                packets.append(out.protectRTCP(r))
            }
        }
        let to = server
        lock.unlock()
        for p in pics { onPicture?(p) }
        if fd >= 0 { for p in packets { Self.send(fd, p, to: to, port: port) } }
        if stall { onStall?() }
    }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            lock.lock(); let s = stopped; let fds = streams.map(\.fd); lock.unlock()
            if s { return }
            var pfds = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&pfds, nfds_t(pfds.count), 50)
            afterPackets()
            if ready <= 0 { continue }
            for (i, p) in pfds.enumerated() where p.revents & Int16(POLLIN) != 0 {
                var from = sockaddr_in6(), len = socklen_t(MemoryLayout<sockaddr_in6>.size)
                let n = withUnsafeMutablePointer(to: &from) { f in
                    f.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(p.fd, &buf, buf.count, 0, $0, &len) }
                }
                guard n > 0 else { continue }
                let pkt = Array(buf[0..<n])
                lock.lock()
                let first = streams[i].raw == 0
                streams[i].raw += 1; streams[i].rawBytes += n
                // 앱이 백그라운드: 받은 양만 세고 해독·조립은 안 한다 (돌아오면 다시 제안해 새로 받는다)
                if _paused { lock.unlock(); continue }
                // RTP/RTCP 구분 (RFC 5761): 두 번째 바이트가 192~223 이면 RTCP
                if n >= 2, (192...223).contains(pkt[1]) {
                    if let inb = streams[i].inbound, inb.unprotectRTCP(pkt) != nil { streams[i].rtcpIn += 1 }
                } else if let inb = streams[i].inbound {
                    if let rtp = inb.unprotectRTP(pkt) {
                        streams[i].ok += 1
                        streams[i].payloadTypes.insert(rtp.payloadType)
                        streams[i].ssrcs.insert(rtp.ssrc)
                        let at = ProcessInfo.processInfo.systemUptime
                        if streams[i].seqStats[rtp.ssrc] != nil {
                            streams[i].seqStats[rtp.ssrc]!.add(rtp.seq, now: at)
                        } else {
                            streams[i].seqStats[rtp.ssrc] = SeqStats(seq: rtp.seq, now: at)
                        }
                        // HEVC RTP 페이로드 머리 2바이트의 NAL 종류 (48 = 묶음, 49 = 조각)
                        if i == 1, rtp.payload.count >= 2 { streams[i].naluTypes[Int(rtp.payload[0] >> 1) & 0x3F, default: 0] += 1 }
                        if i == 1, rtp.payloadType == 100 {
                            let now = ProcessInfo.processInfo.systemUptime
                            lastVideoAt = now
                            trackVideoSeq(rtp.ssrc, rtp.seq, now: now)
                            assembler?.push(rtp, now: now)
                        }
                    } else {
                        streams[i].bad += 1
                    }
                }
                lock.unlock()
                if first {
                    DebugLog.write("HP UDP 첫 패킷: 포트 \(streams[i].localPort) ← [\(RFBSocket.describe(from))]:\(UInt16(bigEndian: from.sin6_port)), \(n)바이트")
                }
            }
        }
    }
}
