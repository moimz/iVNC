#!/bin/bash
# FreeRDP 3.33.1 정적 라이브러리 (클라이언트 공통 + 채널, VideoToolbox H.264): 맥 arm64 / iOS arm64 / iOS 시뮬레이터 arm64
# 사용: build-freerdp.sh macos|ios|sim
# MD4·RC4 는 FreeRDP 자체 구현 (OpenSSL 3 은 legacy 프로바이더에 있어 정적 빌드에선 못 씀 → NTLM·NLA 로그인 실패)
set -e
R=/Users/Arzz/Projects/Ai/iVNC/rdp-build
CMAKE=$R/tools/cmake-4.5.0-macos-universal/CMake.app/Contents/bin/cmake
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
name=$1
case $name in
  macos) plat=(-DCMAKE_OSX_SYSROOT=macosx) ;;
  ios) plat=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos) ;;
  sim) plat=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator) ;;
esac
B=$R/build/freerdp-$name
rm -rf $B; mkdir -p $B; cd $B
$CMAKE $R/src/freerdp-3.33.1 -G "Unix Makefiles" "${plat[@]}" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_INSTALL_PREFIX=$R/out/freerdp/$name \
  -DOPENSSL_ROOT_DIR=$R/out/openssl/$name -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_INCLUDE_DIR=$R/out/openssl/$name/include -DOPENSSL_CRYPTO_LIBRARY=$R/out/openssl/$name/lib/libcrypto.a \
  -DOPENSSL_SSL_LIBRARY=$R/out/openssl/$name/lib/libssl.a -DCMAKE_FIND_ROOT_PATH=$R/out/openssl/$name \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DWITH_SAMPLE=OFF -DWITH_SERVER=OFF -DWITH_CLIENT=OFF \
  -DWITH_CLIENT_COMMON=ON -DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON -DWITH_CLIENT_SDL=OFF \
  -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_CAIRO=OFF -DWITH_JPEG=OFF \
  -DWITH_OPENH264=OFF -DWITH_APPLE_VIDEOTOOLBOX=ON -DWITH_MANPAGES=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF \
  -DWITH_SMARTCARD_EMULATE=OFF -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_AAD=OFF -DWITH_JSON_DISABLED=ON \
  -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_MACAUDIO=OFF -DWITH_AAUDIO=OFF -DWITH_OPENSLES=OFF \
  -DWITH_SNDIO=OFF -DWITH_URIPARSER=OFF -DWITH_WEBVIEW=OFF -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF \
  -DWITH_WINPR_TOOLS=OFF -DWITH_FREERDP_DEPRECATED=OFF -DWITH_INTERNAL_RC4=ON -DWITH_INTERNAL_MD4=ON -DWITH_VERBOSE_WINPR_ASSERT=OFF -DCHANNEL_URBDRC=OFF -DWITH_LIBRARY_VERSIONING=OFF \
  > configure.log 2>&1 || { echo "configure 실패 $name"; tail -30 configure.log; exit 1; }
make -j12 > make.log 2>&1 || { echo "make 실패 $name"; grep -E 'error' make.log | head -20; exit 1; }
make install > install.log 2>&1
echo "freerdp $name 끝"; ls $R/out/freerdp/$name/lib | head -30
