// 데스크톱 앱 E2E(test/app-e2e.mjs)를 운영체제에 맞게 실행한다.
// - 맥·윈도우: 화면이 있으므로 그대로 실행한다(테스트 중 앱 창이 잠깐 떴다 닫힌다).
// - 리눅스: 화면(DISPLAY)이 없으면 가상 화면 xvfb-run으로 감싸서 실행한다.
// 테스트의 종료 코드를 그대로 돌려줘서 실패하면 npm run e2e:app도 실패한다.
import { spawnSync } from 'node:child_process';
import path from 'node:path';

const testFile = path.resolve('test/app-e2e.mjs');
const needsXvfb = process.platform === 'linux' && !process.env.DISPLAY;
const [cmd, args] = needsXvfb ? ['xvfb-run', ['-a', process.execPath, testFile]] : [process.execPath, [testFile]];

console.log(`[run-app-e2e] ${process.platform}에서 실행${needsXvfb ? ' (xvfb 가상 화면)' : ''}`);
const result = spawnSync(cmd, args, { stdio: 'inherit' });
if (result.error) {
  // xvfb-run이 없는 리눅스 등 실행 자체가 실패한 경우
  console.error(`[run-app-e2e] 실행 실패: ${cmd} — ${result.error.message}`);
  if (needsXvfb) console.error('[run-app-e2e] 리눅스에서는 xvfb가 필요합니다. 예: sudo apt install xvfb');
  process.exit(1);
}
process.exit(result.status ?? 1);
