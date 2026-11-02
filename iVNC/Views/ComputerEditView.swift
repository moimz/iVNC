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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("이름 (비우면 주소)", text: $name)
                    TextField("주소 (예: 192.168.0.10, mac.local)", text: $host)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
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
                name = c.name; host = c.host; port = String(c.port); username = c.username
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
        store.save(c, password: password.isEmpty ? nil : password)
        dismiss()
    }
}
