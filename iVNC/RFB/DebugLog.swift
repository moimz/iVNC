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

    static func reset() {
        #if DEBUG
        queue.sync {
            start = Date()
            try? Data().write(to: url)
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
