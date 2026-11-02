import SwiftUI
import UIKit

/// 원격 화면. 처음엔 화면 안에 다 들어오게(contain), 핀치로 확대는 원본 픽셀(1:1)까지, 축소는 contain 까지.
/// 한 손가락 탭은 그 자리 클릭, 두 손가락 탭은 위 막대 보이기·숨기기.
struct ScreenView: UIViewRepresentable {
    let image: CGImage?
    var onClick: (CGPoint) -> Void = { _ in }
    var onTwoFingerTap: () -> Void = {}

    func makeUIView(context: Context) -> ZoomingImageView {
        let v = ZoomingImageView()
        v.onClick = onClick
        v.onTwoFingerTap = onTwoFingerTap
        return v
    }

    func updateUIView(_ v: ZoomingImageView, context: Context) {
        v.onClick = onClick
        v.onTwoFingerTap = onTwoFingerTap
        v.setImage(image)
    }
}

final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    var onClick: (CGPoint) -> Void = { _ in }
    var onTwoFingerTap: () -> Void = {}
    private let content = UIView()
    private var pixelSize = CGSize.zero
    private var lastBounds = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        content.layer.magnificationFilter = .nearest // 원본 근처에서 글자가 또렷하게
        content.layer.minificationFilter = .trilinear
        addSubview(content)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        let two = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
        two.numberOfTouchesRequired = 2
        addGestureRecognizer(two)
        tap.require(toFail: two)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 탭한 자리를 그림의 픽셀 좌표로 바꿔 알린다. 그림 밖이면 무시.
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard pixelSize.width > 0 else { return }
        let p = g.location(in: content)
        let size = content.bounds.size
        guard p.x >= 0, p.y >= 0, p.x < size.width, p.y < size.height else { return }
        onClick(CGPoint(x: p.x * pixelSize.width / size.width, y: p.y * pixelSize.height / size.height))
    }

    @objc private func twoFingerTapped() { onTwoFingerTap() }

    func setImage(_ image: CGImage?) {
        content.layer.contents = image
        guard let image else { return }
        let size = CGSize(width: image.width, height: image.height)
        if size != pixelSize {
            pixelSize = size
            resetZoom()
        }
    }

    /// 원본 크기 = 그림 1픽셀이 화면 1픽셀. 포인트로는 픽셀 / 화면 배율.
    private var originalSize: CGSize {
        let s = window?.screen.scale ?? traitCollection.displayScale
        return CGSize(width: pixelSize.width / s, height: pixelSize.height / s)
    }

    private func resetZoom() {
        guard pixelSize.width > 0, bounds.width > 0 else { return }
        zoomScale = 1
        content.frame = CGRect(origin: .zero, size: originalSize)
        contentSize = originalSize
        let fit = min(bounds.width / originalSize.width, bounds.height / originalSize.height)
        minimumZoomScale = fit
        maximumZoomScale = max(1, fit)
        zoomScale = fit
        centerContent()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds {
            // 회전 등으로 크기가 바뀌면 contain 기준을 다시 잡는다
            let wasMin = zoomScale <= minimumZoomScale + 0.0001
            lastBounds = bounds.size
            guard pixelSize.width > 0 else { return }
            let fit = min(bounds.width / originalSize.width, bounds.height / originalSize.height)
            minimumZoomScale = fit
            maximumZoomScale = max(1, fit)
            if wasMin || zoomScale < fit { zoomScale = fit }
        }
        centerContent()
    }

    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }
}
