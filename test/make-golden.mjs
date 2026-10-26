// Swift 등 다른 구현이 같은 결과를 내는지 대조하기 위한 정답 데이터(test/fixtures/golden.json)를 만든다.
// 사용: node test/make-golden.mjs   (변환 규칙을 바꾸면 다시 실행해 갱신한다)
import { writeFileSync, readFileSync } from 'node:fs';
import { toPlainText, toSlackHtml, extractTitle } from '../src/convert.js';
import { SAMPLE_DOC } from '../src/sample.js';

const cases = {
  '표_4열_빈칸': '| 채널 | 방문자 | 비고 |\n|---|---|---|\n| 검색 | 10 | 좋음 |\n| 인스타 | 5 | |',
  '표_2열': '| 항목 | 값 |\n|---|---|\n| 담당 | 김 |\n| 마감 | 11/15 |',
  '표_1열': '| 할 일 |\n|---|\n| 하나 |\n| 둘 |',
  '표_첫칸_빈칸': '| 이름 | 점수 | 등급 |\n|---|---|---|\n|  | 90 | A |',
  '표_한글폭_정렬': '| 이름 | 값 |\n|---|---|\n| 가나다라 | 1 |\n| ab | 22 |',
  '표_셀_서식': '| a | b | c |\n|---|---|---|\n| **x** | `y` | [l](https://e.com) |',
  '표_셀_줄바꿈': '| a | b | c |\n|---|---|---|\n| 첫<br>둘 | 값 | 끝 |',
  '목록_할일_중첩_시작번호': '- [x] 끝\n- [ ] 남음\n  - 하위\n\n3. 셋\n4. 넷',
  '목록_안의_표': '- 요약\n\n  | 항목 | 값 |\n  |---|---|\n  | a | 1 |',
  '링크_같은주소': '<https://a.com>',
  '링크_일반': '[문서](https://a.com)',
  '위험한_링크': '[클릭](javascript:alert(1))',
  'HTML_태그': '안녕 <script>alert(1)</script> <img src=x onerror=alert(1)>',
  '특수문자': 'A & B &amp; C',
  '줄바꿈': '첫줄\n둘째줄',
  '제목_인용_구분선_코드': '# 큰 제목\n본문\n\n### 작은 제목\n\n> 인용\n\n---\n\n```\ncode  keep\n```',
  '코드_HTML_이스케이프': '```\n<a>\n```',
  '블록_간격': '## 제목\n- a\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n- b',
  '이미지': '![로고](https://e.com/a.png) 와 ![](x.png)',
  '보고서_예제': readFileSync(new URL('./fixtures/sample.md', import.meta.url), 'utf8'),
  '앱_예제_문서': SAMPLE_DOC,
};

const out = {
  설명: 'src/convert.js가 만든 정답. plain_*은 텍스트 복사(표 변환 방식별), slack_*은 Slack 복사의 HTML. options.breaks 기본 true.',
  생성: 'node test/make-golden.mjs',
  cases: Object.entries(cases).map(([name, md]) => ({
    name,
    markdown: md,
    title: extractTitle(md),
    plain_title: toPlainText(md, { tableMode: 'title' }),
    plain_inline: toPlainText(md, { tableMode: 'inline' }),
    plain_grid: toPlainText(md, { tableMode: 'grid' }),
    slack_title: toSlackHtml(md, { tableMode: 'title' }),
    slack_grid: toSlackHtml(md, { tableMode: 'grid' }),
    plain_title_nobreaks: toPlainText(md, { tableMode: 'title', breaks: false }),
    slack_title_nobreaks: toSlackHtml(md, { tableMode: 'title', breaks: false }),
  })),
};
writeFileSync(new URL('./fixtures/golden.json', import.meta.url), JSON.stringify(out, null, 2) + '\n');
console.log(`golden.json: ${out.cases.length}개 사례`);
