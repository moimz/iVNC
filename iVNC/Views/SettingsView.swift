import SwiftUI

/// 앱 설정 (아이폰·아이패드: 목록 왼쪽 위 버튼 → 시트)
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsForm()
                .navigationTitle("설정")
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료") { dismiss() }
                    }
                }
        }
    }
}

/// 설정 내용 (맥은 목록 창 옆 패널과 설정 창에서 이것만 쓴다)
struct SettingsForm: View {
    /// "" = 기기에 맞춤
    @AppStorage(AppSettings.resolutionKey) private var resolution = ""

    var body: some View {
        Form {
            Section {
                Picker("해상도", selection: $resolution) {
                    Text("기기에 맞춤").tag("")
                    ForEach(AppSettings.Resolution.presets) { r in
                        Text(r.title).tag(r.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("원격 화면 해상도")
            } footer: {
                Text("맥 고성능 모드와 윈도우 접속에 쓰입니다. 다음 접속부터 적용됩니다. 맥 일반 모드는 맥의 실제 해상도로 보입니다.")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}
