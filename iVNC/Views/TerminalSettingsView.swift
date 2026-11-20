import SwiftUI

/// 설정 > SSH: 맥 터미널 프로필처럼 [텍스트 | 윈도우 | 셸 | 키보드 | 고급].
/// 맥은 상자 탭(BoxTabView), 아이폰·아이패드는 목록에서 하나씩 들어간다.
enum TerminalSettingsPage: Int, CaseIterable, Identifiable {
    case text, window, shell, keyboard, advanced
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .text: return "텍스트"
        case .window: return "윈도우"
        case .shell: return "셸"
        case .keyboard: return "키보드"
        case .advanced: return "고급"
        }
    }
    var systemImage: String {
        switch self {
        case .text: return "textformat"
        case .window: return "macwindow"
        case .shell: return "apple.terminal"
        case .keyboard: return "keyboard"
        case .advanced: return "gearshape.2"
        }
    }

    @ViewBuilder var form: some View {
        switch self {
        case .text: TerminalTextForm()
        case .window: TerminalWindowForm()
        case .shell: TerminalShellForm()
        case .keyboard: TerminalKeyboardForm()
        case .advanced: TerminalAdvancedForm()
        }
    }
}

#if !os(macOS)
/// 아이폰·아이패드: 설정 > SSH 목록
struct TerminalSettingsList: View {
    var body: some View {
        List {
            Section {
                ForEach(TerminalSettingsPage.allCases) { page in
                    NavigationLink {
                        page.form.navigationTitle(page.title).inlineTitle()
                    } label: {
                        Label(page.title, systemImage: page.systemImage)
                    }
                }
            } footer: {
                Text("SSH 터미널의 모양과 동작입니다. 이 기기에만 저장됩니다.")
            }
        }
    }
}
#endif

/// 텍스트: 배경, 서체, 텍스트, ANSI 색상, 커서
struct TerminalTextForm: View {
    typealias K = TerminalSettings
    typealias D = TerminalSettings.Defaults
    @AppStorage(K.backgroundColor) private var background = D.background
    @AppStorage(K.backgroundOpacity) private var opacity = 1.0
    @AppStorage(K.fontFamily) private var fontFamily = ""
    @AppStorage(K.fontSize) private var fontSize = 13.0
    @AppStorage(K.antialias) private var antialias = true
    @AppStorage(K.useBold) private var useBold = true
    @AppStorage(K.blinkText) private var blinkText = true
    @AppStorage(K.ansiColors) private var ansiColors = true
    @AppStorage(K.brightBold) private var brightBold = false
    @AppStorage(K.textColor) private var textColor = D.text
    @AppStorage(K.boldColor) private var boldColor = D.bold
    @AppStorage(K.selectionColor) private var selectionColor = D.selection
    @AppStorage(K.cursorShape) private var cursorShape = K.CursorShape.underline.rawValue
    @AppStorage(K.cursorBlink) private var cursorBlink = true
    @AppStorage(K.cursorColor) private var cursorColor = D.cursor

    var body: some View {
        Form {
            Section("배경") {
                ColorPicker("색상", selection: .hex($background), supportsOpacity: false)
                LabeledContent("불투명도") {
                    HStack {
                        Slider(value: $opacity, in: 0.3...1)
                        Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("서체") {
                Picker("서체", selection: $fontFamily) {
                    ForEach(TerminalSettings.monospacedFamilies, id: \.self) { f in
                        Text(f.isEmpty ? "SF Mono (시스템)" : f).tag(f)
                    }
                }
                Stepper(value: $fontSize, in: 8...32, step: 1) {
                    LabeledContent("크기", value: "\(Int(fontSize))pt")
                }
                Text("가나다 ABC abc 0123 ~/.ssh $")
                    .font(previewFont)
                    .foregroundStyle(Color(hex: textColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(hex: background).opacity(opacity), in: RoundedRectangle(cornerRadius: 6))
            }
            Section("텍스트") {
                Toggle("안티 앨리어싱 텍스트", isOn: $antialias)
                Toggle("볼드체 사용", isOn: $useBold)
                Toggle("깜박이는 텍스트 허용", isOn: $blinkText)
                Toggle("ANSI 색상 표시", isOn: $ansiColors)
                Toggle("볼드 텍스트에 대해 밝은색 사용", isOn: $brightBold)
                ColorPicker("텍스트", selection: .hex($textColor), supportsOpacity: false)
                ColorPicker("볼드 텍스트", selection: .hex($boldColor), supportsOpacity: false)
                ColorPicker("선택 부분", selection: .hex($selectionColor), supportsOpacity: false)
            }
            Section {
                PaletteRow(title: "보통", prefix: "normal", defaults: D.normal)
                PaletteRow(title: "밝게", prefix: "bright", defaults: D.bright)
            } header: {
                Text("ANSI 색상")
            }
            .disabled(!ansiColors)
            Section("커서") {
                Picker("모양", selection: $cursorShape) {
                    ForEach(TerminalSettings.CursorShape.allCases) { Text($0.title).tag($0.rawValue) }
                }
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #endif
                Toggle("깜박이는 커서", isOn: $cursorBlink)
                ColorPicker("커서", selection: .hex($cursorColor), supportsOpacity: false)
            }
            Section {
                Button("텍스트 설정 기본값으로", role: .destructive) { resetColors() }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private var previewFont: Font {
        fontFamily.isEmpty ? .system(size: fontSize, design: .monospaced) : .custom(fontFamily, size: fontSize)
    }

    private func resetColors() {
        background = D.background; opacity = 1; fontFamily = ""; fontSize = 13
        antialias = true; useBold = true; blinkText = true; ansiColors = true; brightBold = false
        textColor = D.text; boldColor = D.bold; selectionColor = D.selection
        cursorShape = TerminalSettings.CursorShape.underline.rawValue; cursorBlink = true; cursorColor = D.cursor
        for i in 0..<8 {
            UserDefaults.standard.removeObject(forKey: TerminalSettings.palette + "normal\(i)")
            UserDefaults.standard.removeObject(forKey: TerminalSettings.palette + "bright\(i)")
        }
    }
}

/// ANSI 8색 한 줄
private struct PaletteRow: View {
    let title: String
    let prefix: String
    let defaults: [String]

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                ForEach(0..<8, id: \.self) { i in
                    PaletteWell(key: TerminalSettings.palette + prefix + "\(i)", fallback: defaults[i])
                }
            }
        }
    }
}

private struct PaletteWell: View {
    @AppStorage private var hex: String
    init(key: String, fallback: String) { _hex = AppStorage(wrappedValue: fallback, key) }
    var body: some View {
        ColorPicker("", selection: .hex($hex), supportsOpacity: false).labelsHidden()
    }
}

/// 윈도우: 제목, 스크롤백
struct TerminalWindowForm: View {
    typealias K = TerminalSettings
    @AppStorage(K.titleName) private var titleName = true
    @AppStorage(K.titleAddress) private var titleAddress = true
    @AppStorage(K.titleDirectory) private var titleDirectory = false
    @AppStorage(K.titleSize) private var titleSize = false
    @AppStorage(K.scrollbackLimited) private var limited = true
    @AppStorage(K.scrollbackLines) private var lines = 10_000

    var body: some View {
        Form {
            Section {
                Toggle("서버 이름", isOn: $titleName)
                Toggle("계정@주소", isOn: $titleAddress)
                Toggle("작업 디렉토리 (서버가 알려 줄 때)", isOn: $titleDirectory)
                Toggle("창 크기 (열 × 행)", isOn: $titleSize)
            } header: {
                Text("제목")
            }
            Section {
                Toggle("줄 수 제한", isOn: $limited)
                if limited {
                    Stepper(value: $lines, in: 1_000...200_000, step: 1_000) {
                        LabeledContent("줄", value: lines.formatted())
                    }
                }
            } header: {
                Text("스크롤백")
            } footer: {
                Text(limited ? "지나간 내용을 이만큼 기억합니다." : "제한 없이 기억합니다. 오래 열어 두면 메모리를 많이 씁니다.")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

/// 셸: 시작 명령, 끝났을 때, 닫을 때 확인
struct TerminalShellForm: View {
    typealias K = TerminalSettings
    @AppStorage(K.startupCommand) private var command = ""
    @AppStorage(K.onExit) private var onExit = K.OnExit.keep.rawValue
    @AppStorage(K.confirmClose) private var confirmClose = true

    var body: some View {
        Form {
            Section {
                TextField("명령", text: $command, prompt: Text("예: tmux attach || tmux"))
                    .asciiField()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("시작 시 실행")
            } footer: {
                Text("접속하자마자 서버에서 이 명령을 실행합니다. 비워 두면 로그인 셸만 엽니다.")
            }
            Section("셸이 종료되면") {
                Picker("셸이 종료되면", selection: $onExit) {
                    ForEach(K.OnExit.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }
            Section {
                Toggle("접속 중인 창을 닫기 전에 확인", isOn: $confirmClose)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

/// 키보드: Option = Meta, (아이폰·아이패드) 키보드 위 특수 키 줄
struct TerminalKeyboardForm: View {
    typealias K = TerminalSettings
    @AppStorage(K.optionAsMeta) private var optionAsMeta = false
    @AppStorage(K.accessoryKeys) private var accessoryKeys = true

    var body: some View {
        Form {
            Section {
                Toggle("Option 키를 Meta 키로 사용", isOn: $optionAsMeta)
            } footer: {
                Text("켜면 Option+글자를 Esc+글자로 보냅니다 (emacs 등). 끄면 Option 으로 특수 문자를 입력합니다.")
            }
            #if !os(macOS)
            Section {
                Toggle("키보드 위 특수 키 줄", isOn: $accessoryKeys)
            } footer: {
                Text("화면 키보드 위에 ⎋ ⇥ ⌃ 방향키 같은 터미널 키를 둡니다.")
            }
            #endif
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

/// 고급: 터미널 유형, 동아시아 문자 폭, 벨, 입력, 접속 유지
struct TerminalAdvancedForm: View {
    typealias K = TerminalSettings
    @AppStorage(K.termType) private var termType = "xterm-256color"
    @AppStorage(K.ambiguousWide) private var ambiguousWide = false
    @AppStorage(K.bellSound) private var bellSound = true
    @AppStorage(K.bellFlash) private var bellFlash = false
    @AppStorage(K.deleteSendsCtrlH) private var deleteSendsCtrlH = false
    @AppStorage(K.confirmMultilinePaste) private var confirmPaste = true
    @AppStorage(K.keepAlive) private var keepAlive = true

    var body: some View {
        Form {
            Section {
                Picker("터미널 유형 선언", selection: $termType) {
                    ForEach(K.termTypes, id: \.self) { Text($0).tag($0) }
                }
                Toggle("유니코드 동아시아 모호 문자를 넓은 문자로", isOn: $ambiguousWide)
            } header: {
                Text("에뮬레이션")
            } footer: {
                Text("모호 문자(①, ○, ※ 등)를 두 칸으로 그립니다. 서버 프로그램과 칸이 어긋나면 바꿔 보세요.")
            }
            Section("벨") {
                Toggle("경고음", isOn: $bellSound)
                Toggle("화면 깜박이기", isOn: $bellFlash)
            }
            Section("입력") {
                Toggle("삭제 키로 Control-H 보내기", isOn: $deleteSendsCtrlH)
                Toggle("여러 줄을 붙여넣기 전에 확인", isOn: $confirmPaste)
            }
            Section {
                Toggle("접속 유지 신호 보내기", isOn: $keepAlive)
            } footer: {
                Text("한동안 입력이 없어도 공유기·서버가 접속을 끊지 않게 30초마다 신호를 보냅니다. 문자 인코딩은 서버마다 다를 수 있어 SSH 서버 편집에서 고릅니다.")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}
