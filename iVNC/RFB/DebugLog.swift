import Foundation

/// Debug 빌드에서만 Caches/debug.log 에 서버 메시지를 시간과 함께 남긴다 (시뮬레이터 시험용).
enum DebugLog {
    #if DEBUG
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "DebugLog")
    private static var start = Date()
    #endif

    /// 벽시계 시각 HH:mm:ss.SSS (맥 쪽 키 도착 시각과 비교용)
    static func wallClock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// 새 접속: 시각을 0 으로 돌리고 구분선을 넣는다 (다시 접속할 때 앞 접속 기록이 남도록 지우지 않는다. 2MB 를 넘으면 비운다)
    static func reset() {
        #if DEBUG
        queue.sync {
            start = Date()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 2_000_000 { try? Data().write(to: url) }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data("===== 새 접속 =====\n".utf8)); try? h.close()
            } else {
                try? Data("===== 새 접속 =====\n".utf8).write(to: url)
            }
        }
        recentLock.lock(); recentLines = []; recentLock.unlock()
        #endif
    }

    #if DEBUG
    private static let recentLock = NSLock()
    private static var recentLines: [String] = []
    #endif

    /// 화면에 띄울 최근 고성능(HP) 줄
    static var recent: [String] {
        #if DEBUG
        recentLock.lock(); defer { recentLock.unlock() }
        return recentLines
        #else
        return []
        #endif
    }

    static func write(_ s: @autoclosure () -> String) {
        #if DEBUG
        let text = s()
        if text.hasPrefix("HP") || text.hasPrefix("끝") || text.hasPrefix("인증") {
            recentLock.lock()
            recentLines.append(String(format: "%.1f ", Date().timeIntervalSince(start)) + text)
            if recentLines.count > 8 { recentLines.removeFirst(recentLines.count - 8) }
            recentLock.unlock()
        }
        let line = String(format: "%7.2f ", Date().timeIntervalSince(start)) + text + "\n"
        queue.async {
            guard let h = try? FileHandle(forWritingTo: url) else { try? Data(line.utf8).write(to: url); return }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
        #endif
    }
}
