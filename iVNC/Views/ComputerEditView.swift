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
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
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
                }
                #if os(iOS)
                .fileImporter(isPresented: $pickingKey, allowedContentTypes: [.data, .item]) { result in
                    guard case .success(let url) = result else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    takeKey(url)
                }
                #endif
                .alert("SSH 키를 쓸 수 없습니다", isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
                    Button("확인", role: .cancel) {}
                } message: {
                    Text(keyError ?? "")
                }
        }
    }

    /// 맥: 위에 [맥 | 윈도우] 탭이 붙은 상자 (TabView), 아이폰·아이패드: 맨 위 분할 단추
    @ViewBuilder private var content: some View {
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
                Picker("문자 인코딩", selection: $encoding) {
                    ForEach(SSHEncoding.all, id: \.id) { Text($0.title).tag($0.id) }
                }
            } footer: {
                Text("서버가 보내는 글자의 인코딩입니다. 요즘 서버는 거의 UTF-8 이고, 오래된 한국어 서버는 EUC-KR 일 수 있습니다.")
            }
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
        if kind == .ssh {
            c.sshEncoding = encoding == SSHEncoding.defaultID ? nil : encoding
            c.sshColor = color == .none ? nil : color
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
