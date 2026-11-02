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

    init(computer: Computer) {
        self.computer = computer
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
        guard let pw = Keychain.password(for: computer.id) else {
            phase = .failed("저장된 암호가 없습니다. 컴퓨터를 길게 눌러 편집에서 암호를 입력하세요.")
            return
        }
        let c = RFBClient(host: computer.host, port: computer.port, username: computer.username, password: pw,
                          tryHighPerformance: !standardOnly && !UserDefaults.standard.bool(forKey: "debug.hpOff"))
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

    func select(_ d: RemoteDisplay) {
        saveThumbnail()
        selected = d
        phase = .viewing
        client?.select(display: d.id)
    }

    func backToPicker() {
        saveThumbnail()
        client?.pause()
        phase = .picking
    }

    /// 마우스 조작 방식 (컴퓨터별로 기억)
    @Published private(set) var mouseMode: MouseMode = .touch

    func toggleMouseMode() {
        mouseMode = mouseMode == .touch ? .trackpad : .touch
        UserDefaults.standard.set(mouseMode.rawValue, forKey: "mouseMode." + computer.id.uuidString)
    }
    func sendText(_ t: String) { client?.sendText(t) }
    func sendBackspace(_ n: Int) { for _ in 0..<n { client?.sendSpecialKey(0xFF08, name: "BackSpace") } }
    func sendReturn() { client?.sendSpecialKey(0xFF0D, name: "Return") }

    func close() {
        saveThumbnail()
        client?.stop()
        client = nil
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
    /// 떠 있는 버튼으로 연 앱 UI (보는 중에는 이게 켜져야 위 막대가 보인다)
    @State private var menuVisible = false

    init(computer: Computer) {
        _model = StateObject(wrappedValue: SessionModel(computer: computer))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .overlay {
            if model.phase == .viewing {
                // 앱 UI 가 떠 있을 때: 기능 버튼이 아닌 곳을 누르면 UI 만 닫는다 (맥에는 안 보낸다)
                if menuVisible {
                    Button { setMenu(false) } label: {
                        Color.black.opacity(0.2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .ignoresSafeArea()
                }
                // 떠 있는 버튼: 이 버튼의 터치는 맥에 안 보낸다
                FloatingMenuButton(open: menuVisible) { setMenu(!menuVisible) }
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) { if menuVisible || model.phase != .viewing { topBar } }
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            if model.triedHighPerformance {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(DebugLog.recent.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(6)
                        .background(.black.opacity(0.7))
                }
                .padding(.bottom, 30)
                .allowsHitTesting(false)
            }
        }
        #endif
        .statusBarHidden(model.phase == .viewing && !menuVisible)
        .preferredColorScheme(.dark)
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
                ScreenView(renderer: model.renderer, mode: model.mouseMode, input: model)
                    .ignoresSafeArea()
                KeyInputField(active: $model.typing, onText: model.sendText, onBackspace: model.sendBackspace, onReturn: model.sendReturn)
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

    private func setMenu(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { menuVisible = on }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { model.close(); dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            Text(title).font(.headline).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 36)
                .glassEffect()
            if model.isHighPerformance {
                Label("고성능", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10).frame(height: 28)
                    .glassEffect()
            }
            Spacer()
            if model.phase == .viewing {
                Button { model.toggleMouseMode(); setMenu(false) } label: {
                    Image(systemName: model.mouseMode == .touch ? "hand.point.up.left" : "rectangle.and.hand.point.up.left").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(model.mouseMode == .touch ? "터치 모드" : "트랙패드 모드")
                Button { model.typing.toggle(); setMenu(false) } label: {
                    Image(systemName: model.typing ? "keyboard.chevron.compact.down" : "keyboard").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            if model.phase == .viewing && model.displays.count > 1 && !model.isHighPerformance {
                Button { setMenu(false); model.backToPicker() } label: {
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

/// 떠 있는 버튼 (AssistiveTouch 처럼): 끌면 따라오고 놓으면 가까운 좌우 가장자리에 붙는다. 위치를 기억한다.
/// UIKit 으로 만든다: SwiftUI 버튼에 끌기 손동작을 붙이면 탭이 먹지 않았다. 버튼 밖 터치는 아래(화면)로 그대로 보낸다
struct FloatingMenuButton: UIViewRepresentable {
    let open: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> FloatingButtonHost {
        let v = FloatingButtonHost()
        v.action = action
        return v
    }

    func updateUIView(_ v: FloatingButtonHost, context: Context) {
        v.action = action
        v.setOpen(open)
    }
}

final class FloatingButtonHost: UIView {
    var action: () -> Void = {}
    private let button = UIButton(type: .custom)
    private let size: CGFloat = 54
    private var dragStart: CGPoint?

    private var right: Bool {
        get { UserDefaults.standard.object(forKey: "floatingButton.right") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "floatingButton.right") }
    }
    private var yFraction: CGFloat {
        get { UserDefaults.standard.object(forKey: "floatingButton.y") as? CGFloat ?? 0.82 }
        set { UserDefaults.standard.set(newValue, forKey: "floatingButton.y") }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        button.frame = CGRect(x: 0, y: 0, width: size, height: size)
        button.layer.cornerRadius = size / 2
        button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        button.layer.borderWidth = 1
        button.tintColor = .white
        button.alpha = 0.75
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        button.addGestureRecognizer(pan)
        addSubview(button)
        setOpen(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setOpen(_ open: Bool) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        button.setImage(UIImage(systemName: open ? "xmark" : "circle.grid.2x2.fill", withConfiguration: cfg), for: .normal)
        button.alpha = open ? 1 : 0.75
    }

    /// 버튼 밖 터치는 받지 않는다 (화면으로 간다)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        button.frame.insetBy(dx: -6, dy: -6).contains(point) ? button : nil
    }

    private func restingCenter() -> CGPoint {
        let b = bounds
        let x = right ? b.width - size / 2 - 6 : size / 2 + 6
        let y = min(max(yFraction * b.height, size), b.height - size / 2 - 6)
        return CGPoint(x: x, y: y)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if dragStart == nil { button.center = restingCenter() }
    }

    @objc private func tapped() { action() }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            dragStart = button.center
            button.alpha = 1
        case .changed:
            guard let s = dragStart else { return }
            let t = g.translation(in: self)
            button.center = CGPoint(x: s.x + t.x, y: s.y + t.y)
        default:
            right = button.center.x > bounds.width / 2
            yFraction = min(max(button.center.y / bounds.height, 0.08), 0.95)
            dragStart = nil
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                self.button.center = self.restingCenter()
            }
            button.alpha = 0.75
        }
    }
}

extension SessionModel: MouseInput {
    func mouseClick(_ p: CGPoint, button: UInt8) { client?.click(x: Int(p.x), y: Int(p.y), button: button) }
    func mouseDown(_ p: CGPoint) { client?.mouseDown(x: Int(p.x), y: Int(p.y)) }
    func mouseMove(_ p: CGPoint) { client?.mouseMove(x: Int(p.x), y: Int(p.y)) }
    func mouseUp(_ p: CGPoint) { client?.mouseUp(x: Int(p.x), y: Int(p.y)) }
    var serverCursor: CGPoint? { client?.cursorPosition }
}
