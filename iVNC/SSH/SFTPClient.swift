import Foundation
import NIOCore
import NIOSSH
import NIOPosix

/// SFTP 버전 3 클라이언트 (SSH 접속 안의 "sftp" 서브시스템 채널 하나).
/// 빠르게: 읽기·쓰기 요청을 여러 개 미리 보내 두고(파이프라이닝) 오는 대로 받는다. 조각 크기는 서버가 알려 주는 최대
/// (OpenSSH limits@openssh.com) 를 쓰고, 모르면 32KB. 모든 상태는 채널의 이벤트 루프에서만 만진다.
final class SFTPClient {
    struct Entry: Identifiable, Hashable {
        var id: String { path }
        let name: String
        let path: String
        let attrs: Attrs
        var isDirectory: Bool { attrs.isDirectory }
    }

    struct Attrs: Hashable {
        var size: UInt64?
        var permissions: UInt32?
        var mtime: UInt32?
        var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }
        var isSymlink: Bool { (permissions ?? 0) & 0o170000 == 0o120000 }
        var modified: Date? { mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    }

    struct Failure: LocalizedError {
        let code: UInt32
        let message: String
        var errorDescription: String? {
            switch code {
            case 2: return "파일이나 폴더가 없습니다."
            case 3: return "권한이 없습니다."
            case 4: return message.isEmpty ? "서버에서 실패했습니다." : "서버에서 실패했습니다: \(message)"
            default: return message.isEmpty ? "SFTP 오류 (\(code))" : message
            }
        }
    }

    struct Cancelled: LocalizedError {
        var errorDescription: String? { "취소했습니다." }
    }

    fileprivate enum Response {
        case status(UInt32, String)
        case handle(ByteBuffer)
        case data(ByteBuffer)
        case name([(String, Attrs)])
        case attrs(Attrs)
        case extended(ByteBuffer)
    }

    let channel: Channel
    fileprivate let handler: SFTPHandler
    /// 한 번에 읽고 쓰는 크기
    private(set) var readChunk = 32 * 1024
    private(set) var writeChunk = 32 * 1024
    /// 동시에 보내 두는 요청 바이트 (SSH 채널 창 8MB 를 넘지 않게)
    let bytesInFlight = 6 * 1024 * 1024

    private init(channel: Channel, handler: SFTPHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// 채널에 sftp 를 열고 버전을 맞춘다
    /// command 가 있으면 sftp 서브시스템 대신 그 명령(표준 입출력이 sftp-server 에 이어진 것)으로 연다
    static func start(on child: Channel, command: String? = nil) -> EventLoopFuture<SFTPClient> {
        child.pipeline.handler(type: SFTPHandler.self).flatMap { h in
            let client = SFTPClient(channel: child, handler: h)
            let request: Any = command.map { SSHChannelRequestEvent.ExecRequest(command: $0, wantReply: true) }
                ?? SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
            return child.triggerUserOutboundEvent(request)
                .flatMap { h.sendInit() }
                .flatMap { exts -> EventLoopFuture<SFTPClient> in
                    guard exts["limits@openssh.com"] != nil else { return child.eventLoop.makeSucceededFuture(client) }
                    return h.request(200) { $0.writeSSHString("limits@openssh.com") }.map { r in
                        if case .extended(var b) = r,
                           let _ = b.readInteger(as: UInt64.self),
                           let maxRead = b.readInteger(as: UInt64.self),
                           let maxWrite = b.readInteger(as: UInt64.self) {
                            // 너무 크면 한 조각이 채널 창을 오래 막아서 256KB 로 자른다
                            if maxRead > 0 { client.readChunk = Int(min(maxRead, 256 * 1024)) }
                            if maxWrite > 0 { client.writeChunk = Int(min(maxWrite, 256 * 1024)) }
                        }
                        return client
                    }.recover { _ in client }
                }
        }
    }

    func close() { channel.close(promise: nil) }

    // MARK: 기본 요청 (async)

    func realpath(_ path: String) async throws -> String {
        let r = try await handler.request(16) { $0.writeSSHString(path) }.get()
        guard case .name(let list) = r, let first = list.first else { throw Self.fail(r) }
        return first.0
    }

    func stat(_ path: String) async throws -> Attrs {
        let r = try await handler.request(17) { $0.writeSSHString(path) }.get()
        guard case .attrs(let a) = r else { throw Self.fail(r) }
        return a
    }

    func list(_ path: String) async throws -> [Entry] {
        let h = try await openDir(path)
        var out: [Entry] = []
        defer { closeHandle(h) }
        while true {
            let r = try await handler.request(12) { $0.writeSSHString(h) }.get()
            switch r {
            case .name(let list):
                for (name, a) in list where name != "." && name != ".." {
                    out.append(Entry(name: name, path: Self.join(path, name), attrs: a))
                }
            case .status(1, _):
                return out
            default:
                throw Self.fail(r)
            }
        }
    }

    func mkdir(_ path: String) async throws { try await simple(14) { $0.writeSSHString(path); $0.writeInteger(UInt32(0)) } }
    func rmdir(_ path: String) async throws { try await simple(15) { $0.writeSSHString(path) } }
    func remove(_ path: String) async throws { try await simple(13) { $0.writeSSHString(path) } }
    func rename(_ from: String, to: String) async throws { try await simple(18) { $0.writeSSHString(from); $0.writeSSHString(to) } }

    /// 폴더째 지우기 (안쪽부터)
    func removeRecursive(_ e: Entry) async throws {
        if e.isDirectory && !e.attrs.isSymlink {
            for c in try await list(e.path) { try await removeRecursive(c) }
            try await rmdir(e.path)
        } else {
            try await remove(e.path)
        }
    }

    // MARK: 받기 / 올리기 (파이프라이닝)

    /// 서버 파일을 local 에 받는다. progress 는 받은 바이트 수만큼 (이벤트 루프에서 불린다)
    func download(_ remote: String, to local: URL, progress: @escaping (Int) -> Void, isCancelled: @escaping () -> Bool) async throws {
        let size = try? await stat(remote).size
        let h = try await open(remote, flags: 0x01)
        defer { closeHandle(h) }
        let fd = Darwin.open(local.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(fd) }
        let job = DownloadJob(client: self, handle: h, fd: fd, size: size, progress: progress, isCancelled: isCancelled)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            channel.eventLoop.execute { job.start(c) }
        }
    }

    /// local 파일을 서버에 올린다
    func upload(_ local: URL, to remote: String, progress: @escaping (Int) -> Void, isCancelled: @escaping () -> Bool) async throws {
        let fd = Darwin.open(local.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        fstat(fd, &st)
        // 쓰기 + 만들기 + 비우기
        let h = try await open(remote, flags: 0x02 | 0x08 | 0x10)
        defer { closeHandle(h) }
        let job = UploadJob(client: self, handle: h, fd: fd, size: Int(st.st_size), progress: progress, isCancelled: isCancelled)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            channel.eventLoop.execute { job.start(c) }
        }
    }

    // MARK: 내부

    /// 서버 → 서버: 한쪽에서 읽은 조각을 바로 다른 쪽에 쓴다 (이 맥 디스크를 거치지 않음, 파이프라이닝)
    static func relay(from src: SFTPClient, _ srcPath: String, size: UInt64?, to dst: SFTPClient, _ dstPath: String,
                      progress: @escaping (Int) -> Void, isCancelled: @escaping () -> Bool) async throws {
        let rh = try await src.open(srcPath, flags: 0x01)
        defer { src.closeHandle(rh) }
        let wh = try await dst.open(dstPath, flags: 0x02 | 0x08 | 0x10)
        defer { dst.closeHandle(wh) }
        let job = RelayJob(src: src, dst: dst, rh: rh, wh: wh, size: size, progress: progress, isCancelled: isCancelled)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            src.channel.eventLoop.execute { job.start(c) }
        }
    }

    fileprivate func open(_ path: String, flags: UInt32) async throws -> ByteBuffer {
        let r = try await handler.request(3) { b in
            b.writeSSHString(path); b.writeInteger(flags); b.writeInteger(UInt32(0)) // 속성 없음
        }.get()
        guard case .handle(let h) = r else { throw Self.fail(r) }
        return h
    }

    private func openDir(_ path: String) async throws -> ByteBuffer {
        let r = try await handler.request(11) { $0.writeSSHString(path) }.get()
        guard case .handle(let h) = r else { throw Self.fail(r) }
        return h
    }

    fileprivate func closeHandle(_ h: ByteBuffer) {
        _ = handler.request(4) { $0.writeSSHString(h) }
    }

    private func simple(_ type: UInt8, _ body: @escaping (inout ByteBuffer) -> Void) async throws {
        let r = try await handler.request(type, body).get()
        guard case .status(0, _) = r else { throw Self.fail(r) }
    }

    fileprivate static func fail(_ r: Response) -> Error {
        if case .status(let code, let msg) = r { return Failure(code: code, message: msg) }
        return Failure(code: 99, message: "서버 응답을 알 수 없습니다.")
    }

    static func join(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }

    // 이벤트 루프에서만 쓰는 요청 보내기
    fileprivate func readRequest(_ h: ByteBuffer, offset: UInt64, length: Int) -> EventLoopFuture<Response> {
        handler.request(5) { b in b.writeSSHString(h); b.writeInteger(offset); b.writeInteger(UInt32(length)) }
    }

    fileprivate func writeRequest(_ h: ByteBuffer, offset: UInt64, data: [UInt8]) -> EventLoopFuture<Response> {
        handler.request(6) { b in b.writeSSHString(h); b.writeInteger(offset); b.writeInteger(UInt32(data.count)); b.writeBytes(data) }
    }
}

/// 받기: 읽기 요청을 bytesInFlight 만큼 미리 보내 두고, 온 조각은 그 자리에 pwrite
private final class DownloadJob {
    let client: SFTPClient
    let handle: ByteBuffer
    let fd: Int32
    let size: UInt64?
    let progress: (Int) -> Void
    let isCancelled: () -> Bool
    var next: UInt64 = 0
    var inflight = 0
    var eof = false
    var done = false
    var cont: CheckedContinuation<Void, Error>?

    init(client: SFTPClient, handle: ByteBuffer, fd: Int32, size: UInt64?, progress: @escaping (Int) -> Void, isCancelled: @escaping () -> Bool) {
        self.client = client; self.handle = handle; self.fd = fd; self.size = size; self.progress = progress; self.isCancelled = isCancelled
    }

    func start(_ c: CheckedContinuation<Void, Error>) {
        cont = c
        pump()
    }

    private var maxInflight: Int { max(4, client.bytesInFlight / client.readChunk) }

    private func pump() {
        guard !done else { return }
        if isCancelled() { finish(SFTPClient.Cancelled()); return }
        while inflight < maxInflight && !eof {
            if let size, next >= size { break }
            request(offset: next, length: client.readChunk)
            next += UInt64(client.readChunk)
        }
        if inflight == 0 { finish(nil) }
    }

    private func request(offset: UInt64, length: Int) {
        inflight += 1
        client.readRequest(handle, offset: offset, length: length).whenComplete { [self] result in
            inflight -= 1
            switch result {
            case .success(.data(var buf)):
                let got = buf.readableBytes
                let ok = buf.withUnsafeReadableBytes { p in pwrite(fd, p.baseAddress, got, off_t(offset)) == got }
                if !ok { finish(CocoaError(.fileWriteUnknown)); return }
                progress(got)
                // 덜 왔으면 나머지를 다시 (파일 끝이면 다음 요청이 EOF 를 준다)
                if got > 0 && got < length { request(offset: offset + UInt64(got), length: length - got) }
            case .success(.status(1, _)):
                eof = true
            case .success(let r):
                finish(SFTPClient.fail(r)); return
            case .failure(let e):
                finish(e); return
            }
            pump()
        }
    }

    private func finish(_ error: Error?) {
        guard !done else { return }
        done = true
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
        cont = nil
    }
}

/// 올리기: 파일을 조각내어 쓰기 요청을 미리 보내 두고 OK 를 기다린다
private final class UploadJob {
    let client: SFTPClient
    let handle: ByteBuffer
    let fd: Int32
    let size: Int
    let progress: (Int) -> Void
    let isCancelled: () -> Bool
    var next = 0
    var inflight = 0
    var done = false
    var cont: CheckedContinuation<Void, Error>?

    init(client: SFTPClient, handle: ByteBuffer, fd: Int32, size: Int, progress: @escaping (Int) -> Void, isCancelled: @escaping () -> Bool) {
        self.client = client; self.handle = handle; self.fd = fd; self.size = size; self.progress = progress; self.isCancelled = isCancelled
    }

    func start(_ c: CheckedContinuation<Void, Error>) {
        cont = c
        pump()
    }

    private var maxInflight: Int { max(4, client.bytesInFlight / client.writeChunk) }

    private func pump() {
        guard !done else { return }
        if isCancelled() { finish(SFTPClient.Cancelled()); return }
        while inflight < maxInflight && next < size {
            let len = min(client.writeChunk, size - next)
            var chunk = [UInt8](repeating: 0, count: len)
            let n = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress, len, off_t(next)) }
            guard n == len else { finish(CocoaError(.fileReadUnknown)); return }
            let offset = next
            next += len
            inflight += 1
            client.writeRequest(handle, offset: UInt64(offset), data: chunk).whenComplete { [self] result in
                inflight -= 1
                switch result {
                case .success(.status(0, _)): progress(len)
                case .success(let r): finish(SFTPClient.fail(r)); return
                case .failure(let e): finish(e); return
                }
                pump()
            }
        }
        if inflight == 0 && next >= size { finish(nil) }
    }

    private func finish(_ error: Error?) {
        guard !done else { return }
        done = true
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
        cont = nil
    }
}

/// 서버 → 서버 이어 옮기기. 읽기 요청을 미리 보내 두고, 온 조각은 그대로 상대 서버에 쓴다 (모두 보내는 쪽 이벤트 루프에서)
private final class RelayJob {
    let src: SFTPClient
    let dst: SFTPClient
    let rh: ByteBuffer
    let wh: ByteBuffer
    let size: UInt64?
    let progress: (Int) -> Void
    let isCancelled: () -> Bool
    let chunk: Int
    var next: UInt64 = 0
    var inflight = 0
    var eof = false
    var done = false
    var cont: CheckedContinuation<Void, Error>?

    init(src: SFTPClient, dst: SFTPClient, rh: ByteBuffer, wh: ByteBuffer, size: UInt64?,
         progress: @escaping (Int) -> Void, isCancelled: @escaping () -> Bool) {
        self.src = src; self.dst = dst; self.rh = rh; self.wh = wh; self.size = size
        self.progress = progress; self.isCancelled = isCancelled
        chunk = min(src.readChunk, dst.writeChunk)
    }

    func start(_ c: CheckedContinuation<Void, Error>) {
        cont = c
        pump()
    }

    private var maxInflight: Int { max(4, src.bytesInFlight / chunk) }

    private func pump() {
        guard !done else { return }
        if isCancelled() { finish(SFTPClient.Cancelled()); return }
        while inflight < maxInflight && !eof {
            if let size, next >= size { break }
            read(offset: next, length: chunk)
            next += UInt64(chunk)
        }
        if inflight == 0 { finish(nil) }
    }

    private func read(offset: UInt64, length: Int) {
        inflight += 1
        let loop = src.channel.eventLoop
        src.readRequest(rh, offset: offset, length: length).whenComplete { [self] result in
            switch result {
            case .success(.data(var buf)):
                let got = buf.readableBytes
                let bytes = buf.readBytes(length: got) ?? []
                if got > 0 && got < length { read(offset: offset + UInt64(got), length: length - got) }
                dst.writeRequest(wh, offset: offset, data: bytes).hop(to: loop).whenComplete { [self] w in
                    inflight -= 1
                    switch w {
                    case .success(.status(0, _)): progress(got)
                    case .success(let r): finish(SFTPClient.fail(r)); return
                    case .failure(let e): finish(e); return
                    }
                    pump()
                }
            case .success(.status(1, _)):
                inflight -= 1
                eof = true
                pump()
            case .success(let r):
                finish(SFTPClient.fail(r))
            case .failure(let e):
                finish(e)
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !done else { return }
        done = true
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
        cont = nil
    }
}

/// SFTP 패킷 짜 맞추기·요청 번호로 답 찾기
final class SFTPHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    private var context: ChannelHandlerContext?
    private var inbound = ByteBuffer()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: EventLoopPromise<SFTPClient.Response>] = [:]
    private var versionPromise: EventLoopPromise<[String: String]>?

    init() {}

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func handlerRemoved(context: ChannelHandlerContext) {
        failAll()
        self.context = nil
    }

    /// INIT(3) → VERSION. 확장 이름 → 값
    fileprivate func sendInit() -> EventLoopFuture<[String: String]> {
        guard let context else { return SFTPClient.failedFuture(on: nil) }
        let p = context.eventLoop.makePromise(of: [String: String].self)
        versionPromise = p
        var b = context.channel.allocator.buffer(capacity: 9)
        b.writeInteger(UInt32(5)); b.writeInteger(UInt8(1)); b.writeInteger(UInt32(3))
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(b))), promise: nil)
        return p.futureResult
    }

    /// 어느 스레드에서 불러도 된다 (이벤트 루프로 넘겨 보낸다)
    fileprivate func request(_ type: UInt8, _ body: @escaping (inout ByteBuffer) -> Void) -> EventLoopFuture<SFTPClient.Response> {
        guard let context else { return SFTPClient.failedFuture(on: nil) }
        let loop = context.eventLoop
        if !loop.inEventLoop { return loop.flatSubmit { self.request(type, body) } }
        guard self.context != nil else { return loop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
        let id = nextID
        nextID &+= 1
        let p = loop.makePromise(of: SFTPClient.Response.self)
        pending[id] = p
        var payload = context.channel.allocator.buffer(capacity: 64)
        payload.writeInteger(type)
        payload.writeInteger(id)
        body(&payload)
        var b = context.channel.allocator.buffer(capacity: payload.readableBytes + 4)
        b.writeInteger(UInt32(payload.readableBytes))
        b.writeBuffer(&payload)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(b))), promise: nil)
        return p.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard d.type == .channel, case .byteBuffer(var buf) = d.data else { return }
        inbound.writeBuffer(&buf)
        while inbound.readableBytes >= 4, let len = inbound.getInteger(at: inbound.readerIndex, as: UInt32.self),
              inbound.readableBytes >= 4 + Int(len) {
            inbound.moveReaderIndex(forwardBy: 4)
            guard var packet = inbound.readSlice(length: Int(len)) else { break }
            handle(&packet)
        }
        inbound.discardReadBytes()
    }

    private func handle(_ p: inout ByteBuffer) {
        guard let type = p.readInteger(as: UInt8.self) else { return }
        if type == 2 { // VERSION
            _ = p.readInteger(as: UInt32.self)
            var exts: [String: String] = [:]
            while let k = p.readSSHString(), let v = p.readSSHString() { exts[k] = v }
            versionPromise?.succeed(exts)
            versionPromise = nil
            return
        }
        guard let id = p.readInteger(as: UInt32.self), let promise = pending.removeValue(forKey: id) else { return }
        switch type {
        case 101:
            let code = p.readInteger(as: UInt32.self) ?? 4
            promise.succeed(.status(code, p.readSSHString() ?? ""))
        case 102:
            promise.succeed(.handle(p.readSSHBuffer() ?? ByteBuffer()))
        case 103:
            promise.succeed(.data(p.readSSHBuffer() ?? ByteBuffer()))
        case 104:
            let n = p.readInteger(as: UInt32.self) ?? 0
            var list: [(String, SFTPClient.Attrs)] = []
            for _ in 0..<n {
                guard let name = p.readSSHString(), p.readSSHString() != nil else { break }
                list.append((name, Self.readAttrs(&p)))
            }
            promise.succeed(.name(list))
        case 105:
            promise.succeed(.attrs(Self.readAttrs(&p)))
        case 201:
            promise.succeed(.extended(p))
        default:
            promise.succeed(.status(99, "알 수 없는 응답 \(type)"))
        }
    }

    private static func readAttrs(_ p: inout ByteBuffer) -> SFTPClient.Attrs {
        var a = SFTPClient.Attrs()
        guard let flags = p.readInteger(as: UInt32.self) else { return a }
        if flags & 0x1 != 0 { a.size = p.readInteger(as: UInt64.self) }
        if flags & 0x2 != 0 { _ = p.readInteger(as: UInt32.self); _ = p.readInteger(as: UInt32.self) }
        if flags & 0x4 != 0 { a.permissions = p.readInteger(as: UInt32.self) }
        if flags & 0x8 != 0 { _ = p.readInteger(as: UInt32.self); a.mtime = p.readInteger(as: UInt32.self) }
        if flags & 0x8000_0000 != 0, let n = p.readInteger(as: UInt32.self) {
            for _ in 0..<n { _ = p.readSSHString(); _ = p.readSSHString() }
        }
        return a
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll()
        context.fireChannelInactive()
    }

    private func failAll() {
        let all = pending
        pending.removeAll()
        for (_, p) in all { p.fail(ChannelError.ioOnClosedChannel) }
        versionPromise?.fail(ChannelError.ioOnClosedChannel)
        versionPromise = nil
    }
}

extension SFTPClient {
    fileprivate static func failedFuture<T>(on loop: EventLoop?) -> EventLoopFuture<T> {
        (loop ?? MultiThreadedEventLoopGroup.singleton.any()).makeFailedFuture(ChannelError.ioOnClosedChannel)
    }
}

extension ByteBuffer {
    mutating func writeSSHString(_ s: String) {
        writeInteger(UInt32(s.utf8.count))
        writeString(s)
    }

    mutating func writeSSHString(_ b: ByteBuffer) {
        var b = b
        writeInteger(UInt32(b.readableBytes))
        writeBuffer(&b)
    }

    mutating func readSSHBuffer() -> ByteBuffer? {
        guard let n = readInteger(as: UInt32.self) else { return nil }
        return readSlice(length: Int(n))
    }

    mutating func readSSHString() -> String? {
        guard var b = readSSHBuffer() else { return nil }
        return b.readString(length: b.readableBytes)
    }
}
