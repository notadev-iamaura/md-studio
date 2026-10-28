# MD Studio 작업 안내

## 현재 상태
- 동작하는 버전은 웹 화면(`src/`), Electron 맥 앱(`electron/`), Swift 맥 앱(`macos/`) 세 가지입니다. 지우거나 깨뜨리지 마세요.
- Swift 전환은 `docs/SWIFT_PLAN.md`의 1~4단계를 모두 구현했습니다. 진행 상황과 사용자가 직접 확인할 항목은 그 문서 맨 앞 "진행 상황"에 있습니다.
- Swift 앱 구조: `macos/MDCore`(변환 엔진·HTML·보고서·붙여넣기 변환, 화면 없음), `macos/MDStudio/Sources/MDStudioKit`(앱 기능 전체), `macos/MDStudio/Sources/MDStudio`(시작점)
- 사용자에게 묻는 창은 `Prompter`를 거칩니다. 새 기능을 넣으면 `SelfTest.swift`에 점검 단계를 함께 추가하세요.

## 사용자에 대해
- 한국어로, 개발 3개월 차 주니어도 이해할 수 있게 개념부터 쉽게 설명합니다.
- 사용자가 직접 해야 하는 일(Xcode 설치, 권한 허용, 실행 확인)은 단계별로 안내합니다.
- 문서에 불필요한 이모지를 쓰지 않고, 코드가 아닌 긴 글을 코드 블록에 넣지 않습니다.
- 로그를 적극적으로 남기되 문서 본문은 기록하지 않습니다.

## 명령
- `npm install`: 의존성 설치. 화면 테스트 전에 처음 한 번 `npx playwright install chromium-headless-shell`
  - npm이 설치 스크립트를 막아도 Electron 실행 파일은 `npm run app`이나 `npm run e2e:app`을 처음 실행할 때 자동으로 받아진다
- `npm test`: 변환 로직 테스트 / `npm run e2e`: 화면 테스트 / `npm run e2e:app`: Electron 앱 테스트(맥·리눅스 모두, `test/run-app-e2e.mjs`가 운영체제에 맞게 실행)
- `npm run app`: Electron 앱 실행 / `npm run package:app`: 맥 앱 패키징(서명·검증 포함)
- `node test/make-golden.mjs`: 변환 정답 데이터(`test/fixtures/golden.json`) 갱신. 변환 규칙을 바꿨을 때만 실행
- `cd macos/MDCore && swift test`: Swift 변환 엔진 정답 대조(21개 사례 × 8종). `MDCORE_GOLDEN=<경로>`를 주면 다른 정답 파일로 대조
- `cd macos/MDStudio && swift test`: Swift 앱 기능 단위 테스트. `MDSTUDIO_SNAPSHOT_DIR=<폴더>`를 주면 미리보기를 PNG로 저장(디자인 확인용)
- `bash macos/scripts/build-app.sh [--selftest]`: Swift 앱 만들기(공용 빌드·자체 서명·zip). `--selftest`는 실제 창으로 25개 흐름 자동 점검
- 메모리 측정: 앱을 연 뒤 `footprint <pid>` (목표: 문서 1개 기준 60MB 이하, 현재 45MB)

## 규칙
- 변환 규칙의 기준은 `src/convert.js`와 `test/fixtures/golden.json`입니다. Swift 결과가 다르면 정답을 고치지 말고 사용자에게 보고합니다.
- 기능이 실제로 되는지는 직접 실행하거나 붙여 보고 확인한 뒤에 "된다"고 말합니다. 확인하지 못한 부분은 그렇다고 밝힙니다.
