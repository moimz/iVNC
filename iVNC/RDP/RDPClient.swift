import CoreGraphics
import Foundation
import ImageIO

/// 접속 화면(SessionModel)이 쓰는 원격 접속 하나: 맥(RFB)과 윈도우(RDP) 공용
protocol RemoteClient: AnyObject {
    var onEvent: ((RFBClient.Event) -> Void)? { get set }
    var clipboardSharing: Bool { get set }
    var framebuffer: Framebuffer { get }
    var traffic: (bytes: Int, lost: Int, packets: Int) { get }
    var cursorPosition: CGPoint? { get }
    func start()
    func stop()
    func select(display id: UInt32?)
    func pause()
    func frameConsumed()
    func click(x: Int, y: Int, button: UInt8)
    func mouseDown(x: Int, y: Int, button: UInt8)
    func mouseMove(x: Int, y: Int)
    func mouseUp(x: Int, y: Int)
    func scroll(dx: Double, dy: Double, phase: RFBClient.ScrollPhase, momentum: RFBClient.MomentumPhase)
    func sendText(_ text: String)
    func sendSpecialKey(_ keysym: UInt32, name: String)
    func sendCombo(modifiers: [UInt32], key: UInt32, name: String)
    func sendRawKey(_ keysym: UInt32, keycode: UInt16, down: Bool, name: String)
    func sendClipboard(_ content: RFBClient.ClipContent)
    /// 원격 한/영을 한 번 바꾼다 (맥: ⌃Space, 윈도우: 한/영 키)
    func toggleInputSource()
}

extension RemoteClient {
    func scroll(dx: Double, dy: Double) { scroll(dx: dx, dy: dy, phase: .none, momentum: .none) }
    func mouseDown(x: Int, y: Int) { mouseDown(x: x, y: y, button: 1) }
}

extension RFBClient: RemoteClient {
    func toggleInputSource() {
        sendRawKey(0xFFE3, keycode: 59, down: true, name: "Control")
        sendRawKey(0x20, keycode: 49, down: true, name: "Space")
        sendRawKey(0x20, keycode: 49, down: false, name: "Space")
        sendRawKey(0xFFE3, keycode: 59, down: false, name: "Control")
    }
}

/// 윈도우 원격 데스크톱 (FreeRDP). 접속 스레드 하나가 FreeRDP 를 돌리고, 바뀐 그림을 Framebuffer 에 옮겨 담는다.
/// 모니터 고르기는 없다: 원격 화면 하나(우리가 정한 크기)를 "모니터 하나"로 알린다
final class RDPClient: RemoteClient {
    var onEvent: ((RFBClient.Event) -> Void)?
    var clipboardSharing = false
    let framebuffer = Framebuffer()

    private let host: String
    private let port: Int
    private let username: String
    private let domain: String
    private let password: String
    private let size: (width: Int, height: Int)

    /// FreeRDP 접속 (접속 스레드가 끝나면 지운다). 다른 스레드에서 쓸 때는 lock 을 잡는다
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private var stopped = false
    /// 화면 보는 중 (모니터를 고른 뒤). 아니면 그림을 담기만 하고 알리지 않는다
    private var streaming = false
    /// 화면 쪽이 아직 안 가져간 그림이 있음 (알림을 쌓지 않는다)
    private var framePending = false
    private var cursor: (x: Int, y: Int)?
    /// 눌린 마우스 버튼 (1 왼쪽, 2 오른쪽, 4 가운데)
    private var buttons: UInt8 = 0
    /// 연속 스크롤 나머지 (휠 단위)
    private var wheelCarry: (x: Double, y: Double) = (0, 0)

    init(host: String, port: Int, username: String, password: String, size: (width: Int, height: Int)) {
        self.host = host
        self.port = port
        // "도메인\사용자" 로 적었으면 나눈다 (Microsoft 계정 이메일은 그대로)
        if let i = username.firstIndex(of: "\\") {
            domain = String(username[..<i]); self.username = String(username[username.index(after: i)...])
        } else {
            domain = ""; self.username = username
        }
        self.password = password
        // 원격 데스크톱은 너비가 짝수(4의 배수가 안전)여야 한다
        self.size = (max(640, size.width & ~3), max(480, size.height & ~1))
    }

    // MARK: 접속

    /// FreeRDP 로그를 앱 로그로 (한 번)
    private static let logOnce: Void = {
        ivnc_rdp_set_log { line in
            guard let line else { return }
            DebugLog.write("FreeRDP " + String(cString: line))
        }
    }()

    func start() {
        _ = Self.logOnce
        let t = Thread { [weak self] in self?.run() }
        t.name = "RDPClient"
        t.qualityOfService = .userInitiated
        t.start()
    }

    private func emit(_ e: RFBClient.Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    private func run() {
        emit(.status("윈도우에 접속하는 중…"))
        var cb = ivnc_rdp_callbacks()
        // 이 객체는 run 이 끝날 때까지 살아 있다 (스레드가 self 를 잡고 있음)
        cb.owner = Unmanaged.passUnretained(self).toOpaque()
        cb.paint = { owner, buffer, stride, width, height, x, y, w, h in
            guard let owner, let buffer else { return }
            Unmanaged<RDPClient>.fromOpaque(owner).takeUnretainedValue()
                .painted(buffer, stride: Int(stride), width: Int(width), height: Int(height), x: Int(x), y: Int(y), w: Int(w), h: Int(h))
        }
        cb.resized = { owner, width, height in
            guard let owner else { return }
            Unmanaged<RDPClient>.fromOpaque(owner).takeUnretainedValue().resized(Int(width), Int(height))
        }
        cb.ime = { owner, korean in
            guard let owner else { return }
            Unmanaged<RDPClient>.fromOpaque(owner).takeUnretainedValue().remoteIME(korean: korean != 0, reason: "윈도우 알림")
        }
        cb.cursor_new = { owner, bgra, width, height, hotX, hotY in
            guard let bgra, let shape = RDPClient.cursorShape(bgra, Int(width), Int(height), Int(hotX), Int(hotY)) else { return nil }
            return Unmanaged.passRetained(CursorBox(shape)).toOpaque()
        }
        cb.cursor_free = { _, cursor in
            guard let cursor else { return }
            Unmanaged<CursorBox>.fromOpaque(cursor).release()
        }
        cb.cursor_set = { owner, cursor, mode in
            guard let owner else { return }
            let me = Unmanaged<RDPClient>.fromOpaque(owner).takeUnretainedValue()
            switch mode {
            case 0: if let cursor { me.emit(.cursorShape(Unmanaged<CursorBox>.fromOpaque(cursor).takeUnretainedValue().shape)) }
            case 1: me.emit(.cursorShape(RDPClient.hiddenCursor))
            default: me.emit(.cursorShape(nil))
            }
        }
        cb.clip_remote = { owner, kind, data, length in
            guard let owner, let data, length > 0 else { return }
            Unmanaged<RDPClient>.fromOpaque(owner).takeUnretainedValue()
                .remoteClipboard(kind: Int(kind), Data(bytes: data, count: Int(length)))
        }
        cb.log = { _, message in
            guard let message else { return }
            DebugLog.write("RDP: " + String(cString: message))
        }
        guard let h = ivnc_rdp_new(cb) else {
            emit(.failed("원격 데스크톱을 준비하지 못했습니다."))
            return
        }
        ivnc_rdp_set_clipboard(h, clipboardSharing ? 1 : 0)
        lock.lock()
        if stopped { lock.unlock(); ivnc_rdp_free(h); return }
        handle = h
        let pending = pendingClip
        lock.unlock()
        // 접속 전에 받아 둔 이 기기 클립보드 (원격 클립보드 채널이 열리면 알린다)
        if let pending { sendClipboard(pending) }

        var message = [CChar](repeating: 0, count: 256)
        let result = ivnc_rdp_run(h, host, Int32(port), username, domain, password,
                                  Int32(size.width), Int32(size.height), &message, Int32(message.count))
        lock.lock(); handle = nil; let wasStopped = stopped; lock.unlock()
        ivnc_rdp_free(h)
        guard !wasStopped, result != Int32(IVNC_RDP_OK) else { return }
        let detail = String(cString: message)
        emit(.failed(Self.describe(result, detail: detail)))
    }

    private static func describe(_ code: Int32, detail: String) -> String {
        switch Int(code) {
        case Int(IVNC_RDP_AUTH): return "계정 또는 암호가 맞지 않습니다."
        case Int(IVNC_RDP_DNS): return "주소를 찾을 수 없습니다."
        case Int(IVNC_RDP_UNREACHABLE): return "윈도우에 접속할 수 없습니다. PC 가 켜져 있고 원격 데스크톱이 켜져 있는지 확인하세요."
        case Int(IVNC_RDP_ACCOUNT): return "계정을 쓸 수 없습니다 (잠김, 막힘 또는 암호 만료)."
        case Int(IVNC_RDP_DENIED): return "이 계정은 원격 데스크톱 접속 권한이 없습니다."
        case Int(IVNC_RDP_LOGOFF): return "원격에서 연결을 끊었습니다."
        case Int(IVNC_RDP_OTHER_SESSION): return "다른 곳에서 접속해 연결이 끊겼습니다."
        case Int(IVNC_RDP_SECURITY): return "보안 연결(NLA·TLS)을 맺지 못했습니다."
        default: return "연결이 끊겼습니다." + (detail.isEmpty ? "" : " (\(detail))")
        }
    }

    /// 접속 완료·화면 크기 바뀜 (접속 스레드)
    private func resized(_ width: Int, _ height: Int) {
        // 처음 접속: 윈도우 입력기는 영문으로 시작한다고 본다 (윈도우는 한/영 상태를 대개 알려 주지 않는다)
        lock.lock(); let first = koreanIME == nil; lock.unlock()
        if first { remoteIME(korean: false, reason: "접속 처음") }
        framebuffer.resize(width: width, height: height)
        let d = RemoteDisplay(id: 1, isMain: true, scale: 1,
                              desktop: CGRect(x: 0, y: 0, width: width, height: height),
                              framebuffer: CGRect(x: 0, y: 0, width: width, height: height))
        emit(.displays([d]))
    }

    /// 바뀐 영역을 우리 화면 버퍼로 옮긴다 (접속 스레드, FreeRDP 버퍼는 이 안에서만 읽는다)
    private func painted(_ src: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, x: Int, y: Int, w: Int, h: Int) {
        var copied = false
        framebuffer.withPixels { dst, fw, fh in
            guard fw == width, fh == height else { return }
            dst.withMemoryRebound(to: UInt8.self, capacity: fw * fh * 4) { d in
                for row in y..<(y + h) {
                    memcpy(d + (row * fw + x) * 4, src + row * stride + x * 4, w * 4)
                }
            }
            copied = true
        }
        guard copied else { return }
        framebuffer.markDirty(x: x, y: y, w: w, h: h)
        lock.lock()
        let notify = streaming && !framePending
        if notify { framePending = true }
        lock.unlock()
        if notify { emit(.frame) }
    }

    func frameConsumed() {
        lock.lock(); framePending = false; lock.unlock()
    }

    var traffic: (bytes: Int, lost: Int, packets: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return (0, 0, 0) }
        return (Int(ivnc_rdp_received(h)), 0, 0)
    }

    func stop() {
        lock.lock()
        stopped = true
        if let h = handle { ivnc_rdp_stop(h) }
        lock.unlock()
    }

    func select(display id: UInt32?) {
        lock.lock(); streaming = true; framePending = false; let h = handle; lock.unlock()
        // 다시 보기: 원격에 그림을 다시 보내라고 하고, 가진 그림 전체를 한 번 그린다
        if let h { lock.lock(); ivnc_rdp_suppress_output(h, 0); lock.unlock() }
        framebuffer.markDirty(x: 0, y: 0, w: framebuffer.width, h: framebuffer.height)
        emit(.frame)
    }

    func pause() {
        lock.lock(); streaming = false
        if let h = handle { ivnc_rdp_suppress_output(h, 1) }
        lock.unlock()
    }

    private func withHandle(_ body: (OpaquePointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let h = handle { body(h) }
    }

    // MARK: 마우스 (좌표는 원격 화면 픽셀)

    private static let ptrMove: UInt16 = 0x0800, ptrDown: UInt16 = 0x8000
    private static let ptrWheel: UInt16 = 0x0200, ptrHWheel: UInt16 = 0x0400, ptrWheelNegative: UInt16 = 0x0100

    /// 우리 버튼 번호(1 왼쪽, 2 오른쪽, 4 가운데) → PTR_FLAGS_BUTTON1/2/3
    private static func buttonFlag(_ b: UInt8) -> UInt16 {
        switch b {
        case 2: return 0x2000
        case 4: return 0x4000
        default: return 0x1000
        }
    }

    private func clamp(_ x: Int, _ y: Int) -> (Int, Int) {
        (max(0, min(x, framebuffer.width - 1)), max(0, min(y, framebuffer.height - 1)))
    }

    private func send(_ flags: UInt16, _ x: Int, _ y: Int) {
        let (x, y) = clamp(x, y)
        withHandle { ivnc_rdp_mouse($0, flags, Int32(x), Int32(y)) }
        lock.lock(); let moved = cursor?.x != x || cursor?.y != y; cursor = (x, y); lock.unlock()
        if moved { emit(.cursor(x, y)) }
    }

    var cursorPosition: CGPoint? {
        lock.lock(); defer { lock.unlock() }
        return cursor.map { CGPoint(x: $0.x, y: $0.y) }
    }

    func mouseMove(x: Int, y: Int) { send(Self.ptrMove, x, y) }

    func click(x: Int, y: Int, button: UInt8 = 1) {
        commandJoined()
        send(Self.ptrMove, x, y)
        send(Self.buttonFlag(button) | Self.ptrDown, x, y)
        send(Self.buttonFlag(button), x, y)
    }

    func mouseDown(x: Int, y: Int, button: UInt8 = 1) {
        commandJoined() // ⌘클릭 = Ctrl+클릭
        send(Self.ptrMove, x, y)
        lock.lock(); buttons |= button; lock.unlock()
        send(Self.buttonFlag(button) | Self.ptrDown, x, y)
    }

    func mouseUp(x: Int, y: Int) {
        lock.lock(); let held = buttons; buttons = 0; lock.unlock()
        for b in [UInt8(1), 2, 4] where held & b != 0 { send(Self.buttonFlag(b), x, y) }
        if held == 0 { send(Self.buttonFlag(1), x, y) }
    }

    /// dx, dy 는 포인트, 양수 dy = 아래로. 휠 한 칸 = 120. 트랙패드처럼 잘게 오면 모아서 보낸다
    func scroll(dx: Double, dy: Double, phase: RFBClient.ScrollPhase = .none, momentum: RFBClient.MomentumPhase = .none) {
        let continuous = phase != .none || momentum != .none
        if phase == .began { wheelCarry = (0, 0) }
        // 1 포인트 ≈ 3 단위 (한 칸 120 ≈ 40 포인트). 휠 한 번(단계 없음)은 최소 한 칸
        func units(_ v: Double, _ carry: inout Double) -> Int {
            guard v != 0 else { return 0 }
            if !continuous { return v > 0 ? max(120, Int(v * 3)) : min(-120, Int(v * 3)) }
            carry += v * 3
            let n = Int(carry); carry -= Double(n)
            return n
        }
        let pos = cursorPosition ?? CGPoint(x: framebuffer.width / 2, y: framebuffer.height / 2)
        // 윈도우 휠: 양수 = 위로. 우리 dy 양수 = 아래로 → 부호를 뒤집는다
        var vy = -units(dy, &wheelCarry.y), vx = units(dx, &wheelCarry.x)
        func sendWheel(_ v: inout Int, horizontal: Bool) {
            while v != 0 {
                let step = max(-255, min(255, v))
                v -= step
                var flags = horizontal ? Self.ptrHWheel : Self.ptrWheel
                if step < 0 { flags |= Self.ptrWheelNegative | UInt16((256 + step) & 0xFF) } else { flags |= UInt16(step & 0xFF) }
                withHandle { ivnc_rdp_mouse($0, flags, Int32(pos.x), Int32(pos.y)) }
            }
        }
        sendWheel(&vy, horizontal: false)
        sendWheel(&vx, horizontal: true)
    }

    // MARK: 커서 모양

    final class CursorBox {
        let shape: RFBClient.CursorShape
        init(_ shape: RFBClient.CursorShape) { self.shape = shape }
    }

    /// 윈도우 커서 그림 (B G R A, 알파 곱하지 않음) → 커서 모양
    static func cursorShape(_ bgra: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ hotX: Int, _ hotY: Int) -> RFBClient.CursorShape? {
        let data = Data(bytes: bgra, count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return RFBClient.CursorShape(image: image, hotspot: CGPoint(x: hotX, y: hotY))
    }

    /// 원격이 커서를 숨김 (게임·동영상 등): 투명 1픽셀
    static let hiddenCursor: RFBClient.CursorShape? = {
        let px: [UInt8] = [0, 0, 0, 0]
        return px.withUnsafeBufferPointer { cursorShape($0.baseAddress!, 1, 1, 0, 0) }
    }()

    // MARK: 한/영

    /// 원격 입력기가 한글인지 (알림이 없으면 우리가 보낸 한/영 키로 따라간다)
    private var koreanIME: Bool?

    private func remoteIME(korean: Bool, reason: String) {
        lock.lock(); let changed = koreanIME != korean; koreanIME = korean; lock.unlock()
        guard changed else { return }
        DebugLog.write("RDP: 원격 입력기 \(korean ? "한글" : "영문") (\(reason))")
        // 맥 앱의 한/영 맞추기는 입력 소스 이름에 Korean 이 있는지로 비교한다
        emit(.inputSource(korean ? "RDP.Korean" : "RDP.Roman", secure: false))
    }

    func toggleInputSource() {
        key(Self.hangulKey, true); key(Self.hangulKey, false)
        lock.lock(); let now = !(koreanIME ?? false); lock.unlock()
        remoteIME(korean: now, reason: "한/영 키 보냄")
    }

    // MARK: 키보드 (스캔코드. 확장 키는 0x100)

    /// ⌘ 를 누른 채 다른 키·클릭: 그때 Ctrl 을 누른다
    private func commandJoined() {
        lock.lock()
        let pressCtrl = commandDown && !commandAsCtrl
        if commandDown { commandUsed = true }
        if pressCtrl { commandAsCtrl = true }
        lock.unlock()
        if pressCtrl { key(Self.ctrlKey, true) }
    }

    /// ⌘ 를 누른 채지만 Ctrl 없이 보낼 키 (⌘← → Home 등): 눌러 둔 Ctrl 을 뗀다
    private func commandWithoutCtrl() {
        lock.lock()
        let releaseCtrl = commandAsCtrl
        commandUsed = true; commandAsCtrl = false
        lock.unlock()
        if releaseCtrl { key(Self.ctrlKey, false) }
    }

    /// ⌘ 와 함께 누르면 윈도우 키로 바꿔 보내는 맥 단축키. 뗄 때 바꾼 키를 뗀다
    private var remapped: [UInt16: [UInt32]] = [:]

    /// ⌘+키 → 윈도우 동작. nil 이면 보통처럼 Ctrl+키. (Ctrl 필요, 보낼 키들)
    private static func macShortcut(_ keycode: UInt16) -> (ctrl: Bool, keys: [UInt32])? {
        switch keycode {
        case 123: return (false, [0x147])   // ⌘← → Home (줄 처음)
        case 124: return (false, [0x14F])   // ⌘→ → End (줄 끝)
        case 126: return (true, [0x147])    // ⌘↑ → Ctrl+Home (문서 처음)
        case 125: return (true, [0x14F])    // ⌘↓ → Ctrl+End (문서 끝)
        case 12: return (false, [0x38, 0x3E]) // ⌘Q → Alt+F4 (창 닫기)
        default: return nil
        }
    }

    static let hangulKey: UInt32 = 0x72
    static let windowsKey: UInt32 = 0x15B
    static let ctrlKey: UInt32 = 0x1D

    /// ⌘ 를 누르고 있음
    private var commandDown = false
    /// ⌘ 를 누른 동안 다른 키·클릭을 했음 (아니면 뗄 때 윈도우 키)
    private var commandUsed = false
    /// ⌘ 대신 Ctrl 을 눌러 둠
    private var commandAsCtrl = false

    /// 맥 키 코드 → PC 스캔코드. ⌘ 는 Ctrl 로 (⌘C·⌘V 가 윈도우 Ctrl+C·Ctrl+V 로)
    static let scancodes: [UInt16: UInt32] = [
        0: 0x1E, 1: 0x1F, 2: 0x20, 3: 0x21, 4: 0x23, 5: 0x22, 6: 0x2C, 7: 0x2D, 8: 0x2E, 9: 0x2F, 10: 0x56, 11: 0x30,
        12: 0x10, 13: 0x11, 14: 0x12, 15: 0x13, 16: 0x15, 17: 0x14, 18: 0x02, 19: 0x03, 20: 0x04, 21: 0x05, 22: 0x07,
        23: 0x06, 24: 0x0D, 25: 0x0A, 26: 0x08, 27: 0x0C, 28: 0x09, 29: 0x0B, 30: 0x1B, 31: 0x18, 32: 0x16, 33: 0x1A,
        34: 0x17, 35: 0x19, 36: 0x1C, 37: 0x26, 38: 0x24, 39: 0x28, 40: 0x25, 41: 0x27, 42: 0x2B, 43: 0x33, 44: 0x35,
        45: 0x31, 46: 0x32, 47: 0x34, 48: 0x0F, 49: 0x39, 50: 0x29, 51: 0x0E, 53: 0x01,
        55: 0x1D, 54: 0x1D,             // ⌘ → Ctrl (혼자 누르면 윈도우 키, sendRawKey)
        56: 0x2A, 60: 0x36,             // ⇧
        58: 0x38, 61: 0x138,            // ⌥ → Alt
        59: 0x1D, 62: 0x11D,            // ⌃ → Ctrl
        57: 0x3A,                       // Caps Lock
        122: 0x3B, 120: 0x3C, 99: 0x3D, 118: 0x3E, 96: 0x3F, 97: 0x40, 98: 0x41, 100: 0x42,
        101: 0x43, 109: 0x44, 103: 0x57, 111: 0x58,
        123: 0x14B, 124: 0x14D, 125: 0x150, 126: 0x148,
        115: 0x147, 119: 0x14F, 116: 0x149, 121: 0x151, 117: 0x153, 76: 0x11C,
        82: 0x52, 83: 0x4F, 84: 0x50, 85: 0x51, 86: 0x4B, 87: 0x4C, 88: 0x4D, 89: 0x47, 91: 0x48, 92: 0x49,
        65: 0x53, 67: 0x37, 69: 0x4E, 78: 0x4A, 75: 0x135, 71: 0x45,
    ]

    /// X keysym → 스캔코드 (아이폰 키·조합 단추, 맥 이 맥 조합 방식의 특수 키)
    static func scancode(keysym: UInt32) -> UInt32? {
        switch keysym {
        case 0xFF08: return 0x0E
        case 0xFF09: return 0x0F
        case 0xFF0D: return 0x1C
        case 0xFF1B: return 0x01
        case 0xFFFF: return 0x153
        case 0xFF51: return 0x14B
        case 0xFF52: return 0x148
        case 0xFF53: return 0x14D
        case 0xFF54: return 0x150
        case 0xFF50: return 0x147
        case 0xFF57: return 0x14F
        case 0xFF55: return 0x149
        case 0xFF56: return 0x151
        case 0xFFBE...0xFFC7: return 0x3B + (keysym - 0xFFBE)
        case 0xFFC8: return 0x57
        case 0xFFC9: return 0x58
        case 0xFFE1: return 0x2A
        case 0xFFE2: return 0x36
        case 0xFFE3, 0xFFEB: return 0x1D     // Ctrl, ⌘(Super) → Ctrl
        case 0xFFE4, 0xFFEC: return 0x11D
        case 0xFFE7, 0xFFE9: return 0x38     // ⌥ → Alt
        case 0xFFE8, 0xFFEA: return 0x138
        case 0x20: return 0x39
        default:
            // 글자: 미국 자판 자리 (⌘C 같은 조합용)
            guard keysym < 0x80, let s = Unicode.Scalar(keysym) else { return nil }
            let c = Character(s).lowercased()
            return scancodes.first { MacKeyNames.us[$0.key] == c }?.value
        }
    }

    private func key(_ scancode: UInt32, _ down: Bool) {
        withHandle { ivnc_rdp_key($0, down ? 1 : 0, scancode) }
    }

    /// 글자는 유니코드로 (한글 완성 글자도 그대로 들어간다)
    func sendText(_ text: String) {
        withHandle { h in
            for u in text.utf16 {
                if u == 0x0A || u == 0x0D { ivnc_rdp_key(h, 1, 0x1C); ivnc_rdp_key(h, 0, 0x1C); continue }
                ivnc_rdp_unicode(h, 1, u)
                ivnc_rdp_unicode(h, 0, u)
            }
        }
    }

    func sendSpecialKey(_ keysym: UInt32, name: String) {
        guard let sc = Self.scancode(keysym: keysym) else { DebugLog.write("RDP: 모르는 키 \(name)"); return }
        key(sc, true); key(sc, false)
    }

    func sendCombo(modifiers: [UInt32], key k: UInt32, name: String) {
        let mods = modifiers.compactMap { Self.scancode(keysym: $0) }
        guard let sc = Self.scancode(keysym: k) else { DebugLog.write("RDP: 모르는 조합 \(name)"); return }
        for m in mods { key(m, true) }
        key(sc, true); key(sc, false)
        for m in mods.reversed() { key(m, false) }
    }

    /// 맥 앱: 키 자리 그대로 (맥 키 코드 → 스캔코드). 표에 없으면 글자로.
    /// ⌘ 는 맥 단축키처럼: 다른 키와 함께면 Ctrl (⌘C → Ctrl+C), 혼자 눌렀다 떼면 윈도우 키
    func sendRawKey(_ keysym: UInt32, keycode: UInt16, down: Bool, name: String) {
        if keycode == 55 || keycode == 54 {
            lock.lock()
            let asCtrl = commandAsCtrl, alone = commandDown && !commandUsed
            commandDown = down; commandUsed = false; commandAsCtrl = false
            lock.unlock()
            if !down {
                // 창을 떠나며 뗀 것(⌘Tab 으로 다른 앱 등)은 윈도우 키로 치지 않는다
                if asCtrl { key(Self.ctrlKey, false) } else if alone, name != "떠나며 뗌" { key(Self.windowsKey, true); key(Self.windowsKey, false) }
            }
            return
        }
        // 맥 단축키 → 윈도우 동작 (⌘←·⌘→ Home·End, ⌘↑·⌘↓ 문서 처음·끝, ⌘Q Alt+F4)
        lock.lock(); let cmd = commandDown; let mapped = remapped[keycode]; lock.unlock()
        if down, cmd, let m = Self.macShortcut(keycode) {
            if m.ctrl { commandJoined() } else { commandWithoutCtrl() }
            for k in m.keys { key(k, true) }
            lock.lock(); remapped[keycode] = m.keys; lock.unlock()
            return
        }
        if !down, let keys = mapped {
            for k in keys.reversed() { key(k, false) }
            lock.lock(); remapped[keycode] = nil; lock.unlock()
            return
        }
        if down { commandJoined() }
        if let sc = Self.scancodes[keycode] ?? Self.scancode(keysym: keysym) {
            key(sc, down)
        } else if down, keysym < 0x1_0000 || keysym & 0xFF00_0000 == 0x0100_0000 {
            sendText(String(Character(Unicode.Scalar(keysym & 0x00FF_FFFF) ?? " ")))
        }
    }

    // MARK: 클립보드 (윈도우 cliprdr: 글자 CF_UNICODETEXT, 그림 PNG·CF_DIB)

    /// 접속 준비 전에 받은 이 기기 클립보드
    private var pendingClip: RFBClient.ClipContent?

    /// 이 기기에서 복사한 것을 원격이 붙여넣을 수 있게 알린다
    func sendClipboard(_ content: RFBClient.ClipContent) {
        guard clipboardSharing, !content.isEmpty else { return }
        var text: [UInt8]?
        if let t = content.text {
            // 윈도우 줄바꿈 \r\n, UTF-16LE, 끝에 0
            let win = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            text = win.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
        }
        let png = content.png
        let dib = png.flatMap { Self.dib(fromPNG: $0) }
        lock.lock()
        guard let h = handle else { pendingClip = content; lock.unlock(); return }
        pendingClip = nil
        func ptr(_ a: [UInt8]?, _ body: (UnsafePointer<UInt8>?, Int32) -> Void) {
            if let a { a.withUnsafeBufferPointer { body($0.baseAddress, Int32($0.count)) } } else { body(nil, 0) }
        }
        ptr(text) { tp, tl in ptr(dib) { dp, dl in ptr(png) { pp, pl in ivnc_rdp_clip_set(h, tp, tl, dp, dl, pp, pl) } } }
        lock.unlock()
        DebugLog.write("RDP 클립보드 보냄: \(content.summary)\(dib != nil ? ", DIB \(dib!.count / 1000)KB" : "")")
    }

    /// 원격에서 복사한 것 (접속 스레드)
    private func remoteClipboard(kind: Int, _ data: Data) {
        var c = RFBClient.ClipContent()
        switch kind {
        case 1:
            var units = [UInt16](repeating: 0, count: data.count / 2)
            _ = units.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            if let end = units.firstIndex(of: 0) { units.removeSubrange(end...) }
            c.text = String(decoding: units, as: UTF16.self).replacingOccurrences(of: "\r\n", with: "\n")
        case 2:
            c.png = [UInt8](data)
        case 3:
            c.png = Self.png(fromDIB: data)
        default: break
        }
        guard !c.isEmpty else { DebugLog.write("RDP 클립보드: 원격 내용을 못 바꿈 (종류 \(kind), \(data.count)바이트)"); return }
        DebugLog.write("RDP 클립보드 받음: \(c.summary)")
        emit(.clipboard(c))
    }

    /// DIB(비트맵 정보 머리 + 픽셀) → PNG. BMP 파일 머리(14바이트)를 붙여 ImageIO 로 푼다
    static func png(fromDIB dib: Data) -> [UInt8]? {
        guard dib.count > 40 else { return nil }
        func u32(_ o: Int) -> UInt32 { dib.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func u16(_ o: Int) -> UInt16 { dib.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) } }
        let headerSize = Int(u32(0)), bitCount = Int(u16(14)), compression = u32(16), clrUsed = Int(u32(32))
        var offset = 14 + headerSize
        if headerSize == 40 && compression == 3 { offset += 12 } // BI_BITFIELDS 색 마스크
        if bitCount <= 8 { offset += 4 * (clrUsed > 0 ? clrUsed : 1 << bitCount) }
        var file = Data([0x42, 0x4D])
        withUnsafeBytes(of: UInt32(14 + dib.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(contentsOf: [0, 0, 0, 0])
        withUnsafeBytes(of: UInt32(offset).littleEndian) { file.append(contentsOf: $0) }
        file.append(dib)
        guard let src = CGImageSourceCreateWithData(file as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return [UInt8](out as Data)
    }

    /// PNG → DIB (BITMAPINFOHEADER 40바이트 + 32비트 B G R A, 아래 줄부터)
    static func dib(fromPNG png: [UInt8]) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(Data(png) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h <= 50_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
            // CGContext 는 아래가 원점: 메모리 첫 줄 = 그림 맨 위. DIB 는 아래 줄부터라 뒤집어 그린다
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var header = [UInt8]()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        put32(40); put32(UInt32(w)); put32(UInt32(h)); put16(1); put16(32); put32(0) // BI_RGB
        put32(UInt32(w * h * 4)); put32(2835); put32(2835); put32(0); put32(0)
        return header + pixels
    }
}

/// 맥 키 코드 → 미국 자판 글자 (RDP 조합 키 찾기용. 맥 앱의 MacScreenNSView.usKey 와 같은 표)
enum MacKeyNames {
    static let us: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 49: " ", 50: "`",
    ]
}
