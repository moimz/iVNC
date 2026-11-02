import Foundation

/// 애플 인증(보안 타입 30)의 Diffie-Hellman 에 쓰는 큰 수 거듭제곱.
/// 맥은 4096bit 소수를 주므로 몽고메리 곱셈(CIOS)으로 계산한다. 소수는 항상 홀수라 그대로 쓸 수 있다.
enum DHMath {
    /// base^exp mod modulus. 모두 빅엔디언 바이트이고, 결과는 modulus 와 같은 길이.
    static func modPow(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) -> [UInt8] {
        let n = (modulus.count + 7) / 8
        let N = limbs(modulus, count: n)
        let ctx = Montgomery(N: N)
        let one = [UInt64](repeating: 0, count: n).replacing(at: 0, with: 1)
        let x = ctx.toMont(limbs(base, count: n))
        var acc = ctx.toMont(one)
        for byte in exponent {
            for bit in (0..<8).reversed() {
                acc = ctx.mul(acc, acc)
                if (byte >> UInt8(bit)) & 1 == 1 {
                    acc = ctx.mul(acc, x)
                }
            }
        }
        return bytes(ctx.mul(acc, one), count: modulus.count)
    }

    /// 빅엔디언 바이트 → 64bit 단위 리틀엔디언 배열
    private static func limbs(_ b: [UInt8], count n: Int) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: n)
        for (i, byte) in b.reversed().enumerated() where i / 8 < n {
            out[i / 8] |= UInt64(byte) << UInt64((i % 8) * 8)
        }
        return out
    }

    private static func bytes(_ l: [UInt64], count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            out[count - 1 - i] = UInt8(truncatingIfNeeded: l[i / 8] >> UInt64((i % 8) * 8))
        }
        return out
    }

    private struct Montgomery {
        let N: [UInt64]
        let n: Int
        let n0: UInt64 // -N^-1 mod 2^64
        let r2: [UInt64] // R^2 mod N

        init(N: [UInt64]) {
            self.N = N
            n = N.count
            var inv: UInt64 = 1
            for _ in 0..<6 { inv = inv &* (2 &- N[0] &* inv) }
            n0 = 0 &- inv
            // R^2 mod N = 2^(128n) mod N 를 1 에서부터 두 배씩 해서 구한다
            var x = [UInt64](repeating: 0, count: n)
            x[0] = 1
            for _ in 0..<(128 * n) {
                var carry: UInt64 = 0
                for i in 0..<n {
                    let v = x[i]
                    x[i] = (v << 1) | carry
                    carry = v >> 63
                }
                if carry != 0 || !Montgomery.less(x, N) { Montgomery.sub(&x, N) }
            }
            r2 = x
        }

        func toMont(_ a: [UInt64]) -> [UInt64] { mul(a, r2) }

        func mul(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
            var t = [UInt64](repeating: 0, count: n + 2)
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    N.withUnsafeBufferPointer { N in
                        t.withUnsafeMutableBufferPointer { t in
                            for i in 0..<n {
                                var c: UInt64 = 0
                                let bi = b[i]
                                for j in 0..<n { (t[j], c) = Montgomery.mulAdd(a[j], bi, t[j], c) }
                                var (s, o) = t[n].addingReportingOverflow(c)
                                t[n] = s; t[n + 1] = o ? 1 : 0
                                let m = t[0] &* n0
                                (_, c) = Montgomery.mulAdd(m, N[0], t[0], 0)
                                for j in 1..<n { (t[j - 1], c) = Montgomery.mulAdd(m, N[j], t[j], c) }
                                (s, o) = t[n].addingReportingOverflow(c)
                                t[n - 1] = s; t[n] = t[n + 1] &+ (o ? 1 : 0)
                            }
                        }
                    }
                }
            }
            var r = Array(t[0..<n])
            if t[n] != 0 || !Montgomery.less(r, N) { Montgomery.sub(&r, N) }
            return r
        }

        /// x*y + z + c 를 (낮은 64bit, 높은 64bit) 로. 넘치지 않는다.
        @inline(__always)
        static func mulAdd(_ x: UInt64, _ y: UInt64, _ z: UInt64, _ c: UInt64) -> (UInt64, UInt64) {
            var (hi, lo) = x.multipliedFullWidth(by: y)
            var o: Bool
            (lo, o) = lo.addingReportingOverflow(z); if o { hi &+= 1 }
            (lo, o) = lo.addingReportingOverflow(c); if o { hi &+= 1 }
            return (lo, hi)
        }

        static func less(_ a: [UInt64], _ b: [UInt64]) -> Bool {
            for i in (0..<a.count).reversed() where a[i] != b[i] { return a[i] < b[i] }
            return false
        }

        static func sub(_ a: inout [UInt64], _ b: [UInt64]) {
            var borrow: UInt64 = 0
            for i in 0..<a.count {
                let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
                let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                a[i] = d2
                borrow = (o1 || o2) ? 1 : 0
            }
        }
    }
}

private extension Array {
    func replacing(at i: Int, with v: Element) -> [Element] {
        var c = self
        c[i] = v
        return c
    }
}
