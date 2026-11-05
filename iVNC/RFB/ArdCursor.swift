import UIKit

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
        let shape = Self.image(raw: raw, w: w, h: h, hotX: x, hotY: y)
        cache[id] = shape
        return shape
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
        return RFBClient.CursorShape(image: image, hotspot: CGPoint(x: hotX, y: hotY))
    }

    /// 미리 정해진 커서: 화살표 계열은 nil, 나머지는 SF 심볼로 그린다 (핫스팟은 가운데, 손가락은 손끝)
    private static func predefined(_ id: UInt32) -> RFBClient.CursorShape? {
        let symbol: String
        var hot = CGPoint(x: 0.5, y: 0.5)
        switch id {
        case 1:
            // SF 심볼 I자에는 글자("가")가 붙어 있어 직접 그린다
            guard let image = ibeam() else { return nil }
            return RFBClient.CursorShape(image: image, hotspot: CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2))
        case 2: symbol = "plus"
        case 3, 4: symbol = "hand.raised"
        case 5: symbol = "hand.point.up.left"; hot = CGPoint(x: 0.3, y: 0.05)
        case 8: symbol = "nosign"
        case 9: symbol = "arrow.up.and.down.and.arrow.left.and.right"
        case 10: symbol = "arrow.up.and.down"
        case 11: symbol = "arrow.left.and.right"
        default: return nil // 0 기본, 6 기다림, 7 도움말 → 큰 화살표
        }
        guard let image = render(symbol) else { return nil }
        return RFBClient.CursorShape(image: image, hotspot: CGPoint(x: CGFloat(image.width) * hot.x, y: CGFloat(image.height) * hot.y))
    }

    /// 맥 글자 입력 커서처럼: 위아래가 살짝 벌어진 세로 막대, 검은 선에 흰 테두리
    private static func ibeam() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = rendered["ibeam"] { return c }
        let size = CGSize(width: 18, height: 40)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
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
        format.scale = 1
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
}
