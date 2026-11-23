import SwiftUI
import AppKit

// 접속 허용 IP 가 아닐 때의 제목바 시트 (iSQL ServerViews 의 AccessSheet · SeenIPList · VPNList 를 옮김, 사용자 2026-11-23)

/// 허용 IP 가 아닐 때 제목바 시트: 본 IP · 이 맥의 VPN([연결] → 연결되면 retry) · 버튼. 원격 화면 · 터미널 · 접속 시험이 같이 쓴다
struct AccessSheet: View {
    let server: String
    let report: NetworkAccess.Report
    /// 다시 확인 (VPN 이 연결돼도 부른다)
    let retry: () -> Void
    /// 그래도 접속 (nil 이면 버튼 없음: 접속 시험)
    var force: (() -> Void)? = nil
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled").font(.system(size: 26)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(server) 에 접속할 수 없는 IP 입니다").font(.headline)
                    Text("접속 허용 IP: \(report.allowedList.joined(separator: ", "))" + (report.owner.isEmpty || report.owner == server ? "" : " (경유 서버 \(report.owner))"))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            SeenIPList(report: report)
            VPNList(onConnected: retry)
            HStack {
                Button("시스템 설정 > VPN") { VPNList.openSettings() }
                Spacer()
                Button("취소", action: close).keyboardShortcut(.cancelAction)
                if let force { Button("그래도 접속", action: force) }
                Button("다시 확인", action: retry).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// 허용 IP 검사에서 본 IP 들 (인터페이스 · 내부 IP → 공인 IP)
struct SeenIPList: View {
    let report: NetworkAccess.Report
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(report.seen, id: \.self) { s in
                HStack(spacing: 6) {
                    Text(NetworkAccess.label(s.interface)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Text(s.asked ? "\(s.local) → \(s.publicIP ?? "공인 IP 를 알 수 없음")" : "\(s.local) (공인)").monospacedDigit().textSelection(.enabled)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// macOS 에 등록된 VPN 목록 (시스템 설정 > VPN). [연결] 을 누른 VPN 이 연결되면 onConnected.
/// 연결하는 동안은 [취소], 연결 중이었다가 다시 꺼지거나 30초가 지나면 실패로 보고 [연결] 로 돌린다
struct VPNList: View {
    let onConnected: () -> Void
    @State private var vpns: [NetworkAccess.VPN] = []
    @State private var loaded = false
    /// [연결] 을 누른 VPN 과 그때 시각, 연결 중(Connecting)을 본 적 있는지
    @State private var waiting: String?
    @State private var waitStart = Date()
    @State private var sawConnecting = false
    @State private var failed: String?

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension")!)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("이 맥의 VPN").font(.headline).padding(.bottom, 2)
            if !loaded {
                ProgressView().controlSize(.small)
            } else if vpns.isEmpty {
                Text("시스템 설정 > VPN 에 등록된 VPN 이 없습니다. VPN 앱을 직접 켜 주세요.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(vpns) { v in
                HStack(spacing: 8) {
                    Circle().fill(v.connected ? Color.green : (v.connecting || waiting == v.id) ? Color.orange : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                    Text(v.name)
                    if failed == v.id { Text("연결 실패").font(.callout).foregroundStyle(.red) }
                    Spacer()
                    if v.connected {
                        Text("연결됨").foregroundStyle(.secondary).font(.callout)
                    } else if v.connecting || waiting == v.id {
                        ProgressView().controlSize(.small)
                        Button("취소") { cancel(v) }
                    } else {
                        Button("연결") { connect(v) }
                    }
                }
                // 버튼 · 진행 표시가 바뀌어도 줄 높이가 같게
                .frame(height: 28)
            }
        }
        .task { await poll() }
    }

    private func connect(_ v: NetworkAccess.VPN) {
        failed = nil
        waiting = v.id
        waitStart = Date()
        sawConnecting = false
        Task { await NetworkAccess.start(v) }
    }

    private func cancel(_ v: NetworkAccess.VPN) {
        waiting = nil
        Task { await NetworkAccess.stop(v) }
    }

    /// 1초마다 상태를 읽는다. [연결] 을 누른 VPN 이 연결되면 1초 뒤(경로가 바뀔 틈) onConnected
    private func poll() async {
        while !Task.isCancelled {
            let list = await NetworkAccess.vpnList()
            vpns = list
            loaded = true
            if let w = waiting, let v = list.first(where: { $0.id == w }) {
                if v.connected {
                    waiting = nil
                    try? await Task.sleep(for: .seconds(1))
                    onConnected()
                } else if v.connecting {
                    sawConnecting = true
                } else if sawConnecting || Date().timeIntervalSince(waitStart) > 30 {
                    // 연결하다 꺼졌거나(암호 오류 등) 너무 오래 걸림
                    waiting = nil
                    failed = w
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
