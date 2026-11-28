import Foundation

/// Caches/debug.log 에 서버 메시지를 시간과 함께 남긴다. Release 에서도 남겨 문제가 생기면 기기에서 꺼내 본다 (접속할 때 2MB 를 넘으면 비운다).
enum DebugLog {
    private static let url = AppDirectories.caches.appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "DebugLog")
    private static var start = Date()

    /// 벽시계 시각 HH:mm:ss.SSS (맥 쪽 키 도착 시각과 비교용)
    static func wallClock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// 새 접속: 시각을 0 으로 돌리고 구분선을 넣는다 (다시 접속할 때 앞 접속 기록이 남도록 지우지 않는다. 2MB 를 넘으면 비운다)
    static func reset() {
        queue.sync {
            start = Date()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 2_000_000 { try? Data().write(to: url) }
            append(Data("===== 새 접속 =====\n".utf8))
        }
        recentLock.lock(); recentLines = []; recentLock.unlock()
    }

    private static let recentLock = NSLock()
    private static var recentLines: [String] = []

    /// 화면에 띄울 최근 고성능(HP) 줄
    static var recent: [String] {
        recentLock.lock(); defer { recentLock.unlock() }
        return recentLines
    }

    static func write(_ s: @autoclosure () -> String) {
        let text = s()
        if text.hasPrefix("HP") || text.hasPrefix("끝") || text.hasPrefix("인증") {
            recentLock.lock()
            recentLines.append(String(format: "%.1f ", Date().timeIntervalSince(start)) + text)
            if recentLines.count > 8 { recentLines.removeFirst(recentLines.count - 8) }
            recentLock.unlock()
        }
        let line = String(format: "%7.2f ", Date().timeIntervalSince(start)) + text + "\n"
        queue.async { append(Data(line.utf8)) }
    }

    /// 파일 끝에 붙인다. 옛 seekToEndOfFile()/write(_:) 는 실패하면 ObjC 예외를 던져 앱이 죽으므로 (2.6.4 아이폰 연결 종료 때 크래시),
    /// 던지는 API 로 쓰고 실패하면 그 줄은 버린다. queue 안에서만 부른다.
    private static func append(_ data: Data) {
        guard let h = try? FileHandle(forWritingTo: url) else { try? data.write(to: url); return }
        defer { try? h.close() }
        do {
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch {}
    }
}
