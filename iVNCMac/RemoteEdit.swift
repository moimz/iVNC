import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 서버 파일을 맥 앱으로 열어 고치고, 저장하면 서버에 다시 올린다 (Transmit 의 "편집"처럼, 사용자 2026-11-23).
// 받은 파일은 임시 폴더(파일마다 폴더 하나)에 두고 1초마다 수정 시각·크기를 본다. 에디터가 제자리에 쓰든
// 새 파일로 쓴 뒤 바꿔치기하든 둘 다 잡힌다 (폴더 감시는 제자리 쓰기를 못 잡아서 폴링).
// 올리기 전에 서버 파일의 수정 시각이 연 뒤 바뀌었으면 덮어쓸지 묻는다. 탭을 닫으면 감시를 멈추고 임시 파일을 지운다.

/// 열어 둔 서버 파일 하나
@MainActor
final class RemoteEdit {
    let remotePath: String
    let local: URL
    /// 열 때 파인더가 보던 사용자 (root 로 열었으면 root 로만 올린다)
    let viewer: String?
    /// 서버 파일의 마지막으로 아는 수정 시각 (받았을 때·올린 뒤)
    var remoteMtime: UInt32?
    /// 마지막으로 서버와 맞춘 이 맥 파일 상태
    var syncedStamp: Stamp?
    var uploading = false
    /// 바뀐 것을 본 상태 (다음 확인에도 같으면 올린다)
    var pending: Stamp?

    struct Stamp: Equatable { let mtime: Date; let size: Int64 }

    init(remotePath: String, local: URL, viewer: String?) {
        self.remotePath = remotePath
        self.local = local
        self.viewer = viewer
    }

    var currentStamp: Stamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: local.path),
              let m = a[.modificationDate] as? Date else { return nil }
        return Stamp(mtime: m, size: (a[.size] as? NSNumber)?.int64Value ?? 0)
    }
}

extension FileSession {
    /// 임시 폴더 (이 앱 것만)
    static let editRoot = FileManager.default.temporaryDirectory.appendingPathComponent("iVNC-edit", isDirectory: true)

    /// 서버 파일을 받아 app(없으면 기본 앱)으로 연다. 이미 열어 둔 파일이면 받지 않고 그대로 다시 연다
    func openRemote(_ item: FileItem, with app: URL? = nil) {
        guard !item.isDirectory else { return }
        if let e = edits[item.id], FileManager.default.fileExists(atPath: e.local.path) {
            Self.launch(e.local, with: app)
            return
        }
        guard let client else { remote.error = "접속돼 있지 않습니다."; return }
        let dir = Self.editRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let local = dir.appendingPathComponent(item.name)
        let edit = RemoteEdit(remotePath: item.id, local: local, viewer: viewer)
        let path = item.id
        let g = TransferCenter.shared.begin(.download, names: [item.name], server: serverName)
        enqueue(Transfer(name: item.name, upload: false, total: item.size ?? 0) { [weak self] t in
            try await client.download(path, to: local, progress: t.add, isCancelled: t.isCancelled)
            let mtime = try? await client.stat(path).mtime
            await MainActor.run {
                guard let self else { return }
                edit.remoteMtime = mtime
                edit.syncedStamp = edit.currentStamp
                self.edits[path] = edit
                self.startEditWatch()
                Self.launch(local, with: app)
            }
        }, group: g)
        g.preparing = false
    }

    /// 앱으로 열기. 기본 앱이 없는 파일(확장자 없음 등)은 텍스트 에디터로
    static func launch(_ url: URL, with app: URL?) {
        let ws = NSWorkspace.shared
        let target = app ?? ws.urlForApplication(toOpen: url) ?? ws.urlForApplication(toOpen: .plainText)
        let config = NSWorkspace.OpenConfiguration()
        if let target { ws.open([url], withApplicationAt: target, configuration: config) }
        else { ws.open(url) }
    }

    /// 이 파일을 열 수 있는 앱들 (기본 앱이 맨 앞). 서버 파일은 확장자로 고른다
    static func apps(for name: String, localURL: URL? = nil) -> [URL] {
        let ws = NSWorkspace.shared
        if let localURL {
            let list = ws.urlsForApplications(toOpen: localURL)
            if !list.isEmpty { return list }
        }
        let ext = (name as NSString).pathExtension
        let type = ext.isEmpty ? UTType.plainText : (UTType(filenameExtension: ext) ?? .data)
        var list = ws.urlsForApplications(toOpen: type)
        // 알 수 없는 종류(.data)면 텍스트 에디터도 같이
        if type == .data { list += ws.urlsForApplications(toOpen: UTType.plainText).filter { !list.contains($0) } }
        return list
    }

    /// "기타…": 앱을 직접 고른다
    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.message = "파일을 열 앱을 고르세요"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: 저장 감시 → 올리기

    func startEditWatch() {
        guard editTimer == nil else { return }
        editTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkEdits() }
        }
    }

    /// 바뀐 파일은 다음 확인(1초 뒤)에도 그대로면 올린다 (에디터가 아직 쓰는 중일 수 있어서)
    private func checkEdits() {
        for e in edits.values where !e.uploading {
            guard let now = e.currentStamp, now != e.syncedStamp else { e.pending = nil; continue }
            if e.pending == now {
                e.pending = nil
                e.uploading = true
                Task { await uploadEdit(e, stamp: now) }
            } else {
                e.pending = now
            }
        }
    }

    private func uploadEdit(_ e: RemoteEdit, stamp: RemoteEdit.Stamp) async {
        defer { e.uploading = false }
        let name = e.local.lastPathComponent
        // 다시 접속한 뒤라 SFTP 가 아직 안 열렸으면 연다. 접속이 끊겨 있으면 다음 확인 때 다시
        if client == nil, tab?.sshShell != nil { await appear() }
        guard let client else { return }
        if e.viewer != viewer {
            e.syncedStamp = stamp
            Self.alert("\(name) 을(를) 올리지 않았습니다",
                       "\(e.viewer ?? "로그인 계정") 로 열었는데 지금 파인더는 \(viewer ?? "로그인 계정") 로 보고 있습니다. 같은 사용자로 바꾼 뒤 다시 저장하세요.")
            return
        }
        // 연 뒤 서버에서 바뀌었으면 묻는다
        if let before = e.remoteMtime, let now = try? await client.stat(e.remotePath).mtime, now != before {
            let a = NSAlert()
            a.messageText = "\(name) 이(가) 서버에서 바뀌었습니다"
            a.informativeText = "\(e.remotePath)\n연 뒤에 서버의 파일이 바뀌었습니다. 이 맥에서 고친 내용으로 덮어쓸까요?"
            a.alertStyle = .warning
            a.addButton(withTitle: "덮어쓰기")
            a.addButton(withTitle: "올리지 않기")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn {
                e.syncedStamp = stamp
                return
            }
        }
        let g = TransferCenter.shared.begin(.upload, names: [name], server: serverName)
        let path = e.remotePath, local = e.local
        let t = Transfer(name: name, upload: true, total: stamp.size) { t in
            try await client.upload(local, to: path, progress: t.add, isCancelled: t.isCancelled)
        }
        enqueue(t, group: g)
        g.preparing = false
        // 끝날 때까지 기다린다 (실패하면 다음 저장 때 다시)
        while t.state == .waiting || t.state == .running { try? await Task.sleep(for: .milliseconds(200)) }
        if t.state == .done {
            e.syncedStamp = stamp
            e.remoteMtime = try? await client.stat(path).mtime
        } else if case .failed(let why) = t.state {
            e.syncedStamp = stamp
            Self.alert("\(name) 을(를) 서버에 올리지 못했습니다", "\(path)\n\(why)\n다시 저장하면 다시 올립니다.")
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// 탭을 닫을 때: 감시를 멈추고 임시 파일을 지운다
    func stopEdits() {
        editTimer?.invalidate()
        editTimer = nil
        for e in edits.values { try? FileManager.default.removeItem(at: e.local.deletingLastPathComponent()) }
        edits = [:]
    }
}
