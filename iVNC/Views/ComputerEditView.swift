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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("주소 (예: 192.168.0.10, mac.local)", text: $host)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    // 비워 두면 주소를 이름으로 쓴다: 그때 보일 이름을 흐리게 보여 준다
                    TextField(host.trimmingCharacters(in: .whitespaces).isEmpty ? "이름 (비우면 주소)" : host.trimmingCharacters(in: .whitespaces), text: $name)
                    TextField("포트", text: $port).keyboardType(.numberPad)
                } footer: {
                    Text("맥의 시스템 설정 > 일반 > 공유 > 화면 공유가 켜져 있어야 합니다.")
                }
                Section {
                    TextField("맥 계정 이름", text: $username)
                        .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(computer == nil ? "암호" : "암호 (바꿀 때만 입력)", text: $password)
                } footer: {
                    Text("암호는 이 기기의 키체인에만 저장됩니다.")
                }
                Section {
                    Toggle("고성능 모드 우선 사용", isOn: $preferHP)
                } footer: {
                    Text("맥이 지원하면 가상 디스플레이로 영상처럼 받습니다. 안 되면 기본 방식으로 접속합니다.")
                }
                Section {
                    Toggle("백그라운드에서 연결 유지", isOn: $keepAlive)
                } footer: {
                    Text("앱을 잠깐 나가도 연결이 끊기지 않고 맥도 잠들지 않습니다. 그동안 위치를 아주 낮은 정확도로 켜 두어 배터리를 조금 더 씁니다.")
                }
            }
            .navigationTitle(computer == nil ? "컴퓨터 추가" : "컴퓨터 편집")
            .navigationBarTitleDisplayMode(.inline)
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
            }
        }
    }

    private func save() {
        let h = host.trimmingCharacters(in: .whitespaces)
        var c = computer ?? Computer(name: "", host: "", username: "")
        c.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? h : name
        c.host = h
        c.port = Int(port) ?? 5900
        c.username = username.trimmingCharacters(in: .whitespaces)
        c.preferHighPerformance = preferHP
        c.keepAliveInBackground = keepAlive
        store.save(c, password: password.isEmpty ? nil : password)
        dismiss()
    }
}
