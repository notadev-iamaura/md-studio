// 데스크톱 앱(Electron) 검증: 실제 앱을 실행해 맥 기능 연결 부분(파일, 폴더, 클립보드, PDF, 메뉴, 재시작)을 확인한다.
// 맥과 리눅스에서 실행한다(리눅스는 test/run-app-e2e.mjs가 가상 화면 xvfb로 감싼다).
// 맥의 선택 창(dialog)만 정해진 경로를 돌려주도록 바꿔 둔다.
import { createRequire } from 'node:module';
import { mkdtemp, writeFile, readFile, mkdir, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

const require = createRequire(import.meta.url);
const { _electron: electron } = require('playwright');
// electron 패키지는 운영체제에 맞는 실행 파일 경로를 돌려준다(맥: Electron.app/Contents/MacOS/Electron).
// 실행 파일이 아직 없으면 이 시점에 내려받는다.
const ELECTRON_PATH = require('electron');
const ROOT = path.resolve('.');
const SHOTS = path.resolve('test/screenshots');
await mkdir(SHOTS, { recursive: true });

const work = await mkdtemp(path.join(os.tmpdir(), 'mdstudio-app-'));
const userData = path.join(work, 'userData');
const folder = path.join(work, '내 문서');
const exportDir = path.join(work, '내보내기');
await mkdir(folder, { recursive: true });
await mkdir(exportDir, { recursive: true });
await writeFile(path.join(folder, '기존 메모.md'), '# 기존 메모\n\n디스크에 있던 파일');
await mkdir(path.join(folder, '하위'), { recursive: true });
await writeFile(path.join(folder, '하위', '깊은 파일.md'), '# 깊은 파일');
await writeFile(path.join(work, '바깥 파일.md'), '# 폴더 밖 파일');

let passed = 0;
const failures = [];
async function step(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    passed++;
    console.log(`  ok  ${name} (${Date.now() - t0}ms)`);
  } catch (e) {
    failures.push(name);
    console.log(`  FAIL ${name}\n       ${String(e.message).split('\n').slice(0, 6).join('\n       ')}`);
  }
}
const assert = (c, m) => {
  if (!c) throw new Error(m);
};

let app;
let page;
const pageErrors = [];
async function launch() {
  app = await electron.launch({
    executablePath: ELECTRON_PATH,
    args: [ROOT, '--no-sandbox', `--user-data-dir=${userData}`],
    env: { ...process.env, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' },
  });
  page = await app.firstWindow();
  page.on('pageerror', (e) => pageErrors.push(String(e)));
  // 저장 안 한 내용이 있을 때의 확인은 앱(메인 프로세스)이 맥 기본 창으로 처리한다.
  // 리스너를 달아 두지 않으면 Playwright가 이를 웹 확인 창으로 보고 대신 처리하려다 오류가 난다.
  page.on('dialog', () => {});
  page.on('console', (m) => m.type() === 'error' && pageErrors.push(m.text()));
  await page.waitForSelector('.cm-content');
  // 선택 창 대신 정해진 경로를 돌려준다
  await app.evaluate(({ dialog }, { folder, exportDir }) => {
    globalThis.__dialogCalls = [];
    dialog.showOpenDialog = async (_w, opts) => {
      globalThis.__dialogCalls.push(['open', opts.properties]);
      return { canceled: false, filePaths: [opts.properties.includes('openDirectory') ? folder : globalThis.__openFile] };
    };
    dialog.showSaveDialog = async (_w, opts) => {
      globalThis.__dialogCalls.push(['save', path_basename(opts.defaultPath)]);
      return { canceled: false, filePath: `${exportDir}/${path_basename(opts.defaultPath)}` };
    };
    dialog.showMessageBoxSync = () => globalThis.__closeChoice ?? 1;
    function path_basename(p) {
      return p.split('/').pop();
    }
  }, { folder, exportDir });
}
// macOS 클립보드 읽기 (Electron 44의 ClipboardItem 방식)
const readClipboard = () =>
  app.evaluate(async ({ clipboard }) => {
    const [item] = await clipboard.read();
    const get = async (t) => (item && item.types.includes(t) ? (await item.getType(t)).text() : '');
    return { html: await get('text/html'), text: await get('text/plain') };
  });
const editorText = () => page.evaluate(() => document.querySelector('.cm-content').cmView.view.state.doc.toString());
const setEditor = (t) =>
  page.evaluate((t) => {
    const v = document.querySelector('.cm-content').cmView.view;
    v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: t } });
  }, t);
async function waitToast(text) {
  await page.waitForFunction((t) => [...document.querySelectorAll('.toast')].some((e) => e.textContent.includes(t)), text, { timeout: 5000 });
}
async function clickMenu(label) {
  await app.evaluate(({ Menu }, label) => {
    const find = (items) => {
      for (const it of items) {
        if (it.label === label) return it;
        const sub = it.submenu && find(it.submenu.items);
        if (sub) return sub;
      }
      return null;
    };
    const item = find(Menu.getApplicationMenu().items);
    if (!item) throw new Error(`메뉴 없음: ${label}`);
    item.click();
  }, label);
}

console.log('MD Studio 데스크톱 앱 E2E');

await step('앱 실행: 창이 뜨고 맥 기능 연결(mdNative)과 메뉴 막대가 준비된다', async () => {
  await launch();
  assert(await page.evaluate(() => !!window.mdNative && document.documentElement.classList.contains('native')), '앱 모드가 아님');
  assert(await page.evaluate(() => typeof require === 'undefined' && typeof process === 'undefined'), '화면에 Node 기능이 노출됨');
  const labels = await app.evaluate(({ Menu }) => Menu.getApplicationMenu().items.map((i) => i.label));
  assert(['파일', '편집', '보기'].every((l) => labels.includes(l)), `메뉴 이상: ${labels}`);
  assert((await page.title()).includes('MD Studio'), '창 제목 이상');
});

await step('폴더 열기: 한글 이름 폴더의 파일 목록(하위 폴더 포함)이 보인다', async () => {
  await page.click('.sidebar-empty [data-action="openFolder"]');
  await page.waitForSelector('#file-list li .fname');
  const names = await page.$$eval('#file-list li', (lis) => lis.map((l) => l.textContent));
  assert(names.some((n) => n.includes('기존 메모')) && names.some((n) => n.includes('깊은 파일') && n.includes('하위')), `목록 이상: ${names}`);
  assert((await page.textContent('#st-storage')).includes('내 문서'), '상태 표시줄에 폴더 경로 없음');
});

await step('새 문서 저장(⌘S): 실제 디스크에 한글 파일 이름으로 기록된다', async () => {
  await page.click('[data-action="new"]');
  await setEditor('# 앱에서 쓴 글\n\n| 항목 | 값 |\n|---|---|\n| 상태 | 좋음 |');
  await page.click('.cm-content');
  await page.keyboard.press('Control+s');
  await page.waitForSelector('#dlg-name[open]');
  assert((await page.inputValue('#name-input')) === '앱에서 쓴 글.md', '이름 제안 이상');
  await page.keyboard.press('Enter');
  await waitToast('저장했습니다');
  const disk = await readFile(path.join(folder, '앱에서 쓴 글.md'), 'utf8');
  assert(disk.startsWith('# 앱에서 쓴 글'), `디스크 내용 이상: ${disk}`);
});

await step('자동 저장과 안전한 쓰기(임시 파일이 남지 않음)', async () => {
  await page.click('.cm-content');
  await page.keyboard.press('Control+End');
  await page.keyboard.type('\n\n자동 저장된 줄');
  await page.waitForFunction(() => document.querySelector('#st-save').textContent.startsWith('저장됨'), null, { timeout: 5000 });
  const disk = await readFile(path.join(folder, '앱에서 쓴 글.md'), 'utf8');
  assert(disk.endsWith('자동 저장된 줄'), '자동 저장 미반영');
  const leftovers = (await import('node:fs')).readdirSync(folder).filter((f) => f.includes('mdstudio-tmp'));
  assert(!leftovers.length, `임시 파일이 남음: ${leftovers}`);
});

await step('다른 앱이 디스크의 파일을 고치면 창으로 돌아올 때 다시 불러온다', async () => {
  await new Promise((r) => setTimeout(r, 20));
  await writeFile(path.join(folder, '앱에서 쓴 글.md'), '# 앱에서 쓴 글\n\n다른 앱에서 고침');
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.waitForFunction(() => document.querySelector('.cm-content').cmView.view.state.doc.toString().includes('다른 앱에서 고침'), null, { timeout: 4000 });
});

await step('Slack 복사: macOS 클립보드에 HTML(표→목록)과 텍스트가 함께 들어간다', async () => {
  await setEditor('# 보고\n\n| 채널 | 방문 | 전환 |\n|---|---|---|\n| 검색 | 10 | 3% |');
  await page.click('[data-action="copySlack"]');
  await waitToast('Slack용');
  const clip = await readClipboard();
  assert(/<li><b>검색<\/b><ul><li>방문: 10<\/li>/.test(clip.html), `HTML 이상: ${clip.html}`);
  assert(clip.text.includes('• 검색\n   ◦ 방문: 10'), `텍스트 이상: ${clip.text}`);
});

await step('메뉴 막대: Edit > Slack용으로 복사, 보기 > 편집만', async () => {
  await app.evaluate(({ clipboard }) => clipboard.writeText('비움'));
  await page.evaluate(() => document.querySelectorAll('.toast').forEach((t) => t.remove()));
  await clickMenu('Slack용으로 복사');
  await waitToast('Slack용');
  assert((await readClipboard()).html.includes('<b>검색</b>'), '메뉴 복사 실패');
  await clickMenu('편집만');
  await page.waitForFunction(() => document.querySelector('#app').dataset.view === 'edit');
  await clickMenu('편집 + 미리보기');
});

await step('PDF로 내보내기: 인쇄 창 없이 PDF 파일이 바로 만들어진다', async () => {
  await setEditor('# 분기 보고서\n\n## 개요\n내용\n\n## 표\n| a | b |\n|---|---|\n| 1 | 2 |\n\n## 끝\n감사합니다');
  await clickMenu('PDF로 내보내기…');
  await page.waitForSelector('#dlg-export[open]');
  assert((await page.textContent('#export-ok')) === '저장', 'PDF 버튼 문구 이상');
  await page.click('#export-ok');
  await waitToast('분기 보고서.pdf');
  const pdf = await readFile(path.join(exportDir, '분기 보고서.pdf'));
  assert(pdf.subarray(0, 5).toString() === '%PDF-' && pdf.length > 5000, `PDF 이상 (${pdf.length} bytes)`);
});

await step('HTML 보고서 저장', async () => {
  await clickMenu('HTML 보고서로 내보내기…');
  await page.waitForSelector('#dlg-export[open]');
  await page.click('#export-ok');
  await waitToast('분기 보고서.html');
  const html = await readFile(path.join(exportDir, '분기 보고서.html'), 'utf8');
  assert(html.includes('<nav class="toc">'), '보고서 목차 없음');
});

await step('Finder에서 .md 파일 열기(open-file 이벤트)', async () => {
  await setEditor('');
  const target = path.join(folder, '하위', '깊은 파일.md');
  await app.evaluate(({ app }, p) => app.emit('open-file', { preventDefault() {} }, p), target);
  await page.waitForFunction(() => document.querySelector('.cm-content').cmView.view.state.doc.toString() === '# 깊은 파일', null, { timeout: 4000 });
  assert((await page.textContent('#file-name')) === '하위/깊은 파일.md', '폴더 안 파일로 인식되지 않음');
});

await step('보안: 사용자가 고르지 않은 경로는 읽고 쓸 수 없다', async () => {
  const r = await page.evaluate(async (outside) => {
    const out = [];
    for (const fn of [() => window.mdNative.read('/etc/passwd'), () => window.mdNative.read(outside), () => window.mdNative.write('/tmp/evil.md', 'x'), () => window.mdNative.read('relative/path')]) {
      try {
        await fn();
        out.push('허용됨');
      } catch {
        out.push('차단');
      }
    }
    return out;
  }, path.join(work, '바깥 파일.md'));
  assert(r.every((x) => x === '차단'), `차단 결과: ${r}`);
});

await step('저장 안 한 내용이 있을 때 창을 닫으면 확인하고, "취소"면 닫히지 않는다', async () => {
  await page.click('[data-action="new"]');
  await page.click('.cm-content');
  await page.keyboard.type('닫기 전에 쓴 글');
  await page.waitForTimeout(900);
  await app.evaluate(({ BrowserWindow }) => {
    globalThis.__closeChoice = 1;
    BrowserWindow.getAllWindows()[0].close();
  });
  await page.waitForTimeout(600);
  assert(await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length === 1), '취소했는데 창이 닫힘');
  await page.screenshot({ path: `${SHOTS}/app-01-running.png` });
});

await step('"저장하지 않고 닫기" 후 다시 실행하면: 지난 폴더가 자동으로 열리고 쓰던 글이 복구된다', async () => {
  await app.evaluate(({ BrowserWindow }) => {
    globalThis.__closeChoice = 0;
    BrowserWindow.getAllWindows()[0].close();
  });
  await app.waitForEvent('close', { timeout: 10000 }).catch(() => {});
  await launch();
  await page.waitForFunction(() => document.querySelector('.cm-content').cmView.view.state.doc.toString() === '닫기 전에 쓴 글', null, { timeout: 5000 });
  await page.waitForFunction(() => document.querySelector('#folder-name').textContent === '내 문서', null, { timeout: 5000 });
  await page.screenshot({ path: `${SHOTS}/app-02-restarted.png` });
});

await step('화면 오류가 없다', async () => {
  assert(!pageErrors.length, pageErrors.join('\n'));
});

const mainLog = await readFile(path.join(userData, 'logs', 'main.log'), 'utf8').catch(() => '');
console.log(`\n${passed} passed, ${failures.length} failed  (메인 로그 ${mainLog.split('\n').filter(Boolean).length}줄)`);
// 마지막 상태는 복구된 미저장 글이 있어 앱이 닫기 확인을 한다 → "저장하지 않고 닫기"로 답한다.
await app.evaluate(() => (globalThis.__closeChoice = 0)).catch(() => {});
await Promise.race([app.close().catch(() => {}), new Promise((r) => setTimeout(r, 10000))]);
await rm(work, { recursive: true, force: true });
process.exit(failures.length ? 1 : 0);
