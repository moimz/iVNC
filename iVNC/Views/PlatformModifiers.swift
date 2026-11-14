import SwiftUI

/// 아이폰·아이패드에만 있는 입력창·제목 설정을 맥에서도 같은 코드로 쓰려고 감싼다 (맥에서는 아무것도 안 함)
extension View {
    /// 주소 입력: URL 키보드, 자동 대문자·고침 끔
    func urlField() -> some View {
        #if os(iOS)
        keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    /// 영문 입력 (계정 이름 등)
    func asciiField() -> some View {
        #if os(iOS)
        keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    /// 숫자 입력 (포트)
    func numberField() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// 제목을 작게 (시트)
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        formStyle(.grouped)
        #endif
    }
}
