#!/bin/bash
# electron-builder가 만든 맥 앱에 자체 서명(ad-hoc)을 하고 배포용 zip으로 묶는다.
# 애플 실리콘 맥은 서명이 없거나 깨진 실행 파일을 실행하지 않으므로, 리눅스에서 빌드한 앱은 반드시 다시 서명해야 한다.
# 필요 도구: 맥은 기본 탑재된 codesign, 리눅스는 rcodesign (cargo install apple-codesign --version 0.29.0 --locked)
set -euo pipefail
cd "$(dirname "$0")/.."

RC="${RCODESIGN:-rcodesign}"
VERSION="$(node -p "require('./package.json').version")"
# 맥에서는 기본 탑재된 codesign을, 리눅스에서는 rcodesign을 쓴다.
if [ "$(uname)" = "Darwin" ] && ! command -v "$RC" >/dev/null; then
  sign() { codesign --force --deep --sign - "$1"; }
elif command -v "$RC" >/dev/null; then
  sign() { "$RC" sign "$1"; }
else
  echo "서명 도구 없음: 맥에서 실행하거나 rcodesign을 설치하세요 (cargo install apple-codesign --version 0.29.0 --locked)"
  exit 1
fi

for pair in "mac-arm64:apple-silicon" "mac:intel"; do
  DIR="release/${pair%%:*}"
  LABEL="${pair##*:}"
  APP="$DIR/MD Studio.app"
  [ -d "$APP" ] || { echo "건너뜀: $APP 없음"; continue; }
  # Electron 기본 예제 앱은 쓰지 않으므로 뺀다 (서명 전에 해야 서명이 깨지지 않는다)
  rm -f "$APP/Contents/Resources/default_app.asar"
  echo "서명: $APP"
  sign "$APP" > "release/sign-$LABEL.log" 2>&1 || { tail -20 "release/sign-$LABEL.log"; exit 1; }
  OUT="release/MD-Studio-${VERSION}-mac-${LABEL}.zip"
  rm -f "$OUT"
  # -y: 프레임워크 내부의 심볼릭 링크를 링크 그대로 보존 (풀면 앱이 손상되는 것을 막는다)
  (cd "$DIR" && zip -qry "../$(basename "$OUT")" "MD Studio.app")
  # 압축을 다시 풀어 서명이 그대로인지 검증한다 (링크 손실·파일 변형 감지)
  CHECK="$(mktemp -d)"
  unzip -q "$OUT" -d "$CHECK"
  python3 mac/verify-signature.py "$CHECK/MD Studio.app" > "release/verify-$LABEL.log" || { tail -20 "release/verify-$LABEL.log"; rm -rf "$CHECK"; exit 1; }
  rm -rf "$CHECK"
  echo "생성: $OUT ($(du -h "$OUT" | cut -f1)) — $(tail -1 "release/verify-$LABEL.log")"
done
