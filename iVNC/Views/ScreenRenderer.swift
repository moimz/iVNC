import CoreImage
import CoreVideo
import QuartzCore
import UIKit

/// 원격 화면을 SwiftUI 를 거치지 않고 레이어에 바로 그린다 (속도 우선).
/// - 일반: IOSurface 버퍼 둘을 번갈아 쓰며 바뀐 영역만 복사한다 (같은 버퍼를 다시 넣으면 레이어가 새로 안 그린다).
/// - 고성능: 디코더가 내놓은 줄무늬 픽셀 버퍼를 복사 없이 줄무늬 레이어에 바로 넣는다.
@MainActor
final class ScreenRenderer {
    /// 원격 화면 픽셀 크기가 바뀌면 (확대 기준을 다시 잡으려고)
    var onSizeChange: ((CGSize) -> Void)?
    /// 처음 그림이 나왔을 때
    var onFirstImage: (() -> Void)?

    private(set) var pixelSize = CGSize.zero
    let layer = CALayer()
    private var stripeLayers: [CALayer] = []

    // 일반
    private var buffers: [CVPixelBuffer] = []
    private var pending: [CGRect?] = [nil, nil]
    private var front = 0
    // 고성능: 지금 보이는 줄무늬 (레이어가 쓰는 동안 디코더 풀이 다시 쓰지 않게 붙잡아 둔다)
    private var stripeBuffers: [CVPixelBuffer?] = []
    private var shown = false
    private var loggedStripe = false

    init() {
        layer.isOpaque = true
        layer.backgroundColor = UIColor.black.cgColor
        layer.magnificationFilter = .nearest // 원본 근처에서 글자가 또렷하게
        layer.minificationFilter = .trilinear
    }

    private func setSize(_ size: CGSize) {
        guard size != pixelSize else { return }
        pixelSize = size
        onSizeChange?(size)
    }

    private func first() {
        if !shown { shown = true; onFirstImage?() }
    }

    /// 레이어 크기가 정해지면 줄무늬 레이어를 맞춘다
    func layout(bounds: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = bounds
        let n = stripeLayers.count
        for (i, l) in stripeLayers.enumerated() {
            l.frame = CGRect(x: 0, y: bounds.height * CGFloat(i) / CGFloat(n), width: bounds.width, height: bounds.height / CGFloat(n))
        }
        CATransaction.commit()
    }

    // MARK: 일반

    private static func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return pb
    }

    /// 프레임버퍼의 바뀐 영역을 뒤 버퍼에 복사하고 앞으로 내놓는다
    func presentStandard(_ fb: Framebuffer) {
        if !stripeLayers.isEmpty { clearStripes() }
        let dirty = fb.takeDirty()
        var ok = false
        fb.withPixels { p, w, h in
            if buffers.count != 2 || CVPixelBufferGetWidth(buffers[0]) != w || CVPixelBufferGetHeight(buffers[0]) != h {
                buffers = [Self.makeBuffer(w, h), Self.makeBuffer(w, h)].compactMap { $0 }
                let all = CGRect(x: 0, y: 0, width: w, height: h)
                pending = [all, all]
            } else if let dirty {
                pending = pending.map { $0.map { $0.union(dirty) } ?? dirty }
            }
            guard buffers.count == 2 else { return }
            let back = 1 - front
            guard let r = pending[back], !r.isEmpty else { return }
            let pb = buffers[back]
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let x0 = Int(r.minX), x1 = Int(r.maxX)
            for y in Int(r.minY)..<Int(r.maxY) {
                let src = p + y * w + x0
                let dst = (base + y * bpr).assumingMemoryBound(to: UInt32.self) + x0
                // 알파 자리를 채운다 (서버가 보낸 X 바이트가 0 이면 투명하게 보인다)
                for i in 0..<(x1 - x0) { dst[i] = src[i] | 0xFF00_0000 }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            pending[back] = nil
            front = back
            ok = true
        }
        guard ok else { return }
        setSize(CGSize(width: CVPixelBufferGetWidth(buffers[front]), height: CVPixelBufferGetHeight(buffers[front])))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = CVPixelBufferGetIOSurface(buffers[front])?.takeUnretainedValue()
        CATransaction.commit()
        first()
    }

    // MARK: 고성능

    func presentStripe(_ pb: CVPixelBuffer, stripe: Int, stripes: Int) {
        if stripeLayers.count != stripes {
            clearStripes()
            layer.contents = nil
            buffers = []
            for _ in 0..<stripes {
                let l = CALayer()
                l.isOpaque = true
                l.magnificationFilter = .nearest
                l.minificationFilter = .trilinear
                layer.addSublayer(l)
                stripeLayers.append(l)
            }
            stripeBuffers = Array(repeating: nil, count: stripes)
            layout(bounds: layer.frame)
        }
        guard stripe < stripes else { return }
        setSize(CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb) * stripes))
        stripeBuffers[stripe] = pb
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stripeLayers[stripe].contents = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
        CATransaction.commit()
        if !loggedStripe && stripe == stripes - 1 {
            loggedStripe = true
            DebugLog.write("HP 줄무늬 레이어: 전체 \(layer.frame), 마지막 \(stripeLayers[stripe].frame), 상위 \(layer.superlayer != nil ? "붙음" : "없음"), IOSurface \(stripeLayers[stripe].contents != nil ? "있음" : "없음")")
        }
        first()
    }

    private func clearStripes() {
        stripeLayers.forEach { $0.removeFromSuperlayer() }
        stripeLayers = []
        stripeBuffers = []
    }

    // MARK: 썸네일

    /// 지금 보이는 화면 그림
    func snapshot(_ fb: Framebuffer) -> CGImage? {
        guard !stripeBuffers.isEmpty else { return fb.makeImage() }
        let ctx = CIContext()
        var image = CIImage.empty()
        let n = stripeBuffers.count
        for (i, pb) in stripeBuffers.enumerated() {
            guard let pb else { continue }
            let h = CGFloat(CVPixelBufferGetHeight(pb))
            // CIImage 는 아래가 원점: 첫 줄무늬가 맨 위
            image = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(translationX: 0, y: h * CGFloat(n - 1 - i))).composited(over: image)
        }
        return ctx.createCGImage(image, from: CGRect(origin: .zero, size: pixelSize))
    }
}
