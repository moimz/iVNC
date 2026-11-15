import CommonCrypto
import CoreVideo
import Foundation
import zlib

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
        /// 고성능: 디코딩된 줄무늬 (BGRA 픽셀 버퍼, 번호, 줄무늬 수)
        case stripe(CVPixelBuffer, Int, Int)
        /// 맥 커서 위치가 바뀜 (서버 알림 1100, 또는 우리가 보낸 마우스). 프레임버퍼 픽셀
        case cursor(Int, Int)
        /// 맥 커서 모양 (RFB Cursor -239). 화살표면 nil (우리 큰 화살표를 쓴다), 글자 입력·크기 조절 같은 특이한 커서면 그 그림과 핫스팟(픽셀)
        case cursorShape(CursorShape?)
        case failed(String)
        /// 고성능 결과: true 면 가상 디스플레이로 바로 보기, false 면 일반 모드로 바뀌었고 모니터 목록이 뒤따른다
        case highPerformance(Bool)
        /// 같은 접속에서 일반 모드로 못 돌아왔으니 고성능 없이 다시 접속해야 한다
        case reconnectStandard
        /// 원격 맥의 지금 입력 소스 (애플 1109, 예: com.apple.keylayout.ABC, com.apple.inputmethod.Korean.2SetKorean)
        case inputSource(String, secure: Bool)
        /// 원격 맥에서 복사한 것 (클립보드 공유: 글자·그림)
        case clipboard(ClipContent)
    }

    /// 클립보드 내용 (애플 페이스트보드에서 쓰는 종류만)
    struct ClipContent {
        var text: String?
        /// public.png
        var png: [UInt8]?
        /// public.tiff (맥 앱이 그림을 tiff 로만 넣을 때)
        var tiff: [UInt8]?
        var isEmpty: Bool { text == nil && png == nil && tiff == nil }
        var summary: String { [text.map { "글자 \($0.count)자" }, png.map { "png \($0.count / 1000)KB" }, tiff.map { "tiff \($0.count / 1000)KB" }].compactMap { $0 }.joined(separator: ", ") }
    }

    /// 애플 클립보드 공유를 쓸지 (start 전에 정한다. 맥 앱만 켬)
    var clipboardSharing = false
    /// 서버가 알려 준 클립보드 세션 번호 (보낼 때 그대로 돌려준다)
    private var clipSessionID: UInt32 = 0
    /// 서버가 "클립보드 내용 필요"(상태 3)라고 하면 보낼 글자
    private var clipOutgoing: ClipContent?
    private let clipLock = NSLock()

    struct CursorShape {
        let image: CGImage
        /// 그림 픽셀 기준
        let hotspot: CGPoint
        /// 그림 픽셀 몇 개가 화면 1pt 인지 (높은 해상도로 그려 둔 그림은 크다)
        var scale: CGFloat = 1
        /// 맥 앱: 미리 정해진 맥 커서 번호 (1 글자 입력, 5 손가락, 10 위아래 …). 있으면 그림 대신 맥 기본 커서로 바꾼다
        var kind: UInt32? = nil
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
    private let ardCursor = ArdCursorDecoder()
    private let mvs = MVSDecoder()
    /// MVS 받은 양과 해독 시간 (속도 비교용, 화면 갱신 기록 때 적고 비운다)
    private var mvsBytes = 0
    private var mvsNanos: UInt64 = 0
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

    /// 맥 커서 위치 (서버가 알려 주거나 앱이 보낸 마지막 좌표)
    private var cursor: (x: Int, y: Int)?
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
    private var lateCount = 0
    /// 화면이 안 와서 자동 갱신을 잠깐 켰는지 (화면이 오면 끈다)
    private var wakeKick = false

    /// tryHighPerformance: 서버가 고성능을 지원하면 먼저 가상 디스플레이 고성능을 시도한다
    init(host: String, port: Int, username: String, password: String, tryHighPerformance: Bool = true,
         virtualDisplay: (width: Int, height: Int) = (1280, 800)) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.tryHighPerformance = tryHighPerformance
        self.virtualDisplay = virtualDisplay
    }

    /// 고성능 가상 디스플레이 크기 (배율 1 이라 포인트 = 픽셀). 맥은 이 크기의 화면으로 앱을 배치한다
    private let virtualDisplay: (width: Int, height: Int)

    // MARK: - 고성능 (가상 디스플레이 + HEVC/UDP)

    /// off: 시도 안 함, trying: 협상·첫 영상 기다리는 중, on: 영상이 오고 있음, fallingBack: 실패해서 다시 접속을 기다리는 중
    enum HPState { case off, trying, on, fallingBack }
    private let tryHighPerformance: Bool
    private(set) var hpState: HPState = .off
    /// 시도하는 동안 받은 모니터 목록(가상 디스플레이 하나)은 화면에 바로 알리지 않고 결과가 나온 뒤 알린다
    private var hpPendingDisplays: [RemoteDisplay] = []
    /// 협상 답을 받았는지 (5초 협상 시간 초과 판정에서 뺀다)
    private var hpAnswered = false

    #if DEBUG
    /// 시험용: 받는 UDP 포트를 옮겨 일부러 고성능을 실패시키기 (IVNC_HP_PORT_OFFSET)
    static let hpPortOffset = UInt16(ProcessInfo.processInfo.environment["IVNC_HP_PORT_OFFSET"] ?? "0") ?? 0
    #else
    static let hpPortOffset: UInt16 = 0
    #endif

    /// 서버가 고성능을 지원하는지: ServerInit 확장 capability 4번째 바이트의 0x0c 두 비트 (noVNC-ARD capability.js)
    private static func serverOffersHighPerformance(_ capabilities: [UInt8]) -> Bool {
        capabilities.count > 3 && capabilities[3] & 0x0C == 0x0C
    }

    /// 판정 시각을 정한다: 협상이 5초 안에 답까지 안 가면 실패, 답 뒤 3초 안에 검증된 영상이 없으면 실패
    private func hpSchedule(after seconds: Double, _ check: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.hpState == .trying else { return }
            check()
        }
    }

    /// 0.25초마다 본다: 검증된 영상이 하나라도 오면 바로 성공, 시간이 지나면 실패
    private func hpWaitForVideo(deadline: Date) {
        hpSchedule(after: 0.25) { [weak self] in
            guard let self else { return }
            if (self.hpReceiver?.verifiedVideo ?? 0) > 0 {
                self.hpSucceeded()
            } else if Date() >= deadline {
                self.hpFail("답 뒤 2.5초 동안 영상이 안 옴")
            } else {
                self.hpWaitForVideo(deadline: deadline)
            }
        }
    }

    private func hpSucceeded() {
        hpState = .on
        DebugLog.write("HP 성공: 영상 \(hpReceiver?.verifiedVideo ?? 0)개 검증됨 → 가상 디스플레이로 바로 보기")
        emit(.highPerformance(true))
        if !hpPendingDisplays.isEmpty { emit(.displays(hpPendingDisplays)) }
        hpSubscribe()
    }

    /// 고성능 중 자동 화면 갱신(0x09) 구독을 새로 한다: 서버는 이 구독이 있을 때만 커서 모양(1104)·위치(1100)를 TCP 로 보낸다.
    /// 화면 요청(0x03)은 계속 안 보낸다 (그림은 UDP 영상). noVNC-ARD 처럼 성공 직후, Tickle 마다, 업데이트 메시지가 끝날 때마다 보낸다
    /// (안 하면 3초쯤 뒤 구독이 끊겨 커서가 멈췄다고 한다)
    private var hpSubscribeLogged = false
    private func hpSubscribe() {
        guard hpState == .on else { return }
        let w = framebuffer.width, h = framebuffer.height
        guard w > 0, h > 0 else { return }
        socket?.send([9, 0] + [UInt8].be16(1) + [UInt8].be32(0) + [0, 0, 0, 0] + [UInt8].be16(w) + [UInt8].be16(h))
        if !hpSubscribeLogged { hpSubscribeLogged = true; DebugLog.write("HP 자동 갱신 구독(0x09) \(w)x\(h) — 커서 받기") }
    }

    /// 실패: 고성능 없이 다시 접속하라고 알린다.
    /// 같은 접속에서 일반 모드로 돌아가기는 안 된다 (2026-11-02 시험: 1010/1110 없는 인코딩 + 모든 모니터를 보내도
    /// 서버가 4초 넘게 가상 디스플레이만 알렸고, 가상 디스플레이 0개(0x1d)를 보내면 1초 만에 접속을 끊었다)
    private func hpFail(_ reason: String) {
        guard hpState == .trying else { return }
        hpState = .fallingBack
        DebugLog.write("HP 실패: \(reason) → 고성능 없이 다시 접속")
        hpTimer?.cancel(); hpTimer = nil
        hpReceiver?.stop(); hpReceiver = nil
        hpDecoder?.stop(); hpDecoder = nil
        emit(.reconnectStandard)
    }

    // 1011 = 애플 MVS (손실 DCT, 애플 앱의 화질 "적응"). 무손실 ZRLE 보다 훨씬 작다
    private static let standardEncodings: [Int32] = [1011, 16, 6, 1, 0, 1105, 1101, 1100, 1104, 1109, -223, -224, -239] // 1100: 커서 위치, 1104: 애플 커서 모양, 1109: 키보드 입력 상태, -239: 표준 커서 모양 (애플 서버는 안 보냄)

    private var hpSecrets: HP.Secrets?
    private var hpReceiver: HPUDPReceiver?
    private var hpServerPorts: (audio: UInt16, video: UInt16)?
    private var hpTimer: DispatchSourceTimer?
    private var hpDecoder: HPVideoDecoder?
    /// 막혔을 때: 먼저 키 그림을 요청하고, 1초 안에 화면이 안 나오면 다시 제안한다.
    /// 다시 제안 간격은 1초부터 두 배씩 8초까지 (예전엔 30초에 3번 넘으면 30초 동안 포기해 화면이 멈춰 있었다)
    private var hpReoffering = false
    private var hpPausedAt: Date?
    private var hpKeyRequestedAt: TimeInterval = 0
    private var hpLastReoffer: TimeInterval = 0
    private var hpReofferGap: TimeInterval = 1
    private var hpReofferScheduled = false
    private let hpRecoverLock = NSLock()

    private func hpRect(_ enc: Int32, _ body: [UInt8]) {
        DebugLog.write("HP 사각형 \(enc) \(body.count)바이트: \(body.prefix(24).map { String(format: "%02x", $0) }.joined())")
        if enc == 1110 {
            DebugLog.write("HP Message1 문자열 \(HP.message1Strings(body))")
            if let r = hpReceiver, let ports = hpServerPorts, let peer = socket?.peerAddress6 {
                r.punch(server: peer, ports: [ports.audio, ports.video])
                DebugLog.write("HP 먼저 보내기 (제안 직전)")
            }
            hpSendOffer()
        } else if enc == 1010 {
            if let ports = HP.streamPorts(body) {
                hpServerPorts = ports
                DebugLog.write("HP 서버 UDP 포트: 오디오 \(ports.audio), 비디오 \(ports.video)")
                // 보는 중에 포트를 다시 알리면 서버가 영상을 새로 시작하자는 것 (원격 맥 화면 잠금 등, 2026-11-15 맥 앱 로그):
                // 영상·소리가 끊긴 채 기다리므로 바로 다시 제안한다
                if hpState == .on, let r = hpReceiver {
                    if let peer = socket?.peerAddress6 { r.punch(server: peer, ports: [ports.audio, ports.video]) }
                    DebugLog.write("HP 보는 중 포트 다시 알림 → 다시 제안")
                    hpRecoverLock.lock(); hpLastReoffer = 0; hpReofferGap = 1; hpReoffering = false; hpRecoverLock.unlock()
                    hpReoffer()
                    return
                }
                if hpReceiver == nil {
                    let r = HPUDPReceiver()
                    let local = [ports.audio &+ Self.hpPortOffset, ports.video &+ Self.hpPortOffset]
                    if let err = r.bind(ports: local) {
                        DebugLog.write("HP " + err)
                        hpFail("UDP 포트를 열 수 없음")
                        return
                    }
                    hpReceiver = r
                    DebugLog.write("HP UDP 받는 포트 \(local)")
                    if let peer = socket?.peerAddress6 {
                        r.punch(server: peer, ports: [ports.audio, ports.video])
                        DebugLog.write("HP 먼저 보내기 (포트 알림 직후) → [\(RFBSocket.describe(peer))]")
                    } else {
                        DebugLog.write("HP 서버 주소를 알 수 없음")
                    }
                }
            } else {
                do {
                    let a = try HP.answer(body)
                    DebugLog.write("HP 답: 서버 SSRC 오디오 \(String(a.audioSSRC, radix: 16)) 비디오 \(String(a.videoSSRC, radix: 16)), \(a.width)x\(a.height), 줄무늬 \(a.stripes)")
                    if hpState == .on {
                        // 다시 제안한 것의 답: 새 키·SSRC 로 바꾼다
                        hpRecoverLock.lock(); hpReoffering = false; hpRecoverLock.unlock()
                        hpConfigure(a)
                    } else {
                        hpAnswered = true
                        hpStartStreaming(a)
                        hpWaitForVideo(deadline: Date().addingTimeInterval(2.5))
                    }
                } catch {
                    DebugLog.write("HP 답 해석 실패 \(error)")
                    hpFail("답 해석 실패")
                }
            }
        }
    }

    /// 제안(0x1c)을 새 키로 보낸다. 처음과, 영상이 막혀 다시 시작할 때
    private func hpSendOffer() {
        let secrets = HP.Secrets()
        hpSecrets = secrets
        do {
            let offer = try HP.offerMessage(secrets)
            socket?.send(offer)
            DebugLog.write("HP 제안(0x1c) 보냄 \(offer.count)바이트, 내 SSRC 오디오 \(String(secrets.audioSSRC, radix: 16)) 비디오 \(String(secrets.videoSSRC, radix: 16))")
        } catch {
            DebugLog.write("HP 제안 만들기 실패 \(error)")
        }
    }

    /// 답의 키·SSRC 를 수신기에 넣고 영상 조립을 새로 시작한다
    private func hpConfigure(_ a: HP.Answer) {
        guard let r = hpReceiver, let ports = hpServerPorts, let s = hpSecrets, let peer = socket?.peerAddress6 else { return }
        r.configure(index: 0, keys: s.audioKeys, mySSRC: s.audioSSRC, serverSSRC: a.audioSSRC, server: peer, remotePort: ports.audio)
        r.configure(index: 1, keys: s.videoKeys, mySSRC: s.videoSSRC, serverSSRC: a.videoSSRC, server: peer, remotePort: ports.video)
        r.startVideo(baseSSRC: a.videoSSRC, stripes: a.stripes)
        hpStripeCount = max(a.stripes, 1)
        if a.width > 0 && a.height > 0 { framebuffer.resize(width: a.width, height: a.height) }
    }

    /// 영상이 막혔다 (빠진 그림 뒤에 키 그림이 없거나, 영상은 오는데 3초 동안 화면에 나온 그림이 없음).
    /// 키 그림을 요청하고, 1초 뒤에도 화면이 안 나오면 다시 제안한다
    private func hpRecover(_ why: String) {
        guard hpState == .on else { return }
        let now = ProcessInfo.processInfo.systemUptime
        hpRecoverLock.lock()
        let ask = !hpReoffering && now - hpKeyRequestedAt > 1
        if ask { hpKeyRequestedAt = now }
        hpRecoverLock.unlock()
        guard ask else { return }
        DebugLog.write("HP 영상 막힘: \(why), \(hpReceiver?.videoDiag ?? "") / \(hpDecoder?.stats ?? "") → 키 그림 요청")
        hpReceiver?.requestKeyPicture()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.hpState == .on, let d = self.hpDecoder else { return }
            if d.lastOutput > now {
                DebugLog.write("HP 키 그림 요청으로 다시 나옴")
            } else {
                self.hpReoffer()
            }
        }
    }

    /// 새 키로 다시 제안한다. 너무 잦으면 간격이 찰 때까지 미룬다
    private func hpReoffer() {
        let now = ProcessInfo.processInfo.systemUptime
        hpRecoverLock.lock()
        if hpReoffering || hpReofferScheduled { hpRecoverLock.unlock(); return }
        let wait = hpLastReoffer + hpReofferGap - now
        if wait > 0 {
            hpReofferScheduled = true
            hpRecoverLock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.hpRecoverLock.lock(); self.hpReofferScheduled = false; self.hpRecoverLock.unlock()
                // 그사이 다시 나오기 시작했으면 안 한다
                if let d = self.hpDecoder, ProcessInfo.processInfo.systemUptime - d.lastOutput < 1 { return }
                self.hpReoffer()
            }
            return
        }
        hpLastReoffer = now
        hpReofferGap = min(hpReofferGap * 2, 8)
        hpReoffering = true
        let gap = hpReofferGap
        hpRecoverLock.unlock()
        guard hpState == .on else { return }
        DebugLog.write("HP 다시 제안 (다음 간격 \(Int(gap))초)")
        hpSendOffer()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in // 답이 안 오면 다음 막힘 때 다시
            guard let self else { return }
            self.hpRecoverLock.lock(); self.hpReoffering = false; self.hpRecoverLock.unlock()
        }
    }

    /// 디코딩된 줄무늬를 복사 없이 화면에 넘긴다 (화면이 줄무늬 레이어에 바로 넣는다)
    private func hpDraw(_ image: CVPixelBuffer, stripe: Int) {
        hpStripes += 1
        emit(.stripe(image, stripe, hpStripeCount))
    }

    private var hpStripeCount = 4

    private var hpStripes = 0

    /// 답을 받은 뒤: 키를 넣고 디코더를 준비하고, 1초마다 SRTCP 수신 보고를 보내고, 2초마다 받은 양을 적는다
    private func hpStartStreaming(_ a: HP.Answer) {
        guard hpTimer == nil, let r = hpReceiver, hpServerPorts != nil, hpSecrets != nil, socket?.peerAddress6 != nil else {
            DebugLog.write("HP 받기 시작 못 함 (수신기 \(hpReceiver != nil), 포트 \(hpServerPorts != nil), 키 \(hpSecrets != nil), 서버 주소 \(socket?.peerAddress6 != nil))")
            return
        }
        let d = HPVideoDecoder()
        d.onStripe = { [weak self] in self?.hpDraw($0, stripe: $1) }
        d.onNeedKey = { [weak self] in self?.hpRecover("디코더가 밀려 키 그림이 필요") }
        hpDecoder = d
        r.onPicture = { [weak d] in d?.push($0) }
        r.onStall = { [weak self] in self?.hpRecover("조립 막힘") }
        hpConfigure(a)
        var n = 0
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in
            n += 1
            r.sendReports()
            if n % 2 == 0 { DebugLog.write("HP UDP: \(r.summary()) / \(r.videoDiag) / \(d.stats)") }
            // 화면에 실제로 나온 그림 기준 (조립은 되는데 디코더가 버리는 중이면 조립 기준으로는 멈춘 걸 모른다)
            guard let self, self.hpState == .on, !r.paused else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // 영상 패킷은 오는데 화면에 나온 그림이 3초 없으면 막힌 것 (맥 화면이 멈춰 있어 안 보내는 것과 가른다)
            if now - d.lastOutput > 3, let v = r.lastVideoPacketAt, now - v < 1 {
                self.hpRecover("영상은 오는데 3초 동안 화면에 나온 그림 없음")
            }
            // 15초 동안 잘 나오면 다시 제안 간격을 처음(1초)으로
            self.hpRecoverLock.lock()
            if now - d.lastOutput < 1, now - self.hpLastReoffer > 15 { self.hpReofferGap = 1 }
            self.hpRecoverLock.unlock()
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

    /// 지금까지 받은 바이트 (TCP + 고성능 UDP) 와 빠진 영상 패킷 수
    var traffic: (bytes: Int, lost: Int, packets: Int) {
        let udp = hpReceiver?.traffic ?? (bytes: 0, lost: 0, packets: 0)
        return ((socket?.received ?? 0) + udp.bytes, udp.lost, udp.packets)
    }

    func stop() {
        stateLock.lock(); stopped = true; let s = socket; stateLock.unlock()
        watchdog?.cancel()
        hpTimer?.cancel()
        hpReceiver?.stop()
        hpDecoder?.stop()
        s?.close()
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
        if hpState == .on {
            // 고성능은 가상 디스플레이 하나뿐, 모니터 선택도 요청도 없다. 백그라운드에서 멈췄으면 다시 제안해 새로 받는다
            // (멈춘 동안 SRTP 순번을 안 따라가 옛 키로는 해독이 어긋날 수 있다)
            if let r = hpReceiver, r.paused {
                r.paused = false
                DebugLog.write("HP 받기 다시 (\(Int(Date().timeIntervalSince(hpPausedAt ?? Date())))초 멈췄음) → 다시 제안")
                hpRecoverLock.lock(); hpLastReoffer = 0; hpReofferGap = 1; hpRecoverLock.unlock()
                hpReoffer()
            }
            return
        }
        if already { requestUpdate(incremental: false) } else { socket?.send(Self.setDisplay(id)) }
    }

    /// 모니터 고르기 화면으로 돌아갈 때: 화면 요청을 멈춘다.
    func pause() {
        stateLock.lock(); streaming = false; stateLock.unlock()
        // 고성능: 영상·소리 해독과 보고를 멈춘다 (백그라운드에서 밤새 받아 배터리를 쓰던 것)
        if hpState == .on, let r = hpReceiver, !r.paused {
            r.paused = true
            hpPausedAt = Date()
            DebugLog.write("HP 받기 멈춤 (백그라운드)")
        }
        // 켜져 있을 때만 끈다 (끄라는 메시지 뒤 모니터를 바꾸면 서버가 화면 요청에 답하지 않은 적이 있다, 2026-11-02)
        if isAutoUpdateOn { setAutoUpdate(false) }
    }

    /// AutoFBUpdate (0x09): [type][pad][u16 켜기][u32 간격 ms][x][y][w][h]. 간격 0 은 서버 기본(바뀌는 대로 바로).
    private func setAutoUpdate(_ on: Bool, intervalMs: UInt32 = 0) {
        let w = framebuffer.width, h = framebuffer.height
        guard !on || (w > 0 && h > 0 && hpState != .on) else { return }
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
        stateLock.lock()
        framePending = false
        shownFrames += 1
        let now = Date()
        if now.timeIntervalSince(shownSince) >= 2 {
            let fps = Double(shownFrames) / now.timeIntervalSince(shownSince)
            let secs = now.timeIntervalSince(shownSince)
            let rx = (socket?.received ?? 0) - shownReceived
            shownReceived = socket?.received ?? 0
            let mvsInfo = mvsBytes > 0 ? ", MVS \(mvsBytes / 1000)KB 해독 \(mvsNanos / 1_000_000)ms" : ""
            mvsBytes = 0; mvsNanos = 0
            DebugLog.write("화면 갱신 \(String(format: "%.1f", fps))회/초 (\(hpState == .on ? "고성능, 줄무늬 \(hpStripes)개 그림" : "일반")), TCP \(String(format: "%.1f", Double(rx) / secs / 1_000_000))MB/초\(mvsInfo)")
            shownFrames = 0; shownSince = now
        }
        stateLock.unlock()
    }

    /// 화면에 실제로 보여 준 횟수 (속도 비교용)
    private var shownFrames = 0
    private var shownReceived = 0
    private var shownSince = Date()

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
            // 연결 중(소켓이 아직 없을 때) stop 이 불렸으면 여기서 닫는다. 안 그러면 맥에 연결이 남는다
            stateLock.lock(); let stoppedEarly = stopped; if !stoppedEarly { socket = s }; stateLock.unlock()
            if stoppedEarly { s.close(); DebugLog.write("연결 중 종료됨 → 바로 닫음"); return }
            // 접속 직후 다시 붙으면 서버가 ServerInit 전에 멈춰 있을 때가 있다. 고성능 정리 뒤 첫 응답이 8초쯤 걸리니 넉넉히 15초
            s.setReadTimeout(15)
            try handshake(s)
            s.setReadTimeout(0)
            startWatchdog()
            while true {
                try readMessage(s)
            }
        } catch {
            DebugLog.write("끝: \(error)")
            // 고성능 수신·보고도 멈춘다 (끊긴 뒤에도 다시 제안하던 것)
            hpTimer?.cancel(); hpTimer = nil
            hpReceiver?.stop(); hpReceiver = nil
            hpDecoder?.stop(); hpDecoder = nil
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
        var capabilities: [UInt8] = []
        if apple && name.count >= 22 && name[0] == 0 {
            serverFlags = UInt32(name[2]) << 24 | UInt32(name[3]) << 16 | UInt32(name[4]) << 8 | UInt32(name[5])
            capabilities = Array(name[6..<22])
        }
        if apple && tryHighPerformance && Self.serverOffersHighPerformance(capabilities) {
            hpState = .trying
        }
        DebugLog.write("고성능 판단: 시도 설정 \(tryHighPerformance), 서버 지원 \(Self.serverOffersHighPerformance(capabilities)) → \(hpState == .trying ? "시도" : "안 함")")
        framebuffer.resize(width: w, height: h)
        DebugLog.write("ServerInit \(w)x\(h) flags=0x\(String(serverFlags, radix: 16)) 확장 \(name.count >= 22 && name[0] == 0 ? name[6..<22].map { String(format: "%02x", $0) }.joined() : "없음")")
        if serverFlags & 0x04 != 0 { try sessionSelect(s) }

        emit(.status("모니터 정보를 받는 중…"))
        var setup = [UInt8]()
        if apple {
            setup += Self.viewerInfo()
            setup += [0x0A, 0, 0, 1] // SetMode: 조작
            if hpState == .trying {
                // 배율 1 (레티나 아님): 원격 화면을 레티나로 볼 이유가 없고, 픽셀이 1/4 이라 영상이 훨씬 가볍다
                setup += HP.virtualDisplayMessage(width: virtualDisplay.width, height: virtualDisplay.height, scale: 1)
                DebugLog.write("HP 가상 디스플레이 요청 \(virtualDisplay.width)x\(virtualDisplay.height) @1")
                emit(.status("고성능 연결 시도 중…"))
                hpSchedule(after: 5) { [weak self] in
                    guard let self, !self.hpAnswered else { return }
                    self.hpFail("5초 동안 고성능 협상 답이 안 옴")
                }
            }
            setup += Self.setDisplay(nil)
            // 클립보드 자동 동기화 켬 (AutoPasteboard 0x15: [0x15][0][u16 1=켬][0 ×4]) — noVNC-ARD 와 같은 자리
            if clipboardSharing { setup += [0x15, 0, 0, 1, 0, 0, 0, 0] }
        }
        // SetPixelFormat: 32bpp depth24 리틀엔디언 true color, R16 G8 B0
        setup += [0, 0, 0, 0, 32, 24, 0, 1] + [UInt8].be16(255) + [UInt8].be16(255) + [UInt8].be16(255) + [16, 8, 0, 0, 0, 0]
        // 1105(DisplayInfo2) 와 1101 을 함께 넣어야 모니터 목록이 온다 (실험으로 확인)
        var encodings = Self.standardEncodings
        if hpState == .trying { encodings = [1010] + encodings + [1110] } // 고성능: 1010 맨 앞, 1110 맨 뒤
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
            if clipboardSharing, body.count >= 4, body[2] == 0, body[3] == 2 {
                // 원격 클립보드가 바뀜 → 내용 요청 (ClipboardRequest 0x0b: [0x0b][형식 0][0 0][u32 세션])
                clipLock.lock(); let sid = clipSessionID; clipLock.unlock()
                socket?.send([0x0B, 0, 0, 0] + [UInt8].be32(sid))
                DebugLog.write("클립보드: 원격이 바뀜 → 요청")
            }
            if clipboardSharing, body.count >= 4, body[2] == 0, body[3] == 3 {
                // 서버가 우리 클립보드를 달라고 함
                clipLock.lock(); let text = clipOutgoing; clipLock.unlock()
                if let text { sendClipboardNow(text) }
            }
            if body.count >= 4 && body[2] == 0 && body[3] == 4 {
                hpSubscribe()
                if autoUpdateAllowed {
                    if Self.useAutoUpdate { setAutoUpdate(true) } else { requestUpdate(incremental: true) }
                }
            }
        case 0x1F:
            // 클립보드: [형식][0 0][u32 세션][u32 풀린 크기][u32 압축 크기][zlib 애플 페이스트보드]
            let h = try s.read(15)
            func u32(_ o: Int) -> UInt32 { UInt32(h[o]) << 24 | UInt32(h[o + 1]) << 16 | UInt32(h[o + 2]) << 8 | UInt32(h[o + 3]) }
            let sid = u32(3), full = Int(u32(7)), comp = Int(u32(11))
            let data = try s.read(comp)
            clipLock.lock(); clipSessionID = sid; clipLock.unlock()
            guard comp > 0, full > 0, full < 128 << 20 else { DebugLog.write("클립보드: 빈 것 (형식 \(h[0]), 크기 \(full)/\(comp))"); break }
            // 압축 푸는 방법을 차례로 (zlib 한 덩어리 / 머리 없는 deflate / 접속 내내 이어지는 zlib 스트림)
            var pb: [UInt8]?, how = ""
            if let r = Self.zlibInflateLoose(data, size: full) { pb = r; how = "zlib" }
            else if let r = Self.rawInflate(data, size: full) { pb = r; how = "deflate" }
            else if let r = try? clipInflater.inflate(data), !r.isEmpty { pb = r; how = "이어지는 스트림" }
            guard let pb else {
                DebugLog.write("클립보드: 받음 \(comp)바이트 (형식 \(h[0]), 풀면 \(full)), 압축 풀기 실패, 앞 \(data.prefix(4).map { String(format: "%02x", $0) }.joined())")
                break
            }
            let content = Self.pasteboardContent(pb)
            if !content.isEmpty {
                DebugLog.write("클립보드: 원격에서 받음 \(content.summary) (\(how))") // 내용은 남기지 않는다
                emit(.clipboard(content))
            } else {
                DebugLog.write("클립보드: 받음 \(comp)→\(pb.count)바이트 (\(how)), 글자 없음. 구조: \(Self.pasteboardOutline(pb))")
            }
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
            if [0, 1, 6, 16, 1011].contains(enc) { framebuffer.markDirty(x: x, y: y, w: w, h: h) }
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
            case 1011:
                let data = try s.read(Int(try s.u32()))
                // 종류 2 는 양자화 표라 그림이 아니다. 서버가 표만 보내고 화면을 빠뜨리는 때가 있어서
                // 이걸 화면으로 치면 2초 감시가 꺼져 검은 화면에 멈춘다 (2026-11-03 맥북 실측)
                if data.first != 2 { drewPixels = true }
                let t0 = DispatchTime.now().uptimeNanoseconds
                framebuffer.withPixels { p, fw, fh in
                    mvs.decode(data, x: x, y: y, w: w, h: h, pixels: p, fbWidth: fw, fbHeight: fh)
                    #if DEBUG
                    MVSDump.add(data, x: x, y: y, w: w, h: h, pixels: p, fbWidth: fw, fbHeight: fh)
                    #endif
                }
                mvsBytes += data.count
                mvsNanos += DispatchTime.now().uptimeNanoseconds - t0
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
                // flags(4~7번째 바이트) 1 = 원격이 암호 입력 상태로 보임 (잠금 화면 등: 입력 소스가 영문으로 고정, ⌃Space 안 먹음)
                let secure = body.count >= 6 && (UInt32(body[2]) << 24 | UInt32(body[3]) << 16 | UInt32(body[4]) << 8 | UInt32(body[5])) & 1 != 0
                if !source.isEmpty { emit(.inputSource(source, secure: secure)) }
            case 1100: // 애플: 커서 위치
                stateLock.lock()
                let moved = cursor?.x != x || cursor?.y != y
                if moved { cursor = (x, y) }
                stateLock.unlock()
                if moved { DebugLog.write("커서 위치 \(x),\(y)"); emit(.cursor(x, y)) }
            case -223:
                framebuffer.resize(width: w, height: h)
            case -224:
                i = count == 0xFFFF ? Int.max : count
            case 1104: // 애플 커서 모양: [u32 id][u32 크기][zlib] (ArdCursor.swift)
                let hdr = try s.read(8)
                let id = UInt32(hdr[0]) << 24 | UInt32(hdr[1]) << 16 | UInt32(hdr[2]) << 8 | UInt32(hdr[3])
                let size = Int(UInt32(hdr[4]) << 24 | UInt32(hdr[5]) << 16 | UInt32(hdr[6]) << 8 | UInt32(hdr[7]))
                let data = size > 0 ? try s.read(size) : []
                let shape = ardCursor.decode(id: id, data: data, x: x, y: y, w: w, h: h)
                DebugLog.write("애플 커서 \(id) \(w)x\(h) 핫스팟 \(x),\(y) 데이터 \(size) → \(shape == nil ? "화살표" : "특이 커서")")
                emit(.cursorShape(shape))
            case -239: // 커서 모양: 픽셀(우리 형식 32bpp, 메모리 B G R X) + 비트 마스크(줄마다 (w+7)/8 바이트, 앞 비트가 왼쪽)
                let pixels = try s.read(w * h * 4)
                let mask = try s.read((w + 7) / 8 * h)
                let shape = Self.cursorShape(pixels: pixels, mask: mask, w: w, h: h, hotX: x, hotY: y)
                DebugLog.write("커서 모양 \(w)x\(h) 핫스팟 \(x),\(y) → \(shape == nil ? "화살표" : "특이 커서")")
                emit(.cursorShape(shape))
            default:
                DebugLog.write("알 수 없는 인코딩 \(enc) (\(String(format: "%08x", UInt32(bitPattern: enc)))) 사각형 \(x),\(y) \(w)x\(h). 이 메시지의 앞 사각형 \(encs.dropLast()), 사각형 수 \(count)")
                let recent = s.recentBytes
                for k in stride(from: 0, to: recent.count, by: 64) {
                    DebugLog.write("최근 받은 바이트 \(k): " + recent[k..<min(k + 64, recent.count)].map { String(format: "%02x", $0) }.joined())
                }
                throw RFBError.protocolError("알 수 없는 인코딩 \(enc)")
            }
            if i == Int.max { break }
        }

        hpSubscribe()
        if drewPixels { stateLock.lock(); fullRequestAt = nil; stateLock.unlock() }
        if drewPixels && wakeKick {
            wakeKick = false
            lateCount = 0
            DebugLog.write("깨우기 뒤 화면이 옴")
            if !Self.useAutoUpdate { setAutoUpdate(false) }
        }
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
        switch hpState {
        case .trying:
            // 고성능 시도 중의 목록은 가상 디스플레이 하나다: 결과가 나올 때까지 붙잡아 둔다
            hpPendingDisplays = info.displays
            DebugLog.write("HP 시도 중 모니터 목록 \(info.displays.map { "\($0.id) \(Int($0.framebuffer.width))x\(Int($0.framebuffer.height))" })")
            if info.pixelWidth > 0 && info.pixelHeight > 0 { framebuffer.resize(width: info.pixelWidth, height: info.pixelHeight) }
            return
        case .fallingBack:
            return
        default:
            break
        }
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

    /// 키·마우스를 보낸 뒤 화면을 다시 요청한다.
    /// 애플 서버는 걸어 둔 증분 요청에는 화면이 바뀌어도 바로 답하지 않고, 새 요청이 와야 바뀐 부분을 보낸다
    /// (2026-11-15 맥 앱 로그: 키를 친 뒤 2초 Tickle 에 맞춰 다시 요청할 때까지 화면이 안 옴, 수신량 0.0) →
    /// 마지막 입력 0.06초·0.3초 뒤 증분 요청 (입력이 이어지면 미룬다)
    private var nudgeGeneration = 0
    private var lastNudgeAt: TimeInterval = 0
    private let nudgeLock = NSLock()
    private func nudgeAfterInput() {
        guard hpState != .on else { return }
        let now = ProcessInfo.processInfo.systemUptime
        nudgeLock.lock()
        nudgeGeneration &+= 1; let g = nudgeGeneration
        // 끌기·연속 입력 중에도 0.1초에 한 번은 바로 요청 (입력이 이어지면 아래 지연 요청은 계속 미뤄지므로)
        let now_ = now - lastNudgeAt > 0.1
        if now_ { lastNudgeAt = now }
        nudgeLock.unlock()
        if now_ && autoUpdateAllowed && !Self.useAutoUpdate { requestUpdate(incremental: true) }
        for delay in [0.06, 0.3] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.nudgeLock.lock(); let current = self.nudgeGeneration == g; self.nudgeLock.unlock()
                guard current, self.autoUpdateAllowed, !Self.useAutoUpdate else { return }
                self.requestUpdate(incremental: true)
            }
        }
    }

    private func requestUpdate(incremental: Bool) {
        // 고성능 중에는 일반 화면을 요청하지 않는다: 요청이 쌓이면 서버가 영상을 멈추고 일반 화면으로 답하기 시작한다 (2026-11-02 실측)
        guard hpState != .on else { return }
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
                self.lateCount += 1
                DebugLog.write("2초 동안 화면이 안 와서 다시 요청 (\(self.lateCount)번째)")
                self.requestUpdate(incremental: false)
                // 두 번째부터는 자동 갱신을 잠깐 켜서 서버를 깨운다 (화면이 오면 다시 끈다)
                if self.lateCount >= 2 && !self.isAutoUpdateOn && self.hpState != .on {
                    self.wakeKick = true
                    self.setAutoUpdate(true)
                }
            } else if flowing {
                self.lateCount = 0
            }
        }
        watchdog = t
        t.resume()
    }

    // MARK: - 커서 모양

    /// 화살표 계열(핫스팟이 왼쪽 위 1/4 안)은 nil. 나머지(글자 입력 I자, 크기 조절, 십자, 손가락 등)는 그림으로
    static func cursorShape(pixels: [UInt8], mask: [UInt8], w: Int, h: Int, hotX: Int, hotY: Int) -> CursorShape? {
        guard w > 0, h > 0 else { return nil }
        if Double(hotX) <= Double(w) * 0.25 && Double(hotY) <= Double(h) * 0.25 { return nil }
        let rowBytes = (w + 7) / 8
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for yy in 0..<h {
            for xx in 0..<w where mask[yy * rowBytes + xx / 8] & (0x80 >> UInt8(xx % 8)) != 0 {
                let o = (yy * w + xx) * 4
                rgba[o] = pixels[o]; rgba[o + 1] = pixels[o + 1]; rgba[o + 2] = pixels[o + 2]; rgba[o + 3] = 255
            }
        }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return ArdCursorDecoder.smooth(CursorShape(image: image, hotspot: CGPoint(x: hotX, y: hotY)))
    }

    // MARK: - 마우스

    /// 지금 눌린 버튼 (1 왼쪽, 2 오른쪽 — 애플 서버는 2 를 오른쪽, 4 를 가운데로 받는다). 이동할 때도 같이 보내야 드래그가 된다
    private var buttonMask: UInt8 = 0

    /// 마우스 상태 하나를 보낸다 (RFB PointerEvent). 좌표는 프레임버퍼 픽셀.
    /// 더블 클릭 전용 메시지는 없다: 같은 좌표로 빨리 두 번 누르고 떼면 맥이 시간·위치로 판단한다
    private func pointer(_ x: Int, _ y: Int, _ mask: UInt8) {
        let x = max(0, min(x, framebuffer.width - 1)), y = max(0, min(y, framebuffer.height - 1))
        socket?.send([5, mask] + [UInt8].be16(x) + [UInt8].be16(y))
        nudgeAfterInput()
        stateLock.lock(); let moved = cursor?.x != x || cursor?.y != y; cursor = (x, y); stateLock.unlock()
        if moved { emit(.cursor(x, y)) }
    }

    /// 누르고 뗀다. button 1 = 왼쪽, 2 = 오른쪽 (애플 서버 기준. 4 는 가운데 버튼으로 들어간다)
    func click(x: Int, y: Int, button: UInt8 = 1) {
        pointer(x, y, buttonMask)
        pointer(x, y, buttonMask | button)
        if button == 2 {
            // 오른쪽은 실제 마우스처럼 잠깐 눌렀다 뗀다: 같은 순간에 떼면 독은 메뉴를 띄우지만 앱들은 문맥 메뉴를 안 띄웠다
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                self.pointer(x, y, self.buttonMask)
            }
        } else {
            pointer(x, y, buttonMask)
        }
        DebugLog.write("\(button == 2 ? "오른쪽 " : "")클릭 \(x),\(y)")
    }

    func mouseDown(x: Int, y: Int, button: UInt8 = 1) {
        pointer(x, y, buttonMask)
        buttonMask |= button
        pointer(x, y, buttonMask)
        DebugLog.write("누름 \(x),\(y)")
    }

    func mouseMove(x: Int, y: Int) { pointer(x, y, buttonMask) }

    func mouseUp(x: Int, y: Int) {
        buttonMask = 0
        pointer(x, y, 0)
        DebugLog.write("뗌 \(x),\(y)")
    }

    // MARK: - 스크롤 (애플 GestureEvent 0x17, noVNC-ARD 를 따름)

    /// 스크롤 단계 (트랙패드처럼). 0 = 없음 (마우스 휠 한 번)
    enum ScrollPhase: UInt32 { case none = 0, began = 1, changed = 2, ended = 4 }
    /// 손 뗀 뒤 관성 단계
    enum MomentumPhase: UInt32 { case none = 0, begin = 1, `continue` = 2, end = 3 }

    /// 연속 스크롤에서 아직 보내지 않은 줄 단위 나머지
    private var lineCarry: (x: Double, y: Double) = (0, 0)

    /// 1줄이 몇 포인트인지 (noVNC-ARD 가 애플 화면 공유에 맞춘 값)
    private static let pointsPerLine: Float = 45

    /// 지금 커서 자리에서 스크롤한다. dx, dy 는 맥 포인트, 양수 dy = 아래로 (내용이 위로 감)
    func scroll(dx: Double, dy: Double, phase: ScrollPhase = .none, momentum: MomentumPhase = .none) {
        defer { nudgeAfterInput() }
        // 서버는 양수를 위로 받는다 (2026-11-03 실측: 그대로 보내면 끌기·버튼 모두 거꾸로였다)
        let dx = -dx, dy = -dy
        stateLock.lock(); let pos = cursor ?? (framebuffer.width / 2, framebuffer.height / 2); stateLock.unlock()
        let x = UInt16(clamping: pos.0), y = UInt16(clamping: pos.1)
        let sx = Float(dx) / Self.pointsPerLine, sy = Float(dy) / Self.pointsPerLine
        // 줄 단위: 휠 한 번(단계 없음)은 최소 1줄. 끌기·관성처럼 작게 자주 보낼 때는 쌓아 두었다가 1줄이 차면 보낸다
        // (매번 1줄로 올리면 서버가 줄 단위를 쓸 때 스크롤이 과해진다)
        let continuous = phase != .none || momentum != .none
        if phase == .began { lineCarry = (0, 0) }
        func line(_ v: Double, _ carry: inout Double) -> Int16 {
            guard v != 0 else { return 0 }
            if continuous {
                carry += v / Double(Self.pointsPerLine)
                let n = carry.rounded(.towardZero)
                carry -= n
                return Int16(clamping: Int(n))
            }
            let n = Int16(clamping: Int((v / Double(Self.pointsPerLine)).rounded()))
            return v > 0 ? max(1, n) : min(-1, n)
        }
        func f32(_ v: Float) -> [UInt8] { [UInt8].be32(v.bitPattern) }
        func i32(_ v: Int) -> [UInt8] { [UInt8].be32(UInt32(bitPattern: Int32(clamping: v))) }
        func i16(_ v: Int16) -> [UInt8] { [UInt8].be16(Int(UInt16(bitPattern: v))) }
        // sub-type 8 CompactScroll: [f32 x][f32 y][f32 z][u32 1][u32 단계][u32 관성][u16 x][u16 y]
        var m: [UInt8] = [0x17, 0] + [UInt8].be16(32) + [UInt8].be16(2) + [UInt8].be16(8)
        m += f32(sx) + f32(sy) + f32(0) + [UInt8].be32(1) + [UInt8].be32(phase.rawValue) + [UInt8].be32(momentum.rawValue)
        m += [UInt8].be16(Int(x)) + [UInt8].be16(Int(y))
        // sub-type 11 ScrollWheel: [i16 줄 x y z][i32 16.16 x y z][i32 포인트 x y z][u32 단계][u32 관성][u32 0][u16 0][u16 flags][u16 x][u16 y]
        m += [0x17, 0] + [UInt8].be16(54) + [UInt8].be16(1) + [UInt8].be16(11)
        m += i16(line(dx, &lineCarry.x)) + i16(line(dy, &lineCarry.y)) + i16(0)
        m += i32(Int((Double(sx) * 65536).rounded())) + i32(Int((Double(sy) * 65536).rounded())) + i32(0)
        m += i32(Int(dx.rounded())) + i32(Int(dy.rounded())) + i32(0)
        m += [UInt8].be32(phase.rawValue) + [UInt8].be32(momentum.rawValue) + [UInt8].be32(0) + [UInt8].be16(0) + [UInt8].be16(0)
        m += [UInt8].be16(Int(x)) + [UInt8].be16(Int(y))
        socket?.send(m)
        if phase != .changed && momentum != .continue {
            DebugLog.write("스크롤 \(String(format: "%.1f", dx)),\(String(format: "%.1f", dy)) 단계 \(phase) 관성 \(momentum) @\(x),\(y)")
        }
    }

    /// 서버가 알려 준 커서 위치 (트랙패드 모드 포인터의 시작점)
    var cursorPosition: CGPoint? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cursor.map { CGPoint(x: $0.x, y: $0.y) }
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
        DebugLog.write("글자 보냄 \"\(text)\" 시각 \(DebugLog.wallClock())")
    }

    /// 특수 키 (BackSpace 0xFF08, Return 0xFF0D 등)
    func sendSpecialKey(_ keysym: UInt32, name: String) {
        holdUpdatesForTyping()
        sendKeyEvent(keysym, down: true)
        sendKeyEvent(keysym, down: false)
        DebugLog.write("키 보냄 \(name) 시각 \(DebugLog.wallClock())")
    }

    /// 조합키를 누른 채 키 하나를 눌렀다 떼고 조합키를 놓는다 (⌘C 등)
    func sendCombo(modifiers: [UInt32], key: UInt32, name: String) {
        holdUpdatesForTyping()
        for m in modifiers { sendKeyEvent(m, down: true) }
        sendKeyEvent(key, down: true)
        sendKeyEvent(key, down: false)
        for m in modifiers.reversed() { sendKeyEvent(m, down: false) }
        DebugLog.write("조합 보냄 \(modifiers.map { String(format: "%04x", $0) }) + \(name) 시각 \(DebugLog.wallClock())")
    }

    /// 키 하나를 누르거나 뗀다 (맥 키 코드를 함께 실을 수 있다: 맥 앱의 Caps Lock 한영 전환 시험)
    func sendRawKey(_ keysym: UInt32, keycode: UInt16, down: Bool, name: String) {
        sendKeyEvent(keysym, down: down, keycode: keycode)
        // 글자 키는 무슨 글자인지 남기지 않는다 (원격에서 친 암호가 로그에 남지 않게). 특수·조합 키만 값을 남긴다
        let what = keysym >= 0xFF00 && keysym < 0x1_0000 ? String(format: "%04x", keysym) : "글자"
        DebugLog.write("키 \(down ? "누름" : "뗌") \(name) \(what) 키코드 \(keycode) (\(ardKey != nil ? "암호화 0x10" : "평문 4"))")
    }

    private func sendKeyEvent(_ keysym: UInt32, down: Bool, keycode: UInt16 = 0) {
        defer { nudgeAfterInput() }
        if let key = ardKey {
            // EncryptedEvent (0x10): [type][flags] + AES-ECB([0xFF][down][keysym u32][시각 u32][0 0][키코드 u16][유니코드 u16])
            // (noVNC-ARD 는 키코드·유니코드 자리를 0 으로 보낸다)
            var p = [UInt8](repeating: 0, count: 16)
            p[0] = 0xFF
            p[1] = down ? 1 : 0
            p.replaceSubrange(2..<6, with: [UInt8].be32(keysym))
            p.replaceSubrange(6..<10, with: [UInt8].be32(UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1_000_000))))
            // 키코드 자리는 0 으로 둔다 (noVNC-ARD 와 같게). 맥 키 코드를 실으면 원격이 암호 입력 상태(잠금 화면 등)일 때
            // 글자가 안 들어갔다 (2026-11-15). 서버는 keysym 만 보고 키를 찾는다 (자모 방식도 keysym 으로 동작)
            _ = keycode
            socket?.send([0x10, 0] + RFBCrypto.ecbEncrypt(algorithm: CCAlgorithm(kCCAlgorithmAES128), key: key, data: p))
        } else {
            socket?.send([4, down ? 1 : 0, 0, 0] + [UInt8].be32(keysym))
        }
    }

    // MARK: - 클립보드 (애플 페이스트보드, noVNC-ARD 를 따름)

    /// 이 기기 클립보드를 원격으로 (원격에서 붙여넣기 할 수 있게)
    func sendClipboard(_ content: ClipContent) {
        guard clipboardSharing, !content.isEmpty else { return }
        clipLock.lock(); clipOutgoing = content; clipLock.unlock()
        sendClipboardNow(content)
    }

    private func sendClipboardNow(_ content: ClipContent) {
        let pb = Self.pasteboard(content)
        guard let z = Self.zlibCompress(pb) else { return }
        clipLock.lock(); let sid = clipSessionID; clipLock.unlock()
        // ClipboardSend 0x1f: [0x1f][형식 0][0 0][u32 세션][u32 풀린 크기][u32 압축 크기][zlib]
        socket?.send([0x1F, 0, 0, 0] + [UInt8].be32(sid) + [UInt8].be32(UInt32(pb.count)) + [UInt8].be32(UInt32(z.count)) + z)
        DebugLog.write("클립보드: 이 기기에서 보냄 \(content.summary)")
    }

    /// [u32 종류 수] { [u32 이름 길이][이름][u32 flags 0][u32 속성 수 0][u32 데이터 길이][데이터] }
    private static func pasteboard(_ c: ClipContent) -> [UInt8] {
        var items: [(String, [UInt8])] = []
        if let t = c.text { items.append(("public.utf8-plain-text", Array(t.utf8))) }
        if let p = c.png { items.append(("public.png", p)) }
        if let t = c.tiff { items.append(("public.tiff", t)) }
        var out = [UInt8].be32(UInt32(items.count))
        for (name, data) in items {
            let n = Array(name.utf8)
            out += [UInt8].be32(UInt32(n.count)) + n + [UInt8].be32(0) + [UInt8].be32(0) + [UInt8].be32(UInt32(data.count)) + data
        }
        return out
    }

    /// 페이스트보드에서 글자(public.utf8-plain-text)·그림(public.png / public.tiff)을 찾는다
    private static func pasteboardContent(_ b: [UInt8]) -> ClipContent {
        var c = ClipContent()
        var o = 0
        func u32() -> Int? {
            guard o + 4 <= b.count else { return nil }
            defer { o += 4 }
            return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        func bytes(_ n: Int) -> ArraySlice<UInt8>? {
            guard n >= 0, o + n <= b.count else { return nil }
            defer { o += n }
            return b[o..<(o + n)]
        }
        guard let types = u32() else { return c }
        for _ in 0..<min(types, 64) {
            guard let nl = u32(), let name = bytes(nl), u32() != nil, let props = u32() else { return c }
            for _ in 0..<min(props, 64) {
                guard let kl = u32(), bytes(kl) != nil, let vl = u32(), bytes(vl) != nil else { return c }
            }
            guard let dl = u32(), let data = bytes(dl) else { return c }
            switch String(decoding: name, as: UTF8.self) {
            case "public.utf8-plain-text": c.text = String(decoding: data, as: UTF8.self)
            case "public.png": c.png = Array(data)
            case "public.tiff": c.tiff = Array(data)
            default: break
            }
        }
        return c
    }

    /// 클립보드가 접속 내내 이어지는 스트림일 때를 위해 (시험)
    private let clipInflater = Inflater()

    /// zlib 한 덩어리를 끝 표시(Z_STREAM_END)가 없어도 풀린 만큼 받는다.
    /// 애플 서버는 클립보드를 sync flush 로 끊어 보내서 uncompress 는 '덜 끝남'으로 거부했다 (2026-11-15, 78da… 로 시작)
    private static func zlibInflateLoose(_ input: [UInt8], size: Int) -> [UInt8]? {
        var z = z_stream()
        guard inflateInit_(&z, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&z) }
        var out = [UInt8](repeating: 0, count: size + 64)
        var inp = input
        let rc: Int32 = inp.withUnsafeMutableBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                z.next_in = i.baseAddress; z.avail_in = uInt(i.count)
                z.next_out = o.baseAddress; z.avail_out = uInt(o.count)
                return inflate(&z, Z_SYNC_FLUSH)
            }
        }
        let produced = out.count - Int(z.avail_out)
        guard rc == Z_OK || rc == Z_STREAM_END || rc == Z_BUF_ERROR, produced > 0 else { return nil }
        return Array(out.prefix(produced))
    }

    /// 머리 없는 deflate
    private static func rawInflate(_ input: [UInt8], size: Int) -> [UInt8]? {
        var z = z_stream()
        guard inflateInit2_(&z, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&z) }
        var out = [UInt8](repeating: 0, count: size)
        var inp = input
        let rc: Int32 = inp.withUnsafeMutableBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                z.next_in = i.baseAddress; z.avail_in = uInt(i.count)
                z.next_out = o.baseAddress; z.avail_out = uInt(o.count)
                return inflate(&z, Z_FINISH)
            }
        }
        guard rc == Z_STREAM_END || rc == Z_OK else { return nil }
        return Array(out.prefix(size - Int(z.avail_out)))
    }

    /// 페이스트보드 구조만 (종류 이름·크기, 내용은 안 남김) — 형식이 다를 때 보려고
    private static func pasteboardOutline(_ b: [UInt8]) -> String {
        var o = 0, parts: [String] = []
        func u32() -> Int? {
            guard o + 4 <= b.count else { return nil }
            defer { o += 4 }
            return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        guard let n = u32() else { return "짧음 \(b.count)" }
        parts.append("종류 \(n)")
        for _ in 0..<min(n, 20) {
            guard let nl = u32(), nl < 256, o + nl <= b.count else { parts.append("이름 길이 이상 @\(o)"); break }
            let name = String(decoding: b[o..<(o + nl)], as: UTF8.self); o += nl
            guard let flags = u32(), let props = u32() else { parts.append("\(name) 잘림"); break }
            var ok = true
            for _ in 0..<min(props, 50) {
                guard let kl = u32(), o + kl <= b.count else { ok = false; break }; o += kl
                guard let vl = u32(), o + vl <= b.count else { ok = false; break }; o += vl
            }
            guard ok, let dl = u32() else { parts.append("\(name) 속성 \(props) 이상 @\(o)"); break }
            parts.append("\(name)(flags \(flags), 속성 \(props), \(dl)바이트)")
            o += dl
        }
        parts.append("끝 @\(o)/\(b.count)")
        return parts.joined(separator: ", ")
    }

    private static func zlibCompress(_ input: [UInt8]) -> [UInt8]? {
        var len = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(len))
        guard compress2(&out, &len, input, uLong(input.count), Z_DEFAULT_COMPRESSION) == Z_OK else { return nil }
        return Array(out.prefix(Int(len)))
    }

    private static func zlibUncompress(_ input: [UInt8], size: Int) -> [UInt8]? {
        var len = uLongf(size)
        var out = [UInt8](repeating: 0, count: size)
        guard uncompress(&out, &len, input, uLong(input.count)) == Z_OK else { return nil }
        return Array(out.prefix(Int(len)))
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
