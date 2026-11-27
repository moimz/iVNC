import SwiftUI
import Sparkle

/// 자동 업데이트 (Sparkle, 사용자 2026-11-19 — iSQL 과 같은 방식, Ai/devid/자동업데이트.md).
/// 새 버전 목록(appcast.xml)은 GitHub 최신 릴리즈 파일 — iVNCMac-Info.plist 의 SUFeedURL
/// (releases/latest/download/appcast.xml: 늘 최신 릴리즈로 이어지는 정적 주소라 GitHub API 횟수 제한이 없다).
/// 업데이트 zip 은 Sparkle EdDSA 키로 서명하고 앱에는 공개 키(SUPublicEDKey)만 둔다. 비밀 키는 배포하는 맥의 키체인에만.
/// 새 버전이 있으면 릴리즈 설명과 함께 설치 / 나중에 / 건너뛰기를 묻는다 (묻지 않고 설치하지 않음)
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// "업데이트 확인…" 을 누를 수 있는지 (확인 중이면 못 누름)
    private(set) var canCheck = false

    private init() {
        #if DEBUG
        // 디버그(시험) 빌드는 업데이트를 확인하지 않는다 — 자동 시험 중에 업데이트 창이 뜨지 않게
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
            let can = u.canCheckForUpdates
            Task { @MainActor in self?.canCheck = can }
        }
    }

    /// 메뉴 iVNC > 업데이트 확인…
    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// 설정 > 자동으로 업데이트 확인 (Sparkle 이 UserDefaults 에 기억한다)
    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return controller.updater.automaticallyChecksForUpdates }
        set { withMutation(keyPath: \.automaticallyChecks) { controller.updater.automaticallyChecksForUpdates = newValue } }
    }
}

/// 메뉴 iVNC > 업데이트 확인… (확인 중에는 흐리게)
struct UpdateMenuButton: View {
    private var updater = Updater.shared
    var body: some View {
        Button("업데이트 확인…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}

/// 설정 > 업데이트 칸 (맥만)
struct UpdateSection: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        Section {
            LabeledContent("버전") {
                HStack(spacing: 8) {
                    // 한 줄로 못 박지 않으면 줄바꿈될 수 있는 글로 재서 폭을 덜 받아 "a09d…" 로 잘리고 버튼 오른쪽이 빈다 (Ai.md 12번)
                    Text(SettingsForm.versionValue).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
                        .lineLimit(1).fixedSize()
                    Button("업데이트 확인…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                }
            }
            Toggle("자동으로 업데이트 확인", isOn: $updater.automaticallyChecks)
        } header: {
            Text("업데이트")
        } footer: {
            Text("하루에 한 번 새 버전이 있는지 확인하고, 있으면 설치할지 묻습니다.")
        }
    }
}
