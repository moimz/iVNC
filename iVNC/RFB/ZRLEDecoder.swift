import Foundation

/// ZRLE 사각형 디코더. 픽셀 형식은 32bpp depth24 리틀엔디언이라 압축 픽셀(CPIXEL)은 3바이트(B G R).
enum ZRLEDecoder {
    static func decode(_ data: [UInt8], x rx: Int, y ry: Int, w rw: Int, h rh: Int,
                       into p: UnsafeMutablePointer<UInt32>, fbWidth: Int, fbHeight: Int) throws {
        try data.withUnsafeBufferPointer { d in
            var i = 0
            @inline(__always) func byte() throws -> Int {
                guard i < d.count else { throw RFBError.protocolError("ZRLE 데이터 부족") }
                let v = Int(d[i]); i += 1; return v
            }
            @inline(__always) func cpixel() throws -> UInt32 {
                guard i + 3 <= d.count else { throw RFBError.protocolError("ZRLE 데이터 부족") }
                let v = UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | 0xFF000000
                i += 3; return v
            }
            func runLength() throws -> Int {
                var len = 1, b = 0
                repeat { b = try byte(); len += b } while b == 255
                return len
            }

            var tile = [UInt32](repeating: 0, count: 64 * 64)
            var palette = [UInt32](repeating: 0, count: 128)
            var ty = 0
            while ty < rh {
                let th = min(64, rh - ty)
                var tx = 0
                while tx < rw {
                    let tw = min(64, rw - tx)
                    let count = tw * th
                    let sub = try byte()
                    switch sub {
                    case 0:
                        for k in 0..<count { tile[k] = try cpixel() }
                    case 1:
                        let c = try cpixel()
                        for k in 0..<count { tile[k] = c }
                    case 2...16:
                        for k in 0..<sub { palette[k] = try cpixel() }
                        let bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4
                        let mask = (1 << bits) - 1
                        for row in 0..<th {
                            var cur = 0, left = 0
                            for col in 0..<tw {
                                if left == 0 { cur = try byte(); left = 8 }
                                left -= bits
                                tile[row * tw + col] = palette[(cur >> left) & mask]
                            }
                        }
                    case 128:
                        var k = 0
                        while k < count {
                            let c = try cpixel()
                            let n = min(try runLength(), count - k)
                            for m in 0..<n { tile[k + m] = c }
                            k += n
                        }
                    case 130...255:
                        let size = sub - 128
                        for k in 0..<size { palette[k] = try cpixel() }
                        var k = 0
                        while k < count {
                            let b = try byte()
                            let c = palette[b & 127]
                            let n = b & 128 != 0 ? min(try runLength(), count - k) : 1
                            for m in 0..<n { tile[k + m] = c }
                            k += n
                        }
                    default:
                        throw RFBError.protocolError("ZRLE 하위 인코딩 \(sub)")
                    }
                    // 타일을 화면에 옮긴다 (화면 밖은 잘라냄)
                    let x0 = rx + tx, y0 = ry + ty
                    let cw = min(tw, fbWidth - x0)
                    if cw > 0 && x0 >= 0 {
                        for row in 0..<th where y0 + row < fbHeight && y0 + row >= 0 {
                            tile.withUnsafeBufferPointer { t in
                                (p + (y0 + row) * fbWidth + x0).update(from: t.baseAddress! + row * tw, count: cw)
                            }
                        }
                    }
                    tx += 64
                }
                ty += 64
            }
        }
    }
}
