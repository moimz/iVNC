import Foundation
import zlib

/// 연결 내내 이어지는 zlib 스트림 (ZRLE·Zlib 인코딩은 사각형마다 끊지 않고 같은 스트림을 쓴다).
final class Inflater {
    private var stream = z_stream()
    private var out = [UInt8](repeating: 0, count: 1 << 20)

    init() {
        inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    deinit { inflateEnd(&stream) }

    /// 압축된 덩어리 하나를 모두 풀어 돌려준다.
    func inflate(_ input: [UInt8]) throws -> [UInt8] {
        var result = [UInt8]()
        var input = input
        try input.withUnsafeMutableBufferPointer { inp in
            stream.next_in = inp.baseAddress
            stream.avail_in = uInt(inp.count)
            repeat {
                let produced: Int = try out.withUnsafeMutableBufferPointer { o in
                    stream.next_out = o.baseAddress
                    stream.avail_out = uInt(o.count)
                    let rc = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    if rc != Z_OK && rc != Z_BUF_ERROR && rc != Z_STREAM_END {
                        throw RFBError.protocolError("zlib \(rc)")
                    }
                    return o.count - Int(stream.avail_out)
                }
                result += out[0..<produced]
                if produced == 0 && stream.avail_in > 0 { throw RFBError.protocolError("zlib 진행 없음") }
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        return result
    }
}
