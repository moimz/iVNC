import Foundation
import CryptoKit
import NIOCore
import NIOPosix
import NIOSSH

/// SSH 접속 하나 + 셸 채널 하나 (터미널 탭 하나). SwiftNIO SSH.
/// 받은 바이트·상태는 메인 스레드로 넘긴다.
final class SSHShell {
    enum Auth {
        case password(String)
        case key(Curve25519.Signing.PrivateKey)
    }

    /// 서버 지문이 처음이거나 바뀌었을 때 물어본다 (메인 스레드). 답을 completion 으로
    var onHostKeyQuestion: ((HostKeyQuestion, @escaping (Bool) -> Void) -> Void)?
    var onData: (([UInt8]) -> Void)?
    /// 셸이 끝남. 오류면 글, 정상 종료면 nil (exit 코드는 따로)
    var onClose: ((_ error: String?, _ exitStatus: Int?) -> Void)?
    var onConnected: (() -> Void)?

    struct HostKeyQuestion {
        let host: String
        let fingerprint: String
        let keyType: String
        /// 예전 지문과 다름 (중간자 공격일 수 있음)
        let changed: Bool
    }

    private let host: String
    private let port: Int
    private let username: String
    private let auth: Auth
    private let term: String
    private var group: MultiThreadedEventLoopGroup?
    private var connection: Channel?
    private var shell: Channel?
    private var exitStatus: Int?
    private var closed = false

    init(host: String, port: Int, username: String, auth: Auth, term: String) {
        self.host = host; self.port = port; self.username = username; self.auth = auth; self.term = term
    }

    func connect(cols: Int, rows: Int, keepAlive: Bool) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        DebugLog.write("SSH 접속 시작 \(username)@\(host):\(port)")
        let userAuth = UserAuth(username: username, auth: auth)
        let hostAuth = HostKeyCheck(host: host, port: port) { [weak self] q, answer in
            DispatchQueue.main.async {
                guard let ask = self?.onHostKeyQuestion else { answer(false); return }
                ask(q, answer)
            }
        }
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: keepAlive ? 1 : 0)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(15))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: hostAuth)),
                                      allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        ErrorCatcher { [weak self] e in self?.finish(error: Self.describe(e)) },
                    ])
                }
            }
        bootstrap.connect(host: host, port: port).flatMap { [weak self] conn -> EventLoopFuture<Channel> in
            guard let self else { return conn.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
            self.connection = conn
            conn.closeFuture.whenComplete { [weak self] _ in self?.finish(error: nil) }
            return conn.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = conn.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(promise) { child, type in
                    guard type == .session else { return child.eventLoop.makeFailedFuture(ChannelError.badInterfaceAddressFamily) }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(ShellHandler(owner: self))
                    }
                }
                return promise.futureResult
            }
        }.flatMap { [weak self] child -> EventLoopFuture<Void> in
            guard let self else { return child.eventLoop.makeSucceededVoidFuture() }
            self.shell = child
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: self.term, terminalCharacterWidth: cols, terminalRowHeight: rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
            return child.triggerUserOutboundEvent(pty).flatMap {
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))
            }
        }.whenComplete { [weak self] result in
            switch result {
            case .success:
                DebugLog.write("SSH 셸 열림")
                DispatchQueue.main.async { self?.onConnected?() }
            case .failure(let e):
                DebugLog.write("SSH 실패: \(e)")
                self?.finish(error: Self.describe(e))
            }
        }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let shell else { return }
        var buf = shell.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        shell.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf)), promise: nil)
    }

    func resize(cols: Int, rows: Int) {
        shell?.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0), promise: nil)
    }

    func close() {
        closed = true
        connection?.close(promise: nil)
        let g = group
        group = nil
        DispatchQueue.global().async { try? g?.syncShutdownGracefully() }
    }

    fileprivate func received(_ bytes: [UInt8]) {
        DispatchQueue.main.async { [weak self] in self?.onData?(bytes) }
    }

    fileprivate func exited(_ status: Int) { exitStatus = status }

    fileprivate func finish(error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.onClose?(error, self.exitStatus)
            self.connection?.close(promise: nil)
            let g = self.group
            self.group = nil
            DispatchQueue.global().async { try? g?.syncShutdownGracefully() }
        }
    }

    static func describe(_ e: Error) -> String {
        if let c = e as? NIOConnectionError {
            return c.connectionErrors.first.map { "접속할 수 없습니다: \(describe($0.error))" } ?? "접속할 수 없습니다."
        }
        if let s = e as? NIOSSHError {
            switch s.type {
            case .keyExchangeNegotiationFailure: return "서버와 암호화 방식을 맞추지 못했습니다."
            case .remotePeerDoesNotSupportMessage: return "서버가 요청을 지원하지 않습니다."
            default: return "SSH 오류: \(s)"
            }
        }
        if e is ChannelError { return "접속이 끊겼습니다." }
        if let a = e as? AuthFailure { return a.localizedDescription }
        if let h = e as? HostKeyRejected { return h.localizedDescription }
        let ns = e as NSError
        if ns.domain == NSPOSIXErrorDomain || "\(e)".contains("connectTimeout") {
            return "\(e)".contains("Timeout") ? "서버가 응답하지 않습니다." : "접속할 수 없습니다: \(ns.localizedDescription)"
        }
        return "\(e)"
    }
}

// MARK: - 인증

struct AuthFailure: LocalizedError {
    var errorDescription: String? { "로그인하지 못했습니다. 계정과 암호(또는 키)를 확인하세요." }
}

struct HostKeyRejected: LocalizedError {
    var errorDescription: String? { "서버 지문을 받아들이지 않아 접속을 그만뒀습니다." }
}

/// 한 번만 내민다 (안 되면 끝)
private final class UserAuth: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let auth: SSHShell.Auth
    var offered = false
    init(username: String, auth: SSHShell.Auth) { self.username = username; self.auth = auth }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered else { nextChallengePromise.fail(AuthFailure()); return }
        offered = true
        switch auth {
        case .password(let pw):
            guard availableMethods.contains(.password) else { nextChallengePromise.fail(AuthFailure()); return }
            nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: pw))))
        case .key(let k):
            guard availableMethods.contains(.publicKey) else { nextChallengePromise.fail(AuthFailure()); return }
            nextChallengePromise.succeed(.init(username: username, serviceName: "",
                                               offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: k)))))
        }
    }
}

/// 서버 지문 확인 (known_hosts). 처음이면 묻고 저장, 바뀌었으면 경고하고 묻는다
private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate {
    let host: String
    let port: Int
    let ask: (SSHShell.HostKeyQuestion, @escaping (Bool) -> Void) -> Void
    init(host: String, port: Int, ask: @escaping (SSHShell.HostKeyQuestion, @escaping (Bool) -> Void) -> Void) {
        self.host = host; self.port = port; self.ask = ask
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let id = SSHKnownHosts.id(host: host, port: port)
        let saved = SSHKnownHosts.key(for: id)
        if saved == line { validationCompletePromise.succeed(()); return }
        DebugLog.write("SSH 서버 지문 확인 필요 (\(saved == nil ? "처음" : "바뀜"))")
        let parts = line.split(separator: " ")
        let blob = parts.count > 1 ? Data(base64Encoded: String(parts[1])) ?? Data() : Data()
        let fp = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let q = SSHShell.HostKeyQuestion(host: port == 22 ? host : "\(host):\(port)", fingerprint: fp,
                                         keyType: parts.first.map(String.init) ?? "", changed: saved != nil)
        ask(q) { ok in
            if ok {
                SSHKnownHosts.set(line, for: id)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyRejected())
            }
        }
    }
}

/// 알려진 서버 지문 (iCloud 키-값 저장소로 기기끼리 같이 쓴다)
enum SSHKnownHosts {
    private static let prefix = "sshKnownHost."
    static func id(host: String, port: Int) -> String { "[\(host.lowercased())]:\(port)" }
    static func key(for id: String) -> String? {
        NSUbiquitousKeyValueStore.default.string(forKey: prefix + id) ?? UserDefaults.standard.string(forKey: prefix + id)
    }
    static func set(_ line: String, for id: String) {
        UserDefaults.standard.set(line, forKey: prefix + id)
        NSUbiquitousKeyValueStore.default.set(line, forKey: prefix + id)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}

// MARK: - 채널

private final class ShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    weak var owner: SSHShell?
    init(owner: SSHShell) { self.owner = owner }

    func handlerAdded(context: ChannelHandlerContext) {
        // 서버가 보내기를 다 끝내도(EOF) 우리 쪽은 열어 둔다
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = d.data, let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        owner?.received(bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? SSHChannelRequestEvent.ExitStatus { owner?.exited(e.exitStatus) }
        if event is ChannelEvent, case .inputClosed = event as! ChannelEvent { context.close(promise: nil) }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.finish(error: nil)
        context.fireChannelInactive()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }
}

/// 연결 파이프라인 끝의 오류를 잡는다 (인증 실패·서버 지문 거절 등)
private final class ErrorCatcher: ChannelInboundHandler {
    typealias InboundIn = Any
    let onError: (Error) -> Void
    init(onError: @escaping (Error) -> Void) { self.onError = onError }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}
