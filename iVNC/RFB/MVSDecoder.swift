import Foundation

/// 애플 MVS(인코딩 1011) 해독기. 8x8 타일 DCT 손실 압축으로, 애플 화면 공유 앱이 화질 "적응"에서 쓴다.
/// noVNC-ARD `ard/decoders/mvs*.js` 를 옮김 (애플 뷰어 DecodeMultiVariant.c 를 따른 것, IDCT 는 libjpeg islow 와 같은 정수 연산).
///
/// 사각형 데이터: [u32 길이][본문]. 본문 첫 바이트가 종류: 0 = 전체, 1 = 부분(전체 갱신을 기준으로 한 차이), 2 = 양자화 표.
/// 타일이 이미 그린 화면(복사)과 캐시를 참조하므로 화면 버퍼에 바로 그린다.
///
/// 속도: 아이폰에서 해독이 병목이라(5K 화면에서 CPU 를 다 씀) 배열 대신 미리 잡은 메모리, 64비트씩 모아 읽는 비트스트림,
/// 16비트 한 번에 찾는 허프만 표를 쓴다. 결과는 처음 옮긴 것과 픽셀까지 같다 (Ai/iVNC/mvs-bench).
final class MVSDecoder {
    private static let cacheSize = 65000
    private static let entryY = 64, entryCr = 15, entryCb = 20
    private static let entrySize = entryY + entryCr + entryCb // 99
    // 계수 버퍼: Y[0..63], Cb[64..127], Cr[128..191], 지그재그 순서
    private let CB = 64, CR = 128

    private let lumaQuant = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    private let chromaQuant = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    private let coeffs = UnsafeMutablePointer<Int16>.allocate(capacity: 192)
    private let dpcm = UnsafeMutablePointer<Int16>.allocate(capacity: 192)
    private let tile = UnsafeMutablePointer<UInt32>.allocate(capacity: 64)
    private let entry = UnsafeMutablePointer<Int8>.allocate(capacity: entrySize)
    private let dq = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    private let ws = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    private let ySp = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let cbSp = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let crSp = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    // 표 (정적 배열을 매번 찾지 않게 복사해 둔다)
    private let zz = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    private let tCrR = UnsafeMutablePointer<Int>.allocate(capacity: 256)
    private let tCbB = UnsafeMutablePointer<Int>.allocate(capacity: 256)
    private let tCrG = UnsafeMutablePointer<Int>.allocate(capacity: 256)
    private let tCbG = UnsafeMutablePointer<Int>.allocate(capacity: 256)
    /// 범위 자르기 표: [v + 512] = clamp(v, 0, 255)
    private let clampTab = UnsafeMutablePointer<UInt32>.allocate(capacity: 1280)
    /// 허프만: 앞 16비트 → (길이 << 8 | 기호), 길이 0 = 잘못된 부호
    private let huff = UnsafeMutablePointer<UInt16>.allocate(capacity: 65536)

    private var solid = (0, 0, 0)
    private var twoA = (255, 255, 255)
    private var twoB = (181, 213, 254)

    private let cache = UnsafeMutablePointer<Int8>.allocate(capacity: cacheSize * entrySize)
    private var cacheWrite = 0
    private var cacheLast = 0
    private var cacheCount = 0
    private var cachePixels: UnsafeMutablePointer<UInt32>?
    private var cachePixelGen: UnsafeMutablePointer<UInt32>?
    private var quantGen: UInt32 = 1

    // 화면 타일별 기술자 (전체 갱신만 쓴다. 부분 갱신의 기준)
    private var fbW = 0, fbH = 0, tilesXScreen = 0, tilesTotal = 0
    private var dThreshold = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    private var dY = UnsafeMutablePointer<Int8>.allocate(capacity: 1)
    private var dCbValid = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    private var dCbDC = UnsafeMutablePointer<Int8>.allocate(capacity: 1)
    private var dCrValid = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    private var dCrDC = UnsafeMutablePointer<Int8>.allocate(capacity: 1)
    private var dSeq = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    private var dRef = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private var dMatchX = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private var dMatchY = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private var frameSeq: UInt32 = 0

    // 그리는 중인 화면 버퍼
    private var fb: UnsafeMutablePointer<UInt32>!

    private(set) var warnings = 0

    init() {
        lumaQuant.initialize(from: MVSTables.defaultLuma, count: 64)
        chromaQuant.initialize(from: MVSTables.defaultChroma, count: 64)
        zz.initialize(from: MVSTables.zigzag, count: 64)
        tCrR.initialize(from: MVSTables.crR, count: 256)
        tCbB.initialize(from: MVSTables.cbB, count: 256)
        tCrG.initialize(from: MVSTables.crG, count: 256)
        tCbG.initialize(from: MVSTables.cbG, count: 256)
        MVSHuffman.fill(huff)
        for i in 0..<1280 { clampTab[i] = UInt32(min(max(i - 512, 0), 255)) }
        cache.initialize(repeating: 0, count: Self.cacheSize * Self.entrySize)
        for p in [coeffs, dpcm] { p.initialize(repeating: 0, count: 192) }
    }

    deinit {
        for p in [lumaQuant, chromaQuant, zz, tCrR, tCbB, tCrG, tCbG, dq, ws, dRef, dMatchX, dMatchY] as [UnsafeMutablePointer<Int>] { p.deallocate() }
        coeffs.deallocate(); dpcm.deallocate(); tile.deallocate(); entry.deallocate()
        clampTab.deallocate(); ySp.deallocate(); cbSp.deallocate(); crSp.deallocate(); huff.deallocate(); cache.deallocate()
        cachePixels?.deallocate(); cachePixelGen?.deallocate()
        dThreshold.deallocate(); dY.deallocate(); dCbValid.deallocate(); dCbDC.deallocate()
        dCrValid.deallocate(); dCrDC.deallocate(); dSeq.deallocate()
    }

    private func warn(_ s: String) {
        warnings += 1
        if warnings <= 20 { DebugLog.write("MVS: " + s) }
    }

    private func ensureScreen(_ w: Int, _ h: Int) {
        guard w != fbW || h != fbH else { return }
        fbW = w; fbH = h
        tilesXScreen = (w + 7) / 8
        let n = tilesXScreen * ((h + 7) / 8)
        tilesTotal = n
        func fresh<T>(_ p: inout UnsafeMutablePointer<T>, _ count: Int, _ v: T) {
            p.deallocate(); p = .allocate(capacity: count); p.initialize(repeating: v, count: count)
        }
        fresh(&dThreshold, n, 0); fresh(&dY, n * 64, 0)
        fresh(&dCbValid, n, false); fresh(&dCbDC, n, 0)
        fresh(&dCrValid, n, false); fresh(&dCrDC, n, 0)
        fresh(&dSeq, n, 0); fresh(&dRef, n, -1); fresh(&dMatchX, n, 0); fresh(&dMatchY, n, 0)
    }

    /// 사각형 하나를 화면 버퍼(BGRX)에 그린다
    func decode(_ data: [UInt8], x: Int, y: Int, w: Int, h: Int, pixels: UnsafeMutablePointer<UInt32>, fbWidth: Int, fbHeight: Int) {
        guard !data.isEmpty else { return }
        ensureScreen(fbWidth, fbHeight)
        fb = pixels
        let type = data[0]
        if type != 2 && (x + w > fbW || y + h > fbH) { warn("화면 밖 사각형 \(w)x\(h) @\(x),\(y)"); return }
        data.withUnsafeBufferPointer { buf in
            switch type {
            case 2:
                guard data.count == 129 else { warn("양자화 표 \(data.count)바이트"); return }
                for i in 0..<64 { lumaQuant[i] = Int(buf[1 + i]); chromaQuant[i] = Int(buf[65 + i]) }
                quantGen &+= 1
            case 0: fullUpdate(buf, x, y, w, h)
            case 1: partialUpdate(buf, x, y, w, h)
            default: warn("모르는 종류 \(type)")
            }
        }
    }

    // MARK: - 전체 갱신

    private func fullUpdate(_ d: UnsafeBufferPointer<UInt8>, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        guard d.count >= 6 else { return }
        let t1 = Int(d[1]), t2 = Int(d[2])
        let tilesX = (width + 7) / 8, total = tilesX * ((height + 7) / 8)
        let bodyOffset = Int(d[3]) << 16 | Int(d[4]) << 8 | Int(d[5])
        guard bodyOffset >= 6, bodyOffset <= d.count else { warn("본문 위치 이상 \(bodyOffset)"); return }
        var hb = MVSBits(d, from: 6, to: bodyOffset)
        var bb = MVSBits(d, from: bodyOffset, to: d.count)
        _ = hb.bit() // 애플 뷰어가 무시하는 첫 비트

        frameSeq &+= 1
        dpcm.update(repeating: 0, count: 192)
        solid = (0, 0, 0); twoA = (255, 255, 255); twoB = (181, 213, 254)

        var prevDct = -1
        var prevX = x, prevY = y
        var idx = 0
        while idx < total {
            let tileType = hb.bits(3)
            var count = 1
            if hb.bit() == 1 {
                let v4 = hb.bits(4)
                if v4 < 15 { count = v4 + 2 } else {
                    let b1 = hb.bits(8)
                    var v: Int
                    if b1 & 0x80 == 0 { v = b1 } else {
                        let b2 = hb.bits(8)
                        if b2 & 0x80 == 0 { v = b2 << 7 | (b1 & 0x7F) } else {
                            let b3 = hb.bits(8)
                            v = b3 << 14 | (b2 & 0x7F) << 7 | (b1 & 0x7F)
                        }
                    }
                    count = v + 17
                }
            }
            if hb.overrun || bb.overrun { warn("전체 갱신 데이터가 모자람 (타일 \(idx)/\(total))"); return }
            while count > 0 && idx < total {
                let col = idx % tilesX, row = idx / tilesX
                let tx = x + col * 8, ty = y + row * 8
                let tw = min(8, x + width - tx), th = min(8, y + height - ty)
                let si = (ty >> 3) * tilesXScreen + (tx >> 3)
                dSeq[si] = frameSeq
                dRef[si] = -1
                var rendered = true
                switch tileType {
                case 0:
                    tile.update(repeating: 0xFFFF_FFFF, count: 64)
                case 1:
                    dRef[si] = si - 1; dMatchX[si] = prevX; dMatchY[si] = prevY
                    copyTile(prevX, prevY, tx, ty, tw, th); rendered = false
                case 2:
                    dRef[si] = si - tilesXScreen; dMatchX[si] = tx; dMatchY[si] = ty - 8
                    copyTile(tx, ty - 8, tx, ty, tw, th); rendered = false
                case 3: twoColorBW(&bb)
                case 4: solidOrTwoColor(&bb)
                case 5:
                    decodeDCT(&bb, t1, t2, si, prevDct)
                    prevDct = si
                case 6: rendered = loadCache(bb.bits(16))
                default: rendered = loadCache((cacheLast + 1) & 0xFFFF)
                }
                if rendered { putTile(tx, ty, tw, th) }
                prevX = tx; prevY = ty
                count -= 1; idx += 1
            }
        }
        // 두 비트스트림 모두 'm'(0x6d) 로 끝난다
        let he = hb.bits(8), be = bb.bits(8)
        if he != 0x6D || be != 0x6D || hb.overrun || bb.overrun { warn("끝 표시 머리 \(he) 본문 \(be)") }
    }

    // MARK: - 부분 갱신

    private func partialUpdate(_ d: UnsafeBufferPointer<UInt8>, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        guard d.count >= 3 else { return }
        let crLimit = min(Int(d[1]), 64), cbLimit = min(Int(d[2]), 64)
        let tilesX = (width + 7) / 8, total = tilesX * ((height + 7) / 8)
        var bs = MVSBits(d, from: 3, to: d.count)
        for idx in 0..<total {
            let col = idx % tilesX, row = idx / tilesX
            let tx = x + col * 8, ty = y + row * 8
            let tw = min(8, x + width - tx), th = min(8, y + height - ty)
            let si = (ty >> 3) * tilesXScreen + (tx >> 3)
            switch bs.bits(2) {
            case 0: break
            case 1:
                guard partialDCT(&bs, si, crLimit, cbLimit) else { return }
                putTile(tx, ty, tw, th)
            case 2:
                let r = dRef[si]
                if r >= 0 && r < tilesTotal && dSeq[si] == dSeq[r] { copyTile(dMatchX[si], dMatchY[si], tx, ty, tw, th) }
            default:
                let ci = bs.bit() == 1 ? (cacheLast + 1) & 0xFFFF : bs.bits(16)
                if loadCache(ci) { putTile(tx, ty, tw, th) }
            }
            if bs.overrun { warn("부분 갱신 데이터가 모자람 (타일 \(idx)/\(total))"); return }
        }
        let m = bs.bits(8), v = bs.bits(8), s = bs.bits(8)
        if m != 0x6D || v != 0x76 || s != 0x73 || bs.overrun { warn("부분 갱신 끝 표시 \(m) \(v) \(s)") }
    }

    @inline(__always) private static func int8(_ v: Int) -> Int { ((v + 128) & 0xFF) - 128 }

    private func partialDCT(_ bs: inout MVSBits, _ si: Int, _ crLimit: Int, _ cbLimit: Int) -> Bool {
        guard dCrValid[si] && dCbValid[si] else { warn("기준 없는 부분 DCT 타일"); return false }
        coeffs.update(repeating: 0, count: 192)
        entry.update(repeating: 0, count: Self.entrySize)
        let threshold = Int(dThreshold[si])
        let base = si * 64, end64 = base + 64
        coeffs[0] = Int16(dY[base]); entry[0] = dY[base]
        let acCount = bs.bits(6)
        let end = acCount + 1
        var dp = base + 1, ep = 1
        let p1End = min(end, threshold)
        if threshold < 15 {
            var pos = 1
            while pos < p1End {
                let prev = dp < end64 ? Int(dY[dp]) : 0; dp += 1
                let v = prev == 0 ? Self.int8(MVSRice.dc(&bs)) : Self.int8(prev >= 0 ? prev + bs.bits(3) : prev - bs.bits(3))
                coeffs[pos] = Int16(v); if ep < Self.entryY { entry[ep] = Int8(v) }; ep += 1; pos += 1
            }
        } else {
            var pos = 1
            while pos < p1End {
                let prev = dp < end64 ? Int(dY[dp]) : 0; dp += 1
                var v = 0
                if prev == 0 { if bs.bit() == 1 { v = bs.bit() == 1 ? -1 : 1 } } else {
                    let delta = bs.bit()
                    v = Self.int8(prev >= 0 ? prev + delta : prev - delta)
                }
                coeffs[pos] = Int16(v); if ep < Self.entryY { entry[ep] = Int8(v) }; ep += 1; pos += 1
            }
        }
        if acCount >= threshold {
            let deltaBits = threshold < 15 ? 4 : 3
            var pos = threshold
            while pos < end {
                let prev = dp < end64 ? Int(dY[dp]) : 0; dp += 1
                let v = prev == 0 ? Self.int8(MVSRice.dc(&bs)) : Self.int8(prev >= 0 ? prev + bs.bits(deltaBits) : prev - bs.bits(deltaBits))
                if pos < 64 { coeffs[pos] = Int16(v) }
                if ep < Self.entryY { entry[ep] = Int8(v) }
                ep += 1; pos += 1
            }
        }
        coeffs[CR] = Int16(chromaDCDelta(&bs, Int(dCrDC[si])))
        huffmanAC(&bs, CR, crLimit)
        for i in 0..<Self.entryCr { entry[Self.entryY + i] = Int8(truncatingIfNeeded: coeffs[CR + i]) }
        coeffs[CB] = Int16(chromaDCDelta(&bs, Int(dCbDC[si])))
        huffmanAC(&bs, CB, cbLimit)
        for i in 0..<Self.entryCb { entry[Self.entryY + Self.entryCr + i] = Int8(truncatingIfNeeded: coeffs[CB + i]) }

        dequantAndRender()

        // 부분 DCT 타일만 캐시에 들어간다
        cacheWrite += 1
        if cacheWrite == Self.cacheSize { cacheWrite = 1 }
        cacheCount += 1
        (cache + cacheWrite * Self.entrySize).update(from: entry, count: Self.entrySize)
        cachePixelGen?[cacheWrite] = 0
        return true
    }

    private func chromaDCDelta(_ bs: inout MVSBits, _ baseline: Int) -> Int {
        let b = bs.bit()
        if baseline != 0 { return Self.int8(baseline >= 0 ? baseline + b : baseline - b) }
        if b == 1 { return bs.bit() == 1 ? -1 : 1 }
        return 0
    }

    /// K.5 AC 휘도 허프만으로 색차 AC 를 푼다 (표준 JPEG). 63 을 넘는 자리는 63 에 쓴다 (libjpeg 와 같게)
    private func huffmanAC(_ bs: inout MVSBits, _ offset: Int, _ limit: Int) {
        var k = 0
        while k < limit {
            let e = Int(huff[bs.peek16()])
            let len = e >> 8
            if len == 0 { bs.skip(16); return } // 잘못된 부호
            bs.skip(len)
            let s = e & 0xFF
            let run = s >> 4, vb = s & 0x0F
            if vb == 0 {
                if run != 15 { break }
                k += 16; continue
            }
            k += run
            let raw = bs.bits(vb)
            let v = raw < (1 << (vb - 1)) ? raw - (1 << vb) + 1 : raw
            coeffs[offset + min(k + 1, 63)] = Int16(truncatingIfNeeded: v)
            k += 1
            if bs.overrun { return }
        }
    }

    // MARK: - 타일 종류 (tile 에 쓴다)

    @inline(__always) private static func pixel(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0xFF00_0000 | UInt32(truncatingIfNeeded: r) << 16 | UInt32(truncatingIfNeeded: g) << 8 | UInt32(truncatingIfNeeded: b)
    }

    private func twoColorBW(_ bs: inout MVSBits) {
        let sel = bs.bits(8)
        for row in 0..<8 {
            if (sel >> (7 - row)) & 1 == 1 {
                (tile + row * 8).update(repeating: 0xFFFF_FFFF, count: 8)
            } else {
                let bits = bs.bits(8)
                for c in 0..<8 { tile[row * 8 + c] = (bits >> (7 - c)) & 1 == 1 ? 0xFFFF_FFFF : 0xFF00_0000 }
            }
        }
    }

    private func solidOrTwoColor(_ bs: inout MVSBits) {
        let two = bs.bit(), reuse = bs.bit()
        if two == 0 {
            if reuse == 0 { solid = ycbcr20(&bs) }
            tile.update(repeating: Self.pixel(solid.0, solid.1, solid.2), count: 64)
        } else {
            if reuse == 0 { twoA = ycbcr20(&bs); twoB = ycbcr20(&bs) }
            let a = Self.pixel(twoA.0, twoA.1, twoA.2), b = Self.pixel(twoB.0, twoB.1, twoB.2)
            let sel = bs.bits(8)
            for row in 0..<8 {
                let bits = (sel >> (7 - row)) & 1 == 1 ? 0xFF : bs.bits(8)
                for c in 0..<8 { tile[row * 8 + c] = (bits >> (7 - c)) & 1 == 1 ? a : b }
            }
        }
    }

    private func ycbcr20(_ bs: inout MVSBits) -> (Int, Int, Int) {
        let yv = bs.bits(8), cb = bs.bits(6) << 2, cr = bs.bits(6) << 2
        return (Self.clamp(yv + tCrR[cr]), Self.clamp(yv + ((tCbG[cb] + tCrG[cr]) >> 16)), Self.clamp(yv + tCbB[cb]))
    }

    @inline(__always) private static func clamp(_ v: Int) -> Int { v < 0 ? 0 : (v > 255 ? 255 : v) }

    // MARK: - DCT (전체 갱신)

    private func decodeDCT(_ bs: inout MVSBits, _ t1: Int, _ t2: Int, _ si: Int, _ prevDct: Int) {
        coeffs.update(repeating: 0, count: 192)
        if bs.bit() == 1 {
            // 앞 DCT 타일 반복: 계수와 기술자를 그대로
            if prevDct < 0 { warn("앞 DCT 타일 없는 반복") } else {
                coeffs.update(from: dpcm, count: 64)
                coeffs[CB] = dpcm[CB]; coeffs[CR] = dpcm[CR]
                copyDesc(prevDct, si)
            }
        } else {
            let dcMode = bs.bit()
            let threshold = bs.bit() == 1 ? t2 : t1
            if dcMode == 0 {
                let cbR = MVSRice.dc(&bs)
                let cbH = (Int(dpcm[CB]) + (dpcm[CB] < 0 ? 1 : 0)) >> 1
                coeffs[CB] = Int16(truncatingIfNeeded: (cbH - cbR) * 2)
                let crR = MVSRice.dc(&bs)
                let crH = (Int(dpcm[CR]) + (dpcm[CR] < 0 ? 1 : 0)) >> 1
                coeffs[CR] = Int16(truncatingIfNeeded: (crH - crR) * 2)
            } else {
                coeffs[CB] = dpcm[CB]; coeffs[CR] = dpcm[CR]
            }
            coeffs[0] = Int16(truncatingIfNeeded: Int(dpcm[0]) - MVSRice.dc(&bs))
            var pos = 1
            while pos < 64 {
                let r = MVSRice.ac(&bs, pos, threshold)
                if r.eob || bs.overrun { break }
                if r.skip > 0 { pos += r.skip } else { coeffs[pos] = Int16(truncatingIfNeeded: r.value); pos += 1 }
            }
            dThreshold[si] = UInt8(truncatingIfNeeded: threshold)
            let b = si * 64
            for i in 0..<64 { dY[b + i] = Int8(truncatingIfNeeded: coeffs[i]) }
            dCbValid[si] = true; dCbDC[si] = Int8(truncatingIfNeeded: coeffs[CB])
            dCrValid[si] = true; dCrDC[si] = Int8(truncatingIfNeeded: coeffs[CR])
        }
        dpcm.update(from: coeffs, count: 192)
        dequantAndRender()
    }

    private func copyDesc(_ f: Int, _ t: Int) {
        dThreshold[t] = dThreshold[f]
        (dY + t * 64).update(from: dY + f * 64, count: 64)
        dCbValid[t] = dCbValid[f]; dCbDC[t] = dCbDC[f]
        dCrValid[t] = dCrValid[f]; dCrDC[t] = dCrDC[f]
        dSeq[t] = dSeq[f]; dRef[t] = dRef[f]; dMatchX[t] = dMatchX[f]; dMatchY[t] = dMatchY[f]
    }

    // MARK: - 캐시

    private func loadCache(_ idx: Int) -> Bool {
        guard idx != 0, idx <= Self.cacheSize, idx <= cacheCount else { warn("캐시 번호 \(idx) 범위 밖 (\(cacheCount)개)"); return false }
        if cachePixels == nil {
            cachePixels = .allocate(capacity: (Self.cacheSize + 1) * 64)
            let g = UnsafeMutablePointer<UInt32>.allocate(capacity: Self.cacheSize + 1)
            g.initialize(repeating: 0, count: Self.cacheSize + 1)
            cachePixelGen = g
        }
        let pixels = cachePixels! + idx * 64
        if cachePixelGen![idx] == quantGen {
            tile.update(from: pixels, count: 64)
        } else {
            coeffs.update(repeating: 0, count: 192)
            let b = cache + idx * Self.entrySize
            for i in 0..<Self.entryY { coeffs[i] = Int16(b[i]) }
            for i in 0..<Self.entryCr { coeffs[CR + i] = Int16(b[Self.entryY + i]) }
            for i in 0..<Self.entryCb { coeffs[CB + i] = Int16(b[Self.entryY + Self.entryCr + i]) }
            dequantAndRender()
            pixels.update(from: tile, count: 64)
            cachePixelGen![idx] = quantGen
        }
        cacheLast = idx
        return true
    }

    // MARK: - 역양자화 + IDCT + 색 변환

    private func dequantAndRender() {
        let ySp = ySp, cbSp = cbSp, crSp = crSp, tile = tile
        let c = clampTab + 512 // -512..767 → 0..255
        let yFlat = transformPlane(0, lumaQuant, ySp)
        let cbFlat = transformPlane(CB, chromaQuant, cbSp)
        let crFlat = transformPlane(CR, chromaQuant, crSp)
        if cbFlat >= 0 && crFlat >= 0 {
            // 색이 타일 하나에 한 가지 (흔한 경우)
            let rA = tCrR[crFlat], gA = (tCbG[cbFlat] + tCrG[crFlat]) >> 16, bA = tCbB[cbFlat]
            if yFlat >= 0 {
                tile.update(repeating: 0xFF00_0000 | c[yFlat + rA] << 16 | c[yFlat + gA] << 8 | c[yFlat + bA], count: 64)
                return
            }
            for i in 0..<64 {
                let yv = Int(ySp[i])
                tile[i] = 0xFF00_0000 | c[yv + rA] << 16 | c[yv + gA] << 8 | c[yv + bA]
            }
            return
        }
        if yFlat >= 0 { ySp.update(repeating: UInt8(yFlat), count: 64) }
        if cbFlat >= 0 { cbSp.update(repeating: UInt8(cbFlat), count: 64) }
        if crFlat >= 0 { crSp.update(repeating: UInt8(crFlat), count: 64) }
        for i in 0..<64 {
            let yv = Int(ySp[i]), cb = Int(cbSp[i]), cr = Int(crSp[i])
            tile[i] = 0xFF00_0000 | c[yv + tCrR[cr]] << 16 | c[yv + ((tCbG[cb] + tCrG[cr]) >> 16)] << 8 | c[yv + tCbB[cb]]
        }
    }

    /// 한 평면을 역양자화·변환한다. DC 만 있으면 그 한 값을 돌려주고 out 은 그대로, 아니면 -1
    private func transformPlane(_ plane: Int, _ quant: UnsafeMutablePointer<Int>, _ out: UnsafeMutablePointer<UInt8>) -> Int {
        let c = coeffs + plane
        var ac: Int16 = 0
        for i in 1..<64 { ac |= c[i] }
        let dc = Int(c[0]) * quant[0]
        if ac == 0 { return MVSIDCT.flat(dc) }
        for i in 1..<64 {
            let n = zz[i]
            dq[n] = Int(c[i]) * quant[n]
        }
        dq[0] = dc
        MVSIDCT.idct(dq, out, ws)
        return -1
    }

    // MARK: - 화면 버퍼

    @inline(__always) private func putTile(_ tx: Int, _ ty: Int, _ tw: Int, _ th: Int) {
        guard tw > 0, th > 0 else { return }
        let w = fbW, tile = tile
        var dst = fb + ty * w + tx
        if tw == 8 {
            // 8픽셀 줄은 memmove 대신 64비트 네 번
            for r in 0..<th {
                let s = UnsafeRawPointer(tile + r * 8).assumingMemoryBound(to: UInt64.self)
                let d = UnsafeMutableRawPointer(dst)
                d.storeBytes(of: s[0], toByteOffset: 0, as: UInt64.self); d.storeBytes(of: s[1], toByteOffset: 8, as: UInt64.self)
                d.storeBytes(of: s[2], toByteOffset: 16, as: UInt64.self); d.storeBytes(of: s[3], toByteOffset: 24, as: UInt64.self)
                dst += w
            }
            return
        }
        for r in 0..<th {
            dst.update(from: tile + r * 8, count: tw)
            dst += w
        }
    }

    /// 화면 안에서 타일을 복사한다. 원본이 화면 밖이면 그대로 둔다
    private func copyTile(_ sx: Int, _ sy: Int, _ dx: Int, _ dy: Int, _ tw: Int, _ th: Int) {
        guard sx >= 0, sy >= 0 else { return }
        let n = min(tw, fbW - sx)
        guard n > 0 else { return }
        var r = 0
        while r < th && sy + r < fbH {
            (fb + (dy + r) * fbW + dx).update(from: fb + (sy + r) * fbW + sx, count: n)
            r += 1
        }
    }
}

/// MSB 먼저 읽는 비트스트림. 64비트씩 모아 둔다. 끝을 넘으면 0 을 읽고 overrun 이 켜진다
struct MVSBits {
    private let p: UnsafePointer<UInt8>
    private let endByte: Int
    private var next: Int        // 다음에 모을 바이트
    private var cache: UInt64 = 0 // 위쪽 비트부터 채움
    private var have = 0          // cache 에 있는 비트 수
    private var used = 0, limit: Int

    init(_ d: UnsafeBufferPointer<UInt8>, from: Int, to: Int) {
        p = d.baseAddress!
        next = from
        endByte = to
        limit = (to - from) * 8
    }

    var overrun: Bool { used > limit }

    @inline(__always) private mutating func refill() {
        while have <= 56 {
            let b: UInt64 = next < endByte ? UInt64(p[next]) : 0
            next += 1
            cache |= b << UInt64(56 - have)
            have += 8
        }
    }

    @inline(__always) mutating func bit() -> Int {
        if have == 0 { refill() }
        let v = Int(cache >> 63)
        cache <<= 1; have -= 1; used += 1
        return v
    }

    @inline(__always) mutating func bits(_ n: Int) -> Int {
        if n == 0 { return 0 }
        if have < n { refill() }
        let v = Int(cache >> UInt64(64 - n))
        cache <<= UInt64(n); have -= n; used += n
        return v
    }

    /// 앞 16비트를 읽지 않고 본다
    @inline(__always) mutating func peek16() -> Int {
        if have < 16 { refill() }
        return Int(cache >> 48)
    }

    @inline(__always) mutating func skip(_ n: Int) {
        if have < n { refill() }
        cache <<= UInt64(n); have -= n; used += n
    }

    /// 0 이 나올 때까지 1 의 개수 (0 도 읽는다)
    @inline(__always) mutating func ones() -> Int {
        var n = 0
        while true {
            if have < 32 { refill() }
            let lead = (~cache).leadingZeroBitCount
            if lead < have {
                n += lead
                skip(lead + 1)
                return n
            }
            n += have
            used += have; cache = 0; have = 0
            if overrun { return n }
        }
    }
}

enum MVSRice {
    @inline(__always) static func dc(_ bs: inout MVSBits) -> Int {
        let n = bs.ones()
        if n == 0 {
            if bs.bit() == 0 { return 0 }
            return bs.bit() == 1 ? -1 : 1
        }
        let mag: Int
        switch n {
        case 1: mag = 2 + bs.bits(1)
        case 2: mag = 4 + bs.bits(2)
        default: mag = ((n << 3) | bs.bits(3)) - 16
        }
        return bs.bit() == 1 ? -mag : mag
    }

    @inline(__always) private static func acStandard(_ bs: inout MVSBits) -> Int {
        let n = bs.ones()
        let mag: Int
        switch n {
        case 0: mag = 2 + bs.bits(1)
        case 1: mag = 4 + bs.bits(2)
        default: mag = ((n << 3) | bs.bits(3)) - 8
        }
        return bs.bit() == 1 ? -mag : mag
    }

    @inline(__always) private static func acNearDC(_ bs: inout MVSBits) -> Int {
        let n = bs.ones()
        let mag = n <= 3 ? 2 + n * 4 + bs.bits(2) : 18 + (n - 4) * 8 + bs.bits(3)
        return bs.bit() == 1 ? -mag : mag
    }

    @inline(__always) static func quantStep(_ pos: Int, _ t: Int) -> Int {
        if pos <= 5 {
            if t > 14 { return 2 }
            return pos < t ? 8 : 16
        }
        if t > 14 && pos < t { return 2 }
        if t > 14 { return 8 }
        return pos < t ? 8 : 16
    }

    @inline(__always) static func ac(_ bs: inout MVSBits, _ pos: Int, _ t: Int) -> (value: Int, eob: Bool, skip: Int) {
        if bs.bit() == 1 {
            let raw = pos <= 5 ? acNearDC(&bs) : acStandard(&bs)
            return (raw * quantStep(pos, t), false, 0)
        }
        switch bs.bits(2) {
        case 0: return (0, false, 0)
        case 1:
            if bs.bit() == 0 { return (0, true, 0) }
            let ext = bs.bits(2)
            if ext < 3 { return (0, false, ext + 3) }
            var run = 6
            while true {
                let c = bs.bits(3)
                run += c
                if c < 7 || run + pos >= 64 || bs.overrun { break }
            }
            return (0, false, run)
        case 2: return (quantStep(pos, t), false, 0)
        default: return (-quantStep(pos, t), false, 0)
        }
    }
}

/// K.5 AC 휘도 허프만 표 (표준 JPEG)
enum MVSHuffman {
    private static let bitsTable: [Int] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125]
    private static let values: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    /// 앞 16비트로 바로 찾는 표: 값 = 길이 << 8 | 기호 (정규 허프만 부호를 길이 순서로 매긴다)
    static func fill(_ t: UnsafeMutablePointer<UInt16>) {
        t.initialize(repeating: 0, count: 65536)
        var code = 0, vi = 0
        for len in 1...16 {
            for _ in 0..<bitsTable[len - 1] {
                let lo = code << (16 - len), n = 1 << (16 - len)
                let e = UInt16(len << 8 | Int(values[vi]))
                for i in 0..<n { t[lo + i] = e }
                code += 1; vi += 1
            }
            code <<= 1
        }
    }
}

enum MVSTables {
    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]
    static let defaultLuma: [Int] = [
        16, 11, 11, 14, 24, 22, 24, 33, 11, 12, 11, 11, 26, 18, 19, 23,
        13, 13, 14, 24, 20, 21, 22, 28, 13, 17, 14, 21, 23, 25, 34, 34,
        17, 22, 18, 25, 31, 32, 34, 44, 24, 20, 17, 27, 35, 40, 44, 54,
        30, 35, 28, 30, 34, 44, 54, 64, 35, 30, 33, 38, 45, 55, 65, 75,
    ]
    static let defaultChroma: [Int] = [
        19, 19, 24, 47, 76, 99, 99, 99, 19, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
        76, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    ]
    // YCbCr → RGB (libjpeg jdcolor.c, 16bit 고정소수점), 128 을 뺀 색차 값으로 찾는다
    static let crR: [Int] = (0..<256).map { (91881 * ($0 - 128) + 32768) >> 16 }
    static let cbB: [Int] = (0..<256).map { (116130 * ($0 - 128) + 32768) >> 16 }
    static let crG: [Int] = (0..<256).map { -46802 * ($0 - 128) }
    static let cbG: [Int] = (0..<256).map { -22554 * ($0 - 128) + 32768 }
}

/// libjpeg jpeg_idct_islow 정수 IDCT (애플 뷰어와 같은 결과)
enum MVSIDCT {
    private static let CONST_BITS = 13, PASS1_BITS = 2
    private static let F0298 = 2446, F0390 = 3196, F0541 = 4433, F0765 = 6270, F0899 = 7373, F1175 = 9633
    private static let F1501 = 12299, F1847 = 15137, F1961 = 16069, F2053 = 16819, F2562 = 20995, F3072 = 25172

    @inline(__always) private static func range(_ v: Int) -> UInt8 {
        let x = v & 0x3FF
        if x < 128 { return UInt8(x + 128) }
        if x < 512 { return 255 }
        if x < 896 { return 0 }
        return UInt8(x - 896)
    }

    static func flat(_ dc: Int) -> Int {
        Int(range(((dc << PASS1_BITS) + (1 << (PASS1_BITS + 2))) >> (PASS1_BITS + 3)))
    }

    static func idct(_ b: UnsafeMutablePointer<Int>, _ out: UnsafeMutablePointer<UInt8>, _ ws: UnsafeMutablePointer<Int>) {
        for c in 0..<8 {
            if b[c + 8] == 0 && b[c + 16] == 0 && b[c + 24] == 0 && b[c + 32] == 0 && b[c + 40] == 0 && b[c + 48] == 0 && b[c + 56] == 0 {
                let dc = b[c] << PASS1_BITS
                for r in 0..<8 { ws[c + r * 8] = dc }
                continue
            }
            var z2 = b[c + 16], z3 = b[c + 48]
            var z1 = (z2 + z3) * F0541
            var t2 = z1 - z3 * F1847
            var t3 = z1 + z2 * F0765
            z2 = b[c]; z3 = b[c + 32]
            var t0 = (z2 + z3) << CONST_BITS
            var t1 = (z2 - z3) << CONST_BITS
            let t10 = t0 + t3, t13 = t0 - t3, t11 = t1 + t2, t12 = t1 - t2
            t0 = b[c + 56]; t1 = b[c + 40]; t2 = b[c + 24]; t3 = b[c + 8]
            z1 = t0 + t3; z2 = t1 + t2; z3 = t0 + t2
            var z4 = t1 + t3
            let z5 = (z3 + z4) * F1175
            t0 *= F0298; t1 *= F2053; t2 *= F3072; t3 *= F1501
            z1 *= -F0899; z2 *= -F2562
            z3 = z3 * -F1961 + z5; z4 = z4 * -F0390 + z5
            t0 += z1 + z3; t1 += z2 + z4; t2 += z2 + z3; t3 += z1 + z4
            let sh = CONST_BITS - PASS1_BITS, rd = 1 << (sh - 1)
            ws[c] = (t10 + t3 + rd) >> sh; ws[c + 56] = (t10 - t3 + rd) >> sh
            ws[c + 8] = (t11 + t2 + rd) >> sh; ws[c + 48] = (t11 - t2 + rd) >> sh
            ws[c + 16] = (t12 + t1 + rd) >> sh; ws[c + 40] = (t12 - t1 + rd) >> sh
            ws[c + 24] = (t13 + t0 + rd) >> sh; ws[c + 32] = (t13 - t0 + rd) >> sh
        }
        for r in stride(from: 0, to: 64, by: 8) {
            var z2 = ws[r + 2], z3 = ws[r + 6]
            var z1 = (z2 + z3) * F0541
            var t2 = z1 - z3 * F1847
            var t3 = z1 + z2 * F0765
            var t0 = (ws[r] + ws[r + 4]) << CONST_BITS
            var t1 = (ws[r] - ws[r + 4]) << CONST_BITS
            let t10 = t0 + t3, t13 = t0 - t3, t11 = t1 + t2, t12 = t1 - t2
            t0 = ws[r + 7]; t1 = ws[r + 5]; t2 = ws[r + 3]; t3 = ws[r + 1]
            z1 = t0 + t3; z2 = t1 + t2; z3 = t0 + t2
            var z4 = t1 + t3
            let z5 = (z3 + z4) * F1175
            t0 *= F0298; t1 *= F2053; t2 *= F3072; t3 *= F1501
            z1 *= -F0899; z2 *= -F2562
            z3 = z3 * -F1961 + z5; z4 = z4 * -F0390 + z5
            t0 += z1 + z3; t1 += z2 + z4; t2 += z2 + z3; t3 += z1 + z4
            let sh = CONST_BITS + PASS1_BITS + 3, rd = 1 << (sh - 1)
            out[r] = range((t10 + t3 + rd) >> sh); out[r + 7] = range((t10 - t3 + rd) >> sh)
            out[r + 1] = range((t11 + t2 + rd) >> sh); out[r + 6] = range((t11 - t2 + rd) >> sh)
            out[r + 2] = range((t12 + t1 + rd) >> sh); out[r + 5] = range((t12 - t1 + rd) >> sh)
            out[r + 3] = range((t13 + t0 + rd) >> sh); out[r + 4] = range((t13 - t0 + rd) >> sh)
        }
    }
}

#if DEBUG
/// 시험용: 접속 뒤 처음 받은 MVS 사각형 60개를 Caches/mvs-dump.bin 에, 그때 화면을 mvs-fb.bin 에 남긴다 (참고 구현과 비교).
/// 사각형마다 [x y w h 화면폭 화면높이 u16][길이 u32][본문]
enum MVSDump {
    private static var count = 0
    private static var buf = [UInt8]()
    private static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

    static func add(_ data: [UInt8], x: Int, y: Int, w: Int, h: Int, pixels: UnsafeMutablePointer<UInt32>, fbWidth: Int, fbHeight: Int) {
        guard count < 60 else { return }
        count += 1
        for v in [x, y, w, h, fbWidth, fbHeight] { buf += [UInt8].be16(v) }
        buf += [UInt8].be32(UInt32(data.count)) + data
        if count == 60 {
            try? Data(buf).write(to: dir.appendingPathComponent("mvs-dump.bin"))
            try? Data(bytes: pixels, count: fbWidth * fbHeight * 4).write(to: dir.appendingPathComponent("mvs-fb.bin"))
            DebugLog.write("MVS 시험 기록 저장: 사각형 60개 \(buf.count / 1000)KB")
            buf = []
        }
    }
}
#endif
