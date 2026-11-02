import SwiftUI

/// 접속 한 번 (접속 → 모니터 고르기 → 화면 보기)
@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable {
        case connecting(String)
        case picking
        case viewing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting("접속하는 중…")
    @Published private(set) var displays: [RemoteDisplay] = []
    @Published private(set) var selected: RemoteDisplay?
    @Published private(set) var image: CGImage?
    /// 키보드로 원격 맥에 입력 중인지
    @Published var typing = false

    let computer: Computer
    private var client: RFBClient?
    private weak var store: ComputerStore?

    init(computer: Computer) {
        self.computer = computer
    }

    func connect(store: ComputerStore) {
        self.store = store
        client?.stop()
        phase = .connecting("접속하는 중…")
        guard let pw = Keychain.password(for: computer.id) else {
            phase = .failed("저장된 암호가 없습니다. 컴퓨터를 길게 눌러 편집에서 암호를 입력하세요.")
            return
        }
        let c = RFBClient(host: computer.host, port: computer.port, username: computer.username, password: pw)
        c.onEvent = { [weak self] in self?.handle($0) }
        client = c
        c.start()
    }

    private func handle(_ e: RFBClient.Event) {
        switch e {
        case .status(let s):
            if case .connecting = phase { phase = .connecting(s) }
        case .displays(let list):
            displays = list
            // 모니터가 하나여도 바로 고르지 않는다: 맥이 깨어날 때는 모니터가 하나씩 붙어서 처음 목록이 전부가 아닐 수 있다
            if case .connecting = phase {
                store?.markConnected(computer.id)
                phase = .picking
            }
        case .frame:
            image = client?.framebuffer.makeImage()
            client?.frameConsumed()
        case .failed(let msg):
            phase = .failed(msg)
        }
    }

    func select(_ d: RemoteDisplay) {
        saveThumbnail()
        image = nil
        selected = d
        phase = .viewing
        client?.select(display: d.id)
    }

    func backToPicker() {
        saveThumbnail()
        client?.pause()
        phase = .picking
    }

    func click(_ p: CGPoint) { client?.click(x: Int(p.x), y: Int(p.y)) }
    func sendText(_ t: String) { client?.sendText(t) }
    func sendBackspace(_ n: Int) { for _ in 0..<n { client?.sendSpecialKey(0xFF08, name: "BackSpace") } }
    func sendReturn() { client?.sendSpecialKey(0xFF0D, name: "Return") }

    func close() {
        saveThumbnail()
        client?.stop()
        client = nil
    }

    private func saveThumbnail() {
        guard phase == .viewing, let img = image else { return }
        Thumbnails.save(img, computer: computer.id, display: selected?.stableKey)
        store?.thumbnailsChanged()
    }
}

struct SessionView: View {
    @EnvironmentObject private var store: ComputerStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SessionModel
    @State private var chromeVisible = true

    init(computer: Computer) {
        _model = StateObject(wrappedValue: SessionModel(computer: computer))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .overlay(alignment: .top) { if chromeVisible || model.phase != .viewing { topBar } }
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            if RFBClient.hpTest {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(DebugLog.recent.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(6)
                        .background(.black.opacity(0.7))
                }
                .padding(.bottom, 30)
                .allowsHitTesting(false)
            }
        }
        #endif
        .statusBarHidden(model.phase == .viewing && !chromeVisible)
        .preferredColorScheme(.dark)
        .onAppear { model.connect(store: store) }
        .onDisappear { model.close() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .connecting(let status):
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(status).foregroundStyle(.secondary)
            }
        case .picking:
            DisplayPickerView(computer: model.computer, displays: model.displays) { model.select($0) }
                .padding(.top, 56)
        case .viewing:
            ZStack {
                ScreenView(image: model.image, onClick: model.click) { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
                    .ignoresSafeArea()
                KeyInputField(active: $model.typing, onText: model.sendText, onBackspace: model.sendBackspace, onReturn: model.sendReturn)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                if model.image == nil { ProgressView().controlSize(.large) }
            }
        case .failed(let msg):
            ContentUnavailableView {
                Label("접속하지 못했습니다", systemImage: "exclamationmark.triangle")
            } description: {
                Text(msg)
            } actions: {
                Button("다시 시도") { model.connect(store: store) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { model.close(); dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            Text(title).font(.headline).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 36)
                .glassEffect()
            Spacer()
            if model.phase == .viewing {
                Button { model.typing.toggle() } label: {
                    Image(systemName: model.typing ? "keyboard.chevron.compact.down" : "keyboard").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            if model.phase == .viewing && model.displays.count > 1 {
                Button { model.backToPicker() } label: {
                    Label("모니터", systemImage: "display.2").frame(height: 36)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var title: String {
        guard model.phase == .viewing, let d = model.selected, model.displays.count > 1,
              let i = model.displays.sorted(by: DisplayPickerView.order).firstIndex(of: d) else { return model.computer.name }
        return "\(model.computer.name) · 모니터 \(i + 1)"
    }
}
