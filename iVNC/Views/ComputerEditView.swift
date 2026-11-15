import SwiftUI

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

    var body: some View {
        NavigationStack {
            content
                .onChange(of: kind) { old, new in
                    // 포트를 안 바꿨으면 종류의 기본 포트로
                    if port == String(old.defaultPort) || port.isEmpty { port = String(new.defaultPort) }
                }
                .navigationTitle(computer == nil ? "컴퓨터 추가" : "컴퓨터 편집")
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("저장") { save() }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .onAppear {
                    guard let c = computer else { return }
                    name = c.name == c.host ? "" : c.name; host = c.host; port = String(c.port); username = c.username
                    preferHP = c.prefersHighPerformance
                    keepAlive = c.keepsAliveInBackground
                    kind = c.type
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
        .padding()
        #else
        Form {
            Section {
                Picker("종류", selection: $kind) {
                    ForEach(Computer.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            fields
        }
        #endif
    }

    @ViewBuilder private var fields: some View {
        Section {
            TextField(kind == .mac ? "주소 (예: 192.168.0.10, mac.local)" : "주소 (예: 192.168.0.20, pc.local)", text: $host)
                .urlField()
            // 비워 두면 주소를 이름으로 쓴다: 그때 보일 이름을 흐리게 보여 준다
            TextField(host.trimmingCharacters(in: .whitespaces).isEmpty ? "이름 (비우면 주소)" : host.trimmingCharacters(in: .whitespaces), text: $name)
            TextField("포트", text: $port).numberField()
        } footer: {
            Text(kind == .mac ? "맥의 시스템 설정 > 일반 > 공유 > 화면 공유가 켜져 있어야 합니다."
                              : "윈도우의 설정 > 시스템 > 원격 데스크톱이 켜져 있어야 합니다 (윈도우 Pro 이상).")
        }
        Section {
            TextField(kind == .mac ? "맥 계정 이름" : "윈도우 계정 (사용자 이름 또는 Microsoft 계정 이메일)", text: $username)
                .asciiField()
            SecureField(computer == nil ? "암호" : "암호 (바꿀 때만 입력)", text: $password)
        } footer: {
            Text("암호는 이 기기의 키체인에만 저장됩니다.")
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
        store.save(c, password: password.isEmpty ? nil : password)
        dismiss()
    }
}
