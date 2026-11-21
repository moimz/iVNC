import SwiftUI
import CoreText
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// SSH 터미널 모양·동작 설정 (맥 터미널 앱의 프로필 하나와 같은 내용, 프로필 목록은 두지 않는다).
/// 기기마다 UserDefaults 에 저장하고, 글자 크기만 빼고 iCloud 로 맞춘다 (TerminalSettingsSync, 사용자 2026-11-21:
/// 화면 크기가 달라 글자 크기만 기기마다).
/// 터미널 화면은 아직 없다 — 값은 터미널을 만들 때 읽는다.
/// SSH 설정을 iCloud 키-값 저장소로 맥·아이폰·아이패드가 같이 쓴다 (글자 크기 제외).
/// 켤 때: iCloud 에 있으면 받고, 없는 것만 올린다. 그 뒤로는 이 기기에서 바꾸면 올리고, 다른 기기에서 바뀌면 받는다.
/// 기본값으로 되돌린 것(키가 지워진 것)은 넘기지 않는다 — 다른 기기 설정을 지워 버릴 수 있어서
@MainActor
final class TerminalSettingsSync {
    static let shared = TerminalSettingsSync()
    private let cloud = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private var applying = false
    private var started = false

    private static func synced(_ key: String) -> Bool {
        key.hasPrefix("terminal.") && key != TerminalSettings.fontSize
    }

    func start() {
        guard !started else { return }
        started = true
        cloud.synchronize()
        // 받기
        apply(cloud.dictionaryRepresentation.keys.filter(Self.synced))
        // iCloud 에 없는 것만 올리기
        for (k, v) in defaults.dictionaryRepresentation() where Self.synced(k) && cloud.object(forKey: k) == nil {
            cloud.set(v, forKey: k)
        }
        cloud.synchronize()
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] n in
            let keys = (n.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            MainActor.assumeIsolated { self?.apply(keys.filter(Self.synced)) }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }
    }

    private func apply(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        applying = true
        defer { applying = false }
        for k in keys {
            guard let v = cloud.object(forKey: k) else { continue }
            if !Self.same(defaults.object(forKey: k), v) { defaults.set(v, forKey: k) }
        }
    }

    /// 이 기기에서 바뀐 값만 올린다
    private func push() {
        guard !applying else { return }
        var changed = false
        for (k, v) in defaults.dictionaryRepresentation() where Self.synced(k) && !Self.same(cloud.object(forKey: k), v) {
            cloud.set(v, forKey: k)
            changed = true
        }
        if changed { cloud.synchronize() }
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a = a as? NSObject, let b = b as? NSObject else { return a == nil && b == nil }
        return a.isEqual(b)
    }
}

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

    /// 앱에 넣은 글꼴 (Fonts/, SIL OFL 1.1 — Fonts/D2Coding-OFL.txt). 한글이 정확히 영문 2칸이라 글자 사이가 안 벌어진다
    static let bundledFamilies = ["D2Coding"]
    private static let bundledFiles = ["D2Coding", "D2CodingBold"]

    /// 앱에 넣은 글꼴을 이 앱에서만 쓰게 등록 (한 번만). 글꼴 목록·터미널 글꼴을 만들기 전에 부른다
    static let registerBundledFonts: Void = {
        let urls = bundledFiles.compactMap { Bundle.main.url(forResource: $0, withExtension: "ttf") }
        if !urls.isEmpty { CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil) }
    }()

    /// 글꼴 목록에 보일 이름
    static func familyTitle(_ f: String) -> String {
        if f.isEmpty { return "SF Mono (시스템)" }
        return bundledFamilies.contains(f) ? "\(f) (앱 내장 · 한글)" : f
    }

    /// 글자가 차지하는 칸 수 (한글·한자·전각은 2칸, 결합 문자는 0칸) — 터미널과 같은 규칙
    static func cellCount(_ s: String) -> Int { s.unicodeScalars.reduce(0) { $0 + cellWidth(of: $1) } }

    static func cellWidth(of u: Unicode.Scalar) -> Int {
        switch u.value {
        case 0x0300...0x036F, 0x200B...0x200F: return 0
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default: return 1
        }
    }

    /// 고를 수 있는 고정폭 글꼴 집합 이름: "" = 시스템 고정폭, 그다음 앱에 넣은 글꼴, 그다음 이 기기 글꼴
    static var monospacedFamilies: [String] {
        _ = registerBundledFonts
        #if canImport(AppKit)
        let names = NSFontManager.shared.availableFontFamilies.filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
        #else
        let names = UIFont.familyNames.filter { f in
            UIFont.fontNames(forFamilyName: f).first.flatMap { UIFont(name: $0, size: 12) }?
                .fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
        }
        #endif
        return [""] + bundledFamilies + names.filter { !bundledFamilies.contains($0) }.sorted()
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
