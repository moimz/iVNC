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
    /// 셸·SFTP·exec 채널을 여는 접속 (경유하면 마지막 서버로 가는 안쪽 접속)
    private var connection: Channel?
    /// 맨 바깥 TCP 접속 (닫으면 경유 통로까지 모두 닫힌다)
    private var outer: Channel?

    /// 경유 서버 하나 (배스천). 바깥쪽부터 차례로
    struct Hop {
        let host: String
        let port: Int
        let username: String
        let auth: Auth
        /// 오류 글에 붙일 이름
        let name: String
    }
    private let jumps: [Hop]
    private var shell: Channel?
    private var exitStatus: Int?
    private var closed = false
    /// 이 셸을 서버에서 찾는 표식 (LC_ 환경 변수로 붙인다. 우분투 기본 sshd 가 LC_* 를 받아 준다) → 지금 폴더 알아내기
    let marker = UUID().uuidString

    /// 셸 대신 이 명령으로 시작 (복제·새 탭을 지금 폴더에서: cd 뒤 로그인 셸로 바꾼다)
    private let startCommand: String?

    init(host: String, port: Int, username: String, auth: Auth, term: String, startCommand: String? = nil, jumps: [Hop] = []) {
        self.host = host; self.port = port; self.username = username; self.auth = auth; self.term = term
        self.startCommand = startCommand
        self.jumps = jumps
    }

    /// 셸 없이 접속만 하는 모드 (MCP 가 명령·파일만 쓸 때). onConnected 가 불린다
    var interactive = true

    private struct ConnectedOnly: Error {}

    /// 지금 폴더에서 로그인 셸을 여는 명령 (root 로 이어 가려면 sudo -s: 암호는 사용자가 친다)
    static func startCommand(directory: String?, asRoot: Bool) -> String? {
        guard directory != nil || asRoot else { return nil }
        var cmd = ""
        if let d = directory { cmd += "cd -- '" + d.replacingOccurrences(of: "'", with: "'\\''") + "' 2>/dev/null; " }
        cmd += asRoot ? "exec sudo -s" : "exec \"${SHELL:-/bin/sh}\" -l"
        return cmd
    }

    func connect(cols: Int, rows: Int, keepAlive: Bool) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        // 경유 서버들 → 목적지. 바깥 서버에만 TCP 로 붙고, 그 안에서 다음 서버로 통로(direct-tcpip)를 열어 다시 SSH 를 맺는다.
        // 경유 서버에서는 셸을 열지 않으니 그 서버 명령 기록에 아무것도 남지 않고, 안쪽 로그인은 끝에서 끝까지 암호화된다
        let hops = jumps + [Hop(host: host, port: port, username: username, auth: auth, name: "")]
        DebugLog.write("SSH 접속 시작 \(hops.map { "\($0.username)@\($0.host):\($0.port)" }.joined(separator: " → "))")
        let first = hops[0]
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: keepAlive ? 1 : 0)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(15))
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let self else { return }
                    try channel.pipeline.syncOperations.addHandlers(self.sshHandlers(for: first, last: hops.count == 1, allocator: channel.allocator))
                }
            }
        bootstrap.connect(host: first.host, port: first.port).flatMap { [weak self] conn -> EventLoopFuture<Channel> in
            guard let self else { return conn.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
            self.outer = conn
            conn.closeFuture.whenComplete { [weak self] _ in self?.finish(error: nil) }
            return self.chain(conn, index: 1, hops: hops)
        }.flatMap { [weak self] conn -> EventLoopFuture<Channel> in
            guard let self else { return conn.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
            self.connection = conn
            conn.closeFuture.whenComplete { [weak self] _ in self?.finish(error: nil) }
            if keepAlive { self.startAliveCheck(conn) }
            // 셸이 필요 없으면 여기서 접속 완료로 (인증은 첫 채널을 열 때 끝까지 기다린다: NIOSSH 가 채널 열기를 인증 뒤로 미룬다)
            if !self.interactive {
                return conn.pipeline.handler(type: NIOSSHHandler.self).flatMap { _ in
                    conn.eventLoop.makeFailedFuture(ConnectedOnly())
                }
            }
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
            // 표식은 서버가 안 받아 줘도 그만 (답을 안 기다린다)
            child.triggerUserOutboundEvent(SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LC_IVNC_SESSION", value: self.marker), promise: nil)
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: self.term, terminalCharacterWidth: cols, terminalRowHeight: rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
            return child.triggerUserOutboundEvent(pty).flatMap {
                if let cmd = self.startCommand {
                    return child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: cmd, wantReply: true))
                }
                return child.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))
            }
        }.whenComplete { [weak self] result in
            switch result {
            case .success:
                DebugLog.write("SSH 셸 열림")
                DispatchQueue.main.async { self?.onConnected?() }
            case .failure(let e) where e is ConnectedOnly:
                DispatchQueue.main.async { self?.onConnected?() }
            case .failure(let e):
                DebugLog.write("SSH 실패: \(e)")
                self?.finish(error: Self.describe(e))
            }
        }
    }

    /// OpenSSH ServerAliveInterval 60 · ServerAliveCountMax 3 과 같게 (사용자 맥 ~/.ssh/config 값, 사내망에서 자주 끊겨 넣었던 것)
    static let aliveInterval: Int64 = 60
    static let aliveCountMax = 3

    /// 서버가 살아 있는지 주기적으로 묻는다 (ServerAlive). 서버가 조용히 사라지면(전원·망 끊김·와이파이 바꿈)
    /// TCP 는 2시간 가까이 모르므로, SSH 전역 요청을 보내 답(성공이든 거절이든)이 오는지 본다.
    /// 3번 연속 답이 없으면 끊고 "다시 접속" 을 띄운다. 오가는 글 덕분에 한동안 조용하면 끊는 서버·사내망도 붙잡아 둔다.
    /// swift-nio-ssh 는 임의 전역 요청을 밖에 안 열어서, 없는 포워딩 취소(cancel-tcpip-forward)를 보낸다 (서버는 거절로 답한다)
    private func startAliveCheck(_ conn: Channel) {
        var waiting = 0
        conn.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(Self.aliveInterval), delay: .seconds(Self.aliveInterval)) { [weak self] task in
            guard let self, conn.isActive else { task.cancel(); return }
            if waiting >= Self.aliveCountMax {
                task.cancel()
                DebugLog.write("SSH 서버 응답 없음 \(Self.aliveCountMax)번 → 끊음")
                self.finish(error: "서버가 \(Self.aliveInterval * Int64(Self.aliveCountMax))초 동안 응답하지 않아 접속을 끊었습니다.")
                conn.close(promise: nil)
                return
            }
            waiting += 1
            _ = conn.pipeline.handler(type: NIOSSHHandler.self).map { ssh in
                let reply = conn.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                reply.futureResult.whenComplete { _ in waiting = 0 }
                ssh.sendTCPForwardingRequest(.cancel(host: "127.0.0.1", port: 9), promise: reply)
            }
        }
    }

    /// 같은 접속에 SFTP 채널을 하나 더 연다 (다시 로그인하지 않는다)
    /// command: 다른 사용자 셸이 띄운 sftp-server 에 잇는 명령 (없으면 로그인 계정 sftp 서브시스템)
    func openSFTP(command: String? = nil) async throws -> SFTPClient {
        guard let conn = connection else { throw ChannelError.ioOnClosedChannel }
        return try await conn.eventLoop.flatSubmit {
            conn.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh -> EventLoopFuture<SFTPClient> in
                let p = conn.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(p) { child, _ in
                    child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(SFTPHandler()) }
                }
                return p.futureResult.flatMap { SFTPClient.start(on: $0, command: command) }
            }
        }.get()
    }

    struct ExecResult {
        let stdout: String
        let stderr: String
        let exitStatus: Int?
        let timedOut: Bool
    }

    /// 서버에서 명령 하나를 실행해 표준 출력을 받는다 (같은 접속, 별도 채널)
    func exec(_ command: String) async throws -> String { try await execFull(command).stdout }

    /// 명령 하나 실행: 출력·오류·종료 코드. timeout 초가 지나면 채널을 닫는다
    func execFull(_ command: String, timeout: Int = 60) async throws -> ExecResult {
        guard let conn = connection else { throw ChannelError.ioOnClosedChannel }
        return try await conn.eventLoop.flatSubmit {
            conn.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh -> EventLoopFuture<ExecResult> in
                let opened = conn.eventLoop.makePromise(of: Channel.self)
                let output = conn.eventLoop.makePromise(of: ExecResult.self)
                let collector = ExecCollector(output)
                ssh.createChannel(opened) { child, _ in
                    child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(collector) }
                }
                return opened.futureResult.flatMap { child in
                    child.eventLoop.scheduleTask(in: .seconds(Int64(timeout))) {
                        collector.timedOut = true
                        child.close(promise: nil)
                    }
                    return child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
                }.flatMap { output.futureResult }
            }
        }.get()
    }

    // MARK: 터미널 앞쪽 프로세스

    /// 터미널 앞에서 지금 돌고 있는 것 (셸·vim·mysql·top …) 과 그 사용자
    struct Foreground: Equatable {
        let pid: Int
        let comm: String
        let uid: Int
        let user: String
        /// 그 프로세스 폴더 (다른 사용자 프로세스면 못 읽어 nil)
        let directory: String?
        /// 로그인 계정 uid
        let loginUID: Int

        static let shells: Set<String> = ["bash", "zsh", "sh", "dash", "fish", "ksh", "mksh", "ash", "tcsh", "csh", "busybox"]
        var isShell: Bool { Self.shells.contains(comm) }
        /// 로그인 계정과 다른 사용자 셸인지 (sudo su, su - ubuntu …)
        var otherUser: Bool { uid != loginUID }

        init?(line: Substring) {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, let pid = Int(f[0]), let uid = Int(f[2]), let login = Int(f[5]) else { return nil }
            self.pid = pid; comm = f[1]; self.uid = uid; user = f[3].isEmpty ? String(uid) : f[3]
            directory = f[4].hasPrefix("/") ? f[4] : nil; loginUID = login
        }
    }

    /// 앞쪽 프로세스 찾기 (리눅스 /proc). 표식(LC_IVNC_SESSION) 붙은 로그인 셸 → 그 터미널의 앞쪽 프로세스 그룹 →
    /// 그 아래로 내려가며 자기 터미널의 앞쪽인 가장 깊은 프로세스 (sudo 가 새 pty 를 만드는 경우·sudo su 안의 셸·그 셸의 vim 까지).
    /// 백그라운드 작업은 자기 터미널의 앞쪽이 아니라 빠진다. 줄 = pid|comm|uid|user|cwd|로그인uid
    private func foregroundScript(loop: Bool) -> String {
        let m = marker
        return #"""
        p=
        for f in /proc/[0-9]*/environ; do
          grep -qszx 'LC_IVNC_SESSION=\#(m)' "$f" || continue
          q=${f#/proc/}; q=${q%/environ}
          pp=$(awk '{print $4}' /proc/$q/stat 2>/dev/null)
          grep -qszx 'LC_IVNC_SESSION=\#(m)' /proc/$pp/environ 2>/dev/null && continue
          p=$q; break
        done
        [ -n "$p" ] || exit 0
        me=$(id -u); last=
        while [ -d /proc/$p ]; do
          t=$(awk '{print $8}' /proc/$p/stat 2>/dev/null)
          b=$(awk -v t="$t" 'FNR==1{f=FILENAME; sub(/^\/proc\//,"",f); sub(/\/stat$/,"",f); c=$0; sub(/^[^(]*\(/,"",c); sub(/\) .*$/,"",c); r=$0; sub(/^.*\) /,"",r); split(r,a," "); pp[f]=a[2]; tg[f]=a[6]; cm[f]=c}
            END{n=1; q[1]=t; dp[t]=0; h=1; while(h<=n){x=q[h++]; for(k in pp) if(pp[k]==x){q[++n]=k; dp[k]=dp[x]+1}}
                b=t; bd=-1; for(i=1;i<=n;i++){k=q[i]; if(tg[k]==k && dp[k]>bd){b=k; bd=dp[k]}} print b "|" cm[b]}' /proc/[0-9]*/stat 2>/dev/null)
          x=${b%%|*}
          u=$(awk '/^Uid:/{print $2}' /proc/$x/status 2>/dev/null)
          n=$(id -nu "$u" 2>/dev/null)
          d=$(readlink /proc/$x/cwd 2>/dev/null)
          l="$b|$u|$n|$d|$me"
          if [ "$l" != "$last" ]; then echo "$l"; last=$l; fi
          \#(loop ? "sleep 1" : "break")
        done
        """#
    }

    /// 지금 앞쪽 프로세스 (한 번). 리눅스가 아니거나 모르면 nil
    func foreground() async -> Foreground? {
        guard let out = try? await exec(foregroundScript(loop: false)) else { return nil }
        return out.split(separator: "\n").last.flatMap { Foreground(line: $0) }
    }

    /// 앞쪽 프로세스가 바뀔 때마다 알려 준다 (서버에서 1초마다 보고 바뀐 것만 보냄, 채널 하나). 접속이 끝나면 멈춘다
    func watchForeground(_ onChange: @escaping (Foreground) -> Void) {
        guard let conn = connection else { return }
        let script = foregroundScript(loop: true)
        conn.eventLoop.execute {
            _ = conn.pipeline.handler(type: NIOSSHHandler.self).map { ssh in
                let p = conn.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(p) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(LineStreamer { line in
                            if let f = Foreground(line: line[...]) { DispatchQueue.main.async { onChange(f) } }
                        })
                    }
                }
                p.futureResult.whenSuccess { child in
                    child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: script, wantReply: true), promise: nil)
                }
            }
        }
    }

    /// 접속이 살아 있는지
    var isOpen: Bool { connection?.isActive ?? false }

    /// 셸이 지금 있는 폴더 (리눅스: 표식이 붙은 로그인 셸 → 그 터미널의 앞쪽 프로세스 → /proc/…/cwd). 모르면 nil
    func currentDirectory() async -> String? { await currentState().directory }

    /// 지금 폴더 + 앞쪽 셸이 root 인지 (sudo su 등. 로그인 계정이 root 가 아닐 때만 true).
    /// root 셸의 폴더는 일반 계정이 못 읽어 sudo 를 친 폴더(로그인 셸 폴더)가 된다
    func currentState() async -> (directory: String?, root: Bool) {
        let m = marker
        let script = """
        for f in /proc/[0-9]*/environ; do
          grep -qszx 'LC_IVNC_SESSION=\(m)' "$f" || continue
          p=${f#/proc/}; p=${p%/environ}
          pp=$(awk '{print $4}' /proc/$p/stat 2>/dev/null)
          grep -qszx 'LC_IVNC_SESSION=\(m)' /proc/$pp/environ && continue
          t=$(awk '{print $8}' /proc/$p/stat 2>/dev/null)
          readlink /proc/$t/cwd 2>/dev/null || readlink /proc/$p/cwd
          awk '/^Uid:/{print $2}' /proc/$t/status 2>/dev/null
          id -u
          break
        done
        """
        guard let out = try? await exec(script) else { return (nil, false) }
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let dir = lines.first.flatMap { $0.hasPrefix("/") ? String($0) : nil }
        let fgRoot = lines.count >= 3 && lines[1] == "0" && lines[2] != "0"
        return (dir, fgRoot)
    }

    /// 한 서버의 SSH 처리기 + 오류 잡기 (경유 서버면 오류 글 앞에 그 이름)
    private func sshHandlers(for hop: Hop, last: Bool, allocator: ByteBufferAllocator) -> [ChannelHandler] {
        let userAuth = UserAuth(username: hop.username, auth: hop.auth)
        let hostAuth = HostKeyCheck(host: hop.host, port: hop.port) { [weak self] q, answer in
            DispatchQueue.main.async {
                guard let ask = self?.onHostKeyQuestion else { answer(false); return }
                ask(q, answer)
            }
        }
        let prefix = last ? "" : "경유 서버 \(hop.name): "
        return [
            NIOSSHHandler(role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: hostAuth)),
                          allocator: allocator, inboundChildChannelInitializer: nil),
            ErrorCatcher { [weak self] e in self?.finish(error: prefix + Self.describe(e)) },
        ]
    }

    /// conn(이전 서버) 안에서 hops[index] 로 통로를 열고 그 위에 SSH 를 맺는다. 끝까지 가면 마지막 접속
    private func chain(_ conn: Channel, index: Int, hops: [Hop]) -> EventLoopFuture<Channel> {
        guard index < hops.count else { return conn.eventLoop.makeSucceededFuture(conn) }
        let hop = hops[index]
        let via = hops[index - 1].name
        return conn.pipeline.handler(type: NIOSSHHandler.self).flatMap { [weak self] ssh -> EventLoopFuture<Channel> in
            guard let self else { return conn.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
            let promise = conn.eventLoop.makePromise(of: Channel.self)
            let origin = try! SocketAddress(ipAddress: "127.0.0.1", port: 0)
            ssh.createChannel(promise, channelType: .directTCPIP(.init(targetHost: hop.host, targetPort: hop.port, originatorAddress: origin))) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SSHTunnelData())
                    try child.pipeline.syncOperations.addHandlers(self.sshHandlers(for: hop, last: index == hops.count - 1, allocator: child.allocator))
                }
            }
            return promise.futureResult.flatMapErrorThrowing { e in
                if let s = e as? NIOSSHError, s.type == .channelSetupRejected {
                    throw TunnelRejected(via: via, target: "\(hop.host):\(hop.port)")
                }
                throw e
            }.flatMap { self.chain($0, index: index + 1, hops: hops) }
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
        outer?.close(promise: nil)
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
            self.outer?.close(promise: nil)
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
        if let t = e as? TunnelRejected { return t.localizedDescription }
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

/// 경유 서버가 다음 서버로 통로를 안 열어 줌
struct TunnelRejected: LocalizedError {
    let via: String
    let target: String
    var errorDescription: String? {
        "경유 서버 \(via) 가 \(target) 로 가는 통로를 열어 주지 않았습니다. 주소·포트를 확인하거나, 그 서버의 포트 전달(AllowTcpForwarding)이 꺼져 있는지 확인하세요."
    }
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

/// 알려진 서버 지문. 기기마다 따로 확인한다 (사용자 2026-11-21: iCloud 로 넘기지 않음 — 다른 기기에서 믿은 서버라도
/// 이 기기에서 처음 접속할 때 한 번 더 묻는다). 예전에 iCloud 에 올린 지문은 처음 한 번 지운다
enum SSHKnownHosts {
    private static let prefix = "sshKnownHost."
    static func id(host: String, port: Int) -> String { "[\(host.lowercased())]:\(port)" }
    static func key(for id: String) -> String? {
        removeCloudCopiesOnce()
        return UserDefaults.standard.string(forKey: prefix + id)
    }
    static func set(_ line: String, for id: String) {
        UserDefaults.standard.set(line, forKey: prefix + id)
    }

    private static let cleanedKey = "sshKnownHost.cloudCleaned"
    private static func removeCloudCopiesOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: cleanedKey) else { return }
        d.set(true, forKey: cleanedKey)
        let cloud = NSUbiquitousKeyValueStore.default
        for k in cloud.dictionaryRepresentation.keys where k.hasPrefix(prefix) { cloud.removeObject(forKey: k) }
        cloud.synchronize()
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

/// 경유 통로: SSH 채널 데이터 ↔ 바이트 (그 위에 안쪽 SSH 를 얹는다)
private final class SSHTunnelData: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard d.type == .channel, case .byteBuffer(let b) = d.data else { return }
        context.fireChannelRead(wrapInboundOut(b))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let b = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(b))), promise: promise)
    }
}

/// exec 채널의 출력을 모은다 (채널이 닫히면 끝)
/// exec 채널 표준 출력을 줄마다 넘긴다
private final class LineStreamer: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let onLine: (String) -> Void
    private var pending: [UInt8] = []
    init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard d.type == .channel, case .byteBuffer(var buf) = d.data, let b = buf.readBytes(length: buf.readableBytes) else { return }
        pending += b
        while let i = pending.firstIndex(of: 10) {
            onLine(String(decoding: pending[..<i], as: UTF8.self))
            pending.removeSubrange(...i)
        }
    }
}

private final class ExecCollector: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let promise: EventLoopPromise<SSHShell.ExecResult>
    var bytes: [UInt8] = []
    var errBytes: [UInt8] = []
    var status: Int?
    /// 시간이 다 돼 닫았는지
    var timedOut = false
    init(_ p: EventLoopPromise<SSHShell.ExecResult>) { promise = p }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = d.data, let b = buf.readBytes(length: buf.readableBytes) else { return }
        if d.type == .stdErr { errBytes += b } else { bytes += b }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? SSHChannelRequestEvent.ExitStatus { status = e.exitStatus }
        if let e = event as? ChannelEvent, case .inputClosed = e { context.close(promise: nil) }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.succeed(.init(stdout: String(decoding: bytes, as: UTF8.self), stderr: String(decoding: errBytes, as: UTF8.self),
                              exitStatus: status, timedOut: timedOut))
        context.fireChannelInactive()
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
