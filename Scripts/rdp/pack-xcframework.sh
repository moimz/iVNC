#!/bin/bash
# 플랫폼마다 FreeRDP·WinPR·OpenSSL 정적 라이브러리를 하나로 합치고 헤더와 함께 iVNC/Vendor/FreeRDP.xcframework 로
set -e
R=/Users/Arzz/Projects/Ai/iVNC/rdp-build
V=/Users/Arzz/Projects/iVNC/Vendor
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
P=$R/pack; rm -rf $P; mkdir -p $P
args=()
for n in macos ios sim; do
  mkdir -p $P/$n/include
  # 채널 공용 조각(remdesk-common 등)은 설치되지 않아 빌드 폴더에서 같이 넣는다
  common=($(find $R/build/freerdp-$n/channels -name '*-common.a'))
  libtool -static -o $P/$n/libFreeRDP.a $R/out/freerdp/$n/lib/libfreerdp-client.a $R/out/freerdp/$n/lib/libfreerdp.a "${common[@]}" \
    $R/out/freerdp/$n/lib/libwinpr.a $R/out/openssl/$n/lib/libssl.a $R/out/openssl/$n/lib/libcrypto.a 2>&1 | grep -v 'has no symbols' || true
  cp -R $R/out/freerdp/$n/include/freerdp3/freerdp $R/out/freerdp/$n/include/winpr3/winpr $R/out/openssl/$n/include/openssl $P/$n/include/
  args+=(-library $P/$n/libFreeRDP.a -headers $P/$n/include)
done
mkdir -p $V; rm -rf $V/FreeRDP.xcframework
xcodebuild -create-xcframework "${args[@]}" -output $V/FreeRDP.xcframework
