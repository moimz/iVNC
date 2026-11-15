#!/bin/bash
# OpenSSL 3.5.9 정적 라이브러리: 맥 arm64, iOS arm64, iOS 시뮬레이터 arm64 (배포 대상 26.0)
set -e
R=/Users/Arzz/Projects/Ai/iVNC/rdp-build
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
build() { # 이름 Configure대상 추가플래그
  local name=$1 target=$2 flags=$3
  rm -rf $R/build/openssl-$name; mkdir -p $R/build
  cp -R $R/src/openssl-3.5.9 $R/build/openssl-$name
  cd $R/build/openssl-$name
  ./Configure $target no-shared no-tests no-apps no-docs no-module no-legacy --prefix=$R/out/openssl/$name $flags > configure.log 2>&1
  make -j12 build_libs > make.log 2>&1
  make install_dev > install.log 2>&1
  echo "openssl $name 끝"
}
build macos darwin64-arm64-cc "-mmacosx-version-min=26.0" &
build ios ios64-xcrun "-mios-version-min=26.0" &
build sim iossimulator-arm64-xcrun "-mios-simulator-version-min=26.0" &
wait
ls $R/out/openssl/*/lib
