import CoreGraphics

/// 마우스 조작 방식
enum MouseMode: String {
    /// 누른 곳을 바로 클릭 (이동은 안 보냄)
    case touch
    /// 화면에 그린 포인터를 끌어서 움직이고, 탭하면 포인터 자리 클릭 (이동을 보냄)
    case trackpad
}

/// 화면 뷰가 맥에 보낼 마우스 동작. 좌표는 프레임버퍼 픽셀
@MainActor
protocol MouseInput: AnyObject {
    func mouseClick(_ p: CGPoint, button: UInt8)
    func mouseDown(_ p: CGPoint)
    func mouseMove(_ p: CGPoint)
    func mouseUp(_ p: CGPoint)
    /// 서버가 알려 준 커서 위치 (트랙패드 포인터 시작점)
    var serverCursor: CGPoint? { get }
    /// 지금 커서 자리에서 스크롤. dx, dy 는 프레임버퍼 픽셀, 양수 dy = 아래로 (내용이 위로)
    func mouseScroll(_ dx: CGFloat, _ dy: CGFloat, phase: RFBClient.ScrollPhase, momentum: RFBClient.MomentumPhase)
}
