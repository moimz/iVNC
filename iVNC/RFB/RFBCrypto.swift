import CommonCrypto
import CryptoKit
import Foundation

enum RFBCrypto {
    /// 패딩 없는 ECB 암호화 (AES-128 또는 DES)
    static func ecbEncrypt(algorithm: CCAlgorithm, key: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 32)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        precondition(status == kCCSuccess, "CCCrypt 실패 \(status)")
        return Array(out[0..<moved])
    }

    static func md5(_ data: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: data))
    }

    static func random(_ count: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &b)
        return b
    }

    /// 애플 인증(타입 30): 서버의 DH 값으로 128바이트(계정 이름 64 + 암호 64)를 AES 로 암호화해 클라이언트 공개값과 함께 보낸다.
    /// 돌려주는 key 는 접속 중 키 입력을 암호화(EncryptedEvent)하는 데 다시 쓴다.
    static func ardResponse(generator: [UInt8], prime: [UInt8], serverPublic: [UInt8], username: String, password: String) -> (response: [UInt8], key: [UInt8]) {
        let priv = random(32) // 256bit 비밀 지수면 충분하고, 4096bit 계산도 빨라진다
        let pub = DHMath.modPow(base: generator, exponent: priv, modulus: prime)
        let shared = DHMath.modPow(base: serverPublic, exponent: priv, modulus: prime)
        let key = md5(shared)
        var cred = random(128)
        let u = Array(username.utf8.prefix(63)), p = Array(password.utf8.prefix(63))
        cred.replaceSubrange(0..<(u.count + 1), with: u + [0])
        cred.replaceSubrange(64..<(64 + p.count + 1), with: p + [0])
        return (ecbEncrypt(algorithm: CCAlgorithm(kCCAlgorithmAES128), key: key, data: cred) + pub, key)
    }

    /// VNC 암호 인증(타입 2): 비트 순서를 뒤집은 암호로 16바이트 도전값을 DES 암호화
    static func vncResponse(challenge: [UInt8], password: String) -> [UInt8] {
        var key = Array(password.utf8.prefix(8))
        key += [UInt8](repeating: 0, count: 8 - key.count)
        key = key.map { b in
            var r: UInt8 = 0
            for i in 0..<8 where b & (1 << i) != 0 { r |= 1 << (7 - i) }
            return r
        }
        return ecbEncrypt(algorithm: CCAlgorithm(kCCAlgorithmDES), key: key, data: challenge)
    }
}
