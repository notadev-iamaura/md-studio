import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { toPlainText, toSlackHtml, textWidth, extractTitle, stats, escapeHtml, decodeEntities } from '../src/convert.js';

const sample = readFileSync(new URL('./fixtures/sample.md', import.meta.url), 'utf8');

test('4열 표: 제목형은 첫 열을 제목, 나머지를 하위 불릿으로 풀고 빈 칸은 뺀다', () => {
  const out = toPlainText('| 채널 | 방문자 | 비고 |\n|---|---|---|\n| 검색 | 10 | 좋음 |\n| 인스타 | 5 | |', { tableMode: 'title' });
  assert.equal(out, '• 검색\n   ◦ 방문자: 10\n   ◦ 비고: 좋음\n• 인스타\n   ◦ 방문자: 5\n');
});

test('2열 표는 "키: 값" 한 줄로 푼다', () => {
  const out = toPlainText('| 항목 | 값 |\n|---|---|\n| 담당 | 김 |\n| 마감 | 11/15 |');
  assert.equal(out, '• 담당: 김\n• 마감: 11/15\n');
});

test('1열 표는 단순 목록이 된다', () => {
  assert.equal(toPlainText('| 할 일 |\n|---|\n| 하나 |\n| 둘 |'), '• 하나\n• 둘\n');
});

test('첫 칸이 비면 "머리글 + 행 번호"를 제목으로 쓴다', () => {
  const out = toPlainText('| 이름 | 점수 | 등급 |\n|---|---|---|\n|  | 90 | A |');
  assert.match(out, /^• 이름 1\n {3}◦ 점수: 90/);
});

test('한 줄형 표', () => {
  const out = toPlainText('| 채널 | 방문자 | 전환 |\n|---|---|---|\n| 검색 | 10 | 3% |', { tableMode: 'inline' });
  assert.equal(out, '• 검색 — 방문자: 10 · 전환: 3%\n');
});

test('고정폭 표는 한글을 2칸으로 계산해 열을 맞춘다', () => {
  const out = toPlainText('| 이름 | 값 |\n|---|---|\n| 가나다라 | 1 |\n| ab | 22 |', { tableMode: 'grid' });
  const lines = out.trimEnd().split('\n');
  const bar = lines.map((l) => (l.includes('│') ? textWidth(l.slice(0, l.indexOf('│'))) : textWidth(l.slice(0, l.indexOf('┼')))));
  assert.equal(new Set(bar).size, 1, `구분선 위치가 모두 같아야 함: ${JSON.stringify(lines)}`);
});

test('표 안의 서식: Slack HTML에서는 굵게/코드가 살아 있다', () => {
  const html = toSlackHtml('| a | b | c |\n|---|---|---|\n| **x** | `y` | [l](https://e.com) |');
  assert.equal(html, '<ul><li><b><b>x</b></b><ul><li>b: <code>y</code></li><li>c: <a href="https://e.com">l</a></li></ul></li></ul>');
});

test('할 일 목록, 중첩 목록, 시작 번호가 있는 번호 목록', () => {
  const out = toPlainText('- [x] 끝\n- [ ] 남음\n  - 하위\n\n3. 셋\n4. 넷');
  assert.equal(out, '☑ 끝\n☐ 남음\n   ◦ 하위\n\n3. 셋\n4. 넷\n');
  const html = toSlackHtml('3. 셋\n4. 넷');
  assert.equal(html, '<ol start="3"><li>셋</li><li>넷</li></ol>');
});

test('목록 안의 표도 옵션대로 변환된다', () => {
  const md = '- 요약\n\n  | 항목 | 값 |\n  |---|---|\n  | a | 1 |';
  assert.match(toPlainText(md), /• a: 1/);
  assert.match(toPlainText(md, { tableMode: 'grid' }), /항목 │ 값/);
});

test('링크: 텍스트와 주소가 같으면 한 번만 쓴다', () => {
  assert.equal(toPlainText('<https://a.com>'), 'https://a.com\n');
  assert.equal(toPlainText('[문서](https://a.com)'), '문서 (https://a.com)\n');
});

test('위험한 링크(javascript:)는 제거한다', () => {
  const html = toSlackHtml('[클릭](javascript:alert(1))');
  assert.ok(!/javascript/i.test(html), html);
  assert.equal(toPlainText('[클릭](javascript:alert(1))'), '클릭\n');
});

test('HTML 태그는 Slack HTML에 그대로 들어가지 않는다', () => {
  const html = toSlackHtml('안녕 <script>alert(1)</script> <img src=x onerror=alert(1)>');
  assert.ok(!/<script|<img|onerror=/i.test(html), html);
});

test('특수문자: & 는 텍스트에서 그대로, HTML에서는 한 번만 이스케이프', () => {
  assert.equal(toPlainText('A & B &amp; C'), 'A & B & C\n');
  assert.equal(toSlackHtml('A & B &amp; C'), '<p>A &amp; B &amp; C</p>');
  assert.equal(escapeHtml('<&amp;>'), '&lt;&amp;&gt;');
  assert.equal(decodeEntities('&#xAC00;&#44032;&lt;'), '가가<');
});

test('breaks 옵션: 엔터 한 번을 줄바꿈으로', () => {
  assert.equal(toPlainText('첫줄\n둘째줄', { breaks: true }), '첫줄\n둘째줄\n');
  assert.equal(toSlackHtml('첫줄\n둘째줄', { breaks: true }), '<p>첫줄<br>둘째줄</p>');
  assert.equal(toSlackHtml('첫줄\n둘째줄', { breaks: false }), '<p>첫줄 둘째줄</p>');
});

test('제목, 인용, 구분선, 코드 블록', () => {
  const out = toPlainText('# 큰 제목\n본문\n\n### 작은 제목\n\n> 인용\n\n---\n\n```\ncode  keep\n```');
  // 제목 바로 아래 블록은 빈 줄 없이 붙는다 (묶음이 보이도록)
  assert.equal(out, '■ 큰 제목\n본문\n\n□ 작은 제목\n│ 인용\n\n────────────────────\n\ncode  keep\n');
  assert.match(toSlackHtml('```\n<a>\n```'), /^<pre>&lt;a&gt;<\/pre>$/);
});

test('예제 문서 전체가 오류 없이 변환되고 마크다운 기호가 남지 않는다', () => {
  for (const mode of ['title', 'inline', 'grid']) {
    const out = toPlainText(sample, { tableMode: mode });
    assert.ok(!/\*\*|\|---|^#+\s/m.test(out), `${mode}: 마크다운 기호가 남음\n${out}`);
  }
  const html = toSlackHtml(sample);
  assert.ok(!/<table|<h\d/i.test(html), 'Slack HTML에 table/h 태그가 없어야 함');
});

test('Slack HTML: 블록 사이에 빈 줄을 넣어 연속된 목록이 합쳐지지 않게 하고, 제목 아래는 붙인다', () => {
  const html = toSlackHtml('## 제목\n- a\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n- b');
  assert.equal(html, '<p><b>제목</b></p><ul><li>a</li></ul><p><br></p><ul><li><b>1</b>: 2</li></ul><p><br></p><ul><li>b</li></ul>');
});

test('textWidth / extractTitle / stats', () => {
  assert.equal(textWidth('가a'), 3);
  assert.equal(extractTitle('본문\n\n## **보고서** 제목'), '보고서 제목');
  assert.equal(extractTitle('제목 없음'), '');
  assert.deepEqual(stats('안녕 하세요\n둘째'), { chars: 7, words: 3, lines: 2 });
  assert.deepEqual(stats(''), { chars: 0, words: 0, lines: 0 });
});
