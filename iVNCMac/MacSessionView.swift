import SwiftUI

/// 맥 앱 접속 창: 접속 → 모니터 고르기 → 화면 보기
struct MacSessionView: View {
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var model: SessionModel

    init(computer: Computer) {
        _model = StateObject(wrappedValue: SessionModel(computer: computer))
    }

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle(title)
        .toolbar {
            if model.phase == .viewing {
                ToolbarItem(placement: .automatic) {
                    Text(model.trafficText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if model.displays.count > 1 && !model.isHighPerformance {
                    ToolbarItem(placement: .automatic) {
                        Button("모니터 바꾸기", systemImage: "display.2") { model.backToPicker() }
                    }
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("연결 끊기", systemImage: "xmark.circle") { dismissWindow() }
            }
        }
        // 한글 조합 중인 글자 (맥에 아직 안 간 것)
        .overlay(alignment: .bottom) {
            if model.phase == .viewing && !model.composing.isEmpty {
                Text(model.composing).foregroundStyle(.white).underline()
                    .font(.title3.monospaced())
                    .padding(.horizontal, 14).frame(height: 36)
                    .glassEffect()
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { model.connect(store: store) }
        .onDisappear { model.close() }
    }

    private var title: String {
        guard model.phase == .viewing, let d = model.selected else { return model.computer.name }
        if model.isHighPerformance { return model.computer.name + " · 고성능" }
        let sorted = model.displays.sorted(by: DisplayPickerView.order)
        guard sorted.count > 1, let i = sorted.firstIndex(of: d) else { return model.computer.name }
        return model.computer.name + " · 모니터 \(i + 1)"
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .connecting(let status):
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(status).foregroundStyle(.white)
            }
        case .picking:
            DisplayPickerView(computer: model.computer, displays: model.displays) { model.select($0) }
                .foregroundStyle(.white)
                .padding(40)
        case .viewing:
            ZStack {
                MacScreenView(model: model)
                if !model.hasImage { ProgressView().controlSize(.large) }
            }
        case .failed(let msg):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.yellow)
                Text(msg).foregroundStyle(.white).multilineTextAlignment(.center)
                HStack {
                    Button("다시 시도") { model.connect(store: store) }.buttonStyle(.borderedProminent)
                    Button("닫기") { dismissWindow() }
                }
            }
            .padding(40)
        }
    }
}
