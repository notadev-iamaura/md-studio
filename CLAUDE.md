# MD Studio 작업 안내

## 현재 상태
- 동작하는 버전은 웹 화면(`src/`)과 Electron 맥 앱(`electron/`)입니다. 지우거나 깨뜨리지 마세요.
- 다음 작업은 메모리를 줄이기 위한 **Swift 순수 앱 전환**입니다. 시작 전에 `docs/SWIFT_PLAN.md`를 끝까지 읽고 그 단계와 완료 기준을 따르세요.
- Swift 버전은 `macos/` 폴더에 만듭니다.

## 사용자에 대해
- 한국어로, 개발 3개월 차 주니어도 이해할 수 있게 개념부터 쉽게 설명합니다.
- 사용자가 직접 해야 하는 일(Xcode 설치, 권한 허용, 실행 확인)은 단계별로 안내합니다.
- 문서에 불필요한 이모지를 쓰지 않고, 코드가 아닌 긴 글을 코드 블록에 넣지 않습니다.
- 로그를 적극적으로 남기되 문서 본문은 기록하지 않습니다.

## 명령
- `npm install`: 의존성 설치
- `npm test`: 변환 로직 테스트 / `npm run e2e`: 화면 테스트 / `npm run e2e:app`: Electron 앱 테스트
- `npm run app`: Electron 앱 실행 / `npm run package:app`: 맥 앱 패키징(서명·검증 포함)
- `node test/make-golden.mjs`: 변환 정답 데이터(`test/fixtures/golden.json`) 갱신. 변환 규칙을 바꿨을 때만 실행
- `cd macos/MDCore && swift test`: Swift 변환 엔진 정답 대조(21개 사례 × 8종). `MDCORE_GOLDEN=<경로>`를 주면 다른 정답 파일로 대조

## 규칙
- 변환 규칙의 기준은 `src/convert.js`와 `test/fixtures/golden.json`입니다. Swift 결과가 다르면 정답을 고치지 말고 사용자에게 보고합니다.
- 기능이 실제로 되는지는 직접 실행하거나 붙여 보고 확인한 뒤에 "된다"고 말합니다. 확인하지 못한 부분은 그렇다고 밝힙니다.
