import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// 애플 커서 모양 (의사 인코딩 1104, noVNC-ARD `_ardHandleCursorAlpha` 를 따름).
///
/// 사각형 x,y = 핫스팟, w,h = 크기. 내용: [u32 커서 id][u32 데이터 크기][zlib 데이터].
/// - id >= 1000 이고 데이터가 있으면 새 그림: 풀면 BGRX w*h*4 바이트 + 알파 w*h 바이트. id 로 기억해 둔다.
/// - id >= 1000 이고 데이터가 없으면 기억해 둔 그림을 다시 쓴다.
/// - id < 1000 은 미리 정해진 커서 (0 기본 화살표, 1 글자 입력, 2 십자, 3·4 잡기, 5 손가락, 6 기다림, 7 도움말, 8 금지, 9 이동, 10 위아래 크기, 11 좌우 크기).
final class ArdCursorDecoder {
    private var cache: [UInt32: RFBClient.CursorShape?] = [:]

    /// 화살표 계열이면 nil (앱의 큰 화살표를 쓴다)
    func decode(id: UInt32, data: [UInt8], x: Int, y: Int, w: Int, h: Int) -> RFBClient.CursorShape? {
        if id < 1000 { return Self.predefined(id) }
        if data.isEmpty { return cache[id] ?? nil }
        guard w > 0, h > 0, let raw = try? Inflater().inflate(data), raw.count >= w * h * 5 else { return nil }
        let fp = Self.fingerprint(raw.prefix(w * h * 5), w: w, h: h, hotX: x, hotY: y)
        let shape: RFBClient.CursorShape?
        if let kind = Self.known[fp] {
            // 알아본 맥 커서: 앱 자체 그림으로 (선명하게)
            shape = Self.predefined(kind)
            DebugLog.write("커서 지문 \(fp) → 알려진 커서 \(kind)")
        } else {
            shape = Self.image(raw: raw, w: w, h: h, hotX: x, hotY: y)
            Self.save(raw: raw, w: w, h: h, fingerprint: fp)
            DebugLog.write("커서 지문 \(fp) \(w)x\(h) 핫스팟 \(x),\(y) → 모르는 커서 (그림 저장)")
        }
        cache[id] = shape
        return shape
    }

    /// 맥 커서 그림의 지문 → 앱이 그릴 커서 번호 (predefined 와 같은 번호, 12·13 은 대각선 크기 조절로 앱 전용).
    /// 2026-11-06 맥(macOS 27, 배율 1 가상 디스플레이)에서 모은 그림 `Ai/iVNC/cursors/` 를 보고 채움
    static let known: [String: UInt32] = [
        "23x22h12.11-9f7cb0c7": 1,   // 글자 입력 I자
        "32x32h12.8-7420cc8b": 5,    // 손가락
        "18x28h9.14-47055ebd": 10,   // 위아래 크기 조절
        "24x18h12.9-26d10133": 11,   // 좌우 크기 조절
        "22x22h11.11-05428677": 12,  // 대각선 ⤢ (왼쪽 아래 ↔ 오른쪽 위)
        "22x22h11.11-e69f3afd": 13,  // 대각선 ⤡ (왼쪽 위 ↔ 오른쪽 아래)
        "28x40h5.5-44de6d33": 0,     // 화살표
    ]

    /// 크기·핫스팟·그림 내용으로 만든 짧은 지문
    static func fingerprint(_ raw: ArraySlice<UInt8>, w: Int, h: Int, hotX: Int, hotY: Int) -> String {
        let digest = SHA256.hash(data: Data(raw))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(w)x\(h)h\(hotX).\(hotY)-\(hex)"
    }

    /// 모르는 커서 그림을 Caches/cursors/<지문>.png 로 남긴다 (나중에 보고 표에 넣으려고)
    private static func save(raw: [UInt8], w: Int, h: Int, fingerprint: String) {
        let n = w * h
        var bgra = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            let a = Int(raw[n * 4 + i])
            bgra[i * 4] = UInt8(Int(raw[i * 4]) * a / 255)
            bgra[i * 4 + 1] = UInt8(Int(raw[i * 4 + 1]) * a / 255)
            bgra[i * 4 + 2] = UInt8(Int(raw[i * 4 + 2]) * a / 255)
            bgra[i * 4 + 3] = UInt8(a)
        }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = pngData(cg) else { return }
        let dir = AppDirectories.caches.appendingPathComponent("cursors")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent("\(fingerprint).png"))
    }

    /// 핫스팟이 왼쪽 위 1/4 안이면 화살표 계열로 본다
    private static func image(raw: [UInt8], w: Int, h: Int, hotX: Int, hotY: Int) -> RFBClient.CursorShape? {
        if Double(hotX) <= Double(w) * 0.25 && Double(hotY) <= Double(h) * 0.25 { return nil }
        let n = w * h
        var bgra = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            let a = Int(raw[n * 4 + i])
            // 미리 곱한 알파 (CGImage premultipliedFirst)
            bgra[i * 4] = UInt8(Int(raw[i * 4]) * a / 255)
            bgra[i * 4 + 1] = UInt8(Int(raw[i * 4 + 1]) * a / 255)
            bgra[i * 4 + 2] = UInt8(Int(raw[i * 4 + 2]) * a / 255)
            bgra[i * 4 + 3] = UInt8(a)
        }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return smooth(RFBClient.CursorShape(image: image, hotspot: CGPoint(x: hotX, y: hotY)))
    }

    /// 맥이 보내는 커서 그림은 배율 1 이라 작다 (23x22 등). 3배로 부드럽게 키워 두고, 화면에는 원래 픽셀당 1.2pt 로 보인다
    static let ciContext = CIContext()
    static func smooth(_ s: RFBClient.CursorShape) -> RFBClient.CursorShape {
        let up: CGFloat = 3
        let input = CIImage(cgImage: s.image)
        guard let f = CIFilter(name: "CILanczosScaleTransform") else { return s }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(up, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let out = f.outputImage,
              let cg = ciContext.createCGImage(out, from: CGRect(x: 0, y: 0, width: CGFloat(s.image.width) * up, height: CGFloat(s.image.height) * up)) else { return s }
        return RFBClient.CursorShape(image: cg, hotspot: CGPoint(x: s.hotspot.x * up, y: s.hotspot.y * up), scale: up / 1.2)
    }

    /// 미리 정해진 커서: 화살표 계열은 nil, 나머지는 앱이 맥 모양을 본떠 높은 해상도로 그린다 (핫스팟은 가운데, 손가락은 손끝)
    private static func predefined(_ id: UInt32) -> RFBClient.CursorShape? {
        let symbol: String
        var hot = CGPoint(x: 0.5, y: 0.5)
        switch id {
        case 1:
            // SF 심볼 I자에는 글자("가")가 붙어 있어 직접 그린다
            guard let image = ibeam() else { return nil }
            return RFBClient.CursorShape(image: image, hotspot: CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2),
                                         scale: CGFloat(image.height) / 26)
        case 5:
            guard let image = hand() else { return nil }
            // 손끝 (심볼 안 집게손가락 끝)
            return RFBClient.CursorShape(image: image, hotspot: CGPoint(x: CGFloat(image.width) * 0.3, y: CGFloat(image.height) * 0.06),
                                         scale: CGFloat(max(image.width, image.height)) / 28)
        case 10, 11, 12, 13:
            let angle: CGFloat = [10: 0, 11: .pi / 2, 12: .pi / 4, 13: -.pi / 4][Int(id)]!
            guard let image = resize(angle: angle, key: "resize\(id)") else { return nil }
            return RFBClient.CursorShape(image: image, hotspot: CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2),
                                         scale: CGFloat(image.height) / 28)
        case 2: symbol = "plus"
        case 3, 4: symbol = "hand.raised"
        case 8: symbol = "nosign"
        case 9: symbol = "arrow.up.and.down.and.arrow.left.and.right"
        default: return nil // 0 기본, 6 기다림, 7 도움말 → 큰 화살표
        }
        guard let image = render(symbol) else { return nil }
        return RFBClient.CursorShape(image: image, hotspot: CGPoint(x: CGFloat(image.width) * hot.x, y: CGFloat(image.height) * hot.y),
                                     scale: CGFloat(max(image.width, image.height)) / 26)
    }


    /// CGImage → PNG (UIKit·AppKit 없이)
    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

#if canImport(UIKit)
    /// 맥 크기 조절 커서처럼: 떨어진 검은 삼각형 두 개에 흰 테두리. angle 0 = 위아래, π/2 = 좌우, ±π/4 = 대각선
    private static func resize(angle: CGFloat, key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = rendered[key] { return c }
        let size = CGSize(width: 28, height: 28)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            g.translateBy(x: 14, y: 14); g.rotate(by: angle); g.translateBy(x: -14, y: -14)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 14, y: 2.5)); p.addLine(to: CGPoint(x: 20, y: 11)); p.addLine(to: CGPoint(x: 8, y: 11)); p.close()
            p.move(to: CGPoint(x: 14, y: 25.5)); p.addLine(to: CGPoint(x: 20, y: 17)); p.addLine(to: CGPoint(x: 8, y: 17)); p.close()
            p.lineJoinStyle = .round
            UIColor.white.setStroke(); p.lineWidth = 3.5; p.stroke()
            UIColor.black.setFill(); p.fill()
        }
        rendered[key] = img.cgImage
        return img.cgImage
    }

    /// 맥 손가락 커서처럼: 흰 손에 검은 테두리
    private static func hand() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = rendered["hand"] { return c }
        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        guard let base = UIImage(systemName: "hand.point.up.left.fill", withConfiguration: config) else { return nil }
        let pad: CGFloat = 4
        let size = CGSize(width: base.size.width + pad * 2, height: base.size.height + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let black = base.withTintColor(.black, renderingMode: .alwaysOriginal)
            for dx in [-2.0, 0, 2.0] { for dy in [-2.0, 0, 2.0] where dx != 0 || dy != 0 {
                black.draw(at: CGPoint(x: pad + dx, y: pad + dy))
            } }
            base.withTintColor(.white, renderingMode: .alwaysOriginal).draw(at: CGPoint(x: pad, y: pad))
        }
        rendered["hand"] = img.cgImage
        return img.cgImage
    }

    /// 맥 글자 입력 커서처럼: 위아래가 살짝 벌어진 세로 막대, 검은 선에 흰 테두리
    private static func ibeam() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = rendered["ibeam"] { return c }
        let size = CGSize(width: 18, height: 40)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 3, y: 3)); p.addQuadCurve(to: CGPoint(x: 9, y: 6), controlPoint: CGPoint(x: 8, y: 3))
            p.addQuadCurve(to: CGPoint(x: 15, y: 3), controlPoint: CGPoint(x: 10, y: 3))
            p.move(to: CGPoint(x: 9, y: 6)); p.addLine(to: CGPoint(x: 9, y: 34))
            p.move(to: CGPoint(x: 3, y: 37)); p.addQuadCurve(to: CGPoint(x: 9, y: 34), controlPoint: CGPoint(x: 8, y: 37))
            p.addQuadCurve(to: CGPoint(x: 15, y: 37), controlPoint: CGPoint(x: 10, y: 37))
            p.move(to: CGPoint(x: 6, y: 20)); p.addLine(to: CGPoint(x: 12, y: 20))
            p.lineCapStyle = .round
            UIColor.white.setStroke(); p.lineWidth = 5; p.stroke()
            UIColor.black.setStroke(); p.lineWidth = 2; p.stroke()
        }
        rendered["ibeam"] = img.cgImage
        return img.cgImage
    }

    private static var rendered: [String: CGImage] = [:]
    private static let lock = NSLock()

    /// 검은 심볼에 흰 테두리 (맥 커서처럼 어느 배경에서도 보이게)
    private static func render(_ name: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = rendered[name] { return c }
        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .bold)
        guard let base = UIImage(systemName: name, withConfiguration: config) else { return nil }
        let pad: CGFloat = 4
        let size = CGSize(width: base.size.width + pad * 2, height: base.size.height + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let white = base.withTintColor(.white, renderingMode: .alwaysOriginal)
            for dx in [-2.5, 0, 2.5] { for dy in [-2.5, 0, 2.5] where dx != 0 || dy != 0 {
                white.draw(at: CGPoint(x: pad + dx, y: pad + dy))
            } }
            base.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: CGPoint(x: pad, y: pad))
        }
        rendered[name] = img.cgImage
        return img.cgImage
    }
#else
    // 맥 앱: 미리 정해진 커서 그림은 아직 없다 (맥 기본 커서로 바꿔 보여 줄 예정)
    private static func resize(angle: CGFloat, key: String) -> CGImage? { nil }
    private static func hand() -> CGImage? { nil }
    private static func ibeam() -> CGImage? { nil }
    private static func render(_ name: String) -> CGImage? { nil }
#endif
}
