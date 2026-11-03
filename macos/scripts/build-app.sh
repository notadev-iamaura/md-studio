#!/bin/bash
# MD Studio 맥 앱(Swift) 만들기: 빌드 → .app 묶기 → 자체 서명 → 서명 확인 → zip
# 사용: bash macos/scripts/build-app.sh            (결과: macos/build/MD Studio.app, macos/build/MD-Studio-<버전>-mac.zip)
#       bash macos/scripts/build-app.sh --selftest (만든 뒤 자가 점검까지 실행, 결과: macos/build/selftest/)
#       bash macos/scripts/build-app.sh --slim     (이 맥의 칩 전용 + 디버그 이름표 제거로 앱 크기를 줄임.
#                                                   다른 종류의 칩을 쓰는 맥에서는 실행되지 않음)
#       두 옵션은 함께 쓸 수 있다: --slim --selftest
set -euo pipefail

SLIM=0
SELFTEST=0
for arg in "$@"; do
  case "$arg" in
    --slim) SLIM=1 ;;
    --selftest) SELFTEST=1 ;;
    *) echo "[build-app] 알 수 없는 옵션: $arg (쓸 수 있는 옵션: --slim, --selftest)" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/macos/MDStudio"
OUT="$ROOT/macos/build"
APP="$OUT/MD Studio.app"
VERSION="2.0.0"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

mkdir -p "$OUT"
cd "$PKG"
if [[ $SLIM == 1 ]]; then
  echo "[build-app] 1/5 릴리스 빌드 (이 맥의 칩 전용: $(uname -m))"
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/MDStudio"
else
  echo "[build-app] 1/5 릴리스 빌드 (Apple Silicon + Intel 공용)"
  if swift build -c release --arch arm64 --arch x86_64 >"$OUT.build.log" 2>&1; then
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MDStudio"
  else
    echo "[build-app] 공용 빌드 실패 → 이 맥의 칩 전용으로 빌드합니다 (자세한 내용: $OUT.build.log)"
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/MDStudio"
  fi
fi
rm -f "$OUT.build.log"

echo "[build-app] 2/5 앱 묶기"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MDStudio"
if [[ $SLIM == 1 ]]; then
  # 실행에 필요 없는 디버그용 이름표(로컬 심볼)만 지운다. 서명 전에 해야 서명이 깨지지 않는다.
  strip -x "$APP/Contents/MacOS/MDStudio"
fi
cp "$ROOT/mac/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MD Studio</string>
  <key>CFBundleDisplayName</key><string>MD Studio</string>
  <key>CFBundleIdentifier</key><string>local.mdstudio.native</string>
  <key>CFBundleExecutable</key><string>MDStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>로컬 마크다운 편집기</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown 문서</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>md</string><string>markdown</string></array>
      <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "[build-app] 3/5 자체 서명 (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "[build-app] 4/5 서명 확인"
codesign --verify --deep --strict "$APP"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/MDStudio")"
SIZE="$(du -sh "$APP" | cut -f1)"
echo "[build-app]   아키텍처: $ARCHS / 앱 크기: $SIZE"

echo "[build-app] 5/5 압축"
if [[ $SLIM == 1 ]]; then
  ZIP="$OUT/MD-Studio-$VERSION-mac-$(uname -m).zip"
else
  ZIP="$OUT/MD-Studio-$VERSION-mac.zip"
fi
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "[build-app] 완료: $APP"
echo "[build-app]       $ZIP"

if [[ $SELFTEST == 1 ]]; then
  echo "[build-app] 자가 점검 실행 (앱 창이 30초쯤 앞에 떴다가 닫힙니다)"
  rm -rf "$OUT/selftest"
  mkdir -p "$OUT/selftest"
  # Finder에서 연 것처럼 띄워야 창이 앞으로 나와 단축키·찾기까지 실제와 같게 점검된다.
  open -n -W --env "MDSTUDIO_SELFTEST=$OUT/selftest" "$APP"
  if [[ ! -f "$OUT/selftest/selftest.json" ]]; then
    echo "[build-app] 자가 점검 결과가 없습니다. 로그: $OUT/selftest/logs/app.log"
    exit 1
  fi
  /usr/bin/python3 - "$OUT/selftest/selftest.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
for s in r["steps"]:
    print(("  ok  " if s["ok"] else "  FAIL ") + s["name"] + (" — " + s["detail"] if s["detail"] else ""))
print(f'\n{r["passed"]} passed, {r["failed"]} failed')
print("측정값:", ", ".join(f"{k}={v}" for k, v in sorted(r["metrics"].items())))
sys.exit(0 if r["failed"] == 0 else 1)
PY
fi
