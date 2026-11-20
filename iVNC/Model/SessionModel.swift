import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 접속 한 번 (접속 → 모니터 고르기 → 화면 보기)
@MainActor
final class SessionModel: ObservableObject {
    /// 클릭 전에 조합 중인 한글을 먼저 보내라는 알림 (키 입력 뷰가 받는다)
    static let flushCompositionNotification = Notification.Name("iVNC.flushComposition")

    /// 앱이 백그라운드인지 (맥은 창이 가려져도 계속 받으므로 늘 false)
    private static var appInBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    enum Phase: Equatable {
        case connecting(String)
        case picking
        case viewing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting("접속하는 중…")
    @Published private(set) var displays: [RemoteDisplay] = []
    @Published private(set) var selected: RemoteDisplay?
    /// 화면은 SwiftUI 를 거치지 않고 렌더러가 레이어에 바로 그린다
    let renderer = ScreenRenderer()
    /// 첫 그림이 나왔는지 (기다림 표시용)
    @Published private(set) var hasImage = false
    /// 고성능(가상 디스플레이) 연결인지
    @Published private(set) var isHighPerformance = false
    /// 화면 우상단 통신량 (받는 속도, 빠진 패킷)
    @Published private(set) var trafficText = ""
    private var trafficTimer: Timer?
    private var lastTraffic: (bytes: Int, lost: Int, packets: Int, at: Date)?

    private func startTrafficMeter() {
        trafficTimer?.invalidate()
        lastTraffic = nil
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateTraffic() }
    }

    private func updateTraffic() {
        guard let c = client else { trafficText = ""; return }
        let now = Date(), t = c.traffic
        defer { lastTraffic = (t.bytes, t.lost, t.packets, now) }
        guard let last = lastTraffic, t.bytes >= last.bytes else { return }
        let secs = max(now.timeIntervalSince(last.at), 0.1)
        let mbps = Double(t.bytes - last.bytes) * 8 / secs / 1_000_000
        let rate = mbps >= 10 ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps)
        // 고성능 영상 패킷 손실 비율 (이번 1초)
        let lost = max(0, t.lost - last.lost), got = max(0, t.packets - last.packets)
        let pct = lost + got > 0 ? Double(lost) * 100 / Double(lost + got) : 0
        trafficText = "↓ \(rate) Mbps" + (lost > 0 ? String(format: " · 손실 %.0f%%", pct) : "")
    }
    /// 고성능을 시도했는지 (Debug 화면 로그를 띄울지)
    @Published private(set) var triedHighPerformance = false
    /// 키보드로 원격 맥에 입력 중인지
    @Published var typing = false

    let computer: Computer
    private var client: RemoteClient?
    private weak var store: ComputerStore?

    init(computer: Computer) {
        self.computer = computer
        renderer.onFirstImage = { [weak self] in self?.hasImage = true }
        mouseMode = MouseMode(rawValue: UserDefaults.standard.string(forKey: "mouseMode." + computer.id.uuidString) ?? "") ?? .touch
    }

    /// 고성능 가상 디스플레이 크기 (배율 1 픽셀, 가로로 긴 쪽이 너비). 설정에서 해상도를 골랐으면 그것.
    /// "기기에 맞춤"이면: 아이패드는 기기 화면 크기 그대로 (맥 앱들이 아이패드 화면에 맞는 크기로 보인다).
    /// 아이폰은 화면이 너무 작아 맥 화면으로 쓰기 어려우니 1280x800 (확대해서 본다)
    static var virtualDisplaySize: (width: Int, height: Int) {
        if let r = AppSettings.resolution { return (r.width, r.height) }
        #if os(macOS)
        // 맥: 화면에서 쓸 수 있는 영역(메뉴 막대·독 제외)에서 창 제목·도구 막대만큼 뺀 크기 (배율 1)
        let f = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return (Int(f.width) & ~1, Int(f.height - 60) & ~1)
        #else
        let b = UIScreen.main.bounds.size
        guard UIDevice.current.userInterfaceIdiom == .pad else { return (1280, 800) }
        // 짝수로 (픽셀이 2배라 상관없지만 영상 인코더가 짝수를 좋아한다)
        let w = Int(max(b.width, b.height)) & ~1, h = Int(min(b.width, b.height)) & ~1
        return (w, h)
        #endif
    }

    /// 고성능 없이 다시 접속할 때 true
    private var standardOnly = false
    /// 접속 단계에서 실패해 자동으로 다시 시도한 횟수 (3번까지)
    private var retries = 0
    private static let maxRetries = 3

    func connect(store: ComputerStore, keepStatus: Bool = false) {
        guard !closed else { return }
        self.store = store
        client?.stop()
        if !keepStatus { phase = .connecting("접속하는 중…"); retries = 0 }
        // Debug: 서명 없는 시험 빌드(키체인 못 씀)는 IVNC_TEST_PASSWORD 로 가짜 맥에 붙는다
        #if DEBUG
        let testPassword = ProcessInfo.processInfo.environment["IVNC_TEST_PASSWORD"]
        #else
        let testPassword: String? = nil
        #endif
        // SSH 는 화면 세션이 아니다 (터미널은 따로 만든다). 목록에서 막지만 혹시 들어오면
        guard computer.type.showsScreen else {
            phase = .failed("SSH 터미널은 아직 준비 중입니다.")
            return
        }
        guard let pw = Keychain.password(for: computer.id) ?? testPassword else {
            phase = .failed("저장된 암호가 없습니다. 컴퓨터를 길게 눌러 편집에서 암호를 입력하세요.")
            return
        }
        let c: RemoteClient
        if computer.type == .windows {
            // 윈도우 원격 데스크톱: 설정 해상도(또는 이 기기에 맞춘 크기)로 원격 화면을 만든다
            c = RDPClient(host: computer.host, port: computer.port, username: computer.username, password: pw,
                          size: Self.virtualDisplaySize)
            triedHighPerformance = false
        } else {
            c = RFBClient(host: computer.host, port: computer.port, username: computer.username, password: pw,
                          tryHighPerformance: !standardOnly && computer.prefersHighPerformance,
                          virtualDisplay: Self.virtualDisplaySize)
            triedHighPerformance = !standardOnly
        }
        isHighPerformance = false
        c.clipboardSharing = clipboardSharing
        c.onEvent = { [weak self] in self?.handle($0) }
        client = c
        c.start()
    }

    /// 일반 모드 그림을 화면에. 수신 스레드가 아직 푸는 중이면 메인 스레드를 막지 않고 잠시 뒤 다시
    private func presentFrame() {
        guard let c = client else { return }
        if renderer.presentStandard(c.framebuffer) {
            c.frameConsumed()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in self?.presentFrame() }
        }
    }

    private func handle(_ e: RFBClient.Event) {
        switch e {
        case .status(let s):
            if case .connecting = phase { phase = .connecting(retries > 0 ? "\(s) (다시 시도 \(retries)/\(Self.maxRetries))" : s) }
        case .displays(let list):
            displays = list
            // 모니터가 하나여도 바로 고르지 않는다: 맥이 깨어날 때는 모니터가 하나씩 붙어서 처음 목록이 전부가 아닐 수 있다
            // (고성능 시도 중의 목록은 RFBClient 가 결과가 나올 때까지 붙잡아 둔다)
            if case .connecting = phase {
                store?.markConnected(computer.id)
                // 고성능은 가상 디스플레이 하나뿐이니 고르지 않고 바로 본다
                // 윈도우도 원격 화면 하나뿐이라 바로 본다
                if isHighPerformance || computer.type == .windows, let d = list.first { select(d) } else { phase = .picking }
            }
        case .highPerformance(let ok):
            if ok {
                isHighPerformance = true // 바로 뒤에 오는 모니터 목록(가상 디스플레이)으로 바로 들어간다
            } else {
                isHighPerformance = false
            }
        case .reconnectStandard:
            client?.stop() // 가상 디스플레이 내리기 신호를 보내고 끊는다 (남아 있던 것도 같이 정리되길 기대)
            standardOnly = true
            // 원격이 가상 디스플레이를 내리고 실제 모니터를 다시 켤 시간을 준다
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let store = self.store, !self.closed else { return }
                self.connect(store: store)
            }
        case .frame:
            presentFrame()
        case .cursor(let x, let y):
            cursor = CGPoint(x: x, y: y)
        case .inputSource(let id, let secure):
            remoteSecureInput = secure
            remoteInputSource = id
        case .clipboard(let content):
            onRemoteClipboard?(content)
        case .certificateChanged(let host, let answer):
            certificateQuestion = CertificateQuestion(host: host, answer: answer)
        case .cursorShape(let shape):
            cursorShape = shape
        case .stripe(let pb, let stripe, let stripes):
            renderer.presentStripe(pb, stripe: stripe, stripes: stripes, fullHeight: client?.framebuffer.height ?? 0)
            client?.frameConsumed()
        case .failed(let msg):
            // 앱을 나가 있는 동안 맥이 연결을 끊으면(화면 공유 끔·접속 끊기·살아 있음 확인 실패): 위치 사용을 끄고 목록으로 돌아간다
            if backgrounded || Self.appInBackground {
                DebugLog.write("백그라운드: 연결 끊김 (\(msg)) → 위치 끄고 목록으로")
                close()
                ended = true
                return
            }
            // 화면을 보기 전(접속·인증 단계) 실패는 자동으로 3번까지 다시 시도한다.
            // 서버는 접속 직후 다시 붙으면 끊거나 멈출 때가 있다
            if case .connecting = phase, retries < Self.maxRetries, let store {
                retries += 1
                client?.stop()
                client = nil
                let n = retries
                phase = .connecting("다시 시도하는 중 (\(n)/\(Self.maxRetries))…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, case .connecting = self.phase, self.retries == n else { return }
                    self.connect(store: store, keepStatus: true)
                }
            } else {
                phase = .failed(msg)
            }
        }
    }

    private var guided = false

    /// 윈도우 인증서가 지난번과 다를 때 묻는다 (접속 화면이 창으로 띄운다)
    struct CertificateQuestion {
        let host: String
        let answer: (Bool) -> Void
    }
    @Published var certificateQuestion: CertificateQuestion?

    func answerCertificate(_ ok: Bool) {
        let q = certificateQuestion
        certificateQuestion = nil
        // 거절하면 자동으로 다시 시도하지 않는다 (다시 물어보게 됨)
        if !ok { retries = Self.maxRetries }
        q?.answer(ok)
    }

    func select(_ d: RemoteDisplay) {
        saveThumbnail()
        selected = d
        phase = .viewing
        if trafficTimer == nil { startTrafficMeter() }
        #if os(iOS)
        if computer.keepsAliveInBackground { BackgroundKeeper.shared.start() }
        #endif
        if !guided {
            guided = true
            showGuide(mouseMode.title + "\n" + mouseMode.guide)
        }
        client?.select(display: d.id)
        // 서버는 커서가 움직일 때만 위치를 알려 준다: 모르면 화면이 나온 뒤 가운데로 한 번 옮겨 위치를 맞춘다
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.phase == .viewing, let c = self.client, c.cursorPosition == nil else { return }
            let w = c.framebuffer.width, h = c.framebuffer.height
            guard w > 0, h > 0 else { return }
            c.mouseMove(x: w / 2, y: h / 2)
        }
    }

    func backToPicker() {
        saveThumbnail()
        client?.pause()
        phase = .picking
    }

    /// 맥 커서 위치 (프레임버퍼 픽셀). 앱이 큰 포인터로 보여 준다
    @Published private(set) var cursor: CGPoint?
    /// 특이한 맥 커서 (글자 입력·크기 조절 등). nil 이면 큰 화살표
    @Published private(set) var cursorShape: RFBClient.CursorShape?

    /// 스크롤 모드 (메뉴에서 켜고 끈다)
    @Published var scrollMode = false

    /// 위·아래 버튼: 50 포인트씩 (양수 = 아래로)
    func scrollStep(_ dy: Double) { client?.scroll(dx: 0, dy: dy) }

    /// 마우스 조작 방식 (컴퓨터별로 기억)
    @Published private(set) var mouseMode: MouseMode = .touch

    func toggleMouseMode() { setMouseMode(mouseMode == .touch ? .trackpad : .touch) }

    func setMouseMode(_ m: MouseMode) {
        mouseMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mouseMode." + computer.id.uuidString)
    }

    /// 화면 위에 잠깐 보여 주는 안내 (접속 직후 마우스 조작법)
    @Published private(set) var guide: String?
    private var guideToken = 0

    func showGuide(_ text: String, seconds: Double = 3.5) {
        guideToken += 1
        let t = guideToken
        guide = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.guideToken == t { self?.guide = nil }
        }
    }
    /// 조합 중이라 아직 안 보낸 글자 (키보드 위에 보여 준다)
    @Published var composing = ""
    /// 클립보드 공유 (맥 앱이 접속 전에 켠다). 원격에서 복사하면 onRemoteClipboard, 보낼 땐 sendClipboard
    var clipboardSharing = false
    var onRemoteClipboard: ((RFBClient.ClipContent) -> Void)?
    func sendClipboard(_ content: RFBClient.ClipContent) { client?.sendClipboard(content) }

    /// 원격 맥의 지금 입력 소스 (1109). 맥 앱이 이 맥 입력 소스와 한/영을 맞출 때 쓴다
    @Published private(set) var remoteInputSource: String?
    /// 원격이 암호 입력 상태 (1109 flags 1): 입력 소스가 영문으로 고정돼 한/영 맞추기를 쉰다
    private(set) var remoteSecureInput = false

    func sendText(_ t: String) {
        client?.sendText(t)
    }
    func sendBackspace(_ n: Int) {
        for _ in 0..<n { client?.sendSpecialKey(0xFF08, name: "BackSpace") }
    }
    func sendReturn() {
        client?.sendSpecialKey(0xFF0D, name: "Return")
    }
    /// 맥 앱: 키 하나 누름/뗌 + 맥 키 코드
    func sendRawKey(_ keysym: UInt32, keycode: UInt16, down: Bool, name: String) {
        client?.sendRawKey(keysym, keycode: keycode, down: down, name: name)
    }
    /// 원격 한/영을 한 번 바꾼다 (맥 ⌃Space, 윈도우 한/영 키)
    func toggleRemoteInputSource() { client?.toggleInputSource() }
    func sendKey(_ keysym: UInt32, name: String) {
        client?.sendSpecialKey(keysym, name: name)
    }
    func sendCombo(_ modifiers: [UInt32], _ key: UInt32, name: String) {
        client?.sendCombo(modifiers: modifiers, key: key, name: name)
    }

    /// 닫은 뒤에는 다시 시도(2초 뒤 예약된 것 포함)로 새로 접속하지 않는다
    private var closed = false

    func close() {
        closed = true
        trafficTimer?.invalidate(); trafficTimer = nil
        saveThumbnail()
        #if os(iOS)
        BackgroundKeeper.shared.stop()
        #endif
        client?.stop()
        client = nil
    }

    /// 앱을 나갈 때: 화면 받기는 멈추고 연결만 둔다 (맥은 계속 깨워 둔다). 돌아오면 다시 받는다
    private var backgrounded = false
    /// 연결 유지를 안 하는 컴퓨터는 앱을 나가면 바로 끊고 화면을 닫는다 (목록으로)
    @Published private(set) var ended = false

    func enterBackground() {
        // iOS 가 앱을 멈출 때까지 연결이 애매하게 물려 있으면 고성능은 맥에 모니터를 돌려주지 못한다: 바로 끊는다
        if !computer.keepsAliveInBackground {
            DebugLog.write("백그라운드: 연결 유지 안 함, 바로 끊음")
            close()
            ended = true
            return
        }
        guard phase == .viewing, !backgrounded else { return }
        backgrounded = true
        saveThumbnail()
        client?.pause()
        DebugLog.write("백그라운드: 화면 받기 멈춤")
    }

    func enterForeground() {
        guard backgrounded else { return }
        backgrounded = false
        if phase == .viewing, let d = selected { client?.select(display: d.id) }
        DebugLog.write("포그라운드: 화면 다시 받음")
    }

    private func saveThumbnail() {
        guard phase == .viewing, hasImage, let fb = client?.framebuffer, let img = renderer.snapshot(fb) else { return }
        Thumbnails.save(img, computer: computer.id, display: selected?.stableKey)
        store?.thumbnailsChanged()
    }
}

extension MouseMode {
    var title: String { self == .touch ? "터치 모드" : "트랙패드 모드" }
    var symbol: String { self == .touch ? "hand.point.up.left" : "rectangle.and.hand.point.up.left" }
    var guide: String {
        switch self {
        case .touch: return "누른 곳 클릭 · 길게 누르면 우클릭 · 길게 누른 채 끌면 드래그 · 한 손가락으로 화면 이동"
        case .trackpad: return "한 손가락으로 포인터 이동 · 탭하면 클릭 · 두 손가락 탭은 우클릭 · 길게 누른 채 끌면 드래그 · 두 손가락으로 화면 이동"
        }
    }
}

extension SessionModel: MouseInput {
    /// 클릭하면 맥의 포커스가 옮겨 갈 수 있으니, 조합 중인 글자를 먼저 원래 자리에 보낸다
    private func flushComposition() {
        if !composing.isEmpty { NotificationCenter.default.post(name: SessionModel.flushCompositionNotification, object: nil) }
    }
    func mouseClick(_ p: CGPoint, button: UInt8) { flushComposition(); client?.click(x: Int(p.x), y: Int(p.y), button: button) }
    func mouseDown(_ p: CGPoint) { flushComposition(); client?.mouseDown(x: Int(p.x), y: Int(p.y)) }
    func mouseMove(_ p: CGPoint) { client?.mouseMove(x: Int(p.x), y: Int(p.y)) }
    func mouseUp(_ p: CGPoint) { client?.mouseUp(x: Int(p.x), y: Int(p.y)) }
    enum ScreenCorner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    /// 원격 커서를 화면 모서리로 옮겨 핫 코너를 실행한다 (맥 앱 도구 막대). 조금 안쪽에서 모서리로 들어가게 두 번 보낸다
    func moveToCorner(_ c: ScreenCorner) {
        let s = renderer.pixelSize
        guard phase == .viewing, s.width > 1, s.height > 1 else { return }
        let left = c == .topLeft || c == .bottomLeft, top = c == .topLeft || c == .topRight
        let x = left ? 0 : Int(s.width) - 1, y = top ? 0 : Int(s.height) - 1
        let step = Int(min(s.width, s.height) / 10)
        client?.mouseMove(x: left ? x + step : x - step, y: top ? y + step : y - step)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.client?.mouseMove(x: x, y: y) }
    }
    /// 맥 앱: 실제 마우스 버튼을 누른 채로 (1 왼쪽, 2 오른쪽, 4 가운데). 떼기는 mouseUp
    func mouseDown(_ p: CGPoint, button: UInt8) { flushComposition(); client?.mouseDown(x: Int(p.x), y: Int(p.y), button: button) }
    var serverCursor: CGPoint? { client?.cursorPosition }
    /// 프레임버퍼 픽셀 → 맥 포인트 (레티나 모니터는 2픽셀 = 1포인트)
    func mouseScroll(_ dx: CGFloat, _ dy: CGFloat, phase: RFBClient.ScrollPhase, momentum: RFBClient.MomentumPhase) {
        let scale = max(selected?.scale ?? 1, 1)
        client?.scroll(dx: Double(dx / scale), dy: Double(dy / scale), phase: phase, momentum: momentum)
    }
}
