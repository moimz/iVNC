import Foundation

/// 앱 폴더. 아이폰·아이패드는 앱마다 따로 있는 폴더 그대로,
/// 맥은 샌드박스를 안 쓰므로 ~/Library/Caches·Application Support 아래에 com.moimz.iVNC 폴더를 만들어 쓴다
enum AppDirectories {
    static let caches = make(.cachesDirectory)
    static let support = make(.applicationSupportDirectory)

    private static func make(_ d: FileManager.SearchPathDirectory) -> URL {
        var url = FileManager.default.urls(for: d, in: .userDomainMask)[0]
        #if os(macOS)
        url.appendPathComponent("com.moimz.iVNC")
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
