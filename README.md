# iVNC

아이폰·아이패드·맥에서 **맥(화면 공유)**과 **윈도우(원격 데스크톱)**에 접속하고, **SSH 터미널과 파일 주고받기**까지 하는 원격 앱입니다.

*A remote access app for iPhone, iPad and Mac: macOS Screen Sharing (VNC/ARD, including High Performance mode), Windows Remote Desktop (RDP), and an SSH terminal with an SFTP file browser.*

![아이패드 SSH 터미널](docs/screenshots/ipad-terminal.png)

| 맥 | 아이패드 |
|---|---|
| ![맥 SSH 터미널](docs/screenshots/mac-terminal.png) | ![아이패드 화면 공유](docs/screenshots/ipad-screen.png) |
| ![맥 파인더](docs/screenshots/mac-finder.png) | ![아이패드 파인더](docs/screenshots/ipad-finder.png) |
| ![맥 컴퓨터 목록](docs/screenshots/mac-home.png) | ![아이패드 컴퓨터 목록](docs/screenshots/ipad-home.png) |

| 아이폰 | | | |
|---|---|---|---|
| ![컴퓨터 목록](docs/screenshots/iphone-home.png) | ![터미널](docs/screenshots/iphone-terminal.png) | ![열린 탭 · 서버 목록](docs/screenshots/iphone-menu.png) | ![파인더](docs/screenshots/iphone-finder.png) |

<sub>스크린샷의 서버·원격 화면은 시연용으로 만든 것입니다.</sub>

## 기능

**맥에 접속 (VNC / Apple Remote Desktop)**
- 맥 계정으로 로그인 (애플 인증, 키 입력은 암호화해서 보냄)
- 모니터 고르기, 모니터별 미리보기
- **고성능 모드**: 애플 화면 공유의 가상 디스플레이를 HEVC 영상(UDP/SRTP)으로 받음. 해상도를 기기에 맞출 수 있음
- 한글 입력: 이 기기의 한/영 상태에 맞춰 원격 입력 소스를 바꿈
- 원격 커서 모양, 클립보드 공유(글자·그림)

**윈도우에 접속 (RDP, FreeRDP)**
- NLA 로그인 (로컬 계정·Microsoft 계정·`도메인\사용자`)
- 그래픽 파이프라인 + H.264 (VideoToolbox 해독)
- 맥 단축키 그대로: ⌘C·⌘V → Ctrl+C·Ctrl+V, ⌘ 단독 → 윈도우 키, ⌘←/→ → Home/End, ⌘Q → Alt+F4
- 한/영 맞추기, 원격 커서 모양, 클립보드 공유(글자·그림)
- 처음 본 인증서는 기억하고, 바뀌면 묻기

**SSH 터미널 · 파인더**
- 탭으로 여러 서버를 함께 열기 (맥: 창·분할·탭 끌기, 아이패드: 사이드바 + 탭 줄, 아이폰: 옆 메뉴에 열린 탭 · 서버 목록)
- 비밀번호 또는 키 파일 인증, 경유 서버(배스천), 서버마다 색 표시, 문자 인코딩
- 한글 입력이 맥 기본 터미널처럼 자연스럽게, 특수 키 줄(⌃ ⌥ ⇥ 화살표 F1–F12)
- 파인더: 이 기기 ↔ 서버 두 칸, 끌어서 업로드 · 다운로드, 폴더째 옮기기, 이름 바꾸기 · 삭제
- 전송 내역(⇅): 한 번에 보낸 묶음과 파일마다 진행 막대, 남은 파일 수 배지
- 터미널에서 `sudo su` 로 바꾼 사용자 그대로 파일을 다룸 (맥)
- 맥: MCP 서버 — AI 에이전트가 허락 받은 범위에서 명령 실행 · 파일 읽기/쓰기

**공통**
- 아이폰·아이패드: 터치 모드와 트랙패드 모드, 화면 확대·이동, 특수 키 줄
- 맥: 키를 원격으로 바로 보내거나(⌨︎) 이 맥에서 조합해 보내기(가), 시스템 단축키(⌘Tab 등)를 원격으로 보내기
- 원격 화면 해상도 설정, 컴퓨터 목록 · SSH 설정 iCloud 동기화(글자 크기는 기기마다), 암호와 SSH 키는 iCloud 키체인
- 서버 지문은 기기마다 따로 확인

## 요구 사항

- iOS / iPadOS 26 이상, macOS 26 이상 (맥 앱은 Apple 실리콘 전용)
- 맥 쪽: 시스템 설정 > 일반 > 공유 > 화면 공유 켜기 (고성능 모드는 macOS 14 이상의 Apple 실리콘 맥)
- 윈도우 쪽: 설정 > 시스템 > 원격 데스크톱 켜기 (Windows Pro 이상)

## 빌드

Xcode 26 이상. 대상은 `iVNC`(아이폰·아이패드)와 `iVNCMac`(맥) 두 개이고 `iVNC` 폴더를 함께 씁니다.

윈도우 접속에 쓰는 FreeRDP 는 저장소에 넣지 않았습니다. 먼저 정적 라이브러리를 빌드해 `Vendor/FreeRDP.xcframework` 를 만들어야 합니다.

```bash
Scripts/rdp/build-openssl.sh
Scripts/rdp/build-freerdp.sh macos
Scripts/rdp/build-freerdp.sh ios
Scripts/rdp/build-freerdp.sh sim
Scripts/rdp/pack-xcframework.sh
```

스크립트 맨 위의 작업 폴더 경로(`R=`)와 소스 위치는 자기 환경에 맞게 고쳐 쓰세요. 자세한 내용은 [Scripts/rdp/README.md](Scripts/rdp/README.md) 에 있습니다. 서명은 Xcode 자동 서명을 쓰며 팀 ID 는 자기 것으로 바꿔야 합니다.

## 라이선스

[MIT](LICENSE). 단, [noVNC-ARD](https://github.com/peetinc/noVNC-ARD) 에서 옮긴 아래 파일은 [MPL 2.0](https://mozilla.org/MPL/2.0/) 입니다.

- `iVNC/RFB/ArdCursor.swift`, `HPVideo.swift`, `HighPerformance.swift`, `MVSDecoder.swift`, `SRTP.swift`

앱에 넣는 외부 라이브러리:

| 라이브러리 | 라이선스 |
|---|---|
| [FreeRDP](https://github.com/FreeRDP/FreeRDP) 3.33.1 | Apache 2.0 |
| [OpenSSL](https://github.com/openssl/openssl) 3.5.9 | Apache 2.0 |
| [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) · [SwiftNIO](https://github.com/apple/swift-nio) | Apache 2.0 |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) (맥 자동 업데이트) | MIT |

고지 전문은 [iVNC/App/OpenSourceLicenses.txt](iVNC/App/OpenSourceLicenses.txt) (앱 설정 > 오픈 소스 라이선스) 에 있습니다.

애플 화면 공유의 고성능 모드·MVS 인코딩·커서 처리는 공개 문서가 없는 기능으로, noVNC-ARD 의 리버스 엔지니어링 구현을 바탕으로 했습니다. Apple, macOS, Windows 는 각 회사의 상표입니다.
