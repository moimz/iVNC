import SwiftUI

/// 맥 앱 접속 창: 접속 → 모니터 고르기 → 화면 보기
struct MacSessionView: View {
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var model: SessionModel
    /// 화면을 보다가 모니터 바꾸기를 눌렀을 때 (처음 고를 때는 phase == .picking)
    @State private var changingDisplay = false

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
                // 속도는 버튼 묶음 밖에 글자만
                ToolbarItem(placement: .automatic) {
                    Text(model.trafficText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .sharedBackgroundVisibility(.hidden)
                if model.displays.count > 1 && !model.isHighPerformance {
                    ToolbarItem(placement: .automatic) {
                        Button("모니터 바꾸기", systemImage: "display.2") { changingDisplay = true }
                    }
                }
            }
        }
        // 모니터 고르기: 제목 막대 아래에 붙어 내려오는 시트
        .sheet(isPresented: pickerShown) {
            VStack(spacing: 0) {
                DisplayPickerView(computer: model.computer, displays: model.displays,
                                  title: model.phase == .picking ? "볼 모니터를 고르세요" : "모니터 바꾸기",
                                  current: model.phase == .viewing ? model.selected : nil, compact: true) { d in
                    changingDisplay = false
                    model.select(d)
                }
                HStack {
                    Spacer()
                    Button(model.phase == .picking ? "접속 취소" : "취소") {
                        if model.phase == .picking { dismissWindow() } else { changingDisplay = false }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding([.horizontal, .bottom], 20)
            }
            .frame(width: 560)
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

    private var pickerShown: Binding<Bool> {
        Binding(get: { model.phase == .picking || (changingDisplay && model.phase == .viewing) },
                set: { if !$0 { changingDisplay = false } })
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
            Color.clear // 모니터 고르기는 시트로
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
