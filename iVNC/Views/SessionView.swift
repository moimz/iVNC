import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var mouseSettings = false
    /// 마우스 설정 팝업 높이 (안의 내용을 재서 맞춘다)
    @State private var mouseSettingsHeight: CGFloat = 320
    /// 모니터 바꾸기 팝업
    @State private var displaySettings = false
    @State private var displaySettingsHeight: CGFloat = 300

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
                    FloatingMenuButton(scroll: model.scrollMode, menu: menu, endScroll: { model.scrollMode = false })
                        .ignoresSafeArea(.container) // 키보드가 뜨면 그 위로 올라가게 (키보드 영역은 피한다)
                }
            }
        }
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
                .fittedSheet(height: $mouseSettingsHeight, regular: sizeClass == .regular)
        }
        .sheet(isPresented: $displaySettings) {
            DisplayPickerView(computer: model.computer, displays: model.displays, title: "모니터 바꾸기", current: model.selected, compact: true) {
                displaySettings = false
                if $0 != model.selected { model.select($0) }
            }
            .fittedSheet(height: $displaySettingsHeight, regular: sizeClass == .regular)
        }
        .statusBarHidden(model.phase == .viewing)
        .preferredColorScheme(.dark)
        // 시스템이 키보드를 내리면 키보드 버튼 상태도 맞춘다 (안 그러면 다음에 누를 때 거꾸로 동작한다)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in model.typing = false }
        .onChange(of: scenePhase) { _, p in
            if p == .background { model.enterBackground() } else if p == .active { model.enterForeground() }
        }
        .onChange(of: model.ended) { _, e in if e { dismiss() } }
        // 화면을 보는 동안은 손을 안 대도(영상·작업 지켜보기) 기기가 잠기지 않게
        .onChange(of: model.phase == .viewing, initial: true) { _, viewing in UIApplication.shared.isIdleTimerDisabled = viewing }
        .onAppear { model.connect(store: store) }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.close()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .connecting(let status):
            VStack(spacing: 16) {
                Text(model.computer.name).font(.title2.weight(.semibold)).lineLimit(1)
                ProgressView().controlSize(.large)
                Text(status).foregroundStyle(.secondary)
                cancelButton
                    .padding(.top, 12)
            }
            .padding(.horizontal, 24)
        case .picking:
            VStack(spacing: 0) {
                DisplayPickerView(computer: model.computer, displays: model.displays) { model.select($0) }
                    .padding(.top, 56)
                cancelButton
                    .padding(.bottom, 24)
            }
        case .viewing:
            ZStack {
                ScreenView(renderer: model.renderer, mode: model.mouseMode, scrollMode: model.scrollMode, cursor: model.cursor, cursorShape: model.cursorShape, input: model)
                    .ignoresSafeArea()
                KeyInputField(active: $model.typing, onText: model.sendText, onBackspace: model.sendBackspace, onReturn: model.sendReturn,
                              onPending: { model.composing = $0 }, onKey: model.sendKey, onCombo: model.sendCombo, menu: menu)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                if !model.hasImage { ProgressView().controlSize(.large) }
                // 우상단 통신량: 느릴 때 맥이 덜 보내는 건지 받는 쪽이 막힌 건지 보려고
                if !model.trafficText.isEmpty {
                    Text(model.trafficText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.35), in: .capsule)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 4)
                        .padding(.trailing, 8)
                        .allowsHitTesting(false)
                }
            }
        case .failed(let msg):
            ContentUnavailableView {
                Label("접속하지 못했습니다", systemImage: "exclamationmark.triangle")
            } description: {
                Text(msg)
            } actions: {
                Button("다시 시도") { model.connect(store: store) }.buttonStyle(.borderedProminent)
                Button("닫기") { end() }
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
            tools.append(UIAction(title: "모니터 바꾸기", image: UIImage(systemName: "display.2")) { _ in displaySettings = true })
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

    /// 접속 전 화면(접속 중·모니터 고르기)의 나가기 버튼: 살짝 붉은 글래스
    private var cancelButton: some View {
        Button { end() } label: {
            Text("접속 취소").padding(.horizontal, 8)
        }
        .buttonStyle(.glassProminent)
        .tint(.red.opacity(0.55))
    }

    private func end() {
        model.close()
        dismiss()
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
    /// 스크롤 모드일 때 버튼을 누르면 메뉴 대신 이걸 부른다 (스크롤 모드 끄기)
    var endScroll: () -> Void = {}

    func makeUIView(context: Context) -> FloatingButtonHost { FloatingButtonHost() }

    func updateUIView(_ v: FloatingButtonHost, context: Context) {
        v.setMenu(menu)
        v.endScroll = endScroll
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
    var endScroll: () -> Void = {}
    /// 첫 배치를 마쳤는지
    private var placed = false
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

    /// 스크롤 모드면 바로 끈다 (노란 화살표 버튼 = 스크롤 모드 끄기). 아니면 메뉴
    @objc private func tapped() {
        if scroll { endScroll() } else { menuButton.performPrimaryAction() }
    }

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
            // 처음에는 제자리에 바로 놓는다 (애니메이션하면 화면 원점에서 날아온다). 그 뒤 크기가 바뀔 때만 움직인다
            if placed {
                UIView.animate(withDuration: 0.25) { self.button.center = c }
            } else if bounds.width > 0 {
                button.center = c
                placed = true
            }
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

/// 팝업을 안의 내용 크기에 맞춘다.
/// 아이폰(좁은 화면)은 아래에서 올라오는 시트를 내용 높이로, 아이패드(넓은 화면)는 화면 가운데 카드를 내용 크기로 (애플 기본 모양)
private struct FittedSheet: ViewModifier {
    @Binding var height: CGFloat
    /// 띄우는 화면이 넓은지 (시트 안쪽은 아이패드에서도 좁은 화면으로 알려 주어 바깥에서 받는다)
    let regular: Bool

    func body(content: Content) -> some View {
        if regular {
            content
                .frame(width: 520)
                .fixedSize(horizontal: false, vertical: true)
                .presentationSizing(.fitted)
        } else {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .presentationDetents([.height(height)])
        }
    }
}

extension View {
    fileprivate func fittedSheet(height: Binding<CGFloat>, regular: Bool) -> some View { modifier(FittedSheet(height: height, regular: regular)) }
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
