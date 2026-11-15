// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Derived from noVNC-ARD (https://github.com/peetinc/noVNC-ARD), MPL-2.0.

import CommonCrypto
import Foundation

/// SRTP / SRTCP, AES_256_CM_HMAC_SHA1_80 (RFC 3711, 키 유도는 RFC 6188). 재생 방지 없음.
/// 고성능 화면 공유의 영상·소리용. noVNC-ARD `ard/hp/srtp.js` 를 옮김.
final class SRTPContext {
    private struct Keys {
        let cipher: [UInt8]
        let auth: [UInt8]
        let salt: [UInt8]
    }

    private let rtp: Keys
    private let rtcp: Keys
    /// SSRC 별로 검증된 가장 큰 패킷 번호 (롤오버 카운터 × 65536 + 순번)
    private(set) var highestIndex: [UInt32: UInt64] = [:]
    private var rtcpIndex: UInt32 = 0
    private static let tagLength = 10

    /// masterKey 32바이트, masterSalt 14바이트
    init(masterKey: [UInt8], masterSalt: [UInt8]) {
        func derive(_ label: UInt8, _ length: Int) -> [UInt8] {
            var iv = masterSalt + [0, 0]
            iv[7] ^= label
            return Self.keystream(key: masterKey, iv: iv, length: length)
        }
        rtp = Keys(cipher: derive(0, 32), auth: derive(1, 20), salt: derive(2, 14))
        rtcp = Keys(cipher: derive(3, 32), auth: derive(4, 20), salt: derive(5, 14))
    }

    #if DEBUG
    /// 시험용: 유도된 RTP 키 (RFC 6188 시험 값과 비교)
    var debugRTPKeys: (cipher: [UInt8], auth: [UInt8], salt: [UInt8]) { (rtp.cipher, rtp.auth, rtp.salt) }
    #endif

    /// AES 카운터 모드 키 흐름. iv 의 마지막 16bit 가 블록 번호.
    private static func keystream(key: [UInt8], iv: [UInt8], length: Int) -> [UInt8] {
        guard length > 0 else { return [] }
        let blocks = (length + 15) / 16
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        for b in 0..<blocks {
            var c = iv
            let n = (Int(c[14]) << 8 | Int(c[15])) + b
            c[14] = UInt8((n >> 8) & 0xFF); c[15] = UInt8(n & 0xFF)
            counters.replaceSubrange((b * 16)..<(b * 16 + 16), with: c)
        }
        return Array(RFBCrypto.ecbEncrypt(algorithm: CCAlgorithm(kCCAlgorithmAES), key: key, data: counters).prefix(length))
    }

    /// 카운터 블록: (salt XOR SSRC XOR 패킷 번호) << 16
    private static func counterBlock(salt: [UInt8], ssrc: UInt32, index: UInt64) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 16)
        b.replaceSubrange(4..<8, with: [UInt8].be32(ssrc))
        b[8] = UInt8((index >> 40) & 0xFF); b[9] = UInt8((index >> 32) & 0xFF)
        b.replaceSubrange(10..<14, with: [UInt8].be32(UInt32(truncatingIfNeeded: index)))
        for i in 0..<14 { b[i] ^= salt[i] }
        return b
    }

    private static func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), key, key.count, data, data.count, &out)
        return out
    }

    private static func estimateROC(_ highest: UInt64?, _ seq: UInt16) -> UInt64 {
        guard let highest else { return 0 }
        let roc = highest >> 16, last = Int(highest & 0xFFFF), s = Int(seq)
        if last < 0x8000 { return (s - last > 0x8000 && roc > 0) ? roc - 1 : roc }
        return (last - 0x8000 > s) ? roc + 1 : roc
    }

    struct RTPPacket {
        let ssrc: UInt32
        let seq: UInt16
        let timestamp: UInt32
        let marker: Bool
        let payloadType: UInt8
        /// 헤더 확장 (확장 머리 4바이트 포함). 고성능 영상은 8바이트: [4..6) 그림의 패킷 수, [6..8) 프레임 번호
        let extensionBytes: [UInt8]
        let payload: [UInt8]
    }

    /// SRTP 패킷 하나를 검증하고 푼다. 태그가 안 맞으면 nil.
    func unprotectRTP(_ p: [UInt8]) -> RTPPacket? {
        let end = p.count - Self.tagLength
        guard end >= 12 else { return nil }
        let headerLen = 12 + 4 * Int(p[0] & 0x0F)
        var payloadOffset = headerLen
        if p[0] & 0x10 != 0 {
            guard headerLen + 4 <= end else { return nil }
            payloadOffset += 4 + 4 * (Int(p[headerLen + 2]) << 8 | Int(p[headerLen + 3]))
        }
        guard payloadOffset <= end else { return nil }
        let seq = UInt16(p[2]) << 8 | UInt16(p[3])
        let ssrc = UInt32(p[8]) << 24 | UInt32(p[9]) << 16 | UInt32(p[10]) << 8 | UInt32(p[11])
        let roc = Self.estimateROC(highestIndex[ssrc], seq)
        let mac = Self.hmac(rtp.auth, Array(p[0..<end]) + [UInt8].be32(UInt32(truncatingIfNeeded: roc)))
        guard Array(mac.prefix(Self.tagLength)) == Array(p[end...]) else { return nil }
        let index = roc << 16 | UInt64(seq)
        if (highestIndex[ssrc] ?? 0) < index || highestIndex[ssrc] == nil { highestIndex[ssrc] = index }
        let body = Array(p[payloadOffset..<end])
        let ks = Self.keystream(key: rtp.cipher, iv: Self.counterBlock(salt: rtp.salt, ssrc: ssrc, index: index), length: body.count)
        var payload = body
        for i in 0..<payload.count { payload[i] ^= ks[i] }
        return RTPPacket(ssrc: ssrc, seq: seq, timestamp: UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7]),
                         marker: p[1] & 0x80 != 0, payloadType: p[1] & 0x7F,
                         extensionBytes: Array(p[headerLen..<payloadOffset]), payload: payload)
    }

    /// SRTCP 패킷 하나를 검증하고 푼다 (복합 RTCP 원문). 태그가 안 맞으면 nil.
    func unprotectRTCP(_ p: [UInt8]) -> [UInt8]? {
        let end = p.count - Self.tagLength - 4
        guard end >= 8 else { return nil }
        let mac = Self.hmac(rtcp.auth, Array(p[0..<(end + 4)]))
        guard Array(mac.prefix(Self.tagLength)) == Array(p[(end + 4)...]) else { return nil }
        let word = UInt32(p[end]) << 24 | UInt32(p[end + 1]) << 16 | UInt32(p[end + 2]) << 8 | UInt32(p[end + 3])
        var out = Array(p[0..<end])
        if word >> 31 == 1 {
            let ssrc = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])
            let ks = Self.keystream(key: rtcp.cipher, iv: Self.counterBlock(salt: rtcp.salt, ssrc: ssrc, index: UInt64(word & 0x7FFF_FFFF)), length: end - 8)
            for i in 8..<end { out[i] ^= ks[i - 8] }
        }
        return out
    }

    /// 평문 복합 RTCP 를 암호화하고 태그를 붙인다. 첫 번호는 1.
    func protectRTCP(_ plain: [UInt8]) -> [UInt8] {
        rtcpIndex += 1
        let ssrc = UInt32(plain[4]) << 24 | UInt32(plain[5]) << 16 | UInt32(plain[6]) << 8 | UInt32(plain[7])
        var out = plain
        let ks = Self.keystream(key: rtcp.cipher, iv: Self.counterBlock(salt: rtcp.salt, ssrc: ssrc, index: UInt64(rtcpIndex)), length: plain.count - 8)
        for i in 8..<plain.count { out[i] ^= ks[i - 8] }
        out += [UInt8].be32(0x8000_0000 | rtcpIndex)
        out += Self.hmac(rtcp.auth, out).prefix(Self.tagLength)
        return out
    }

    /// 수신 보고(RR, 보고 블록 1개) + 빈 CNAME SDES. 44바이트 (noVNC-ARD feedback.js)
    /// 아직 받은 게 없을 때의 보고 블록 (예전 보고와 같은 모양)
    static func emptyBlock(_ ssrc: UInt32) -> [UInt8] {
        [UInt8].be32(ssrc) + [UInt8](repeating: 0, count: 20)
    }

    static func receiverReport(ssrc: UInt32, sourceSSRC: UInt32, highestSeq: UInt32) -> [UInt8] {
        var r = [UInt8].be32(0x81C9_0007) + [UInt8].be32(ssrc) + [UInt8].be32(sourceSSRC)
        r += [UInt8].be32(0) + [UInt8].be32(highestSeq) + [UInt8].be32(0) + [UInt8].be32(0) + [UInt8].be32(0)
        r += [UInt8].be32(0x81CA_0002) + [UInt8].be32(ssrc) + [UInt8].be32(0x0100_0000)
        return r
    }
}
