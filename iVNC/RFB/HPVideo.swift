import CoreMedia
import Foundation
import VideoToolbox

/// 고성능 영상: RTP 패킷 → HEVC 그림 (noVNC-ARD `ard/hp/rtp-video.js` 를 옮김)
///
/// 서버는 화면을 가로 줄무늬로 나눠, 줄무늬마다 HEVC 그림 하나씩 보낸다. 모두 한 비트스트림이고,
/// 줄무늬마다 RTP 스트림(SSRC = 기준 + 줄무늬 번호)이 따로 있다.
/// 페이로드는 RFC 7798 형식에 16bit DON(디코딩 순서 번호)이 늘 붙는다. DON 은 그림마다 하나, 모든 스트림에 걸쳐 센다.
/// 헤더 확장(8바이트)에 그림의 패킷 수가 있다.
///
/// 그림의 패킷을 도착 순서와 상관없이 모아 NAL 들로 되살리고, 첫 키 그림부터 DON 순서대로 내보낸다.
/// 빠진 패킷은 받는 쪽이 NACK 으로 다시 요청한다(서버가 따르는지는 로그 "되찾음"으로 확인). 그래도 빠진 그림 때문에 막히면 가장 가까운 완성된 키 그림으로 건너뛴다.
/// 키 그림도 없으면 버퍼를 비우고 다음 키 그림을 기다리며 onStall 을 부른다 (키 그림을 요청하거나 다시 제안해야 한다).
final class HPVideoAssembler {
    struct Picture {
        let don: Int
        let stripe: Int
        let key: Bool
        /// 시작 코드 없는 NAL 들
        let nals: [[UInt8]]
    }

    private enum Part {
        case units([[UInt8]])
        case fragment([UInt8])
    }

    private final class Pending {
        let stripe: Int
        let count: Int
        var parts: [UInt16: Part] = [:]
        var built: (nals: [[UInt8]], key: Bool)?
        var doneAt: TimeInterval = 0
        init(stripe: Int, count: Int) { self.stripe = stripe; self.count = count }
    }

    private static let maxBuffered = 512
    /// 뒤 그림이 끝났는데 앞 그림이 이만큼 안 채워지면 막힌 것. 빠진 패킷을 NACK 으로 다시 받을 시간(요청 두 번)을 준다
    private static let stallSeconds = 0.3

    private let baseSSRC: UInt32
    private let stripes: Int
    var onPicture: ((Picture) -> Void)?
    var onStall: (() -> Void)?

    private var pictures: [Int: Pending] = [:]
    private var ref: Int?
    private var first: Int?
    private var next: Int?
    private(set) var stalled = false

    private(set) var emitted = 0, skipped = 0, malformed = 0, ignored = 0, keyWaits = 0

    init(baseSSRC: UInt32, stripes: Int) {
        self.baseSSRC = baseSSRC
        self.stripes = max(stripes, 1)
    }

    var diag: String { "모으는 중 \(pictures.count), 다음 \(next.map(String.init) ?? "-"), 내보냄 \(emitted), 건너뜀 \(skipped), 잘못됨 \(malformed), 무시 \(ignored), 키 기다림 \(keyWaits)번\(stalled ? ", 멈춤" : "")" }

    private static func delta(_ to: Int, _ from: Int) -> Int {
        ((to - from) % 0x10000 + 0x10000 + 0x8000) % 0x10000 - 0x8000
    }

    func push(_ rtp: SRTPContext.RTPPacket, now: TimeInterval) {
        guard !stalled else { ignored += 1; return }
        collect(rtp, now: now)
        tick(now: now)
    }

    private func collect(_ rtp: SRTPContext.RTPPacket, now: TimeInterval) {
        let stripe = Int(Int64(rtp.ssrc) - Int64(baseSSRC))
        let ext = rtp.extensionBytes
        guard stripe >= 0, stripe < stripes, ext.count == 8 else { ignored += 1; return }
        let count = Int(ext[4]) << 8 | Int(ext[5])
        guard count > 0, let (don16, part) = Self.parse(rtp.payload) else { malformed += 1; return }

        if ref == nil { ref = don16 }
        let base = next ?? ref!
        let don = base + Self.delta(don16, base)
        if let next, don < next { ignored += 1; return }

        let pic: Pending
        if let p = pictures[don] {
            guard p.stripe == stripe, p.count == count else { malformed += 1; return }
            pic = p
        } else {
            pic = Pending(stripe: stripe, count: count)
            pictures[don] = pic
        }
        guard pic.parts[rtp.seq] == nil, pic.parts.count < pic.count else { return }
        pic.parts[rtp.seq] = part
        guard pic.parts.count == pic.count else { return }

        // 순번 순서로 (한 그림은 순번 공간의 절반보다 훨씬 짧으니 첫 패킷과의 거리로 정렬하면 넘침도 맞다)
        let firstSeq = Int(pic.parts.keys.first!)
        let ordered = pic.parts.sorted { Self.delta(Int($0.key), firstSeq) < Self.delta(Int($1.key), firstSeq) }.map(\.value)
        guard let built = Self.assemble(ordered) else { malformed += 1; return }
        pic.built = built
        pic.doneAt = now

        if next == nil && built.key { start(at: don) }
        emit()
    }

    /// (DON, 조각) 또는 잘못되면 nil
    private static func parse(_ p: [UInt8]) -> (Int, Part)? {
        guard p.count >= 4 else { return nil }
        let type = Int(p[0] >> 1) & 0x3F
        if type < 48 {
            // NAL 머리, DON, 나머지
            return (Int(p[2]) << 8 | Int(p[3]), .units([Array(p[0..<2]) + p[4...]]))
        }
        if type == 48 {
            // 묶음: 머리, DON, { 크기, NAL } 반복
            var units: [[UInt8]] = []
            var o = 4
            while o < p.count {
                guard o + 2 <= p.count else { return nil }
                let size = Int(p[o]) << 8 | Int(p[o + 1])
                o += 2
                guard size >= 2, o + size <= p.count else { return nil }
                units.append(Array(p[o..<(o + size)]))
                o += size
            }
            return units.isEmpty ? nil : (Int(p[2]) << 8 | Int(p[3]), .units(units))
        }
        if type == 49 {
            // 조각: 머리, 조각 머리, DON, 조각 데이터
            guard p.count >= 5 else { return nil }
            return (Int(p[3]) << 8 | Int(p[4]), .fragment(p))
        }
        return nil
    }

    private static func assemble(_ parts: [Part]) -> (nals: [[UInt8]], key: Bool)? {
        var units: [[UInt8]] = []
        var open: (type: UInt8, data: [UInt8])?
        for part in parts {
            switch part {
            case .units(let u):
                guard open == nil else { return nil }
                units += u
            case .fragment(let p):
                let type = p[2] & 0x3F
                if p[2] & 0x80 != 0 {
                    // 시작: NAL 자체 머리는 페이로드 머리에서 종류만 바꾼 것
                    guard open == nil else { return nil }
                    open = (type, [(p[0] & 0x81) | (type << 1), p[1]])
                } else if open == nil || open!.type != type {
                    return nil
                }
                open!.data += p[5...]
                if p[2] & 0x40 != 0 {
                    units.append(open!.data)
                    open = nil
                }
            }
        }
        guard open == nil, !units.isEmpty else { return nil }
        let key = units.contains { (16...21).contains(Int($0[0] >> 1) & 0x3F) } // IRAP
        return (units, key)
    }

    private func start(at don: Int) {
        pictures = pictures.filter { $0.key >= don }
        first = don
        next = don
    }

    private func emit() {
        while let n = next, let pic = pictures[n], let built = pic.built {
            pictures[n] = nil
            next = n + 1
            emitted += 1
            onPicture?(Picture(don: n, stripe: pic.stripe, key: built.key, nals: built.nals))
        }
    }

    func tick(now: TimeInterval) {
        guard !stalled else { return }
        var stall = pictures.count > Self.maxBuffered
        if !stall && next != nil {
            // 기다리는 그림이 안 끝났는데 뒤 그림이 끝난 지 오래면 막힌 것
            stall = pictures.values.contains { $0.built != nil && now - $0.doneAt > Self.stallSeconds }
        }
        guard stall else { return }
        if let n = next, let key = pictures.filter({ $0.key > n && $0.value.built?.key == true }).keys.min() {
            for d in pictures.keys where d < key { pictures[d] = nil; skipped += 1 }
            next = key
            emit()
            return
        }
        // 멈추지 않고 키 그림을 기다린다: 다음 완성된 키 그림부터 다시 내보낸다 (키 그림 요청·다시 제안은 onStall 쪽에서)
        pictures.removeAll()
        next = nil
        first = nil
        ref = nil
        keyWaits += 1
        onStall?()
    }
}

/// HEVC 그림(줄무늬) → VideoToolbox 디코딩 → BGRA 픽셀 버퍼
final class HPVideoDecoder {
    /// 디코딩된 줄무늬 하나 (BGRA 픽셀 버퍼, 줄무늬 번호)
    var onStripe: ((CVPixelBuffer, Int) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "HPDecode", qos: .userInteractive)
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [[UInt8]] = []
    private let lock = NSLock()
    private var _submitted = 0, _decoded = 0, _failed = 0, _dropped = 0
    private var backlog = 0
    private var skippingToKey = false
    private var _lastOutput = ProcessInfo.processInfo.systemUptime
    /// 밀려서 키 그림부터 다시 받아야 할 때 (다시 제안)
    var onNeedKey: (() -> Void)?

    /// 마지막으로 그림이 나온 시각 (화면이 멈췄는지 판단)
    var lastOutput: TimeInterval { lock.lock(); defer { lock.unlock() }; return _lastOutput }

    var stats: String {
        lock.lock(); defer { lock.unlock() }
        return "디코더 넣음 \(_submitted), 나옴 \(_decoded), 실패 \(_failed), 버림 \(_dropped), 밀림 \(backlog)"
    }

    func push(_ pic: HPVideoAssembler.Picture) {
        lock.lock()
        // 디코더가 많이 밀리면 다음 키 그림까지 버린다 (중간 그림만 버리면 뒤 그림이 깨진다).
        // 키 그림이 안 오면 3초 뒤 다시 제안해 새로 받는다
        var needKey = false
        if backlog > 60 && !skippingToKey { skippingToKey = true; needKey = true }
        if skippingToKey && !pic.key {
            _dropped += 1; lock.unlock()
            // 서버는 키 그림을 처음과 다시 제안했을 때만 보낸다: 기다리기만 하면 영원히 멈춘다 (2026-11-02 잠금 해제 때 실측)
            if needKey { onNeedKey?() }
            return
        }
        skippingToKey = false
        backlog += 1
        lock.unlock()
        queue.async { [weak self] in
            self?.decode(pic)
            self?.lock.lock(); self?.backlog -= 1; self?.lock.unlock()
        }
    }

    func stop() {
        queue.async { [weak self] in
            if let s = self?.session { VTDecompressionSessionInvalidate(s) }
            self?.session = nil
        }
    }

    private func count(_ body: (HPVideoDecoder) -> Void) { lock.lock(); body(self); lock.unlock() }

    private func decode(_ pic: HPVideoAssembler.Picture) {
        if pic.key {
            let sets = [32, 33, 34].compactMap { t in pic.nals.first { Int($0[0] >> 1) & 0x3F == t } }
            if sets.count == 3 && sets != parameterSets {
                guard makeSession(sets) else { return }
            }
        }
        guard let session, let format else { count { $0._dropped += 1 }; return }

        // 길이(4바이트) 붙은 NAL 들 (매개변수 묶음은 형식 설명에 들어 있으니 뺀다)
        var data = [UInt8]()
        for nal in pic.nals where !(32...34).contains(Int(nal[0] >> 1) & 0x3F) {
            data += [UInt8].be32(UInt32(nal.count)) + nal
        }
        guard !data.isEmpty else { return }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) == noErr
        else { count { $0._failed += 1 }; return }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample
        else { count { $0._failed += 1 }; return }

        count { $0._submitted += 1 }
        let stripe = pic.stripe
        let rc = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.count { $0._failed += 1 }
                return
            }
            self.count { $0._decoded += 1; $0._lastOutput = ProcessInfo.processInfo.systemUptime }
            self.logOutputOnce(image)
            self.onStripe?(image, stripe)
        }
        if rc != noErr {
            count { $0._failed += 1 }
            DebugLog.write("HP 디코딩 실패 \(rc)")
            if rc == kVTInvalidSessionErr { self.session = nil; parameterSets = [] }
        }
    }

    private var loggedOutput = false

    /// 디코더 출력 형식을 한 번 적는다. 출력 버퍼는 복사 없이 화면 레이어에 바로 넣는다
    /// (예전 검은 화면은 버퍼 탓이 아니라 레이어 크기가 0 이던 것이었다)
    private func logOutputOnce(_ src: CVPixelBuffer) {
        guard !loggedOutput else { return }
        loggedOutput = true
        let f = CVPixelBufferGetPixelFormatType(src)
        let fcc = String(bytes: [24, 16, 8, 0].map { UInt8((f >> $0) & 0xFF) }, encoding: .ascii) ?? "\(f)"
        DebugLog.write("HP 디코더 출력: \(CVPixelBufferGetWidth(src))x\(CVPixelBufferGetHeight(src)) 형식 \(fcc) IOSurface \(CVPixelBufferGetIOSurface(src) != nil ? "있음" : "없음")")
    }

    private func makeSession(_ sets: [[UInt8]]) -> Bool {
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        var fmt: CMVideoFormatDescription?
        let rc: OSStatus = sets[0].withUnsafeBufferPointer { a in
            sets[1].withUnsafeBufferPointer { b in
                sets[2].withUnsafeBufferPointer { c in
                    let ptrs = [a.baseAddress!, b.baseAddress!, c.baseAddress!]
                    let sizes = sets.map(\.count)
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                                                                               parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                               nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
                }
            }
        }
        guard rc == noErr, let fmt else {
            DebugLog.write("HP 형식 설명 만들기 실패 \(rc)")
            onError?("HEVC 형식 설명 실패 \(rc)")
            return false
        }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var s: VTDecompressionSession?
        let rc2 = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt, decoderSpecification: nil,
                                               imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard rc2 == noErr, let s else {
            DebugLog.write("HP 디코더 만들기 실패 \(rc2) (\(dims.width)x\(dims.height))")
            onError?("HEVC 디코더를 만들 수 없음 \(rc2)")
            return false
        }
        var hw: CFBoolean?
        VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hw)
        DebugLog.write("HP 디코더 준비: 줄무늬 \(dims.width)x\(dims.height), 하드웨어 \(hw.map { CFBooleanGetValue($0) ? "예" : "아니오" } ?? "모름")")
        session = s
        format = fmt
        parameterSets = sets
        return true
    }
}
