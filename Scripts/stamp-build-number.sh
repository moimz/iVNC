#!/bin/sh
# 빌드 번호 = git 커밋 수, 커밋 해시를 Info.plist 에 넣는다 (설정 아래에 "버전 0.1 (235, fa0e978)" 로 보인다).
# 커밋하지 않은 변경이 있으면 해시 뒤에 "+" 를 붙인다.
# Info.plist 처리가 끝난 뒤에 돌도록 그 파일을 입력으로 둔다 (아니면 처리하면서 덮어쓴다)
cd "$SRCROOT" || exit 0
count=$(git rev-list --count HEAD 2>/dev/null) || exit 0
hash=$(git rev-parse --short HEAD 2>/dev/null)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then hash="$hash+"; fi
plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $count" "$plist"
/usr/libexec/PlistBuddy -c "Delete :iVNCCommit" "$plist" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :iVNCCommit string $hash" "$plist"
# 2.0b 처럼 이름이 b 로 끝나는 브랜치(다음 버전 시험판)는 설정에 "2.0b" 로 보이게 표시만 남긴다 (inPlayer 와 같은 방식)
/usr/libexec/PlistBuddy -c "Delete :iVNCBeta" "$plist" >/dev/null 2>&1
case "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" in
    *b) /usr/libexec/PlistBuddy -c "Add :iVNCBeta bool true" "$plist" ;;
esac
