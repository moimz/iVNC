import CoreGraphics
import Foundation

/// 서버가 DisplayInfo2(애플 의사 인코딩 1105)로 알려 주는 모니터 하나
struct RemoteDisplay: Identifiable, Hashable {
    let id: UInt32
    let isMain: Bool
    let scale: Double
    /// 데스크톱 좌표 (포인트). 배치 그림에 쓴다.
    let desktop: CGRect
    /// 모든 모니터를 합친 프레임버퍼 안의 위치 (픽셀)
    let framebuffer: CGRect

    /// id 는 화면 구성이 바뀌면(잠금 포함) 달라질 수 있어서, 미리보기 그림은 위치·크기로 기억한다.
    var stableKey: String {
        "\(Int(framebuffer.minX))_\(Int(framebuffer.minY))_\(Int(framebuffer.width))x\(Int(framebuffer.height))"
    }
}

struct DisplayInfo2 {
    /// 지금 보내는 화면. 0xFFFFFFFF 면 모든 모니터를 합친 것
    let currentDisplayID: UInt32
    let pixelWidth: Int
    let pixelHeight: Int
    let displays: [RemoteDisplay]

    static let allDisplays: UInt32 = 0xFFFF_FFFF

    /// [u16 ver][u16 w][u16 h][u16 pw][u16 ph][u32 displayId][u32 flags][u16 count] + 모니터당 56바이트
    init?(_ d: [UInt8]) {
        guard d.count >= 20 else { return nil }
        func u16(_ o: Int) -> Int { Int(d[o]) << 8 | Int(d[o + 1]) }
        func i16(_ o: Int) -> CGFloat { CGFloat(Int16(bitPattern: UInt16(u16(o)))) }
        func u32(_ o: Int) -> UInt32 { UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3]) }
        func f64(_ o: Int) -> Double { Double(bitPattern: UInt64(u32(o)) << 32 | UInt64(u32(o + 4))) }
        pixelWidth = u16(6)
        pixelHeight = u16(8)
        currentDisplayID = u32(10)
        var list = [RemoteDisplay]()
        for k in 0..<u16(18) {
            let o = 20 + k * 56
            guard o + 56 <= d.count else { break }
            let top = i16(o + 20), left = i16(o + 22), bottom = i16(o + 24), right = i16(o + 26)
            let ftop = i16(o + 28), fleft = i16(o + 30), fbottom = i16(o + 32), fright = i16(o + 34)
            list.append(RemoteDisplay(id: u32(o + 16), isMain: u32(o + 36) & 1 != 0, scale: f64(o),
                                      desktop: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                                      framebuffer: CGRect(x: fleft, y: ftop, width: fright - fleft, height: fbottom - ftop)))
        }
        displays = list
    }
}
