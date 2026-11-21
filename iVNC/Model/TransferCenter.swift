import SwiftUI

// 파일 전송 내역 (맥·아이패드 공용, 2026-11-21 사용자): 제목 줄 ⇅ 버튼을 누르면 받기·올리기 내역을 본다.
// 한 번에 시킨 것(파일 여러 개·폴더째)은 묶음 하나 = 진행 막대 하나, 펼치면 파일마다 진행 막대.

/// 파일 하나 옮기기. 받은 바이트는 이벤트 루프에서 늘고 화면은 타이머로 읽는다
final class Transfer: Identifiable, @unchecked Sendable {
    enum State: Equatable { case waiting, running, done, cancelled, failed(String) }
    let id = UUID()
    let name: String
    let upload: Bool
    /// 서버 → 서버
    let relay: Bool
    let total: Int64
    let work: (Transfer) async throws -> Void
    var state: State = .waiting
    var startedAt: Date?
    var finishedAt: Date?
    private let lock = NSLock()
    private var _done: Int64 = 0
    private var _cancelled = false

    init(name: String, upload: Bool, total: Int64, relay: Bool = false, work: @escaping (Transfer) async throws -> Void) {
        self.name = name; self.upload = upload; self.relay = relay; self.total = total; self.work = work
    }

    var done: Int64 { lock.lock(); defer { lock.unlock() }; return _done }
    func add(_ n: Int) { lock.lock(); _done += Int64(n); lock.unlock() }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : (state == .done ? 1 : 0) }
    var isActive: Bool { state == .waiting || state == .running }
    var isFailed: Bool { if case .failed = state { return true } else { return false } }
}

/// 한 번에 시킨 전송 묶음 (예: "photo.jpg 외 3개" 받기)
@MainActor
final class TransferGroup: Identifiable {
    enum Kind { case upload, download, relay }
    let id = UUID()
    let title: String
    let server: String
    let kind: Kind
    let date = Date()
    private(set) var items: [Transfer] = []
    /// 폴더 안을 아직 훑는 중 (파일 수·전체 크기가 더 늘 수 있다)
    var preparing = true
    private var cancelled = false

    init(title: String, server: String, kind: Kind) {
        self.title = title; self.server = server; self.kind = kind
    }

    func add(_ t: Transfer) {
        if cancelled { t.cancel(); t.state = .cancelled }
        items.append(t)
    }

    var total: Int64 { items.reduce(0) { $0 + $1.total } }
    var done: Int64 { items.reduce(0) { $0 + min($1.done, $1.total) } }
    var fraction: Double {
        let t = total
        if t > 0 { return min(1, Double(done) / Double(t)) }
        return items.isEmpty ? 0 : Double(finishedCount) / Double(items.count)
    }
    var isActive: Bool { preparing || items.contains(where: \.isActive) }
    var doneCount: Int { items.filter { $0.state == .done }.count }
    var failedCount: Int { items.filter(\.isFailed).count }
    var cancelledCount: Int { items.filter { $0.state == .cancelled }.count }
    var finishedCount: Int { items.filter { !$0.isActive }.count }
    var startedAt: Date? { items.compactMap(\.startedAt).min() }

    /// 지금 속도 (바이트/초): 시작부터 받은 양 / 걸린 시간
    var speed: Double {
        guard let s = startedAt else { return 0 }
        return Double(done) / max(Date().timeIntervalSince(s), 0.1)
    }

    func cancel() {
        cancelled = true
        preparing = false
        for t in items where t.isActive {
            t.cancel()
            if t.state == .waiting { t.state = .cancelled }
        }
    }
}

/// 앱 전체 전송 내역
@MainActor
final class TransferCenter: ObservableObject {
    static let shared = TransferCenter()
    @Published private(set) var groups: [TransferGroup] = []
    private var ticker: Timer?

    /// 새 묶음. 제목은 시킨 항목 이름으로 ("a.txt", "a.txt 외 2개")
    func begin(_ kind: TransferGroup.Kind, names: [String], server: String) -> TransferGroup {
        let title = names.count <= 1 ? (names.first ?? "") : "\(names[0]) 외 \(names.count - 1)개"
        let g = TransferGroup(title: title, server: server, kind: kind)
        groups.append(g)
        // 너무 쌓이면 끝난 오래된 것부터 버린다
        if groups.count > 50, let i = groups.firstIndex(where: { !$0.isActive }) { groups.remove(at: i) }
        startTicker()
        return g
    }

    var isActive: Bool { groups.contains(where: \.isActive) }
    /// 아직 남은 파일 수 (⇅ 배지)
    var remaining: Int { groups.filter(\.isActive).reduce(0) { $0 + $1.items.filter(\.isActive).count } }
    var hasFinished: Bool { groups.contains { !$0.isActive } }

    func clearFinished() { groups.removeAll { !$0.isActive } }

    /// 묶음의 파일들을 차례로 옮긴다 (동시에 parallel 개). 다 끝날 때까지 기다린다 (아이패드)
    func run(_ g: TransferGroup, parallel: Int = 2) async {
        startTicker()
        var queue = g.items[...]
        await withTaskGroup(of: Void.self) { tg in
            for _ in 0..<parallel {
                guard let t = queue.popFirst() else { break }
                tg.addTask { await self.runOne(t) }
            }
            while await tg.next() != nil {
                if let t = queue.popFirst() { tg.addTask { await self.runOne(t) } }
            }
        }
        objectWillChange.send()
    }

    private func runOne(_ t: Transfer) async {
        guard t.state == .waiting, !t.isCancelled() else { if t.isActive { t.state = .cancelled }; return }
        t.state = .running
        t.startedAt = Date()
        do {
            try await t.work(t)
            t.state = .done
        } catch {
            t.state = t.isCancelled() ? .cancelled : .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        t.finishedAt = Date()
    }

    /// 진행 막대를 0.25초마다 다시 그린다 (조각마다 그리면 너무 잦다)
    func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.objectWillChange.send()
                if !self.isActive { self.ticker?.invalidate(); self.ticker = nil }
            }
        }
    }
}

// MARK: - 화면

/// 제목 줄의 ⇅ 버튼: 누르면 전송 내역. 옮기는 중이면 남은 파일 수 배지 (사용자: 아래 상태 줄 대신).
/// 배지가 화면 모서리 둥근 곳에 잘리지 않게 툴바 맨 앞에 둔다
struct TransferHistoryButton: View {
    @ObservedObject private var center = TransferCenter.shared
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "arrow.up.arrow.down")
                #if os(iOS)
                // 다른 툴바 아이콘(17pt)보다 2pt 작게 (사용자)
                .font(.system(size: 15, weight: .regular))
                #endif
                .foregroundStyle(center.isActive ? Color.accentColor : Color.primary)
                .overlay(alignment: .topTrailing) {
                    if center.isActive { badge.offset(x: 10, y: -9) }
                }
        }
        .help("전송 내역")
        .accessibilityLabel("전송 내역")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            TransferHistoryView()
                .presentationCompactAdaptation(.sheet)
        }
    }
}

extension TransferHistoryButton {
    /// 빨간 알약에 남은 수 (폴더를 훑는 중이라 아직 0 이면 점만)
    @ViewBuilder fileprivate var badge: some View {
        let n = center.remaining
        Text(n > 0 ? (n > 99 ? "99+" : "\(n)") : " ")
            .font(.system(size: 10, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(.red))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// 전송 내역 목록: 묶음마다 통합 진행 막대, 펼치면 파일마다 진행 막대
struct TransferHistoryView: View {
    @ObservedObject private var center = TransferCenter.shared
    @State private var expanded: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 왼쪽 닫기 · 가운데 제목 · 오른쪽 휴지통(끝난 것 지우기) — 사용자
            ZStack {
                Text("전송 내역").font(.headline)
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .help("닫기").accessibilityLabel("닫기")
                    Spacer()
                    Button { withAnimation(.snappy) { center.clearFinished() } } label: { Image(systemName: "trash") }
                        .disabled(!center.hasFinished)
                        .help("끝난 내역 지우기").accessibilityLabel("끝난 내역 지우기")
                }
                #if os(iOS)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                #endif
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if center.groups.isEmpty {
                ContentUnavailableView("전송 내역이 없습니다", systemImage: "arrow.up.arrow.down",
                                       description: Text("파일을 받거나 올리면 여기에 보입니다."))
                    .frame(minHeight: 220)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(center.groups.reversed()) { g in
                            TransferGroupRow(group: g, expanded: Binding(
                                get: { expanded.contains(g.id) },
                                set: { if $0 { expanded.insert(g.id) } else { expanded.remove(g.id) } }))
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 520)
            }
        }
        #if os(macOS)
        .frame(width: 440)
        #else
        .frame(minWidth: 380, idealWidth: 440)
        #endif
    }
}

private struct TransferGroupRow: View {
    let group: TransferGroup
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(group.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(group.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: group.fraction)
                        .tint(group.failedCount > 0 ? .red : tint)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                if group.isActive {
                    Button { group.cancel() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("이 묶음 취소")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(.rect)
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.items) { TransferItemRow(item: $0, tint: tint) }
                    if group.preparing {
                        Label("폴더 안을 살펴보는 중…", systemImage: "ellipsis").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 60).padding(.trailing, 16).padding(.bottom, 12)
            }
        }
    }

    private var icon: String {
        switch group.kind {
        case .upload: "arrow.up.circle.fill"
        case .download: "arrow.down.circle.fill"
        case .relay: "arrow.left.arrow.right.circle.fill"
        }
    }

    private var tint: Color {
        switch group.kind {
        case .upload: .orange
        case .download: .accentColor
        case .relay: .purple
        }
    }

    private var statusLine: String {
        let size = "\(Self.bytes(group.done)) / \(Self.bytes(group.total))"
        let count = "\(group.finishedCount)/\(group.items.count)개"
        var parts = [group.server]
        if group.isActive {
            if group.preparing && group.items.isEmpty { parts.append("준비 중…") }
            else { parts += [size, count, "\(Self.bytes(Int64(group.speed)))/s"] }
        } else if group.failedCount > 0 {
            parts += ["실패 \(group.failedCount)개", "완료 \(group.doneCount)개"]
        } else if group.cancelledCount > 0 {
            parts += ["취소됨", "완료 \(group.doneCount)/\(group.items.count)개"]
        } else {
            parts += ["완료", "\(group.items.count)개", Self.bytes(group.total)]
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

private struct TransferItemRow: View {
    let item: Transfer
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                stateIcon.font(.caption)
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(sizeText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            // 파일 막대는 옮기는 중일 때만 (끝나면 지운다 — 묶음 막대는 늘 보인다, 사용자)
            if item.state == .running {
                ProgressView(value: item.fraction)
                    .tint(tint)
                    .controlSize(.small)
            }
            if case .failed(let msg) = item.state {
                Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch item.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(tint)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var sizeText: String {
        switch item.state {
        case .running: "\(TransferGroupRow.bytes(item.done)) / \(TransferGroupRow.bytes(item.total))"
        default: TransferGroupRow.bytes(item.total)
        }
    }
}
