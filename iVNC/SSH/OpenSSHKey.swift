import Foundation
import CryptoKit
import CommonCrypto

/// OpenSSH 개인 키 파일(`-----BEGIN OPENSSH PRIVATE KEY-----`, openssh-key-v1) 에서 ed25519 키를 꺼낸다.
/// 암호 걸린 키(bcrypt + aes256-ctr / aes256-cbc)도 푼다. SwiftNIO SSH 는 키 파일을 읽어 주지 않아 직접 한다.
enum OpenSSHKey {
    enum Failure: LocalizedError {
        case notOpenSSH, unsupportedKeyType(String), unsupportedCipher(String), needsPassphrase, wrongPassphrase, broken
        var errorDescription: String? {
            switch self {
            case .notOpenSSH: return "OpenSSH 형식 개인 키가 아닙니다 (-----BEGIN OPENSSH PRIVATE KEY-----)."
            case .unsupportedKeyType(let t): return "지원하지 않는 키 종류입니다: \(t). ed25519 키만 쓸 수 있습니다."
            case .unsupportedCipher(let c): return "지원하지 않는 키 암호화 방식입니다: \(c)"
            case .needsPassphrase: return "암호가 걸린 키입니다. 서버 편집에서 키 암호를 넣어 주세요."
            case .wrongPassphrase: return "키 암호가 맞지 않습니다."
            case .broken: return "키 파일이 손상됐습니다."
            }
        }
    }

    static func ed25519(from file: Data, passphrase: String?) throws -> Curve25519.Signing.PrivateKey {
        let text = String(decoding: file, as: UTF8.self)
        guard let begin = text.range(of: "-----BEGIN OPENSSH PRIVATE KEY-----"),
              let end = text.range(of: "-----END OPENSSH PRIVATE KEY-----") else { throw Failure.notOpenSSH }
        let b64 = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let blob = Data(base64Encoded: String(b64)) else { throw Failure.broken }
        var r = Reader(Array(blob))
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard r.take(magic.count) == magic else { throw Failure.notOpenSSH }
        let cipher = try r.string()
        let kdf = try r.string()
        let kdfOptions = try r.bytes()
        guard try r.u32() == 1 else { throw Failure.broken } // 키 개수
        _ = try r.bytes() // 공개 키
        var priv = try r.bytes()

        if cipher != "none" {
            guard kdf == "bcrypt" else { throw Failure.unsupportedCipher(kdf) }
            guard let pass = passphrase, !pass.isEmpty else { throw Failure.needsPassphrase }
            var o = Reader(kdfOptions)
            let salt = try o.bytes()
            let rounds = try o.u32()
            let (keyLen, ivLen, mode): (Int, Int, CCMode)
            switch cipher {
            case "aes256-ctr": (keyLen, ivLen, mode) = (32, 16, CCMode(kCCModeCTR))
            case "aes256-cbc": (keyLen, ivLen, mode) = (32, 16, CCMode(kCCModeCBC))
            case "aes128-ctr": (keyLen, ivLen, mode) = (16, 16, CCMode(kCCModeCTR))
            default: throw Failure.unsupportedCipher(cipher)
            }
            var derived = [UInt8](repeating: 0, count: keyLen + ivLen)
            let pw = Array(pass.utf8)
            let rc = pw.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pw.count) { cp in
                    ivnc_bcrypt_pbkdf(cp, pw.count, salt, salt.count, &derived, derived.count, rounds)
                }
            }
            guard rc == 0 else { throw Failure.broken }
            priv = try aes(mode: mode, key: Array(derived[0..<keyLen]), iv: Array(derived[keyLen...]), data: priv)
        }

        var p = Reader(priv)
        // 같은 값 두 개: 다르면 암호가 틀린 것
        guard try p.u32() == p.u32() else { throw cipher == "none" ? Failure.broken : Failure.wrongPassphrase }
        let type = try p.string()
        guard type == "ssh-ed25519" else { throw Failure.unsupportedKeyType(type) }
        _ = try p.bytes() // 공개 키 32바이트
        let secret = try p.bytes() // 씨앗 32 + 공개 키 32
        guard secret.count == 64 else { throw Failure.broken }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: secret[0..<32])
    }

    private static func aes(mode: CCMode, key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        var ref: CCCryptorRef?
        var status = CCCryptorCreateWithMode(CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                             iv, key, key.count, nil, 0, 0, CCModeOptions(mode == CCMode(kCCModeCTR) ? kCCModeOptionCTR_BE : 0), &ref)
        guard status == kCCSuccess, let ref else { throw Failure.broken }
        defer { CCCryptorRelease(ref) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        status = CCCryptorUpdate(ref, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved == data.count else { throw Failure.broken }
        return out
    }

    /// SSH 바이트 읽기 (uint32 큰 끝, 길이가 앞에 붙은 문자열)
    private struct Reader {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }
        mutating func take(_ n: Int) -> [UInt8]? {
            guard n >= 0, i + n <= b.count else { return nil }
            defer { i += n }
            return Array(b[i..<i + n])
        }
        mutating func u32() throws -> UInt32 {
            guard let x = take(4) else { throw Failure.broken }
            return x.reduce(0) { $0 << 8 | UInt32($1) }
        }
        mutating func bytes() throws -> [UInt8] {
            let n = Int(try u32())
            guard let x = take(n) else { throw Failure.broken }
            return x
        }
        mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
    }
}
