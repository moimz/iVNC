import SwiftUI

/// 맥 앱 접속 창: 접속 → 모니터 고르기 → 화면 보기
struct MacSessionView: View {
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var model: SessionModel
    /// 화면을 보다가 모니터 바꾸기를 눌렀을 때 (처음 고를 때는 phase == .picking)
    @State private var changingDisplay = false
    /// 한글 조합을 어디서 할지 (도구 막대 토글, 메뉴 "입력"과 같은 값)
    @AppStorage(MacScreenNSView.KeyMode.defaultsKey) private var keyMode = MacScreenNSView.KeyMode.remote.rawValue
    /// 시스템 단축키를 원격으로 보낼지 (켜려면 손쉬운 사용 권한)
    @AppStorage(SystemKeyCapture.defaultsKey) private var systemKeysToRemote = false
    @State private var needsAccessibility = false

    init(computer: Computer) {
        _model = StateObject(wrappedValue: SessionModel(computer: computer))
    }

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle(title)
        // 도구 막대는 늘 같은 모양으로 둔다 (단계마다 버튼이 없어지면 제목 막대 높이가 바뀌어 창 크기 계산이 어긋난다)
        .toolbar {
            // 속도는 버튼 묶음 밖에 글자만
            ToolbarItem(placement: .automatic) {
                Text(model.phase == .viewing ? model.trafficText : "")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .sharedBackgroundVisibility(.hidden)
            // 한글 조합 위치: 분할 단추 [⌨︎ 키 바로 전송 | 가 조합 후 전송] (칸마다 툴팁)
            ToolbarItem(placement: .automatic) {
                KeyModeSegments(mode: $keyMode)
            }
            // 토글끼리 한 묶음으로 붙지 않게 띄운다
            ToolbarSpacer(.fixed)
            // 시스템 단축키: [⌘ 원격으로 | 💻 이 맥에서] (⌘Q 는 어느 쪽이든 원격으로)
            ToolbarItem(placement: .automatic) {
                SystemKeySegments(toRemote: Binding(get: { systemKeysToRemote }, set: { setSystemKeys($0) }))
            }
            // 모니터 버튼은 따로 떨어진 묶음으로
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .automatic) {
                // display.2 는 옆으로 넓어 버튼이 뚱뚱해진다 (도구 막대는 글꼴 크기를 무시) → 그림 크기를 고정
                Button { changingDisplay = true } label: {
                    Image(systemName: "display.2")
                        .resizable().scaledToFit()
                        .frame(width: 18, height: 14)
                        .accessibilityLabel("모니터 바꾸기")
                }
                    .disabled(!(model.phase == .viewing && model.displays.count > 1 && !model.isHighPerformance))
                    .help(model.isHighPerformance ? "고성능 모드는 가상 디스플레이 하나만 봅니다" : "모니터 바꾸기")
            }
        }
        // 모니터 고르기: 제목 막대 아래에 붙어 내려오는 시트
        .sheet(isPresented: pickerShown) {
            VStack(spacing: 0) {
                DisplayPickerView(computer: model.computer, displays: model.displays,
                                  title: model.phase == .picking ? "볼 모니터를 고르세요" : "모니터 바꾸기",
                                  current: model.phase == .viewing ? model.selected : nil, compact: true) { d in
                    changingDisplay = false
                    model.select(d)
                }
                HStack {
                    Spacer()
                    Button(model.phase == .picking ? "접속 취소" : "취소") {
                        if model.phase == .picking { dismissWindow() } else { changingDisplay = false }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding([.horizontal, .bottom], 20)
            }
            .frame(width: 560)
        }
        // 한글 조합 중인 글자 (맥에 아직 안 간 것)
        .overlay(alignment: .bottom) {
            if model.phase == .viewing && !model.composing.isEmpty {
                Text(model.composing).foregroundStyle(.white).underline()
                    .font(.title3.monospaced())
                    .padding(.horizontal, 14).frame(height: 36)
                    .glassEffect()
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
        }
        // 고성능을 시도하면 설정 해상도로 창을 먼저 연다 (실패하면 모니터를 고른 뒤 그 크기로)
        .background(WindowReader { w, view in
            if model.computer.prefersHighPerformance {
                let v = SessionModel.virtualDisplaySize
                SessionWindowSizer.of(w).fit(pixel: CGSize(width: v.width, height: v.height), measuring: view)
            } else {
                _ = SessionWindowSizer.of(w)
            }
        })
        .alert("기기 제어 권한이 필요합니다", isPresented: $needsAccessibility) {
            Button("설정 열기") { SystemKeyCapture.openPrivacySettings() }
            Button("나중에", role: .cancel) {}
        } message: {
            Text("시스템 단축키를 원격 맥으로 보내려면 시스템 설정 > 개인정보 보호 및 보안 > 기기 제어 및 데이터 접근에서 iVNC 를 켜 주세요.\n\n목록에 iVNC 가 이미 켜져 있는데도 이 창이 뜨면, 예전 빌드의 권한입니다. iVNC 를 \"−\" 로 지운 뒤 \"+\" 로 /Applications/iVNC.app 을 다시 추가해 주세요. 켠 뒤 ⌘ 단추를 다시 누르면 됩니다.")
        }
        .onAppear {
            model.clipboardSharing = MacClipboard.enabled
            model.onRemoteClipboard = { MacClipboard.setFromRemote($0) }
            model.connect(store: store)
            if systemKeysToRemote && !SystemKeyCapture.shared.setEnabled(true) { systemKeysToRemote = false }
        }
        .onDisappear { model.close() }
        // 앱을 끌 때도 접속을 정리하고 끊는다 (창 닫힘이 오기 전에 프로세스가 끝날 수 있다)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.close() }
    }

    /// 시스템 단축키 보내는 곳 바꾸기. 권한이 없으면 안내하고 이 맥 그대로
    private func setSystemKeys(_ remote: Bool) {
        if remote {
            if SystemKeyCapture.shared.setEnabled(true) {
                systemKeysToRemote = true
            } else {
                needsAccessibility = true
                systemKeysToRemote = false
            }
        } else {
            SystemKeyCapture.shared.setEnabled(false)
            systemKeysToRemote = false
        }
    }

    private var pickerShown: Binding<Bool> {
        Binding(get: { model.phase == .picking || (changingDisplay && model.phase == .viewing) },
                set: { if !$0 { changingDisplay = false } })
    }

    private var title: String {
        guard model.phase == .viewing, let d = model.selected else { return model.computer.name }
        if model.isHighPerformance { return model.computer.name + " · 고성능" }
        let sorted = model.displays.sorted(by: DisplayPickerView.order)
        guard sorted.count > 1, let i = sorted.firstIndex(of: d) else { return model.computer.name }
        return model.computer.name + " · 모니터 \(i + 1)"
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .connecting(let status):
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(status).foregroundStyle(.white)
            }
        case .picking:
            Color.clear // 모니터 고르기는 시트로
        case .viewing:
            ZStack {
                MacScreenView(model: model, keyMode: keyMode)
                if !model.hasImage { ProgressView().controlSize(.large) }
            }
        case .failed(let msg):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.yellow)
                Text(msg).foregroundStyle(.white).multilineTextAlignment(.center)
                HStack {
                    Button("다시 시도") { model.connect(store: store) }.buttonStyle(.borderedProminent)
                    Button("닫기") { dismissWindow() }
                }
            }
            .padding(40)
        }
    }
}
