import SwiftUI
import UIKit

/// 마우스 조작 방식
enum MouseMode: String {
    /// 누른 곳을 바로 클릭 (이동은 안 보냄)
    case touch
    /// 화면에 그린 포인터를 끌어서 움직이고, 탭하면 포인터 자리 클릭 (이동을 보냄)
    case trackpad
}

/// 화면 뷰가 맥에 보낼 마우스 동작. 좌표는 프레임버퍼 픽셀
@MainActor
protocol MouseInput: AnyObject {
    func mouseClick(_ p: CGPoint, button: UInt8)
    func mouseDown(_ p: CGPoint)
    func mouseMove(_ p: CGPoint)
    func mouseUp(_ p: CGPoint)
    /// 서버가 알려 준 커서 위치 (트랙패드 포인터 시작점)
    var serverCursor: CGPoint? { get }
    /// 지금 커서 자리에서 스크롤. dx, dy 는 프레임버퍼 픽셀, 양수 dy = 아래로 (내용이 위로)
    func mouseScroll(_ dx: CGFloat, _ dy: CGFloat, phase: RFBClient.ScrollPhase, momentum: RFBClient.MomentumPhase)
}

/// 원격 화면. 처음엔 화면 안에 다 들어오게(contain), 확대는 원본 픽셀(1:1)까지, 축소는 contain 까지.
/// 손동작은 Ai/iVNC.md 8장 설계를 따른다.
struct ScreenView: UIViewRepresentable {
    let renderer: ScreenRenderer
    let mode: MouseMode
    /// 스크롤 모드: 한 손가락 끌기는 스크롤만 (포인터 이동·클릭 없음)
    var scrollMode = false
    /// 맥 커서 위치 (터치 모드에서 큰 포인터로 보여 준다)
    var cursor: CGPoint?
    /// 특이한 맥 커서 모양 (nil 이면 큰 화살표)
    var cursorShape: RFBClient.CursorShape?
    weak var input: MouseInput?

    func makeUIView(context: Context) -> ZoomingImageView {
        let v = ZoomingImageView()
        v.attach(renderer)
        v.input = input
        v.mode = mode
        v.scrollMode = scrollMode
        return v
    }

    func updateUIView(_ v: ZoomingImageView, context: Context) {
        v.input = input
        if v.mode != mode { v.mode = mode }
        if v.scrollMode != scrollMode { v.scrollMode = scrollMode }
        if v.macCursor != cursor { v.macCursor = cursor }
        if v.cursorShape?.image !== cursorShape?.image { v.cursorShape = cursorShape }
    }
}

final class ZoomingImageView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    weak var input: MouseInput?
    var mode: MouseMode = .touch { didSet { applyMode() } }
    var scrollMode = false { didSet { applyMode() } }
    /// 맥 커서 위치. 터치 모드에서는 큰 포인터가 이걸 따라간다 (맥 커서는 너무 작아 잘 안 보인다)
    var macCursor: CGPoint? {
        didSet {
            guard mode == .touch, let c = macCursor else { return }
            pointer = c
            placePointer()
        }
    }

    /// 특이한 맥 커서 모양: 큰 화살표 대신 그 모양을 같은 크기로 보여 준다
    var cursorShape: RFBClient.CursorShape? {
        didSet {
            pointerView.setShape(cursorShape)
            placePointer()
        }
    }

    private let content = LayerHostView()
    private var pixelSize = CGSize.zero
    private var lastBounds = CGSize.zero

    /// 흔들림 허용 (화면 pt): 이 안의 움직임은 "안 움직임"
    private static let slop: CGFloat = 10
    private static let doubleTapTime: TimeInterval = 0.3
    private static let doubleTapDistance: CGFloat = 40

    private let tap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let longPress = UILongPressGestureRecognizer()
    private let trackPan = UIPanGestureRecognizer()
    private let scrollPan = UIPanGestureRecognizer()
    // 스크롤: 이번 손동작의 방향(가로면 true), 직전 이동량, 관성
    private var scrollHorizontal = false
    private var lastScrollTranslation = CGPoint.zero
    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGFloat = 0
    private var momentumStarted = false
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    // 더블 클릭: 직전 탭 (시각, 화면 위치, 보낸 픽셀 좌표)
    private var lastTap: (time: Date, view: CGPoint, pixel: CGPoint)?

    // 길게 누르기: 처음 누른 자리(화면, 픽셀), 드래그 중인지, 트랙패드 포인터 시작점
    private var pressStart: (view: CGPoint, pixel: CGPoint)?
    private var pressPointerStart: CGPoint?
    private var mouseDragging = false
    /// 손가락이 처음 닿은 자리 (길게 누르기의 기준. 인식 시점 위치는 이미 흔들렸을 수 있다)
    private var touchDownPoint: CGPoint?
    private let pressMark = UIView()

    // 트랙패드 포인터 (픽셀 좌표)
    private var pointer: CGPoint?
    private let pointerView = PointerView()
    private var lastMoveSent = Date.distantPast
    private var lastPanTranslation = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        delaysContentTouches = false
        addSubview(content)

        tap.addTarget(self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.addTarget(self, action: #selector(twoFingerTapped(_:)))
        addGestureRecognizer(twoFingerTap)
        longPress.minimumPressDuration = 0.4
        longPress.allowableMovement = Self.slop
        longPress.addTarget(self, action: #selector(longPressed(_:)))
        longPress.delegate = self
        addGestureRecognizer(longPress)
        trackPan.maximumNumberOfTouches = 1
        trackPan.addTarget(self, action: #selector(trackPanned(_:)))
        addGestureRecognizer(trackPan)
        scrollPan.maximumNumberOfTouches = 1
        scrollPan.addTarget(self, action: #selector(scrollPanned(_:)))
        addGestureRecognizer(scrollPan)
        tap.require(toFail: twoFingerTap)
        // 길게 누르기가 실패(10pt 넘게 움직임)해야 화면 이동·포인터 이동이 시작된다
        panGestureRecognizer.require(toFail: longPress)
        trackPan.require(toFail: longPress)

        pressMark.isUserInteractionEnabled = false
        pressMark.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        pressMark.layer.borderColor = UIColor.white.cgColor
        pressMark.layer.borderWidth = 1.5
        pressMark.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        pressMark.layer.cornerRadius = 22
        pressMark.isHidden = true
        addSubview(pressMark)
        pointerView.isHidden = true
        addSubview(pointerView)
        applyMode()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// 키보드에 가려지는 높이. 이만큼 화면을 위로 더 끌어 올릴 수 있게 아래 여백을 준다
    private var keyboardInset: CGFloat = 0

    @objc private func keyboardChanged(_ n: Notification) {
        var overlap: CGFloat = 0
        if n.name != UIResponder.keyboardWillHideNotification,
           let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue, let w = window {
            let mine = convert(bounds, to: w)
            overlap = max(0, mine.maxY - end.minY)
        }
        guard overlap != keyboardInset else { return }
        keyboardInset = overlap
        UIView.animate(withDuration: 0.25) {
            self.centerContent()
            // 키보드가 내려가면 위로 올려 둔 만큼 다시 내린다 (끌 수 있는 범위 안으로)
            let maxY = max(-self.contentInset.top, self.contentSize.height - self.bounds.height + self.contentInset.bottom)
            if self.contentOffset.y > maxY { self.contentOffset.y = maxY }
            self.placePointer()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyMode() {
        // 터치 모드: 한 손가락 끌기 = 화면 이동. 트랙패드 모드: 한 손가락 = 포인터, 두 손가락 끌기 = 화면 이동
        // 스크롤 모드: 한 손가락 = 스크롤, 두 손가락 끌기 = 화면 이동. 클릭·포인터 이동은 모두 끈다
        panGestureRecognizer.minimumNumberOfTouches = mode == .touch && !scrollMode ? 1 : 2
        trackPan.isEnabled = mode == .trackpad && !scrollMode
        twoFingerTap.isEnabled = mode == .trackpad && !scrollMode
        tap.isEnabled = !scrollMode
        longPress.isEnabled = !scrollMode
        scrollPan.isEnabled = scrollMode
        if !scrollMode { stopMomentum() }
        lastTap = nil
        if mode == .trackpad {
            if pointer == nil { placeInitialPointer() }
            pointerView.isHidden = pixelSize == .zero
            placePointer()
        } else {
            // 터치 모드: 큰 포인터는 맥 커서 위치를 보여 주기만 한다
            pointer = macCursor
            pointerView.isHidden = macCursor == nil
            placePointer()
        }
    }

    // MARK: 좌표

    /// 화면(이 뷰) 위치 → 프레임버퍼 픽셀. 그림 밖이면 nil
    private func pixel(at viewPoint: CGPoint) -> CGPoint? {
        guard pixelSize.width > 0 else { return nil }
        let p = convert(viewPoint, to: content)
        let size = content.bounds.size
        guard p.x >= 0, p.y >= 0, p.x < size.width, p.y < size.height else { return nil }
        return CGPoint(x: (p.x * pixelSize.width / size.width).rounded(.down), y: (p.y * pixelSize.height / size.height).rounded(.down))
    }

    private func viewPoint(ofPixel p: CGPoint) -> CGPoint {
        let size = content.bounds.size
        return content.convert(CGPoint(x: p.x * size.width / pixelSize.width, y: p.y * size.height / pixelSize.height), to: self)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: 탭

    /// 클릭은 떼는 순간 바로 보낸다. 짧은 시간 안에 가까운 곳에 두 번째 탭이 오면 첫 탭 좌표로 보내 맥이 더블 클릭으로 알아듣게 한다
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let v = g.location(in: self)
        let target: CGPoint?
        if mode == .trackpad { target = pointer } else { target = pixel(at: v) }
        guard var p = target else { return }
        if let last = lastTap, Date().timeIntervalSince(last.time) < Self.doubleTapTime,
           Self.distance(last.view, v) < Self.doubleTapDistance {
            p = last.pixel
            lastTap = nil // 세 번째 탭은 새로 시작
        } else {
            lastTap = (Date(), v, p)
        }
        input?.mouseClick(p, button: 1)
    }

    @objc private func twoFingerTapped(_ g: UITapGestureRecognizer) {
        guard let p = pointer else { return }
        input?.mouseClick(p, button: 2)
    }

    // MARK: 길게 누르기: 그대로 떼면 오른쪽 클릭, 10pt 넘게 끌면 드래그 (좌표는 처음 누른 자리 기준)

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        let v = g.location(in: self)
        switch g.state {
        case .began:
            let down = touchDownPoint ?? v
            let start: CGPoint?
            if mode == .trackpad { start = pointer } else { start = pixel(at: down) }
            guard let start else { g.state = .cancelled; return }
            pressStart = (down, start)
            pressPointerStart = pointer
            mouseDragging = false
            haptic.impactOccurred()
            pressMark.center = mode == .trackpad ? viewPoint(ofPixel: start) : down
            pressMark.isHidden = false
            bringSubviewToFront(pressMark)
        case .changed:
            guard let s = pressStart else { return }
            if !mouseDragging {
                guard Self.distance(s.view, v) > Self.slop else { return }
                mouseDragging = true
                pressMark.isHidden = true
                input?.mouseDown(s.pixel)
            }
            let p = dragPoint(start: s, now: v)
            if mode == .trackpad { pointer = p; placePointer(); followPointer() }
            sendMove(p, force: false)
        case .ended:
            pressMark.isHidden = true
            guard let s = pressStart else { return }
            if mouseDragging {
                let p = dragPoint(start: s, now: v)
                sendMove(p, force: true)
                input?.mouseUp(p)
            } else {
                input?.mouseClick(s.pixel, button: 2)
            }
            pressStart = nil; mouseDragging = false; lastTap = nil
        default:
            pressMark.isHidden = true
            if mouseDragging, let s = pressStart { input?.mouseUp(dragPoint(start: s, now: v)) }
            pressStart = nil; mouseDragging = false
        }
    }

    /// 드래그 중 맥 좌표: 터치 모드는 손가락 아래, 트랙패드 모드는 처음 포인터 + 손가락 이동량
    private func dragPoint(start s: (view: CGPoint, pixel: CGPoint), now v: CGPoint) -> CGPoint {
        if mode == .touch {
            if let p = pixel(at: v) { return p }
            return clampPixel(CGPoint(x: s.pixel.x + (v.x - s.view.x) * pixelsPerPoint, y: s.pixel.y + (v.y - s.view.y) * pixelsPerPoint))
        }
        let base = pressPointerStart ?? s.pixel
        return clampExact(CGPoint(x: base.x + (v.x - s.view.x) * pixelsPerPoint, y: base.y + (v.y - s.view.y) * pixelsPerPoint))
    }

    /// 화면 1pt 가 프레임버퍼 몇 픽셀인지 (지금 확대 기준)
    private var pixelsPerPoint: CGFloat {
        guard content.bounds.width > 0 else { return 1 }
        return pixelSize.width / content.bounds.width / zoomScale
    }

    /// 화면 안으로만 자른다 (내림 없음). 트랙패드 포인터는 소수점을 유지하고 보낼 때만 정수로 바꾼다
    private func clampExact(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), pixelSize.width - 1), y: min(max(p.y, 0), pixelSize.height - 1))
    }

    private func clampPixel(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), pixelSize.width - 1).rounded(.down), y: min(max(p.y, 0), pixelSize.height - 1).rounded(.down))
    }

    /// 이동은 초당 30번까지만 보낸다 (마지막은 꼭 보낸다)
    private func sendMove(_ p: CGPoint, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastMoveSent) >= 1.0 / 30 else { return }
        lastMoveSent = now
        input?.mouseMove(p)
    }

    // MARK: 스크롤 모드: 한 손가락 끌기로 스크롤 (손가락 방향대로 내용이 움직임, 처음 방향으로 고정, 손 떼면 관성)

    @objc private func scrollPanned(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            stopMomentum()
            scrollHorizontal = abs(t.x) > abs(t.y)
            lastScrollTranslation = .zero
            sendScroll(t, phase: .began)
        case .changed:
            sendScroll(t, phase: .changed)
        case .ended, .cancelled:
            input?.mouseScroll(0, 0, phase: .ended, momentum: .none)
            let v = g.velocity(in: self)
            momentumVelocity = scrollHorizontal ? v.x : v.y
            if g.state == .ended && abs(momentumVelocity) > 150 { startMomentum() }
        default: break
        }
    }

    /// 손가락 이동(pt) → 맥에 보낼 양(픽셀). 손가락이 위로 가면 내용도 위로 = 아래로 스크롤 (양수)
    private func sendScroll(_ t: CGPoint, phase: RFBClient.ScrollPhase) {
        let d = scrollHorizontal ? t.x - lastScrollTranslation.x : t.y - lastScrollTranslation.y
        lastScrollTranslation = t
        let px = -d * pixelsPerPoint
        if scrollHorizontal { input?.mouseScroll(px, 0, phase: phase, momentum: .none) }
        else { input?.mouseScroll(0, px, phase: phase, momentum: .none) }
    }

    private func startMomentum() {
        momentumStarted = false
        let link = CADisplayLink(target: self, selector: #selector(momentumStep(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    /// 손 뗀 속도에서 아이폰처럼 감속한다 (아이폰 기본 감속률 0.998/ms = 1초에 약 13.5% 남음)
    @objc private func momentumStep(_ link: CADisplayLink) {
        let dt = CGFloat(link.targetTimestamp - link.timestamp)
        momentumVelocity *= pow(0.135, dt)
        if abs(momentumVelocity) < 30 { stopMomentum(); return }
        let px = -momentumVelocity * dt * pixelsPerPoint
        let phase: RFBClient.MomentumPhase = momentumStarted ? .continue : .begin
        momentumStarted = true
        if scrollHorizontal { input?.mouseScroll(px, 0, phase: .none, momentum: phase) }
        else { input?.mouseScroll(0, px, phase: .none, momentum: phase) }
    }

    private func stopMomentum() {
        guard let link = momentumLink else { return }
        link.invalidate()
        momentumLink = nil
        if momentumStarted { input?.mouseScroll(0, 0, phase: .none, momentum: .end) }
        momentumStarted = false
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === longPress { touchDownPoint = touch.location(in: self) }
        return true
    }

    // MARK: 트랙패드: 한 손가락 끌기로 포인터 이동 (빠르게 끌면 더 멀리)

    @objc private func trackPanned(_ g: UIPanGestureRecognizer) {
        guard pixelSize.width > 0 else { return }
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            lastPanTranslation = .zero
            if pointer == nil { placeInitialPointer() }
            fallthrough
        case .changed:
            let dx = t.x - lastPanTranslation.x, dy = t.y - lastPanTranslation.y
            lastPanTranslation = t
            let v = g.velocity(in: self)
            let speed = hypot(v.x, v.y)
            let gain = min(max(0.9 + speed / 900, 0.9), 3) // 느리면 손가락만큼, 빠르면 최대 3배
            let p = pointer ?? .zero
            // 소수점까지 쌓는다: 매번 픽셀로 내림하면 천천히 움직일 때(한 번에 1픽셀 미만) 오른쪽·아래로는 안 가고 왼쪽·위로는 더 간다
            pointer = clampExact(CGPoint(x: p.x + dx * gain * pixelsPerPoint, y: p.y + dy * gain * pixelsPerPoint))
            placePointer()
            followPointer()
            sendMove(pointer!, force: false)
        case .ended, .cancelled:
            if let p = pointer { sendMove(p, force: true) }
        default: break
        }
    }

    /// 트랙패드 포인터 시작점: 맥 커서 위치를 알면 거기, 모르면(서버는 커서가 움직일 때만 알려 준다) 화면 가운데에 두고
    /// 맥 커서를 그리로 옮겨 둘을 맞춘다
    private func placeInitialPointer() {
        guard pixelSize.width > 0 else { return }
        if let c = input?.serverCursor {
            pointer = clampPixel(c)
        } else {
            let p = CGPoint(x: (pixelSize.width / 2).rounded(.down), y: (pixelSize.height / 2).rounded(.down))
            pointer = p
            input?.mouseMove(p)
        }
    }

    private func placePointer() {
        guard let p = pointer, pixelSize.width > 0 else { return }
        pointerView.isHidden = false
        let v = viewPoint(ofPixel: p)
        let hot = pointerView.hotspot
        pointerView.frame.origin = CGPoint(x: v.x - hot.x, y: v.y - hot.y) // 화살표 끝(특이 커서는 핫스팟)이 좌표
        bringSubviewToFront(pointerView)
    }

    /// 포인터가 보이는 영역 가장자리(15%)에 닿으면 그 방향으로 화면을 민다
    private func followPointer() {
        guard let p = pointer else { return }
        let v = viewPoint(ofPixel: p)
        let b = bounds
        let visibleMaxY = b.maxY - keyboardInset // 키보드에 가린 부분은 안 보이는 영역
        let mx = b.width * 0.15, my = (b.height - keyboardInset) * 0.15
        var off = contentOffset
        if v.x < b.minX + mx { off.x -= b.minX + mx - v.x }
        if v.x > b.maxX - mx { off.x += v.x - (b.maxX - mx) }
        if v.y < b.minY + my { off.y -= b.minY + my - v.y }
        if v.y > visibleMaxY - my { off.y += v.y - (visibleMaxY - my) }
        let minX = -contentInset.left, maxX = max(minX, contentSize.width - b.width + contentInset.right)
        let minY = -contentInset.top, maxY = max(minY, contentSize.height - b.height + contentInset.bottom)
        off.x = min(max(off.x, minX), maxX)
        off.y = min(max(off.y, minY), maxY)
        if off != contentOffset { contentOffset = off; placePointer() }
    }

    // MARK: 화면 크기·확대

    /// 렌더러의 레이어를 붙이고, 원격 화면 크기가 바뀌면 확대 기준을 다시 잡는다
    func attach(_ r: ScreenRenderer) {
        content.hosted = r
        content.layer.addSublayer(r.layer)
        r.onSizeChange = { [weak self] size in
            self?.pixelSize = size
            self?.resetZoom()
        }
        if r.pixelSize != .zero { pixelSize = r.pixelSize; resetZoom() }
    }

    /// 원본 크기 = 그림 1픽셀이 화면 1픽셀. 포인트로는 픽셀 / 화면 배율.
    private var originalSize: CGSize {
        let s = window?.screen.scale ?? traitCollection.displayScale
        return CGSize(width: pixelSize.width / s, height: pixelSize.height / s)
    }

    /// 최대 확대: 화면에 맞춘 크기의 3배, 또는 맥 1픽셀이 아이폰 1pt 가 될 때까지 중 큰 쪽.
    /// (예전엔 "맥 1픽셀 = 화면 1픽셀"까지라, 배율 1 가상 디스플레이를 3배 화면 아이폰에 맞추면 이미 그 한계라 확대가 안 됐다)
    private func maxZoom(fit: CGFloat) -> CGFloat {
        let s = window?.screen.scale ?? traitCollection.displayScale
        return max(fit * 3, s, 1)
    }

    private func resetZoom() {
        guard pixelSize.width > 0, bounds.width > 0 else { return }
        zoomScale = 1
        content.frame = CGRect(origin: .zero, size: originalSize)
        contentSize = originalSize
        let fit = min(bounds.width / originalSize.width, bounds.height / originalSize.height)
        minimumZoomScale = fit
        maximumZoomScale = maxZoom(fit: fit)
        zoomScale = fit
        centerContent()
        if mode == .trackpad {
            if let p = pointer { pointer = clampPixel(p) } else { placeInitialPointer() }
            placePointer()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds {
            // 회전 등으로 크기가 바뀌면 contain 기준을 다시 잡는다
            let wasMin = zoomScale <= minimumZoomScale + 0.0001
            lastBounds = bounds.size
            guard pixelSize.width > 0 else { return }
            // 뷰 크기가 정해지기 전에 화면 크기가 먼저 왔으면 (고성능은 첫 그림이 뷰보다 먼저 온다) 여기서 처음 잡는다
            if content.bounds.size != originalSize { resetZoom(); return }
            let fit = min(bounds.width / originalSize.width, bounds.height / originalSize.height)
            minimumZoomScale = fit
            maximumZoomScale = maxZoom(fit: fit)
            if wasMin || zoomScale < fit { zoomScale = fit }
        }
        centerContent()
        placePointer()
    }

    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy + keyboardInset, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent(); placePointer() }
}

/// 트랙패드 모드 포인터: 흰 화살표에 검은 테두리 (끝이 왼쪽 위)
final class PointerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 18, height: 26))
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 2, y: 1))
        path.addLine(to: CGPoint(x: 2, y: 21))
        path.addLine(to: CGPoint(x: 7, y: 16.5))
        path.addLine(to: CGPoint(x: 10.5, y: 24))
        path.addLine(to: CGPoint(x: 13.5, y: 22.5))
        path.addLine(to: CGPoint(x: 10, y: 15))
        path.addLine(to: CGPoint(x: 16, y: 15))
        path.close()
        shape.path = path.cgPath
        shape.fillColor = UIColor.white.cgColor
        shape.strokeColor = UIColor.black.cgColor
        shape.lineWidth = 1.2
        shape.shadowOpacity = 0.4
        shape.shadowRadius = 1.5
        shape.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(shape)
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.shadowOpacity = 0.4
        imageLayer.shadowRadius = 1.5
        imageLayer.shadowOffset = CGSize(width: 0, height: 1)
        imageLayer.isHidden = true
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    private let shape = CAShapeLayer()
    private let imageLayer = CALayer()
    /// 뷰 안에서 가리키는 점 (화살표 끝, 특이 커서는 핫스팟)
    private(set) var hotspot = CGPoint(x: 2, y: 1)

    /// 특이한 맥 커서 모양을 보여 준다. nil 이면 큰 화살표로 돌아간다
    func setShape(_ s: RFBClient.CursorShape?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let s, s.image.width > 0, s.image.height > 0 else {
            imageLayer.isHidden = true
            shape.isHidden = false
            frame.size = CGSize(width: 18, height: 26)
            hotspot = CGPoint(x: 2, y: 1)
            return
        }
        // 그림 픽셀 → 화면 pt (그림마다 정해진 배율. 맥이 보낸 그림은 원래 크기의 1.2배, 앱이 그린 것은 26pt)
        let k = 1 / max(s.scale, 0.01)
        let size = CGSize(width: CGFloat(s.image.width) * k, height: CGFloat(s.image.height) * k)
        frame.size = size
        imageLayer.frame = CGRect(origin: .zero, size: size)
        imageLayer.contents = s.image
        imageLayer.isHidden = false
        shape.isHidden = true
        hotspot = CGPoint(x: s.hotspot.x * k, y: s.hotspot.y * k)
    }
}

/// 렌더러 레이어를 담는 뷰: 크기가 바뀌면 렌더러 레이어를 맞춘다 (확대는 이 뷰의 변환으로)
final class LayerHostView: UIView {
    weak var hosted: ScreenRenderer?
    override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.layout(bounds: bounds)
    }
}
