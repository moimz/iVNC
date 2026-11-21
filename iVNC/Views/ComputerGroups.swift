import SwiftUI

/// 컴퓨터 목록의 묶음 머리 (누르면 접었다 폈다). 아이폰·아이패드·맥 공용
struct ComputerGroupHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(count)개")
        .accessibilityValue(expanded ? "펼침" : "접힘")
    }
}

/// SSH 서버 한 줄 (아이콘, 이름, 계정@주소)
struct SSHRow: View {
    let computer: Computer
    /// 맥: 한 번 눌러 고른 줄
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            ServerIcon(color: computer.sshColor ?? .none, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.name).font(.body).lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(address).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }

    /// 계정@주소 (기본 포트가 아니면 :포트)
    private var address: String {
        let user = computer.username.isEmpty ? "" : computer.username + "@"
        let port = computer.port == Computer.Kind.ssh.defaultPort ? "" : ":\(computer.port)"
        return user + computer.host + port
    }
}

/// 서버 아이콘: 서버 색으로 칠한 둥근 정사각형 + 터미널 그림 (iSQL ServerIcon 과 같은 모양).
/// 바탕이 밝으면(노랑 등) 그림을 어둡게
struct ServerIcon: View {
    let color: ServerColor
    var size: CGFloat = 30
    @Environment(\.colorScheme) private var scheme

    private var glyphColor: Color {
        guard let c = color.color else { return .white }
        var env = EnvironmentValues()
        env.colorScheme = scheme
        let r = c.resolve(in: env)
        let l = 0.2126 * Double(r.linearRed) + 0.7152 * Double(r.linearGreen) + 0.0722 * Double(r.linearBlue)
        return l > 0.55 ? Color.black.opacity(0.72) : .white
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.color ?? Color.gray)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "apple.terminal.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(glyphColor)
            }
    }
}

/// SSH 줄들을 둥근 상자 하나에 구분선으로 잇는다
struct SSHList<Row: View>: View {
    let computers: [Computer]
    @ViewBuilder let row: (Computer) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(computers.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider().padding(.leading, 54) }
                row(c)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// 묶음을 접었는지 기억하는 키
enum ComputerGroupKeys {
    static let screens = "home.group.screens.expanded"
    static let ssh = "home.group.ssh.expanded"
}

extension Computer {
    /// 검색: 이름·주소·계정에 낱말이 모두 들어 있으면 (대소문자 무시, 띄어 쓴 낱말마다)
    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = [name, host, username].joined(separator: " ")
        return words.allSatisfy { hay.localizedCaseInsensitiveContains($0) }
    }
}
