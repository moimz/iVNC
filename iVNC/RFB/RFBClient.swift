import CommonCrypto
import Foundation

/// macOS 화면 공유(RFB 003.889 + 애플 확장) 클라이언트.
///
/// 순서: 접속 → 애플 인증 → 모니터 목록(DisplayInfo2)을 받는다 (화면 데이터는 아직 안 받음)
/// → `select(display:)` 로 모니터를 고르면 그 모니터만 받는다.
/// 수신은 전용 스레드에서 하고, 알림(`onEvent`)은 메인 스레드로 보낸다.
final class RFBClient {
    enum Event {
        case status(String)
        case displays([RemoteDisplay])
        case frame
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    let framebuffer = Framebuffer()

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private var socket: RFBSocket?
    private var thread: Thread?
    private var stopped = false

    private let zrle = Inflater()
    private let zlibRaw = Inflater()
    private let stateLock = NSLock()
    /// 화면을 받고 있는지 (모니터를 고르기 전에는 화면 요청을 보내지 않는다)
    private var streaming = false
    /// 고른 모니터. 서버가 그 모니터로 바꿨다는 DisplayInfo2 를 기다리는 중이면 awaitingSwitch
    private var selectedID: UInt32?
    private var awaitingSwitch = false
    /// 서버가 지금 보내는 모니터 (마지막 DisplayInfo2 기준)
    private var serverDisplayID: UInt32?
    /// 화면 쪽이 아직 앞 그림을 가져가지 않았으면 알림을 또 보내지 않는다
    private var framePending = false

    /// 화면 보호기 막기: 화면을 받는 동안 커서가 멈춰 있으면, 그 자리에 그대로 마우스 이동을 보내 맥의 유휴 시간을 되돌린다.
    /// Debug 빌드는 Darwin 알림으로 켜고 끈다 (`KeepAwake`).
    private var cursor: (x: Int, y: Int)?
    private var cursorChangedAt = Date.distantPast
    /// 앱에서 직접 조작한 마지막 시각 (제어 기능이 들어가면 갱신한다)
    private var lastLocalInput = Date.distantPast
    private var keepAwakeTimer: DispatchSourceTimer?
    /// 애플 인증에서 얻은 AES 키. 있으면 키 입력을 EncryptedEvent(0x10)로 보낸다 (noVNC-ARD 와 같은 방식)
    private var ardKey: [UInt8]?
    /// 전체 화면(비증분) 요청을 보내고 아직 화면을 못 받았으면 그 시각과 그때까지 받은 바이트 수.
    /// 2초 동안 데이터가 거의 안 들어오면 다시 요청한다 (큰 화면을 받는 중에는 다시 요청하지 않는다).
    private var fullRequestAt: Date?
    private var fullRequestReceived = 0
    /// 화면 업데이트 메시지 안에서 DisplayInfo2 를 받았으면, 그 메시지를 다 읽은 뒤에 전체 화면을 요청한다 (실험 CLI 와 같은 순서)
    private var inUpdate = false
    private var fullRequestPending = false
    /// 애플 자동 화면 갱신(AutoFBUpdate 0x09)을 켰는지. 켜면 서버가 바뀐 부분을 알아서 계속 보낸다.
    /// 일반 VNC 방식(업데이트마다 다시 요청)만 쓰면 애플 서버가 수십 초 뒤 보내기를 멈춘다 (2026-11-02 ubion 에서 확인).
    private var autoUpdateOn = false
    /// 자동 화면 갱신(서버가 밀어 보내기)을 쓸지. 기본은 끔: 앱이 한 장 다 받고 다음 장을 요청해야
    /// 서버가 앱 속도에 맞춰 보낸다. 자동으로 켜 두면 앱이 조금만 느려도 서버 쪽에 화면이 쌓여
    /// 키 입력이 수십 초씩 밀렸다 (2026-11-02 ubion, 동영상 재생 중 측정).
    static var useAutoUpdate = false
    /// 키를 치는 동안(마지막 키 뒤 1초)은 자동 갱신을 꺼서 서버가 화면보다 키를 먼저 처리하게 한다
    private var typingHoldUntil = Date.distantPast
    private static let typingHold: TimeInterval = 1.0
    private let autoLock = NSLock()
    private var watchdog: DispatchSourceTimer?

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    // MARK: - 고성능 시험 (Debug, 환경 변수 IVNC_HP=1, 받는 포트를 옮기려면 IVNC_HP_PORT_OFFSET)

    #if DEBUG
    static let hpTest = ProcessInfo.processInfo.environment["IVNC_HP"] != nil
    static let hpPortOffset = UInt16(ProcessInfo.processInfo.environment["IVNC_HP_PORT_OFFSET"] ?? "0") ?? 0
    #else
    static let hpTest = false
    static let hpPortOffset: UInt16 = 0
    #endif
    private var hpSecrets: HP.Secrets?
    private var hpReceiver: HPUDPReceiver?
    private var hpServerPorts: (audio: UInt16, video: UInt16)?
    private var hpTimer: DispatchSourceTimer?

    private func hpRect(_ enc: Int32, _ body: [UInt8]) {
        DebugLog.write("HP 사각형 \(enc) \(body.count)바이트: \(body.prefix(24).map { String(format: "%02x", $0) }.joined())")
        if enc == 1110 {
            DebugLog.write("HP Message1 문자열 \(HP.message1Strings(body))")
            let secrets = HP.Secrets()
            hpSecrets = secrets
            do {
                let offer = try HP.offerMessage(secrets)
                socket?.send(offer)
                DebugLog.write("HP 제안(0x1c) 보냄 \(offer.count)바이트, 내 SSRC 오디오 \(String(secrets.audioSSRC, radix: 16)) 비디오 \(String(secrets.videoSSRC, radix: 16))")
            } catch {
                DebugLog.write("HP 제안 만들기 실패 \(error)")
            }
        } else if enc == 1010 {
            if let ports = HP.streamPorts(body) {
                hpServerPorts = ports
                DebugLog.write("HP 서버 UDP 포트: 오디오 \(ports.audio), 비디오 \(ports.video)")
                if hpReceiver == nil {
                    let r = HPUDPReceiver()
                    let local = [ports.audio &+ Self.hpPortOffset, ports.video &+ Self.hpPortOffset]
                    if let err = r.bind(ports: local) { DebugLog.write("HP " + err) } else { hpReceiver = r; DebugLog.write("HP UDP 받는 포트 \(local)") }
                }
            } else {
                do {
                    let a = try HP.answer(body)
                    DebugLog.write("HP 답: 서버 SSRC 오디오 \(String(a.audioSSRC, radix: 16)) 비디오 \(String(a.videoSSRC, radix: 16)), \(a.width)x\(a.height), 줄무늬 \(a.stripes)")
                } catch {
                    DebugLog.write("HP 답 해석 실패 \(error)")
                }
                hpStartWatching()
            }
        }
    }

    /// 답을 받은 뒤: 1초마다 서버 포트로 작은 패킷을 보내고(포트 따라오기 시험), 2초마다 받은 양을 적는다
    private func hpStartWatching() {
        guard hpTimer == nil, let r = hpReceiver, let ports = hpServerPorts, let ip = socket?.peerIPv4 else { return }
        var n = 0
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler {
            n += 1
            if n <= 10 { r.punch(index: 0, to: ip, port: ports.audio); r.punch(index: 1, to: ip, port: ports.video) }
            if n % 2 == 0 { DebugLog.write("HP UDP 받은 양: \(r.summary())") }
        }
        hpTimer = t
        t.resume()
    }

    #if DEBUG
    /// 디버그 신호로 지금 접속을 건드리기 위한 참조
    static weak var current: RFBClient?

    /// 디버그: 지금 화면 전체를 다시 요청한다
    func debugRequestFull() { DebugLog.write("디버그: 전체 화면 요청"); requestUpdate(incremental: false) }

    /// 디버그: 마우스를 화면 가운데로 옮긴다 (실제로 커서가 움직인다)
    func debugMoveMouse() {
        let x = framebuffer.width / 2, y = framebuffer.height / 2
        DebugLog.write("디버그: 마우스를 \(x),\(y) 로 이동")
        socket?.send([5, 0] + [UInt8].be16(x) + [UInt8].be16(y))
    }
    #endif

    func start() {
        #if DEBUG
        Self.current = self
        #endif
        let t = Thread { [weak self] in self?.run() }
        t.name = "RFBClient"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() {
        stateLock.lock(); stopped = true; stateLock.unlock()
        keepAwakeTimer?.cancel()
        watchdog?.cancel()
        hpTimer?.cancel()
        hpReceiver?.stop()
        socket?.close()
    }

    /// 모니터를 고른다. nil 이면 모든 모니터를 합친 화면.
    func select(display id: UInt32?) {
        stateLock.lock()
        let target = id ?? DisplayInfo2.allDisplays
        selectedID = target
        streaming = true
        // 이미 그 모니터를 보내고 있으면 서버가 DisplayInfo2 를 다시 안 보내므로 바로 요청한다
        let already = serverDisplayID == target
        awaitingSwitch = !already
        stateLock.unlock()
        if already { requestUpdate(incremental: false) } else { socket?.send(Self.setDisplay(id)) }
    }

    /// 모니터 고르기 화면으로 돌아갈 때: 화면 요청을 멈춘다.
    func pause() {
        stateLock.lock(); streaming = false; stateLock.unlock()
        setAutoUpdate(false)
    }

    /// AutoFBUpdate (0x09): [type][pad][u16 켜기][u32 간격 ms][x][y][w][h]. 간격 0 은 서버 기본(바뀌는 대로 바로).
    private func setAutoUpdate(_ on: Bool, intervalMs: UInt32 = 0) {
        let w = framebuffer.width, h = framebuffer.height
        guard !on || (w > 0 && h > 0) else { return }
        autoLock.lock(); autoUpdateOn = on; autoLock.unlock()
        socket?.send([9, 0] + [UInt8].be16(on ? 1 : 0) + [UInt8].be32(intervalMs) + [0, 0, 0, 0] + [UInt8].be16(w) + [UInt8].be16(h))
        DebugLog.write("자동 화면 갱신 \(on ? "켬" : "끔") \(w)x\(h) 간격 \(intervalMs)ms")
    }

    /// 자동 갱신을 지금 켜 둘 수 있는지: 화면을 받는 중이고, 모니터 전환을 기다리지 않고, 키를 치는 중이 아닐 때
    private var autoUpdateAllowed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return streaming && !awaitingSwitch && Date() >= typingHoldUntil
    }

    private var isAutoUpdateOn: Bool {
        autoLock.lock(); defer { autoLock.unlock() }
        return autoUpdateOn
    }

    /// 키를 보낼 때: 자동 갱신을 끄고, 1초 동안 키가 더 없으면 다시 켠다
    private func holdUpdatesForTyping() {
        guard KeepAwake.typingPriority else { return }
        stateLock.lock(); typingHoldUntil = Date().addingTimeInterval(Self.typingHold); stateLock.unlock()
        if isAutoUpdateOn { setAutoUpdate(false) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.typingHold + 0.05) { [weak self] in
            guard let self, self.autoUpdateAllowed else { return }
            if Self.useAutoUpdate {
                if !self.isAutoUpdateOn { self.setAutoUpdate(true) }
            } else {
                self.requestUpdate(incremental: true)
            }
        }
    }

    /// 화면 쪽이 그림을 가져간 뒤 부른다.
    func frameConsumed() {
        stateLock.lock(); framePending = false; stateLock.unlock()
    }

    // MARK: - 수신 스레드

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    private func run() {
        do {
            emit(.status("접속하는 중…"))
            DebugLog.reset()
            DebugLog.write("접속 \(host):\(port)")
            let s = try RFBSocket(host: host, port: port)
            socket = s
            try handshake(s)
            startKeepAwake()
            startWatchdog()
            while true {
                try readMessage(s)
            }
        } catch {
            DebugLog.write("끝: \(error)")
            stateLock.lock(); let wasStopped = stopped; stateLock.unlock()
            if !wasStopped {
                emit(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        socket?.close()
    }

    private func handshake(_ s: RFBSocket) throws {
        let version = String(decoding: try s.read(12), as: UTF8.self)
        guard version.hasPrefix("RFB ") else { throw RFBError.protocolError("VNC 서버가 아닙니다") }
        let apple = version.hasPrefix("RFB 003.889")
        DebugLog.write("서버 버전 \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
        // 003.889 를 그대로 돌려줘야 애플 확장(모니터 목록·선택)이 켜진다
        s.send(Array((apple ? "RFB 003.889\n" : "RFB 003.008\n").utf8))

        let n = Int(try s.u8())
        if n == 0 {
            let reason = String(decoding: try s.read(Int(try s.u32())), as: UTF8.self)
            throw RFBError.connect(reason)
        }
        let types = try s.read(n)
        DebugLog.write("보안 타입 \(types)")
        emit(.status("인증하는 중…"))
        if types.contains(30) {
            s.send([30])
            let gen = try s.read(2)
            let keyLen = try s.u16()
            let prime = try s.read(keyLen)
            let serverPub = try s.read(keyLen)
            DebugLog.write("ARD DH 키 \(keyLen * 8)bit 받음, 계산 시작")
            defer { DebugLog.write("ARD 응답 보냄") }
            let ard = RFBCrypto.ardResponse(generator: gen, prime: prime, serverPublic: serverPub, username: username, password: password)
            ardKey = ard.key
            s.send(ard.response)
        } else if types.contains(2) {
            s.send([2])
            s.send(RFBCrypto.vncResponse(challenge: try s.read(16), password: password))
        } else if types.contains(1) {
            s.send([1])
        } else {
            throw RFBError.protocolError("지원하는 인증 방식이 없습니다 (\(types))")
        }
        let result = try s.u32()
        DebugLog.write("인증 결과 \(result)")
        if result != 0 {
            var reason = ""
            if let len = try? s.u32(), len < 4096, let r = try? s.read(Int(len)) { reason = String(decoding: r, as: UTF8.self) }
            throw RFBError.authFailed(reason)
        }

        // ClientInit: 0xC1 = 공유 + 세션 선택 + 확장 ServerInit
        s.send([apple ? 0xC1 : 0x01])
        let w = try s.u16(), h = try s.u16()
        _ = try s.read(16) // 서버 픽셀 형식 (아래에서 우리 것으로 바꾼다)
        let name = try s.read(Int(try s.u32()))
        var serverFlags: UInt32 = 0
        if apple && name.count >= 22 && name[0] == 0 {
            serverFlags = UInt32(name[2]) << 24 | UInt32(name[3]) << 16 | UInt32(name[4]) << 8 | UInt32(name[5])
        }
        framebuffer.resize(width: w, height: h)
        DebugLog.write("ServerInit \(w)x\(h) flags=0x\(String(serverFlags, radix: 16)) 확장 \(name.count >= 22 && name[0] == 0 ? name[6..<22].map { String(format: "%02x", $0) }.joined() : "없음")")
        if serverFlags & 0x04 != 0 { try sessionSelect(s) }

        emit(.status("모니터 정보를 받는 중…"))
        var setup = [UInt8]()
        if apple {
            setup += Self.viewerInfo()
            setup += [0x0A, 0, 0, 1] // SetMode: 조작
            if Self.hpTest {
                setup += HP.virtualDisplayMessage(width: 1280, height: 800, scale: 2)
                DebugLog.write("HP 가상 디스플레이 요청 1280x800pt @2")
            }
            setup += Self.setDisplay(nil)
        }
        // SetPixelFormat: 32bpp depth24 리틀엔디언 true color, R16 G8 B0
        setup += [0, 0, 0, 0, 32, 24, 0, 1] + [UInt8].be16(255) + [UInt8].be16(255) + [UInt8].be16(255) + [16, 8, 0, 0, 0, 0]
        // 1105(DisplayInfo2) 와 1101 을 함께 넣어야 모니터 목록이 온다 (실험으로 확인)
        var encodings: [Int32] = [16, 6, 1, 0, 1105, 1101, 1100, 1109, -223, -224] // 1100: 커서 위치, 1109: 키보드 입력 상태
        if Self.hpTest { encodings = [1010] + encodings + [1110] } // 고성능: 1010 맨 앞, 1110 맨 뒤
        setup += [2, 0] + [UInt8].be16(encodings.count) + encodings.flatMap { [UInt8].be32(UInt32(bitPattern: $0)) }
        s.send(setup)
        if !apple {
            // 표준 VNC 서버: 모니터 정보가 없으니 전체를 하나로
            let all = RemoteDisplay(id: DisplayInfo2.allDisplays, isMain: true, scale: 1,
                                    desktop: CGRect(x: 0, y: 0, width: w, height: h), framebuffer: CGRect(x: 0, y: 0, width: w, height: h))
            emit(.displays([all]))
        }
    }

    private func sessionSelect(_ s: RFBSocket) throws {
        let body = try s.read(try s.u16())
        let allowed = body.count >= 6 ? UInt32(body[2]) << 24 | UInt32(body[3]) << 16 | UInt32(body[4]) << 8 | UInt32(body[5]) : 0
        let console = body.count > 10 ? body[10...].prefix { $0 != 0 } : []
        let cmd: UInt8 = (!console.isEmpty || allowed & 2 != 0) ? 1 : 0
        var user = Array(username.utf8.prefix(63))
        user += [UInt8](repeating: 0, count: 64 - user.count)
        s.send([UInt8].be16(72) + [UInt8].be16(1) + [0, 0, 0, 0, cmd, 0] + user)
        while true {
            let r = try s.read(try s.u16())
            let status = r.count >= 6 ? UInt32(r[2]) << 24 | UInt32(r[3]) << 16 | UInt32(r[4]) << 8 | UInt32(r[5]) : 99
            if status == 0 || status == 4 { return }
            if status != 2 && status != 3 { throw RFBError.protocolError("세션이 거부되었습니다 (\(status))") }
        }
    }

    private func readMessage(_ s: RFBSocket) throws {
        let type = try s.u8()
        switch type {
        case 0: try framebufferUpdate(s)
        case 1: _ = try s.read(3); let n = try s.u16(); try s.skip(n * 6)
        case 2: break
        case 3: _ = try s.read(3); try s.skip(Int(try s.u32()))
        case 4, 7: break // 애플: 확인, NOP
        case 0x14: // 애플: 상태 알림
            _ = try s.u8()
            let body = try s.read(try s.u16())
            DebugLog.write("상태 알림 \(body.prefix(4).map { String(format: "%02x", $0) }.joined())")
            // 4 = Tickle: 보낼 게 없을 때 2초마다 온다. 서버가 화면 보내기를 멈추고 이것만 보내는 경우가 있어서,
            // 받을 때마다 자동 화면 갱신을 다시 켜 준다 (noVNC-ARD 와 같은 방식, 화면이 오는 동안에는 안 온다)
            if body.count >= 4 && body[2] == 0 && body[3] == 4 {
                if autoUpdateAllowed {
                    if Self.useAutoUpdate { setAutoUpdate(true) } else { requestUpdate(incremental: true) }
                }
            }
        case 0x1F: let h = try s.read(15); try s.skip(Int(UInt32(h[11]) << 24 | UInt32(h[12]) << 16 | UInt32(h[13]) << 8 | UInt32(h[14])))
        case 0x20: let h = try s.read(8); try s.skip(Int(UInt32(h[4]) << 24 | UInt32(h[5]) << 16 | UInt32(h[6]) << 8 | UInt32(h[7])))
        case 0x51: handleDisplayInfo2(try s.read(try s.u16()))
        case 150: break
        case 248: _ = try s.read(3); _ = try s.u32(); try s.skip(Int(try s.u8()))
        default: throw RFBError.protocolError("알 수 없는 서버 메시지 \(type)")
        }
    }

    private func framebufferUpdate(_ s: RFBSocket) throws {
        inUpdate = true
        defer { inUpdate = false }
        _ = try s.u8()
        let count = try s.u16()
        var drewPixels = false
        var encs = [Int32]()
        var i = 0
        while count == 0xFFFF || i < count {
            i += 1
            let x = try s.u16(), y = try s.u16(), w = try s.u16(), h = try s.u16()
            let enc = try s.s32()
            encs.append(enc)
            switch enc {
            case 0:
                drewPixels = true
                let row = UnsafeMutablePointer<UInt32>.allocate(capacity: max(w, 1))
                defer { row.deallocate() }
                for yy in 0..<h {
                    try s.read(into: row, count: w * 4)
                    framebuffer.withPixels { p, fw, fh in
                        let cw = min(w, fw - x)
                        if cw > 0 && y + yy < fh { (p + (y + yy) * fw + x).update(from: row, count: cw) }
                    }
                }
            case 1:
                drewPixels = true
                let sx = try s.u16(), sy = try s.u16()
                framebuffer.withPixels { p, fw, fh in
                    guard x + w <= fw, y + h <= fh, sx + w <= fw, sy + h <= fh else { return }
                    let tmp = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
                    defer { tmp.deallocate() }
                    for r in 0..<h { (tmp + r * w).update(from: p + (sy + r) * fw + sx, count: w) }
                    for r in 0..<h { (p + (y + r) * fw + x).update(from: tmp + r * w, count: w) }
                }
            case 16:
                drewPixels = true
                let data = try zrle.inflate(try s.read(Int(try s.u32())))
                var err: Error?
                framebuffer.withPixels { p, fw, fh in
                    do { try ZRLEDecoder.decode(data, x: x, y: y, w: w, h: h, into: p, fbWidth: fw, fbHeight: fh) } catch { err = error }
                }
                if let err { throw err }
            case 6:
                drewPixels = true
                let data = try zlibRaw.inflate(try s.read(Int(try s.u32())))
                framebuffer.withPixels { p, fw, fh in
                    data.withUnsafeBytes { d in
                        let src = d.bindMemory(to: UInt32.self)
                        let cw = min(w, fw - x)
                        for r in 0..<h where y + r < fh && cw > 0 && (r + 1) * w <= src.count {
                            (p + (y + r) * fw + x).update(from: src.baseAddress! + r * w, count: cw)
                        }
                    }
                }
            case 1105:
                handleDisplayInfo2(try s.read(try s.u16()))
            case 1010, 1110:
                hpRect(enc, try s.read(try s.u16()))
            case 1101:
                let hdr = try s.read(8)
                try s.skip((Int(hdr[4]) << 8 | Int(hdr[5])) * 28)
            case 1109: // 애플: 키보드 입력 상태 [u16 길이][u16 입력 소스 수][u32 flags][u16 문자열 길이][UTF-8 입력 소스]
                let body = try s.read(try s.u16())
                var source = ""
                if body.count >= 8 {
                    let n = Int(body[6]) << 8 | Int(body[7])
                    source = String(decoding: body.dropFirst(8).prefix(n), as: UTF8.self)
                }
                DebugLog.write("키보드 입력 상태(1109) 사각형 \(x),\(y) \(w)x\(h) 내용 \(body.prefix(8).map { String(format: "%02x", $0) }.joined()) 입력 소스 \(source)")
            case 1100: // 애플: 커서 위치
                stateLock.lock()
                let moved = cursor?.x != x || cursor?.y != y
                if moved { cursor = (x, y); cursorChangedAt = Date() }
                stateLock.unlock()
                if moved { DebugLog.write("커서 위치 \(x),\(y)") }
            case -223:
                framebuffer.resize(width: w, height: h)
            case -224:
                i = count == 0xFFFF ? Int.max : count
            case -239:
                try s.skip(w * h * 4 + (w + 7) / 8 * h)
            default:
                throw RFBError.protocolError("알 수 없는 인코딩 \(enc)")
            }
            if i == Int.max { break }
        }

        if drewPixels { stateLock.lock(); fullRequestAt = nil; stateLock.unlock() }
        stateLock.lock()
        let stream = streaming && !awaitingSwitch
        DebugLog.write("업데이트 메시지: 인코딩 \(encs), 누적 수신 \(s.received / 1000)KB, 다음 요청 \(stream ? (fullRequestPending ? "전체" : "증분") : "안 보냄 (화면 받는 중 \(streaming), 모니터 전환 대기 \(awaitingSwitch))")")
        let notify = drewPixels && !framePending
        if notify { framePending = true }
        stateLock.unlock()
        if notify { emit(.frame) }
        if stream {
            if fullRequestPending {
                requestUpdate(incremental: false)
            } else if autoUpdateAllowed {
                if Self.useAutoUpdate {
                    if !isAutoUpdateOn { if drewPixels { setAutoUpdate(true) } else { requestUpdate(incremental: true) } }
                } else {
                    requestUpdate(incremental: true)
                }
            }
        }
        fullRequestPending = false
    }

    private func handleDisplayInfo2(_ data: [UInt8]) {
        guard let info = DisplayInfo2(data) else { DebugLog.write("DisplayInfo2 해석 실패 \(data.count)바이트"); return }
        DebugLog.write("DisplayInfo2 현재=\(String(info.currentDisplayID, radix: 16)) 픽셀 \(info.pixelWidth)x\(info.pixelHeight) 모니터 \(info.displays.count)개: "
            + info.displays.map { "[id \($0.id)\($0.isMain ? " 주" : "") 데스크톱 \(Int($0.desktop.minX)),\(Int($0.desktop.minY)) \(Int($0.desktop.width))x\(Int($0.desktop.height)) fb \(Int($0.framebuffer.minX)),\(Int($0.framebuffer.minY)) \(Int($0.framebuffer.width))x\(Int($0.framebuffer.height))]" }.joined(separator: " "))
        if !info.displays.isEmpty { emit(.displays(info.displays)) }
        guard info.pixelWidth > 0 && info.pixelHeight > 0 else { return }
        framebuffer.resize(width: info.pixelWidth, height: info.pixelHeight)
        if isAutoUpdateOn { setAutoUpdate(false) }
        stateLock.lock()
        serverDisplayID = info.currentDisplayID
        let switched = awaitingSwitch && (selectedID == nil || info.currentDisplayID == selectedID)
        if switched { awaitingSwitch = false }
        let stream = streaming && !awaitingSwitch
        stateLock.unlock()
        // 고른 모니터로 바뀌었거나, 보는 중에 화면 구성이 바뀌면 전체를 새로 받는다
        if stream {
            if inUpdate { fullRequestPending = true } else { requestUpdate(incremental: false) }
        }
    }

    private func requestUpdate(incremental: Bool) {
        let w = framebuffer.width, h = framebuffer.height
        guard w > 0 && h > 0 else { return } // 0x0 요청은 서버를 멈추게 한다 (noVNC-ARD)
        if !incremental {
            stateLock.lock(); fullRequestAt = Date(); fullRequestReceived = socket?.received ?? 0; stateLock.unlock()
            DebugLog.write("전체 화면 요청 \(w)x\(h)")
        } else {
            DebugLog.write("증분 요청 \(w)x\(h)")
        }
        socket?.send([3, incremental ? 1 : 0, 0, 0, 0, 0] + [UInt8].be16(w) + [UInt8].be16(h))
    }

    /// 모니터를 바꾼 직후 서버가 첫 요청에 답하지 않는 경우가 있어 다시 요청한다.
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let flowing = (self.socket?.received ?? 0) - self.fullRequestReceived > 64_000
            let late = self.streaming && !self.awaitingSwitch && !flowing && (self.fullRequestAt.map { Date().timeIntervalSince($0) > 2 } ?? false)
            if flowing { self.fullRequestAt = Date(); self.fullRequestReceived = self.socket?.received ?? 0 }
            self.stateLock.unlock()
            if late {
                DebugLog.write("2초 동안 화면이 안 와서 다시 요청")
                self.requestUpdate(incremental: false)
            }
        }
        watchdog = t
        t.resume()
    }

    // MARK: - 마우스

    /// 화면 좌표(프레임버퍼 픽셀)를 누르고 뗀다
    func click(x: Int, y: Int) {
        let x = max(0, min(x, framebuffer.width - 1)), y = max(0, min(y, framebuffer.height - 1))
        for mask: UInt8 in [0, 1, 0] {
            socket?.send([5, mask] + [UInt8].be16(x) + [UInt8].be16(y))
        }
        stateLock.lock(); cursor = (x, y); cursorChangedAt = Date(); stateLock.unlock()
        markLocalInput()
        DebugLog.write("클릭 \(x),\(y)")
    }

    // MARK: - 키 입력

    /// 글자 하나를 눌렀다 뗀다. 영어·숫자는 그 글자, 그 밖(한글 등)은 유니코드 keysym(0x01000000 + 코드)
    func sendText(_ text: String) {
        holdUpdatesForTyping()
        for scalar in text.unicodeScalars {
            let keysym: UInt32
            switch scalar.value {
            case 0x0A, 0x0D: keysym = 0xFF0D // Return
            case 0x09: keysym = 0xFF09 // Tab
            case 0x20...0x7E, 0xA0...0xFF: keysym = scalar.value
            default: keysym = 0x0100_0000 | scalar.value
            }
            sendKeyEvent(keysym, down: true)
            sendKeyEvent(keysym, down: false)
        }
        markLocalInput()
        DebugLog.write("글자 보냄 \"\(text)\" 시각 \(DebugLog.wallClock())")
    }

    /// 특수 키 (BackSpace 0xFF08, Return 0xFF0D 등)
    func sendSpecialKey(_ keysym: UInt32, name: String) {
        holdUpdatesForTyping()
        sendKeyEvent(keysym, down: true)
        sendKeyEvent(keysym, down: false)
        markLocalInput()
        DebugLog.write("키 보냄 \(name) 시각 \(DebugLog.wallClock())")
    }

    private func markLocalInput() {
        stateLock.lock(); lastLocalInput = Date(); stateLock.unlock()
    }

    private func sendKeyEvent(_ keysym: UInt32, down: Bool) {
        if let key = ardKey {
            // EncryptedEvent (0x10): [type][flags] + AES-ECB([0xFF][down][keysym u32][시각 u32][0 ×6])
            var p = [UInt8](repeating: 0, count: 16)
            p[0] = 0xFF
            p[1] = down ? 1 : 0
            p.replaceSubrange(2..<6, with: [UInt8].be32(keysym))
            p.replaceSubrange(6..<10, with: [UInt8].be32(UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1_000_000))))
            socket?.send([0x10, 0] + RFBCrypto.ecbEncrypt(algorithm: CCAlgorithm(kCCAlgorithmAES128), key: key, data: p))
        } else {
            socket?.send([4, down ? 1 : 0, 0, 0] + [UInt8].be32(keysym))
        }
    }

    // MARK: - 화면 보호기 막기

    private func startKeepAwake() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in self?.keepAwakeTick() }
        keepAwakeTimer = t
        t.resume()
    }

    private func keepAwakeTick() {
        guard KeepAwake.enabled else { DebugLog.write("화면 보호기 막기: 꺼짐"); return }
        stateLock.lock()
        let now = Date()
        let pos = cursor, still = now.timeIntervalSince(cursorChangedAt), idle = now.timeIntervalSince(lastLocalInput)
        let active = streaming && !awaitingSwitch
        stateLock.unlock()
        // 맥 앞에서 마우스를 움직이는 중(5초 안)이거나 앱에서 조작 중(30초 안)이면 보내지 않는다.
        guard active, still >= 5, idle >= 30 else {
            DebugLog.write("화면 보호기 막기: 건너뜀 (화면 받는 중 \(active), 커서 멈춘 지 \(Int(min(still, 9999)))초)")
            return
        }
        if let pos {
            // 커서가 지금 있는 자리에 그대로 이동: 화면에는 아무 변화가 없다
            socket?.send([5, 0] + [UInt8].be16(pos.x) + [UInt8].be16(pos.y))
            DebugLog.write("화면 보호기 막기: 제자리 마우스 이동 \(pos.x),\(pos.y)")
        } else {
            // 커서 위치를 모르면(서버는 커서가 움직일 때만 알려 준다) 기능이 없는 F19 키를 눌렀다 뗀다
            let f19: UInt32 = 0xFFD0
            sendKeyEvent(f19, down: true)
            sendKeyEvent(f19, down: false)
            DebugLog.write("화면 보호기 막기: F19 키 (커서 위치 모름)")
        }
    }

    // MARK: - 애플 메시지

    /// SetDisplay (0x0d): [type][u8 모두 합치기][2 pad][u32 모니터 id]
    private static func setDisplay(_ id: UInt32?) -> [UInt8] {
        guard let id, id != DisplayInfo2.allDisplays else { return [0x0D, 1, 0, 0, 0, 0, 0, 0] }
        return [0x0D, 0, 0, 0] + [UInt8].be32(id)
    }

    /// ViewerInfo (0x21): 애플 화면 공유 앱처럼 자신을 소개한다 (noVNC-ARD 와 같은 값)
    private static func viewerInfo() -> [UInt8] {
        var m = [UInt8](repeating: 0, count: 66)
        m[0] = 0x21
        m[2] = 0; m[3] = 62
        m[4] = 0; m[5] = 1
        m.replaceSubrange(6..<10, with: [UInt8].be32(2))
        m.replaceSubrange(10..<22, with: [UInt8].be32(6) + [UInt8].be32(1) + [UInt8].be32(0))
        m.replaceSubrange(22..<34, with: [UInt8].be32(15) + [UInt8].be32(0) + [UInt8].be32(0))
        m[34] = 0xB0; m[36] = 0x0C; m[37] = 0x03; m[38] = 0x90; m[44] = 0x40
        return m
    }
}
