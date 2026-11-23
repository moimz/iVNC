import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// 컴퓨터 추가·편집 창
struct ComputerEditView: View {
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismiss) private var dismiss
    let computer: Computer?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "5900"
    @State private var username = ""
    @State private var password = ""
    @State private var preferHP = true
    @State private var keepAlive = true
    @State private var kind: Computer.Kind = .mac
    // SSH 인증 (iSQL 과 같은 모양: [키 파일 | 비밀번호], 키 고르기, 키 암호)
    @State private var sshAuth: SSHAuth = .key
    @State private var keyName: String?
    /// 새로 고른 키 파일 내용 (저장할 때 키체인에)
    @State private var newKey: Data?
    @State private var keyPassphrase = ""
    @State private var keyError: String?
    @State private var pickingKey = false
    @State private var encoding = SSHEncoding.defaultID
    @State private var color = ServerColor.none
    @State private var jump: UUID?
    /// 접속 허용 IP 칸에 친 글 그대로 (저장할 때 나눈다)
    @State private var allowedText = ""
    /// 접속 시험에서 허용 IP 가 아니었으면 그 결과 (맥: VPN 시트)
    @State private var testBlocked: NetworkAccess.Report?
    /// SSH 접속 시험 (맥: 아래 막대 왼쪽)
    @State private var test: TestState = .idle
    @State private var testShell: SSHShell?
    @State private var testHostKey: (q: SSHShell.HostKeyQuestion, answer: (Bool) -> Void)?
    @State private var testDetail: String?

    enum TestState: Equatable { case idle, testing, ok(String), failed }

    var body: some View {
        NavigationStack {
            content
                .onChange(of: kind) { old, new in
                    // 포트를 안 바꿨으면 종류의 기본 포트로
                    if port == String(old.defaultPort) || port.isEmpty { port = String(new.defaultPort) }
                }
                #if !os(macOS)
                // 맥은 시트 위 제목 없이 (탭과 버튼만)
                .navigationTitle(computer == nil ? "컴퓨터 추가" : "컴퓨터 편집")
                .inlineTitle()
                #endif
                .toolbar {
                    #if os(macOS)
                    // 맥 시트 아래 막대: destructiveAction 자리가 왼쪽 끝 (취소·저장은 오른쪽)
                    if kind == .ssh {
                        ToolbarItem(placement: .destructiveAction) { testButton }
                    }
                    #endif
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { testShell?.close(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("저장") { save() }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || needsKey)
                    }
                }
                .onAppear {
                    guard let c = computer else { return }
                    name = c.name == c.host ? "" : c.name; host = c.host; port = String(c.port); username = c.username
                    preferHP = c.prefersHighPerformance
                    keepAlive = c.keepsAliveInBackground
                    kind = c.type
                    sshAuth = c.sshAuth ?? .password
                    keyName = c.sshKeyName
                    encoding = c.sshEncoding ?? SSHEncoding.defaultID
                    color = c.sshColor ?? .none
                    jump = c.sshJump
                    allowedText = (c.allowedIPs ?? []).joined(separator: ", ")
                }
                #if os(iOS)
                .fileImporter(isPresented: $pickingKey, allowedContentTypes: [.data, .item]) { result in
                    guard case .success(let url) = result else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    takeKey(url)
                }
                #endif
                .alert("서버 지문 확인", isPresented: Binding(get: { testHostKey != nil }, set: { if !$0 { testHostKey?.answer(false); testHostKey = nil } })) {
                    Button("믿고 계속") { testHostKey?.answer(true); testHostKey = nil }
                    Button("취소", role: .cancel) { testHostKey?.answer(false); testHostKey = nil }
                } message: {
                    if let q = testHostKey?.q {
                        Text((q.changed ? "⚠️ 서버 지문이 예전과 다릅니다. 중간에서 누가 가로채는 것일 수 있습니다.\n\n" : "처음 접속하는 서버입니다.\n\n")
                             + "\(q.host)\n\(q.keyType) \(q.fingerprint)")
                    }
                }
                .alert("접속하지 못했습니다", isPresented: Binding(get: { testDetail != nil }, set: { if !$0 { testDetail = nil } })) {
                    Button("확인", role: .cancel) {}
                } message: {
                    Text(testDetail ?? "")
                }
                #if os(macOS)
                .sheet(isPresented: Binding(get: { testBlocked != nil }, set: { if !$0 { testBlocked = nil } })) {
                    if let r = testBlocked {
                        AccessSheet(server: name.isEmpty ? host : name, report: r,
                                    retry: { testBlocked = nil; runTest() },
                                    close: { testBlocked = nil })
                    }
                }
                #endif
                .onChange(of: host) { test = .idle }
                .onChange(of: port) { test = .idle }
                .onChange(of: username) { test = .idle }
                .onChange(of: sshAuth) { test = .idle }
                .onDisappear { testShell?.close() }
                .alert("SSH 키를 쓸 수 없습니다", isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
                    Button("확인", role: .cancel) {}
                } message: {
                    Text(keyError ?? "")
                }
        }
    }

    /// 맥: 위에 [맥 | 윈도우] 탭이 붙은 상자 (TabView), 아이폰·아이패드: 맨 위 분할 단추
    @ViewBuilder private var content: some View {
        if computer != nil {
            // 편집: 종류는 바꿀 일이 없어(SSH 를 맥으로 등) 종류 탭 없이 그 종류 칸만 (사용자)
            Form { fields }
                .formStyle(.grouped)
                #if os(macOS)
                .scrollContentBackground(.hidden)
                #endif
                // 맥: 여백은 grouped Form 자체 여백만 (탭 상자용 .padding() 을 또 주면 두 겹으로 넓어졌다, 사용자)
        } else {
            addContent
        }
    }

    /// 추가: 종류를 고르는 탭과 칸
    @ViewBuilder private var addContent: some View {
        #if os(macOS)
        TabView(selection: $kind) {
            ForEach(Computer.Kind.allCases, id: \.self) { k in
                Form { fields }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .tabItem { Text(k.title) }
                    .tag(k)
            }
        }
        // 기본 모양은 탭을 도구 막대에 좁은 고정 폭으로 붙여 글자가 잘린다 → 표준 탭 상자(글자 폭대로)
        .tabViewStyle(.grouped)
        .padding()
        #else
        Form {
            Section {
                Picker("종류", selection: $kind) {
                    ForEach(Computer.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 목록 상자 밖에 떠 있게 (배경·여백 없이)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            fields
        }
        #endif
    }

    @ViewBuilder private var fields: some View {
        Section {
            row("주소", hostPrompt, $host) { $0.urlField() }
            row("이름", "선택 사항", $name) { $0 }
            row("포트", String(kind.defaultPort), $port) { $0.numberField() }
            if kind == .ssh {
                // 색 점 줄 (iSQL 서버 색과 같은 모양). 메뉴 Picker 는 맥에서 색이 빠진다
                LabeledContent("색") {
                    HStack(spacing: 8) {
                        ForEach(ServerColor.allCases) { c in
                            Button { color = c } label: {
                                ZStack {
                                    if let col = c.color {
                                        Circle().fill(col.opacity(0.85)).frame(width: 18, height: 18)
                                    } else {
                                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 18, height: 18)
                                    }
                                    if color == c { Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 24, height: 24) }
                                }
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(c.label)
                            .accessibilityLabel(c.label)
                        }
                    }
                }
            }
        }
        Section {
            row("계정", userPrompt, $username) { $0.asciiField() }
            if kind == .ssh {
                LabeledContent("인증") {
                    Picker("인증", selection: $sshAuth) {
                        ForEach(SSHAuth.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if kind == .ssh && sshAuth == .key {
                LabeledContent("SSH 키") {
                    HStack(spacing: 8) {
                        Text(keyName ?? "고르세요").foregroundStyle(keyName == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                        Button { chooseKey() } label: { Image(systemName: "key.fill") }
                            .help("키 파일 고르기")
                            .accessibilityLabel("키 파일 고르기")
                    }
                }
                LabeledContent("키 암호") {
                    SecureField("키 암호", text: $keyPassphrase, prompt: Text(hasSavedKey && newKey == nil ? "바꿀 때만 입력" : "선택"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
            } else {
                LabeledContent(kind == .ssh ? "비밀번호" : "암호") {
                    SecureField("암호", text: $password, prompt: Text(computer == nil ? "" : "바꿀 때만 입력"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
            }
        } footer: {
            if kind == .ssh {
                Text(sshAuth == .key
                     ? "개인 키 파일(.pub 가 아닌 것)을 고르세요. 키 내용과 키 암호는 키체인에 저장되어 iCloud 로 아이폰·아이패드·맥이 같이 씁니다. 암호가 걸린 키면 키 암호를 넣어 두세요."
                     : "비밀번호는 키체인에 저장해 두었다가 접속할 때 대신 넣습니다.")
            }
        }
        if kind == .ssh {
            Section {
                Picker("경유 서버", selection: $jump) {
                    Text("없음").tag(UUID?.none)
                    ForEach(jumpCandidates) { c in Text("\(c.name)  (\(c.username)@\(c.host))").tag(Optional(c.id)) }
                }
            } footer: {
                Text("배스천 서버를 거쳐 접속합니다. 경유 서버에서는 셸을 열지 않고 통로만 열어, 그 서버 명령 기록에 아무것도 남지 않습니다. 이 서버의 로그인은 경유 서버가 볼 수 없게 암호화됩니다.")
            }
            Section {
                Picker("문자 인코딩", selection: $encoding) {
                    ForEach(SSHEncoding.all, id: \.id) { Text($0.title).tag($0.id) }
                }
            } footer: {
                Text("서버가 보내는 글자의 인코딩입니다. 요즘 서버는 거의 UTF-8 이고, 오래된 한국어 서버는 EUC-KR 일 수 있습니다.")
            }
        }
        Section {
            row("허용 IP", "선택 (예: 203.0.113.10, 10.0.0.0/8)", $allowedText) { $0.asciiField() }
        } footer: {
            Text(kind == .ssh && jump != nil
                 ? "경유 서버를 거치면 이 서버는 이 기기의 IP 를 보지 못하므로, 경유 서버에 적은 허용 IP 로 확인합니다."
                 : "이 컴퓨터에 들어갈 수 있는 이 기기의 IP. 적어 두면 접속 전에 확인하고, 아니면 VPN 을 켜라고 알려 줍니다. 비우면 확인하지 않습니다.")
        }
        if kind == .mac {
            Section {
                Toggle("고성능 모드 우선 사용", isOn: $preferHP)
            } footer: {
                Text("맥이 지원하면 가상 디스플레이로 영상처럼 받습니다. 안 되면 기본 방식으로 접속합니다.")
            }
        }
        #if os(iOS)
        Section {
            Toggle("백그라운드에서 연결 유지", isOn: $keepAlive)
        } footer: {
            Text("앱을 잠깐 나가도 연결이 끊기지 않고 컴퓨터도 잠들지 않습니다. 그동안 위치를 아주 낮은 정확도로 켜 두어 배터리를 조금 더 씁니다.")
        }
        #endif
    }

    private var hostPrompt: String {
        switch kind {
        case .mac: return "192.168.0.10, mac.local"
        case .windows: return "192.168.0.20, pc.local"
        case .ssh: return "192.168.0.30, server.example.com"
        }
    }

    private var userPrompt: String {
        switch kind {
        case .mac: return "맥 사용자 이름"
        case .windows: return "사용자 이름 또는 Microsoft 계정 이메일"
        case .ssh: return "사용자 이름"
        }
    }

    /// 경유 서버로 고를 수 있는 SSH 서버 (자기 자신, 자기를 거쳐 가는 서버는 빼서 고리가 안 생기게)
    private var jumpCandidates: [Computer] {
        let me = computer?.id
        return store.computers.filter { c in
            c.type == .ssh && c.id != me && !(me.map { id in store.jumpChain(for: c).contains { $0.id == id } } ?? false)
        }
    }

    /// 이 컴퓨터에 이미 저장된 키가 있는지 (편집할 때)
    private var hasSavedKey: Bool { computer?.sshKeyName != nil && computer?.sshAuth == .key }

    /// SSH 키 방식인데 키를 아직 안 골랐으면 저장할 수 없다
    private var needsKey: Bool { kind == .ssh && sshAuth == .key && keyName == nil }

    private func chooseKey() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.message = "SSH 개인 키 파일을 고르세요 (.pub 가 아닌 파일)"
        if panel.runModal() == .OK, let url = panel.url { takeKey(url) }
        #else
        pickingKey = true
        #endif
    }

    /// 고른 파일이 OpenSSH·PEM 개인 키인지 보고 받아 둔다 (풀어 보는 것은 접속 단계에서)
    private func takeKey(_ url: URL) {
        guard let d = try? Data(contentsOf: url), d.count < 64 * 1024 else {
            keyError = "파일을 읽을 수 없습니다."
            return
        }
        let text = String(decoding: d, as: UTF8.self)
        if url.pathExtension == "pub" || text.hasPrefix("ssh-") {
            keyError = "공개 키(.pub)입니다. 같은 이름의 .pub 가 없는 개인 키 파일을 고르세요."
            return
        }
        guard text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----") else {
            keyError = "SSH 개인 키 파일이 아닙니다."
            return
        }
        newKey = d
        keyName = url.lastPathComponent
    }

    /// 왼쪽 이름표 + 오른쪽 입력칸 (예시는 입력칸 안 흐린 글씨로)
    private func row<F: View>(_ label: String, _ prompt: String, _ text: Binding<String>,
                              style: (TextField<Text>) -> F) -> some View {
        LabeledContent(label) {
            style(TextField(label, text: text, prompt: Text(prompt)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: 접속 시험

    @ViewBuilder private var testButton: some View {
        HStack(spacing: 8) {
            // 결과 글이 붙어도 버튼이 늘어나지 않게 (막대가 남는 폭을 이 묶음에 줘서 버튼이 길어졌다, 사용자)
            Button("접속 시험") { runTest() }
                .fixedSize()
                .disabled(test == .testing || host.trimmingCharacters(in: .whitespaces).isEmpty || username.trimmingCharacters(in: .whitespaces).isEmpty || needsKey)
            switch test {
            case .idle: EmptyView()
            case .testing: ProgressView().controlSize(.small)
            case .ok(let who):
                Label(who, systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                    .fixedSize()
                    .help(testHost)
            case .failed:
                Button { testDetail = lastTestError } label: {
                    Label("실패", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(lastTestError)
            }
        }
    }

    @State private var lastTestError = ""
    /// 접속 시험이 닿은 서버 이름 (hostname, 도움말로)
    @State private var testHost = ""

    /// 고른 계정·인증(입력 중인 값, 없으면 저장된 값)으로 접속해 whoami 까지 해 본다. 저장은 하지 않는다
    private func runTest() {
        testShell?.close()
        let h = host.trimmingCharacters(in: .whitespaces)
        let user = username.trimmingCharacters(in: .whitespaces)
        func fail(_ m: String) { lastTestError = m; test = .failed; testDetail = m }
        // 이 서버 인증
        let auth: SSHShell.Auth
        if sshAuth == .key {
            guard let file = newKey ?? computer.flatMap({ Keychain.sshKey(for: $0.id) }) else { return fail("SSH 키를 골라 주세요.") }
            let pass = !keyPassphrase.isEmpty ? keyPassphrase : (newKey == nil ? computer.flatMap { Keychain.sshKeyPassphrase(for: $0.id) } : nil)
            do { auth = .key(try OpenSSHKey.ed25519(from: file, passphrase: pass)) } catch { return fail(error.localizedDescription) }
        } else {
            guard let pw = !password.isEmpty ? password : computer.flatMap({ Keychain.password(for: $0.id) }) else { return fail("비밀번호를 넣어 주세요.") }
            auth = .password(pw)
        }
        // 경유 서버 (저장된 값으로)
        var hops: [SSHShell.Hop] = []
        if let jump, let j0 = store.computers.first(where: { $0.id == jump }) {
            for j in store.jumpChain(for: j0) + [j0] {
                switch Self.savedAuth(j) {
                case .success(let a): hops.append(.init(host: j.host, port: j.port, username: j.username, auth: a, name: j.name))
                case .failure(let m): return fail("경유 서버 \(j.name): \(m.text)")
                }
            }
        }
        test = .testing
        testBlocked = nil
        // 접속 허용 IP: 앱 접속과 같은 검사 (경유 서버가 있으면 그 서버의 목록, 없으면 입력 중인 목록)
        let jumpsForGate = jump.flatMap { id in store.computers.first { $0.id == id } }.map { store.jumpChain(for: $0) + [$0] } ?? []
        let gateList = jumpsForGate.first?.allowedIPs ?? (jumpsForGate.isEmpty ? NetworkAccess.parseList(allowedText) : [])
        let gateName = jumpsForGate.first?.name ?? (name.isEmpty ? h : name)
        Task { @MainActor in
            if !gateList.isEmpty {
                var r = await NetworkAccess.check(gateList)
                r.owner = gateName
                guard test == .testing else { return }
                if !r.allowed {
                    fail(NetworkAccess.explain(r, server: name.isEmpty ? h : name) + "\nVPN 을 켜면 다시 시험합니다.")
                    testDetail = nil
                    testBlocked = r
                    return
                }
            }
            startTest(h: h, user: user, auth: auth, hops: hops)
        }
    }

    private func startTest(h: String, user: String, auth: SSHShell.Auth, hops: [SSHShell.Hop]) {
        func fail(_ m: String) { lastTestError = m; test = .failed; testDetail = m }
        let s = SSHShell(host: h, port: Int(port) ?? 22, username: user, auth: auth, term: "xterm-256color", jumps: hops)
        s.interactive = false
        s.onHostKeyQuestion = { q, answer in testHostKey = (q, answer) }
        var finished = false
        s.onConnected = {
            Task { @MainActor in
                // 인증은 첫 채널을 열 때 끝난다 → whoami 로 확인
                do {
                    let r = try await s.execFull("whoami; hostname", timeout: 15)
                    let lines = r.stdout.split(separator: "\n").map(String.init)
                    finished = true
                    testHost = lines.dropFirst().first ?? h
                    test = .ok("\(lines.first ?? user) 로 로그인됨")
                } catch {
                    finished = true
                    fail("로그인하지 못했습니다: \(error.localizedDescription)")
                }
                s.close()
            }
        }
        s.onClose = { err, _ in
            guard !finished else { return }
            finished = true
            fail(err ?? "접속이 끊겼습니다.")
        }
        testShell = s
        s.connect(cols: 80, rows: 24, keepAlive: false)
    }

    struct AuthMessage: Error { let text: String }

    /// 저장된 인증 (경유 서버용)
    private static func savedAuth(_ c: Computer) -> Result<SSHShell.Auth, AuthMessage> {
        if c.sshAuth == .key {
            guard let file = Keychain.sshKey(for: c.id) else { return .failure(.init(text: "저장된 SSH 키가 없습니다.")) }
            do { return .success(.key(try OpenSSHKey.ed25519(from: file, passphrase: Keychain.sshKeyPassphrase(for: c.id)))) }
            catch { return .failure(.init(text: error.localizedDescription)) }
        }
        guard let pw = Keychain.password(for: c.id) else { return .failure(.init(text: "저장된 비밀번호가 없습니다.")) }
        return .success(.password(pw))
    }

    private func save() {
        let h = host.trimmingCharacters(in: .whitespaces)
        var c = computer ?? Computer(name: "", host: "", username: "")
        c.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? h : name
        c.host = h
        c.kind = kind
        c.port = Int(port) ?? kind.defaultPort
        c.username = username.trimmingCharacters(in: .whitespaces)
        c.preferHighPerformance = preferHP
        c.keepAliveInBackground = keepAlive
        let ips = NetworkAccess.parseList(allowedText)
        c.allowedIPs = ips.isEmpty ? nil : ips
        if kind == .ssh {
            c.sshEncoding = encoding == SSHEncoding.defaultID ? nil : encoding
            c.sshColor = color == .none ? nil : color
            c.sshJump = jump
            c.sshAuth = sshAuth
            if sshAuth == .key {
                c.sshKeyName = keyName
                if let newKey { Keychain.setSSHKey(newKey, for: c.id) }
                if !keyPassphrase.isEmpty { Keychain.setSSHKeyPassphrase(keyPassphrase, for: c.id) }
                // 새 키를 골랐는데 암호를 안 넣었으면, 예전 키의 암호는 맞지 않으니 지운다
                else if newKey != nil { Keychain.deleteSSHKeyPassphrase(for: c.id) }
            } else {
                c.sshKeyName = nil
                Keychain.deleteSSHKey(for: c.id)
            }
        }
        store.save(c, password: password.isEmpty ? nil : password)
        dismiss()
    }
}
