import SwiftUI

/// 앱 설정 (아이폰·아이패드: 목록 왼쪽 위 버튼 → 시트). [일반 | 화면 공유 | SSH] 를 목록에서 하나씩 들어간다
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                #if !os(macOS)
                NavigationLink { GeneralSettingsForm().navigationTitle("일반").inlineTitle() } label: {
                    Label("일반", systemImage: "gearshape")
                }
                NavigationLink { ScreenSettingsForm().navigationTitle("화면 공유").inlineTitle() } label: {
                    Label("화면 공유", systemImage: "display.2")
                }
                NavigationLink { TerminalSettingsList().navigationTitle("SSH").inlineTitle() } label: {
                    Label("SSH", systemImage: "terminal")
                }
                #endif
            }
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

/// 설정 > 화면 공유: 원격 화면 해상도 (맥 고성능·윈도우)
struct ScreenSettingsForm: View {
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

/// 설정 > 일반: 백그라운드 연결 유지(아이폰·아이패드), 업데이트(맥), 오픈 소스 라이선스, 버전
struct GeneralSettingsForm: View {
    @State private var showLicenses = false
    @AppStorage(AppSettings.keepAliveKey) private var keepAlive = true

    var body: some View {
        Form {
            #if os(macOS)
            UpdateSection() // 자동 업데이트 (맥 앱만, iVNCMac/Updater.swift)
            #else
            Section {
                Toggle("백그라운드에서 연결 유지", isOn: $keepAlive)
            } footer: {
                Text("백그라운드 진입 시 GPS 신호를 활용하여 원격 서버와 연결을 계속 유지합니다.")
            }
            .onChange(of: keepAlive) { BackgroundKeeper.shared.refresh() }
            #endif
            Section {
                Button("오픈 소스 라이선스") { showLicenses = true }
            } footer: {
                Text(SettingsForm.versionText).frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .sheet(isPresented: $showLicenses) { LicensesView() }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

/// 버전 글자 (예전 이름 그대로 둔다)
enum SettingsForm {
    /// "버전 2.6 (빌드 178 · 3fa9740)" — 빌드 번호는 git 커밋 수, 뒤는 커밋 해시 ("+" 는 커밋 전 변경 포함). Scripts/stamp-build-number.sh, Ai.md "앱 안의 버전 표시"
    static var versionText: String { "버전 " + versionValue }

    /// "버전" 이름표가 이미 있는 곳(맥 정보 창)에 쓰는 값만: "2.6 (빌드 178 · 3fa9740)"
    static var versionValue: String {
        let info = Bundle.main.infoDictionary ?? [:]
        // b 로 끝나는 브랜치(시험판) 빌드는 "2.0b"
        let version = (info["CFBundleShortVersionString"] as? String ?? "-") + (info["iVNCBeta"] as? Bool == true ? "b" : "")
        let build = info["CFBundleVersion"] as? String ?? "-"
        let commit = info["iVNCCommit"] as? String
        return "\(version) (빌드 \(build)\(commit.map { " · \($0)" } ?? ""))"
    }
}

/// 오픈 소스 라이선스 (FreeRDP·OpenSSL, Apache 2.0). 앱에 넣은 OpenSourceLicenses.txt 를 그대로 보여 준다
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        Bundle.main.url(forResource: "OpenSourceLicenses", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("오픈 소스 라이선스")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }
}
