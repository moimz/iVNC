import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// SSH 터미널 모양·동작 설정 (맥 터미널 앱의 프로필 하나와 같은 내용, 프로필 목록은 두지 않는다).
/// 기기마다 UserDefaults 에 저장한다 (iCloud 동기화 안 함: 기기마다 화면과 글자 크기가 달라서).
/// 터미널 화면은 아직 없다 — 값은 터미널을 만들 때 읽는다.
enum TerminalSettings {
    private static let p = "terminal."

    // 텍스트
    static let backgroundColor = p + "backgroundColor"
    static let backgroundOpacity = p + "backgroundOpacity"
    /// "" = 시스템 고정폭 글꼴(SF Mono)
    static let fontFamily = p + "fontFamily"
    static let fontSize = p + "fontSize"
    static let antialias = p + "antialias"
    static let useBold = p + "useBold"
    static let blinkText = p + "blinkText"
    static let ansiColors = p + "ansiColors"
    static let brightBold = p + "brightBold"
    static let textColor = p + "textColor"
    static let boldColor = p + "boldColor"
    static let selectionColor = p + "selectionColor"
    /// "normal0"…"normal7", "bright0"…"bright7" 를 뒤에 붙인다
    static let palette = p + "palette."
    static let cursorShape = p + "cursorShape"
    static let cursorBlink = p + "cursorBlink"
    static let cursorColor = p + "cursorColor"

    // 윈도우
    static let titleName = p + "title.name"
    static let titleAddress = p + "title.address"
    static let titleDirectory = p + "title.directory"
    static let titleSize = p + "title.size"
    static let scrollbackLimited = p + "scrollbackLimited"
    static let scrollbackLines = p + "scrollbackLines"

    // 셸
    static let startupCommand = p + "startupCommand"
    static let onExit = p + "onExit"
    static let confirmClose = p + "confirmClose"

    // 키보드
    static let optionAsMeta = p + "optionAsMeta"
    static let accessoryKeys = p + "accessoryKeys"

    // 고급
    static let termType = p + "termType"
    static let ambiguousWide = p + "ambiguousWide"
    static let bellSound = p + "bellSound"
    static let bellFlash = p + "bellFlash"
    static let deleteSendsCtrlH = p + "deleteSendsCtrlH"
    static let confirmMultilinePaste = p + "confirmMultilinePaste"
    static let keepAlive = p + "keepAlive"

    enum CursorShape: String, CaseIterable, Identifiable {
        case block, underline, bar
        var id: String { rawValue }
        var title: String {
            switch self {
            case .block: return "█ 사각형"
            case .underline: return "▁ 밑줄"
            case .bar: return "▏ 수직 막대"
            }
        }
    }

    /// 셸이 끝났을 때 (원격에서 exit 하거나 접속이 끊겼을 때)
    enum OnExit: String, CaseIterable, Identifiable {
        case close, closeIfClean, keep
        var id: String { rawValue }
        var title: String {
            switch self {
            case .close: return "창 닫기"
            case .closeIfClean: return "셸이 정상 종료되면 닫기"
            case .keep: return "창 닫지 않기"
            }
        }
    }

    static let termTypes = ["xterm-256color", "xterm", "vt100", "ansi"]

    /// 기본 색 (맥 터미널 기본 프로필과 비슷하게)
    enum Defaults {
        static let background = "#1E1E1E"
        static let text = "#E6E6E6"
        static let bold = "#FFFFFF"
        static let selection = "#5A5FA8"
        static let cursor = "#FFAA66"
        static let normal = ["#808080", "#FF6E67", "#A5F35F", "#FFFFAA", "#A6D4FF", "#FF77FF", "#C8C8FF", "#E6E6E6"]
        static let bright = ["#A8A8A8", "#FFB3AE", "#CBFFB1", "#FFFFC4", "#BFE1FF", "#FFA8FF", "#DCDCFF", "#FFFFFF"]
    }

    /// 고를 수 있는 고정폭 글꼴 집합 이름 (앞에 "" = 시스템 고정폭)
    static var monospacedFamilies: [String] {
        #if canImport(AppKit)
        let names = NSFontManager.shared.availableFontFamilies.filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
        #else
        let names = UIFont.familyNames.filter { f in
            UIFont.fontNames(forFamilyName: f).first.flatMap { UIFont(name: $0, size: 12) }?
                .fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
        }
        #endif
        return [""] + names.sorted()
    }
}

/// "#RRGGBB" 문자열로 저장하는 색 바인딩 (ColorPicker 용)
extension Binding where Value == Color {
    static func hex(_ value: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hex: value.wrappedValue) }, set: { value.wrappedValue = $0.hexString })
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        #if canImport(AppKit)
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func h(_ x: CGFloat) -> String { String(format: "%02X", Int((min(max(x, 0), 1) * 255).rounded())) }
        return "#" + h(r) + h(g) + h(b)
    }
}
