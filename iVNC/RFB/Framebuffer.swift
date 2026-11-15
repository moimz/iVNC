import CoreGraphics
import Foundation

/// 서버 화면 픽셀 (32bpp, 메모리 순서 B G R X). 수신 스레드가 쓰고 화면 쪽이 복사해 간다.
final class Framebuffer {
    private(set) var width = 0
    private(set) var height = 0
    private(set) var pixels: UnsafeMutablePointer<UInt32>?
    private let lock = NSLock()
    /// 화면 쪽이 아직 가져가지 않은 바뀐 영역 (픽셀)
    private var dirty: CGRect?

    deinit { pixels?.deallocate() }

    func resize(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        guard width != self.width || height != self.height else { return }
        pixels?.deallocate()
        self.width = width
        self.height = height
        if width > 0 && height > 0 {
            let p = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
            p.initialize(repeating: 0xFF000000, count: width * height)
            pixels = p
        } else {
            pixels = nil
        }
        dirty = CGRect(x: 0, y: 0, width: width, height: height)
    }

    func markDirty(x: Int, y: Int, w: Int, h: Int) {
        lock.lock(); defer { lock.unlock() }
        let r = CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isEmpty else { return }
        dirty = dirty.map { $0.union(r) } ?? r
    }

    /// 바뀐 영역을 가져가고 비운다
    func takeDirty() -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        let d = dirty; dirty = nil
        return d
    }

    /// 잠근 채로 픽셀을 고친다. 사각형이 화면 밖이면 잘라낸다.
    func withPixels(_ body: (UnsafeMutablePointer<UInt32>, Int, Int) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let p = pixels { body(p, width, height) }
    }

    /// 화면 쪽(메인 스레드)용: 잠금이 비어 있을 때만 바뀐 영역을 가져가며 픽셀을 읽는다.
    /// 수신 스레드가 큰 화면을 푸는 동안(잠근 채) 메인 스레드가 기다리면 앱이 멈춘다(무지개 커서) → 못 잡으면 false, 다음에 다시
    func tryRead(_ body: (_ dirty: CGRect?, UnsafeMutablePointer<UInt32>, Int, Int) -> Void) -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        let d = dirty; dirty = nil
        if let p = pixels { body(d, p, width, height) }
        return true
    }

    /// 지금 화면을 복사한 그림
    func makeImage() -> CGImage? {
        lock.lock()
        guard let p = pixels, width > 0, height > 0 else { lock.unlock(); return nil }
        let data = Data(bytes: p, count: width * height * 4)
        let w = width, h = height
        lock.unlock()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
