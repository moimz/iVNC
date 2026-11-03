import SwiftUI

/// 접속 한 번 (접속 → 모니터 고르기 → 화면 보기)
@MainActor
final class SessionModel: ObservableObject {
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
    /// 고성능을 시도했는지 (Debug 화면 로그를 띄울지)
    @Published private(set) var triedHighPerformance = false
    /// 키보드로 원격 맥에 입력 중인지
    @Published var typing = false

    let computer: Computer
    private var client: RFBClient?
    private weak var store: ComputerStore?

    /// UI 시험: 접속하지 않고 가짜 화면으로 화면 UI 만 띄운다 (임시, UI 정리용)
    let preview: Bool
    private var previewFB: Framebuffer?

    init(computer: Computer, preview: Bool = false) {
        self.computer = computer
        self.preview = preview
        renderer.onFirstImage = { [weak self] in self?.hasImage = true }
        mouseMode = MouseMode(rawValue: UserDefaults.standard.string(forKey: "mouseMode." + computer.id.uuidString) ?? "") ?? .touch
    }

    /// 고성능 없이 다시 접속할 때 true
    private var standardOnly = false
    /// 접속 단계에서 실패해 자동으로 다시 시도한 횟수 (3번까지)
    private var retries = 0
    private static let maxRetries = 3

    func connect(store: ComputerStore, keepStatus: Bool = false) {
        self.store = store
        client?.stop()
        if !keepStatus { phase = .connecting("접속하는 중…"); retries = 0 }
        if preview { startPreview(); return }
        guard let pw = Keychain.password(for: computer.id) else {
            phase = .failed("저장된 암호가 없습니다. 컴퓨터를 길게 눌러 편집에서 암호를 입력하세요.")
            return
        }
        let c = RFBClient(host: computer.host, port: computer.port, username: computer.username, password: pw,
                          tryHighPerformance: !standardOnly && computer.prefersHighPerformance)
        isHighPerformance = false
        triedHighPerformance = !standardOnly
        c.onEvent = { [weak self] in self?.handle($0) }
        client = c
        c.start()
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
                if isHighPerformance, let d = list.first { select(d) } else { phase = .picking }
            }
        case .highPerformance(let ok):
            if ok {
                isHighPerformance = true // 바로 뒤에 오는 모니터 목록(가상 디스플레이)으로 바로 들어간다
            } else {
                isHighPerformance = false
            }
        case .reconnectStandard:
            client?.stop()
            standardOnly = true
            if let store { connect(store: store) }
        case .frame:
            if let fb = client?.framebuffer { renderer.presentStandard(fb) }
            client?.frameConsumed()
        case .cursor(let x, let y):
            cursor = CGPoint(x: x, y: y)
        case .stripe(let pb, let stripe, let stripes):
            renderer.presentStripe(pb, stripe: stripe, stripes: stripes)
            client?.frameConsumed()
        case .failed(let msg):
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

    func select(_ d: RemoteDisplay) {
        saveThumbnail()
        selected = d
        phase = .viewing
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

    func sendText(_ t: String) {
        client?.sendText(t)
    }
    func sendBackspace(_ n: Int) {
        for _ in 0..<n { client?.sendSpecialKey(0xFF08, name: "BackSpace") }
    }
    func sendReturn() {
        client?.sendSpecialKey(0xFF0D, name: "Return")
    }
    func sendKey(_ keysym: UInt32, name: String) {
        client?.sendSpecialKey(keysym, name: name)
    }

    func close() {
        saveThumbnail()
        client?.stop()
        client = nil
    }

    /// 마지막 접속 그림(없으면 무늬)을 맥 화면인 척 띄우고, 가짜 모니터 두 대로 바로 보기에 들어간다
    private func startPreview() {
        let w = 2560, h = 1600
        let fb = Framebuffer()
        fb.resize(width: w, height: h)
        fb.withPixels { p, w, h in
            // 메모리 순서 B G R X = 32비트 리틀 엔디언 + 앞 바이트 버림
            guard let ctx = CGContext(data: p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            if let img = Thumbnails.load(computer: computer.id)?.cgImage {
                ctx.interpolationQuality = .high
                ctx.draw(img, in: rect)
            } else {
                for i in 0..<16 {
                    ctx.setFillColor(i % 2 == 0 ? CGColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1) : CGColor(red: 0.12, green: 0.2, blue: 0.4, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: h * i / 16, width: w, height: h / 16 + 1))
                }
            }
        }
        previewFB = fb
        displays = [
            RemoteDisplay(id: 1, isMain: true, scale: 2, desktop: CGRect(x: 0, y: 0, width: 1280, height: 800), framebuffer: CGRect(x: 0, y: 0, width: w, height: h)),
            RemoteDisplay(id: 2, isMain: false, scale: 1, desktop: CGRect(x: 1280, y: 0, width: 1920, height: 1080), framebuffer: CGRect(x: w, y: 0, width: 1920, height: 1080)),
        ]
        cursor = CGPoint(x: w / 2, y: h / 2)
        select(displays[0])
        renderer.presentStandard(fb)
    }

    private func saveThumbnail() {
        guard phase == .viewing, hasImage, let fb = client?.framebuffer, let img = renderer.snapshot(fb) else { return }
        Thumbnails.save(img, computer: computer.id, display: selected?.stableKey)
        store?.thumbnailsChanged()
    }
}

struct SessionView: View {
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SessionModel
    @State private var mouseSettings = false
    /// 마우스 설정 팝업 높이 (안의 내용을 재서 맞춘다)
    @State private var mouseSettingsHeight: CGFloat = 320

    init(computer: Computer, preview: Bool = false) {
        _model = StateObject(wrappedValue: SessionModel(computer: computer, preview: preview))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .overlay {
            if model.phase == .viewing {
                // 스크롤 모드: 오른쪽에 위·아래 버튼 (한 번에 50포인트)
                if model.scrollMode {
                    VStack(spacing: 12) {
                        Button { model.scrollStep(-50) } label: { Image(systemName: "chevron.up").frame(width: 44, height: 44) }
                        Button { model.scrollStep(50) } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                }
                // 떠 있는 버튼: 누르면 버튼 옆에 메뉴가 뜬다. 이 버튼의 터치는 맥에 안 보낸다
                // 키보드가 떠 있는 동안은 키보드 위 줄에 같은 메뉴 버튼이 있어 숨긴다
                if !model.typing {
                    FloatingMenuButton(scroll: model.scrollMode, menu: menu)
                        .ignoresSafeArea(.container) // 키보드가 뜨면 그 위로 올라가게 (키보드 영역은 피한다)
                }
            }
        }
        .overlay(alignment: .top) { if model.phase != .viewing { topBar } }
        // 키보드 바로 위: 한글을 조합하는 동안 조합 중인 글자(맥에 아직 안 간 것)만 보여 준다.
        // 영어는 치는 즉시 맥으로 가서 보여 줄 필요가 없다
        .overlay(alignment: .bottom) {
            if model.phase == .viewing && model.typing && !model.composing.isEmpty {
                Text(model.composing).foregroundStyle(.white).underline()
                    .font(.title3.monospaced())
                    .lineLimit(1)
                    .padding(.horizontal, 14).frame(height: 40)
                    .glassEffect()
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if model.phase == .viewing, let g = model.guide {
                Text(g)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 24).padding(.top, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.guide)
        .sheet(isPresented: $mouseSettings) {
            MouseSettingsView(mode: model.mouseMode) { model.setMouseMode($0); mouseSettings = false }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mouseSettingsHeight = $0 }
                .presentationDetents([.height(mouseSettingsHeight)])
        }
        .statusBarHidden(model.phase == .viewing)
        .preferredColorScheme(.dark)
        // 시스템이 키보드를 내리면 키보드 버튼 상태도 맞춘다 (안 그러면 다음에 누를 때 거꾸로 동작한다)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in model.typing = false }
        .onAppear { model.connect(store: store) }
        .onDisappear { model.close() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .connecting(let status):
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(status).foregroundStyle(.secondary)
            }
        case .picking:
            DisplayPickerView(computer: model.computer, displays: model.displays) { model.select($0) }
                .padding(.top, 56)
        case .viewing:
            ZStack {
                ScreenView(renderer: model.renderer, mode: model.mouseMode, scrollMode: model.scrollMode, cursor: model.cursor, input: model)
                    .ignoresSafeArea()
                KeyInputField(active: $model.typing, onText: model.sendText, onBackspace: model.sendBackspace, onReturn: model.sendReturn,
                              onPending: { model.composing = $0 }, onKey: model.sendKey, menu: menu)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                if !model.hasImage { ProgressView().controlSize(.large) }
            }
        case .failed(let msg):
            ContentUnavailableView {
                Label("접속하지 못했습니다", systemImage: "exclamationmark.triangle")
            } description: {
                Text(msg)
            } actions: {
                Button("다시 시도") { model.connect(store: store) }.buttonStyle(.borderedProminent)
            }
        }
    }

    /// 떠 있는 버튼의 메뉴 (iOS 기본 팝업 메뉴: 버튼 위치에 따라 위나 아래에 뜬다)
    private var menu: UIMenu {
        // 체크 표시(state)는 쓰지 않는다: 하나라도 있으면 모든 항목이 체크 자리만큼 밀린다
        let mouse = UIAction(title: "마우스 설정", image: UIImage(systemName: model.mouseMode.symbol)) { _ in
            mouseSettings = true
        }
        var tools: [UIMenuElement] = [
            UIAction(title: model.scrollMode ? "스크롤 모드 끄기" : "스크롤 모드", image: UIImage(systemName: "arrow.up.and.down")) { _ in
                model.scrollMode.toggle()
            },
            UIAction(title: model.typing ? "키보드 숨기기" : "키보드", image: UIImage(systemName: model.typing ? "keyboard.chevron.compact.down" : "keyboard")) { _ in
                model.typing.toggle()
            },
        ]
        if model.displays.count > 1 && !model.isHighPerformance {
            tools.append(UIAction(title: "모니터 바꾸기", image: UIImage(systemName: "display.2")) { _ in model.backToPicker() })
        }
        let end = UIAction(title: "연결 끊기", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
            model.close(); dismiss()
        }
        return UIMenu(title: title + (model.isHighPerformance ? " · 고성능" : ""), children: [
            UIMenu(options: .displayInline, children: [mouse]),
            UIMenu(options: .displayInline, children: tools),
            UIMenu(options: .displayInline, children: [end]),
        ])
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { model.close(); dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            // 버튼이 많아 자리가 모자라면 이름은 숨긴다 (빈 칸으로 찌그러지지 않게)
            ViewThatFits(in: .horizontal) {
                Text(title).font(.headline).lineLimit(1).fixedSize()
                    .padding(.horizontal, 14).frame(height: 36)
                    .glassEffect()
                Color.clear.frame(width: 0, height: 36)
            }
            if model.isHighPerformance {
                Label("고성능", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10).frame(height: 28)
                    .glassEffect()
            }
            Spacer()
            if model.phase == .viewing {
                Button { model.toggleMouseMode() } label: {
                    Image(systemName: model.mouseMode == .touch ? "hand.point.up.left" : "rectangle.and.hand.point.up.left").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(model.mouseMode == .touch ? "터치 모드" : "트랙패드 모드")
                Button { model.scrollMode.toggle() } label: {
                    Image(systemName: "arrow.up.and.down").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(model.scrollMode ? .yellow : nil)
                .accessibilityLabel(model.scrollMode ? "스크롤 모드 끄기" : "스크롤 모드")
                Button { model.typing.toggle() } label: {
                    Image(systemName: model.typing ? "keyboard.chevron.compact.down" : "keyboard").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            if model.phase == .viewing && model.displays.count > 1 && !model.isHighPerformance {
                Button { model.backToPicker() } label: {
                    Label("모니터", systemImage: "display.2").frame(height: 36)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var title: String {
        guard model.phase == .viewing, let d = model.selected, model.displays.count > 1,
              let i = model.displays.sorted(by: DisplayPickerView.order).firstIndex(of: d) else { return model.computer.name }
        return "\(model.computer.name) · 모니터 \(i + 1)"
    }
}

/// 떠 있는 버튼: 누르면 메뉴, 길게 누른 뒤 던지면 네 모서리 중 그쪽으로 옮긴다. 위치를 기억한다.
/// UIKit 으로 만든다: SwiftUI 버튼에 끌기 손동작을 붙이면 탭이 먹지 않았다. 버튼 밖 터치는 아래(화면)로 그대로 보낸다
struct FloatingMenuButton: UIViewRepresentable {
    var scroll = false
    let menu: UIMenu

    func makeUIView(context: Context) -> FloatingButtonHost { FloatingButtonHost() }

    func updateUIView(_ v: FloatingButtonHost, context: Context) {
        v.setMenu(menu)
        v.setScroll(scroll)
    }
}

/// 떠 있는 메뉴 버튼: 네 모서리 중 하나에 붙는다. 누르면 메뉴, 길게 누른 뒤 던지면 그쪽 모서리로 옮겨 간다.
final class FloatingButtonHost: UIView {
    private let button = UIButton(type: .system)
    /// 메뉴만 띄우는 숨은 버튼: 보이는 버튼에 메뉴를 붙이면 메뉴가 터치를 가져가 길게 누르기가 안 된다
    private let menuButton = UIButton(type: .custom)
    private let size: CGFloat = 54
    private let margin: CGFloat = 12
    /// 이만큼 움직이거나 이 속도로 튕기면 그 방향 모서리로 옮긴다
    private let flickDistance: CGFloat = 24
    private let flickSpeed: CGFloat = 250
    private var scroll = false
    /// 길게 눌러 끄는 중: 누른 자리, 던진 속도를 재려는 최근 위치
    private var grabStart: CGPoint?
    private var samples: [(p: CGPoint, t: TimeInterval)] = []

    private var right: Bool {
        get { UserDefaults.standard.object(forKey: "floatingButton.right") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "floatingButton.right") }
    }
    private var bottom: Bool {
        get { UserDefaults.standard.object(forKey: "floatingButton.bottom") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "floatingButton.bottom") }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        button.frame = CGRect(x: 0, y: 0, width: size, height: size)
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.isUserInteractionEnabled = false
        addSubview(menuButton)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.3
        button.addGestureRecognizer(hold)
        addSubview(button)
        setScroll(false, force: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setMenu(_ menu: UIMenu) { menuButton.menu = menu }

    /// 메뉴는 기준 뷰를 덮으며 펼쳐진다: 기준을 버튼 바로 위(위쪽 모서리면 바로 아래)의 얇은 띠로 두어 버튼을 가리지 않게 한다
    private func placeMenuAnchor(_ c: CGPoint) {
        let y = bottom ? c.y - size / 2 - 6 : c.y + size / 2 + 5
        menuButton.frame = CGRect(x: c.x - size / 2, y: y, width: size, height: 1)
    }

    @objc private func tapped() { menuButton.performPrimaryAction() }

    /// 스크롤 모드면 위아래 화살표(노란색), 아니면 기본 아이콘
    func setScroll(_ scroll: Bool, force: Bool = false) {
        guard scroll != self.scroll || force else { return }
        self.scroll = scroll
        var c = UIButton.Configuration.glass()
        c.cornerStyle = .capsule
        // 글래스 버튼은 글자색 설정을 덮어써서, 그림 자체에 색을 입힌다
        c.image = UIImage(systemName: scroll ? "arrow.up.and.down" : "ellipsis",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))?
            .withTintColor(scroll ? .systemYellow : .white, renderingMode: .alwaysOriginal)
        button.configuration = c
    }

    /// 버튼 밖 터치는 받지 않는다 (화면으로 간다)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        button.frame.insetBy(dx: -6, dy: -6).contains(point) ? button : nil
    }

    private func corner(right: Bool, bottom: Bool) -> CGPoint {
        let b = bounds, s = safeAreaInsets
        let x = right ? b.width - s.right - margin - size / 2 : s.left + margin + size / 2
        let y = bottom ? b.height - max(s.bottom, margin) - size / 2 : s.top + margin + size / 2
        return CGPoint(x: x, y: y)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if grabStart == nil {
            let c = corner(right: right, bottom: bottom)
            placeMenuAnchor(c)
            UIView.animate(withDuration: 0.25) { self.button.center = c }
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        let now = CACurrentMediaTime()
        switch g.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            grabStart = p
            samples = [(p, now)]
            UIView.animate(withDuration: 0.15) { self.button.transform = CGAffineTransform(scaleX: 1.15, y: 1.15) }
        case .changed:
            guard let s = grabStart else { return }
            // 손가락을 절반만 따라온다: 끌어다 놓기보다 던지는 느낌
            let home = corner(right: right, bottom: bottom)
            button.center = CGPoint(x: home.x + (p.x - s.x) * 0.5, y: home.y + (p.y - s.y) * 0.5)
            samples.append((p, now))
            samples.removeAll { now - $0.t > 0.1 }
        default:
            guard let s = grabStart else { return }
            var v = CGPoint.zero
            if let first = samples.first, now - first.t > 0.01 {
                v = CGPoint(x: (p.x - first.p.x) / (now - first.t), y: (p.y - first.p.y) / (now - first.t))
            }
            // 축마다: 조금이라도 움직였거나 튕겼으면 그 방향 모서리로
            let dx = p.x - s.x, dy = p.y - s.y
            var r = right, btm = bottom
            if abs(dx) > flickDistance || abs(v.x) > flickSpeed { r = (abs(dx) > flickDistance ? dx : v.x) > 0 }
            if abs(dy) > flickDistance || abs(v.y) > flickSpeed { btm = (abs(dy) > flickDistance ? dy : v.y) > 0 }
            if r != right || btm != bottom { UISelectionFeedbackGenerator().selectionChanged() }
            right = r; bottom = btm
            grabStart = nil
            samples = []
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0) {
                self.button.transform = .identity
                self.button.center = self.corner(right: r, bottom: btm)
            }
            placeMenuAnchor(corner(right: r, bottom: btm))
        }
    }
}

/// 마우스 모드 고르기 팝업: 모드마다 조작법을 짧게 보여 준다
struct MouseSettingsView: View {
    let mode: MouseMode
    let choose: (MouseMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("마우스 설정").font(.headline).padding(.bottom, 4)
            ForEach([MouseMode.touch, .trackpad], id: \.self) { m in
                Button { choose(m) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: m.symbol).font(.title2).frame(width: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.title).font(.body.weight(.semibold))
                            Text(m.guide).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if m == mode { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.tint) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 16).fill(m == mode ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
            }
        }
        .padding(20)
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
        if !composing.isEmpty { NotificationCenter.default.post(name: HangulInputField.flushNotification, object: nil) }
    }
    func mouseClick(_ p: CGPoint, button: UInt8) { flushComposition(); previewCursor(p); client?.click(x: Int(p.x), y: Int(p.y), button: button) }
    func mouseDown(_ p: CGPoint) { flushComposition(); previewCursor(p); client?.mouseDown(x: Int(p.x), y: Int(p.y)) }
    func mouseMove(_ p: CGPoint) { previewCursor(p); client?.mouseMove(x: Int(p.x), y: Int(p.y)) }
    func mouseUp(_ p: CGPoint) { previewCursor(p); client?.mouseUp(x: Int(p.x), y: Int(p.y)) }
    /// UI 시험에서는 맥 대신 커서 위치를 바로 옮겨 준다
    private func previewCursor(_ p: CGPoint) { if preview { cursor = p } }
    var serverCursor: CGPoint? { preview ? cursor : client?.cursorPosition }
    /// 프레임버퍼 픽셀 → 맥 포인트 (레티나 모니터는 2픽셀 = 1포인트)
    func mouseScroll(_ dx: CGFloat, _ dy: CGFloat, phase: RFBClient.ScrollPhase, momentum: RFBClient.MomentumPhase) {
        let scale = max(selected?.scale ?? 1, 1)
        client?.scroll(dx: Double(dx / scale), dy: Double(dy / scale), phase: phase, momentum: momentum)
    }
}
