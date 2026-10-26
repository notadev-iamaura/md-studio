// 실제 브라우저에서 dist/MD-Studio.html을 열어 주요 흐름을 검증한다.
// 폴더 선택 창은 자동화할 수 없으므로 브라우저 내부 저장소(OPFS)를 "사용자가 고른 폴더"로 대신 넘긴다.
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import path from 'node:path';

// 환경에 미리 설치된 Playwright를 쓴다 (ESM은 NODE_PATH를 보지 않으므로 require로 불러온다)
const { chromium } = createRequire(import.meta.url)('playwright');
const DIST = path.resolve('dist/MD-Studio.html');
const SHOTS = path.resolve('test/screenshots');
await mkdir(SHOTS, { recursive: true });

let passed = 0;
const failures = [];
async function step(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    passed++;
    console.log(`  ok  ${name} (${Date.now() - t0}ms)`);
  } catch (e) {
    failures.push({ name, e });
    console.log(`  FAIL ${name}\n       ${e.message.split('\n').join('\n       ')}`);
  }
}
function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

// OPFS는 보안 컨텍스트가 필요해 localhost로 서빙한다. (file:// 실행은 별도로 확인)
const html = await readFile(DIST);
const server = createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(html);
}).listen(0);
const URL_HTTP = `http://localhost:${server.address().port}/`;

// 컨테이너 기본 로케일(C)에서는 Chromium이 한글 파일 이름을 변환하지 못하므로 UTF-8로 띄운다. (macOS는 기본이 UTF-8)
const browser = await chromium.launch({ env: { ...process.env, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' } });
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'ko-KR' });
await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: URL_HTTP.slice(0, -1) });
const consoleErrors = [];
function watchPage(p) {
  p.on('console', (m) => m.type() === 'error' && consoleErrors.push(m.text()));
  p.on('pageerror', (e) => consoleErrors.push(String(e)));
  p.on('crash', () => consoleErrors.push('페이지 충돌(crash)'));
  return p;
}
// 복구 테스트에서 탭을 닫고 새 탭을 열기 때문에 let으로 둔다.
let page = watchPage(await context.newPage());

// 폴더/저장 선택 창을 OPFS로 대체하고, 알림(toast) 개수를 세어 비동기 동작 완료를 기다릴 수 있게 한다.
await context.addInitScript(() => {
  window.__toasts = [];
  new MutationObserver((muts) => {
    for (const m of muts) for (const n of m.addedNodes) if (n.classList?.contains('toast')) window.__toasts.push(n.textContent);
  }).observe(document, { childList: true, subtree: true });
  window.showDirectoryPicker = async () => {
    const root = await navigator.storage.getDirectory();
    return root.getDirectoryHandle('내문서', { create: true });
  };
  window.showSaveFilePicker = async ({ suggestedName }) => {
    const root = await navigator.storage.getDirectory();
    const dir = await root.getDirectoryHandle('내보내기', { create: true });
    return dir.getFileHandle(suggestedName, { create: true });
  };
});

const editorText = () => page.evaluate(() => document.querySelector('.cm-content').cmView.view.state.doc.toString());
async function setEditor(text) {
  await page.evaluate((t) => {
    const view = document.querySelector('.cm-content').cmView.view;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: t } });
  }, text);
}
// 버튼을 누르고 그 동작의 알림이 뜰 때까지 기다린다.
async function clickAndWaitToast(selector) {
  const before = await page.evaluate(() => window.__toasts.length);
  await page.click(selector);
  await page.waitForFunction((n) => window.__toasts.length > n, before);
  return page.evaluate(() => window.__toasts.at(-1));
}
async function readClipboard() {
  return page.evaluate(async () => {
    const items = await navigator.clipboard.read();
    const out = {};
    for (const it of items) for (const type of it.types) out[type] = await (await it.getType(type)).text();
    return out;
  });
}
async function opfsRead(dir, name) {
  return page.evaluate(
    async ([d, n]) => {
      const root = await navigator.storage.getDirectory();
      const f = await (await (await root.getDirectoryHandle(d)).getFileHandle(n)).getFile();
      return f.text();
    },
    [dir, name],
  );
}
async function opfsWrite(dir, name, text) {
  return page.evaluate(
    async ([d, n, t]) => {
      const root = await navigator.storage.getDirectory();
      const h = await (await root.getDirectoryHandle(d, { create: true })).getFileHandle(n, { create: true });
      const w = await h.createWritable();
      await w.write(t);
      await w.close();
    },
    [dir, name, text],
  );
}

const TABLE_MD = `# 주간 보고

이번 주 **핵심 성과**입니다. [링크](https://example.com)

| 채널 | 방문자 | 전환율 |
|---|---:|---|
| 검색 | 12,400 | 3.2% |
| 인스타 | 8,100 | |

- [x] 완료한 일
- [ ] 남은 일
  - 하위 항목
`;

console.log('MD Studio E2E');

await step('처음 실행: 오류 없이 열리고 예제 문서가 보인다', async () => {
  await page.goto(URL_HTTP);
  await page.waitForSelector('.cm-content');
  assert((await editorText()).startsWith('# MD Studio 사용 안내'), '예제 문서가 로드되지 않음');
  await page.waitForSelector('#preview-doc h1');
  assert((await page.textContent('#preview-doc h1')) === 'MD Studio 사용 안내', '미리보기 제목 불일치');
  assert((await page.locator('#preview-doc table').count()) === 1, '미리보기에 표가 없음');
  await page.screenshot({ path: `${SHOTS}/01-first-run.png` });
});

await step('편집하면 미리보기와 상태 표시줄이 갱신된다', async () => {
  await setEditor(TABLE_MD);
  await page.waitForFunction(() => document.querySelector('#preview-doc h1')?.textContent === '주간 보고');
  const st = await page.textContent('#st-stats');
  assert(/\d+자/.test(st), `글자 수 표시 이상: ${st}`);
  assert(!(await page.isHidden('#dirty-dot')), '변경 표시가 보여야 함');
});

await step('실제 키보드 입력과 한글 입력', async () => {
  await page.click('.cm-content');
  await page.keyboard.press('ControlOrMeta+End');
  await page.keyboard.press('Enter');
  await page.keyboard.type('- 키보드로 입력한 항목');
  await page.keyboard.press('Enter');
  await page.keyboard.type('다음 줄');
  const t = await editorText();
  assert(t.includes('- 키보드로 입력한 항목\n- 다음 줄'), `Enter로 목록이 이어지지 않음:\n${t.slice(-80)}`);
});

await step('서식 버튼: 굵게 / 제목 / 표 넣기 / 실행 취소', async () => {
  await setEditor('강조할 단어');
  await page.evaluate(() => {
    const v = document.querySelector('.cm-content').cmView.view;
    v.dispatch({ selection: { anchor: 0, head: 3 } });
  });
  await page.click('[data-cmd="bold"]');
  assert((await editorText()) === '**강조할** 단어', `굵게 실패: ${await editorText()}`);
  await page.click('[data-cmd="bold"]');
  assert((await editorText()) === '강조할 단어', `굵게 해제 실패: ${await editorText()}`);
  await page.click('[data-cmd="h2"]');
  assert((await editorText()) === '## 강조할 단어', `제목 실패: ${await editorText()}`);
  await page.click('[data-cmd="h2"]');
  assert((await editorText()) === '강조할 단어', `제목 해제 실패: ${await editorText()}`);
  await page.click('[data-cmd="table"]');
  assert((await editorText()).includes('| 항목 | 내용 | 비고 |'), '표 삽입 실패');
  await page.keyboard.press('ControlOrMeta+z');
  assert(!(await editorText()).includes('| 항목 |'), '실행 취소 실패');
});

await step('Slack 복사: 클립보드에 HTML(표→목록)과 텍스트가 함께 들어간다', async () => {
  await setEditor(TABLE_MD);
  await clickAndWaitToast('[data-action="copySlack"]');
  const clip = await readClipboard();
  assert(clip['text/html'] && clip['text/plain'], `두 형식이 모두 있어야 함: ${Object.keys(clip)}`);
  assert(!/<table/i.test(clip['text/html']), 'Slack HTML에 table이 남음');
  assert(/<li><b>검색<\/b><ul><li>방문자: 12,400<\/li>/.test(clip['text/html']), `표가 목록으로 안 풀림:\n${clip['text/html']}`);
  assert(clip['text/plain'].includes('• 인스타\n   ◦ 방문자: 8,100\n'), `텍스트 변환 이상:\n${clip['text/plain']}`);
  assert(!clip['text/plain'].includes('전환율: \n'), '빈 칸이 출력됨');
});

await step('서식 복사: 표와 인라인 스타일이 유지된다', async () => {
  await clickAndWaitToast('[data-action="copyRich"]');
  const clip = await readClipboard();
  assert(/<table[^>]*style="border-collapse/.test(clip['text/html']), '표/인라인 스타일 없음');
  assert(/☑/.test(clip['text/html']) && !/<input/.test(clip['text/html']), '체크박스가 문자로 바뀌지 않음');
});

await step('텍스트 / MD 복사, 선택 영역만 복사', async () => {
  await clickAndWaitToast('[data-action="copyPlain"]');
  let clip = await readClipboard();
  assert(!clip['text/html'] && clip['text/plain'].startsWith('■ 주간 보고'), `텍스트 복사 이상: ${JSON.stringify(clip).slice(0, 200)}`);
  await clickAndWaitToast('[data-action="copyMd"]');
  clip = await readClipboard();
  assert(clip['text/plain'] === TABLE_MD, 'MD 원문 불일치');
  await page.evaluate(() => {
    const v = document.querySelector('.cm-content').cmView.view;
    v.dispatch({ selection: { anchor: 0, head: 7 } });
  });
  await clickAndWaitToast('[data-action="copyPlain"]');
  clip = await readClipboard();
  assert(clip['text/plain'] === '■ 주간 보고\n', `선택 영역 복사 이상: ${JSON.stringify(clip['text/plain'])}`);
});

await step('미리보기 탭과 표 변환 방식 전환', async () => {
  await page.evaluate(() => document.querySelector('.cm-content').cmView.view.dispatch({ selection: { anchor: 0 } }));
  await page.click('[data-tab="slack"]');
  await page.waitForSelector('#slack-content li');
  await page.screenshot({ path: `${SHOTS}/02-slack-preview.png` });
  await page.click('[data-tab="plain"]');
  await page.selectOption('#table-mode', 'grid');
  const plain = await page.textContent('#preview-plain');
  assert(plain.includes('채널   │ 방문자 │ 전환율'), `고정폭 표 이상:\n${plain}`);
  await page.screenshot({ path: `${SHOTS}/03-plain-grid.png` });
  await page.selectOption('#table-mode', 'title');
  await page.click('[data-tab="doc"]');
});

await step('붙여넣기: 웹/Docs의 서식 있는 HTML은 마크다운으로, 마크다운 텍스트는 그대로', async () => {
  await setEditor('');
  await page.click('.cm-content');
  const pasted = await page.evaluate(() => {
    const dt = new DataTransfer();
    dt.setData('text/html', '<b id="docs-internal-guid-1" style="font-weight:normal"><h2>회의록</h2><p>오늘은 <span style="font-weight:700">중요</span>합니다.</p><ul><li>하나</li></ul><table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table></b>');
    dt.setData('text/plain', '회의록 오늘은 중요합니다.');
    document.querySelector('.cm-content').dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    return document.querySelector('.cm-content').cmView.view.state.doc.toString();
  });
  assert(pasted.includes('## 회의록') && pasted.includes('**중요**') && pasted.includes('-   하나') || pasted.includes('- 하나'), `HTML→MD 변환 이상:\n${pasted}`);
  assert(pasted.includes('| a | b |'), `표 변환 이상:\n${pasted}`);
  assert(!pasted.startsWith('**'), 'Google Docs 감싸기 태그가 굵게로 변환됨');

  await setEditor('');
  const kept = await page.evaluate(() => {
    const dt = new DataTransfer();
    dt.setData('text/html', '<p><strong>제목</strong></p>');
    dt.setData('text/plain', '## 제목\n\n- 이미 마크다운');
    document.querySelector('.cm-content').dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    return document.querySelector('.cm-content').cmView.view.state.doc.toString();
  });
  assert(kept === '## 제목\n\n- 이미 마크다운', `이미 마크다운인 텍스트는 원문 그대로 들어가야 함:\n${kept}`);
});

await step('폴더 열기 → 새 문서 저장(⌘S) → 파일 목록에 나타나고 실제 파일에 기록된다', async () => {
  await opfsWrite('내문서', '기존 메모.md', '# 기존 메모\n\n이미 있던 파일');
  await page.click('.sidebar-empty [data-action="openFolder"]');
  await page.waitForSelector('#file-list li .fname');
  assert((await page.textContent('#folder-name')) === '내문서', '폴더 이름 표시 이상');
  await setEditor('# 새 보고서\n\n본문입니다.');
  await page.click('.cm-content');
  await page.keyboard.press('ControlOrMeta+s');
  await page.waitForSelector('#dlg-name[open]');
  assert((await page.inputValue('#name-input')) === '새 보고서.md', '파일 이름 제안 이상');
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => [...document.querySelectorAll('#file-list .fname')].some((e) => e.textContent === '새 보고서'));
  assert((await opfsRead('내문서', '새 보고서.md')) === '# 새 보고서\n\n본문입니다.', '파일 내용 불일치');
  assert(await page.isHidden('#dirty-dot'), '저장 후에도 변경 표시가 남음');
  await page.screenshot({ path: `${SHOTS}/04-folder-saved.png` });
});

await step('자동 저장: 열린 파일을 고치면 잠시 뒤 파일에 기록된다', async () => {
  await page.click('.cm-content');
  await page.keyboard.press('ControlOrMeta+End');
  await page.keyboard.type('\n\n자동 저장 확인');
  await page.waitForFunction(() => document.querySelector('#st-save').textContent.startsWith('저장됨'), null, { timeout: 5000 });
  assert((await opfsRead('내문서', '새 보고서.md')).endsWith('자동 저장 확인'), '자동 저장이 파일에 반영되지 않음');
});

await step('다른 파일로 전환 / 다른 앱에서 바뀐 파일 다시 불러오기', async () => {
  await page.click('#file-list li:has-text("기존 메모")');
  await page.waitForFunction(() => document.querySelector('.cm-content').cmView.view.state.doc.toString().startsWith('# 기존 메모'));
  await page.waitForTimeout(30);
  await opfsWrite('내문서', '기존 메모.md', '# 기존 메모\n\n외부에서 수정함');
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.waitForFunction(() => document.querySelector('.cm-content').cmView.view.state.doc.toString().includes('외부에서 수정함'), null, { timeout: 3000 });
});

await step('자동 저장을 끄면 파일 전환 시 저장 여부를 묻는다', async () => {
  await page.evaluate(() => {
    const s = JSON.parse(localStorage.getItem('md-studio:settings'));
    s.autosave = false;
    localStorage.setItem('md-studio:settings', JSON.stringify(s));
  });
  await page.click('[data-action="settings"]');
  await page.uncheck('[data-setting="autosave"]');
  await page.click('#dlg-settings .dlg-actions button');
  await page.click('.cm-content');
  await page.keyboard.press('ControlOrMeta+End');
  await page.keyboard.type(' 미저장');
  await page.click('#file-list li:has-text("새 보고서")');
  await page.waitForSelector('#dlg-confirm[open]');
  await page.click('#dlg-confirm button[value="cancel"]');
  assert((await editorText()).endsWith(' 미저장'), '취소했는데 문서가 바뀜');
  await page.click('#file-list li:has-text("새 보고서")');
  await page.waitForSelector('#dlg-confirm[open]');
  await page.click('#dlg-confirm button[value="save"]');
  await page.waitForFunction(() => document.querySelector('.cm-content').cmView.view.state.doc.toString().startsWith('# 새 보고서'));
  assert((await opfsRead('내문서', '기존 메모.md')).endsWith(' 미저장'), '"저장" 선택이 파일에 반영되지 않음');
});

await step('HTML 보고서 내보내기', async () => {
  await setEditor('# 분기 보고서\n\n## 개요\n내용\n\n## 성과\n| a | b |\n|---|---|\n| 1 | 2 |\n\n## 다음 단계\n- 할 일');
  await page.click('#btn-export');
  await page.click('[data-action="exportHtml"]');
  await page.waitForSelector('#dlg-export[open]');
  assert((await page.inputValue('#export-name')) === '분기 보고서', '보고서 제목 기본값 이상');
  const msg = await clickAndWaitToast('#export-ok');
  assert(msg.includes('분기 보고서.html'), `내보내기 알림 이상: ${msg}`);
  const report = await opfsRead('내보내기', '분기 보고서.html');
  assert(report.startsWith('<!doctype html>') && report.includes('<nav class="toc">') && report.includes('class="table-wrap"'), '보고서 구조 이상');
  assert((report.match(/<h1/g) || []).length === 1, '제목이 중복됨');
  const rp = await context.newPage();
  await rp.setContent(report);
  await rp.screenshot({ path: `${SHOTS}/05-report.png`, fullPage: true });
  await rp.close();
});

await step('탭이 갑자기 닫혀도 저장하지 않은 새 문서가 다시 열면 복구된다', async () => {
  // 직전 단계에서 고친 내용이 있으므로(자동 저장 꺼짐) 확인 창이 떠야 한다.
  await page.click('[data-action="new"]');
  await page.waitForSelector('#dlg-confirm[open]');
  await page.click('#dlg-confirm button[value="discard"]');
  await page.waitForFunction(() => document.querySelector('.cm-content').cmView.view.state.doc.length === 0);
  await page.click('.cm-content');
  await page.keyboard.type('복구되어야 하는 글');
  await page.waitForTimeout(900); // 임시본 저장 간격(0.7초)보다 길게
  // 헤드리스 Chromium은 IndexedDB에서 OPFS 폴더 핸들을 꺼내는 순간 브라우저 전체가 종료되는 버그가 있다.
  // (앱 코드 없이도 재현됨. 실제 macOS Chrome의 진짜 폴더 핸들과는 무관)
  // 그래서 기억된 폴더 정보만 지우고 임시본 복구를 검증한다. 폴더 자동 재연결은 실제 Mac에서 확인해야 한다.
  await page.evaluate(
    () =>
      new Promise((resolve) => {
        const q = indexedDB.deleteDatabase('md-studio');
        q.onsuccess = q.onerror = q.onblocked = () => resolve();
      }),
  );
  // 확인 창 없이 강제로 닫는다 (브라우저 강제 종료와 같은 상황)
  await page.close({ runBeforeUnload: false });
  page = watchPage(await context.newPage());
  await page.goto(URL_HTTP);
  await page.waitForSelector('.cm-content');
  await page.waitForFunction(() => window.__toasts.some((t) => t.includes('복구')), null, { timeout: 3000 });
  const after = await editorText();
  assert(after === '복구되어야 하는 글', `복구 실패. 편집기 내용: ${JSON.stringify(after)}`);
  assert(!(await page.isHidden('#dirty-dot')), '복구한 내용은 저장 안 됨 상태로 보여야 함');
});

await step('다크 모드 화면', async () => {
  await page.emulateMedia({ colorScheme: 'dark' });
  await setEditor(TABLE_MD);
  await page.waitForTimeout(200);
  await page.screenshot({ path: `${SHOTS}/06-dark.png` });
  await page.emulateMedia({ colorScheme: 'light' });
});

await step('좁은 화면에서도 가로 스크롤 없이 표시된다', async () => {
  await page.setViewportSize({ width: 820, height: 900 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
  assert(!overflow, '가로 스크롤 발생');
  await page.screenshot({ path: `${SHOTS}/07-narrow.png` });
  await page.setViewportSize({ width: 1440, height: 900 });
});

await step('file:// 로 직접 열어도 동작한다 (실제 사용 방식)', async () => {
  const p2 = await browser.newPage();
  const errs = [];
  p2.on('pageerror', (e) => errs.push(String(e)));
  await p2.goto(`file://${DIST}`);
  await p2.waitForSelector('#preview-doc h1');
  const fs = await p2.evaluate(() => 'showDirectoryPicker' in window && window.isSecureContext);
  assert(fs, 'file:// 에서 폴더 저장 API를 쓸 수 없음');
  assert(!errs.length, `오류: ${errs.join('\n')}`);
  await p2.close();
});

await step('브라우저 콘솔 오류가 없다', async () => {
  assert(!consoleErrors.length, consoleErrors.join('\n'));
});

const logs = await page.evaluate(() => document.querySelectorAll('#log-list li').length);
console.log(`\n${passed} passed, ${failures.length} failed (로그 패널 항목: ${logs})`);
await browser.close();
server.close();
process.exit(failures.length ? 1 : 0);
