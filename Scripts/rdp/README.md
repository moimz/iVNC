# FreeRDP 빌드 (윈도우 RDP 접속용)

`Vendor/FreeRDP.xcframework` 는 git 에 넣지 않는다. 이 스크립트들로 다시 만든다.

- 소스: OpenSSL 3.5.9 (LTS), FreeRDP 3.33.1 — 공식 GitHub 릴리스, sha256 확인
- 도구: CMake 4.5.0 (공식 tar 를 작업 폴더에만 풀어 씀)
- 작업 폴더: `Ai/iVNC/rdp-build/` (dl, src, tools, build, out, pack)

순서:
1. `build-openssl.sh` — 맥 arm64 / iOS arm64 / iOS 시뮬레이터 arm64, 정적, 배포 대상 26.0
2. `build-freerdp.sh macos|ios|sim` — 정적, 클라이언트 공통 + 채널, VideoToolbox H.264, LTO 끔(비트코드면 xcframework 로 못 묶음)
3. `pack-xcframework.sh` — 플랫폼마다 합쳐 `Vendor/FreeRDP.xcframework`

라이선스: FreeRDP·OpenSSL 모두 Apache 2.0 (앱에 고지할 것).
