import CoreGraphics
import Foundation

/// 서버 화면 픽셀 (32bpp, 메모리 순서 B G R X). 수신 스레드가 쓰고 화면 쪽이 복사해 간다.
final class Framebuffer {
    private(set) var width = 0
    private(set) var height = 0
    private(set) var pixels: UnsafeMutablePointer<UInt32>?
    private let lock = NSLock()

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
    }

    /// 잠근 채로 픽셀을 고친다. 사각형이 화면 밖이면 잘라낸다.
    func withPixels(_ body: (UnsafeMutablePointer<UInt32>, Int, Int) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let p = pixels { body(p, width, height) }
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
