// 브라우저 전용 출력 처리: 정제(sanitize), 서식 복사용 인라인 스타일, 클립보드, 보고서, 붙여넣기 변환
import DOMPurify from 'dompurify';
import TurndownService from 'turndown';
import { gfm } from 'turndown-plugin-gfm';
import { toDocHtml, escapeHtml } from './convert.js';
import { createLogger } from './logger.js';

const log = createLogger('output');

// ---------------------------------------------------------------------------
// 문서 HTML
// ---------------------------------------------------------------------------

export function sanitize(html) {
  return DOMPurify.sanitize(html, {
    ADD_ATTR: ['target', 'start', 'align'],
    FORBID_TAGS: ['style', 'script', 'iframe', 'form'],
  });
}

function slugify(text) {
  return (
    String(text)
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s-]/gu, '')
      .replace(/\s+/g, '-') || 'section'
  );
}

// 마크다운 → 정제된 HTML 요소(컨테이너). 제목에 앵커 id를 붙인다.
export function renderDocFragment(md, opts) {
  const container = document.createElement('div');
  container.innerHTML = sanitize(toDocHtml(md, opts));
  const used = new Map();
  container.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach((h) => {
    const base = slugify(h.textContent);
    const n = used.get(base) || 0;
    used.set(base, n + 1);
    h.id = n ? `${base}-${n}` : base;
  });
  container.querySelectorAll('a[href]').forEach((a) => {
    if (!a.getAttribute('href').startsWith('#')) {
      a.setAttribute('target', '_blank');
      a.setAttribute('rel', 'noopener noreferrer');
    }
  });
  return container;
}

// ---------------------------------------------------------------------------
// 서식 복사 (Google Docs / Word / Gmail / Notion)
// 붙여넣기 대상 앱은 <style> 블록을 버리므로 모든 스타일을 태그에 직접 넣는다.
// ---------------------------------------------------------------------------

const FONT = "-apple-system, BlinkMacSystemFont, 'Apple SD Gothic Neo', 'Malgun Gothic', 'Segoe UI', Arial, sans-serif";
const MONO = "Menlo, Consolas, 'D2Coding', monospace";
const INLINE_STYLES = {
  h1: 'font-size:24px;font-weight:700;margin:20px 0 10px;line-height:1.3;',
  h2: 'font-size:20px;font-weight:700;margin:18px 0 8px;line-height:1.3;',
  h3: 'font-size:17px;font-weight:700;margin:16px 0 6px;line-height:1.35;',
  h4: 'font-size:15px;font-weight:700;margin:14px 0 6px;',
  h5: 'font-size:14px;font-weight:700;margin:12px 0 4px;',
  h6: 'font-size:13px;font-weight:700;margin:12px 0 4px;color:#59636e;',
  p: 'margin:0 0 10px;line-height:1.6;',
  ul: 'margin:0 0 10px;padding-left:24px;',
  ol: 'margin:0 0 10px;padding-left:24px;',
  li: 'margin:2px 0;line-height:1.6;',
  table: 'border-collapse:collapse;margin:0 0 12px;',
  th: 'border:1px solid #d0d7de;padding:6px 10px;background:#f6f8fa;font-weight:700;',
  td: 'border:1px solid #d0d7de;padding:6px 10px;',
  blockquote: 'margin:0 0 10px;padding:2px 12px;border-left:4px solid #d0d7de;color:#59636e;',
  pre: `margin:0 0 12px;padding:10px 12px;background:#f6f8fa;border-radius:6px;font-family:${MONO};font-size:13px;line-height:1.5;white-space:pre-wrap;`,
  code: `font-family:${MONO};font-size:90%;background:#eff1f3;padding:1px 4px;border-radius:4px;`,
  a: 'color:#0969da;text-decoration:underline;',
  hr: 'border:none;border-top:1px solid #d0d7de;margin:16px 0;',
  img: 'max-width:100%;',
};

export function toRichCopyHtml(md, opts) {
  const root = renderDocFragment(md, opts);
  // 체크박스는 대부분의 앱에서 사라지므로 문자로 바꾼다.
  root.querySelectorAll('input[type=checkbox]').forEach((cb) => {
    cb.replaceWith(document.createTextNode(cb.checked || cb.hasAttribute('checked') ? '☑ ' : '☐ '));
  });
  root.querySelectorAll('li').forEach((li) => {
    if (/^[☑☐]/.test(li.textContent.trim())) li.style.listStyleType = 'none';
  });
  root.querySelectorAll('*').forEach((el) => {
    const tag = el.tagName.toLowerCase();
    let style = INLINE_STYLES[tag] || '';
    if (tag === 'code' && el.parentElement?.tagName === 'PRE') style = 'font-family:inherit;';
    if ((tag === 'th' || tag === 'td') && el.getAttribute('align')) style += `text-align:${el.getAttribute('align')};`;
    if (style) el.setAttribute('style', style + (el.getAttribute('style') || ''));
    el.removeAttribute('id');
    el.removeAttribute('class');
  });
  return `<div style="font-family:${FONT};font-size:14px;color:#1f2328;line-height:1.6;">${root.innerHTML}</div>`;
}

// ---------------------------------------------------------------------------
// 클립보드: HTML과 텍스트를 동시에 넣어 붙여넣는 앱이 알맞은 쪽을 고르게 한다.
// ---------------------------------------------------------------------------

export async function writeClipboard({ html, text }) {
  // 맥 앱에서는 macOS 클립보드에 직접 HTML과 텍스트를 함께 넣는다.
  if (window.mdNative) {
    await window.mdNative.writeClipboard({ html: html || null, text });
    log.debug('macOS 클립보드로 복사', { html: html?.length ?? 0, text: text.length });
    return 'native';
  }
  const wrappedHtml = html ? `<meta charset="utf-8">${html}` : null;
  if (navigator.clipboard && window.ClipboardItem) {
    try {
      const data = { 'text/plain': new Blob([text], { type: 'text/plain' }) };
      if (wrappedHtml) data['text/html'] = new Blob([wrappedHtml], { type: 'text/html' });
      await navigator.clipboard.write([new ClipboardItem(data)]);
      log.debug('클립보드 API로 복사', { html: html?.length ?? 0, text: text.length });
      return 'clipboard-api';
    } catch (e) {
      log.warn('클립보드 API 실패, 대체 방식으로 복사합니다', e);
    }
  }
  // 대체 방식: copy 이벤트를 가로채 두 형식을 직접 채운다.
  return new Promise((resolve, reject) => {
    const onCopy = (e) => {
      e.preventDefault();
      e.clipboardData.setData('text/plain', text);
      if (wrappedHtml) e.clipboardData.setData('text/html', wrappedHtml);
    };
    document.addEventListener('copy', onCopy, { once: true });
    const ok = document.execCommand('copy');
    document.removeEventListener('copy', onCopy);
    if (ok) {
      log.debug('execCommand 방식으로 복사', { html: html?.length ?? 0, text: text.length });
      resolve('exec-command');
    } else reject(new Error('브라우저가 클립보드 복사를 허용하지 않았습니다'));
  });
}

// ---------------------------------------------------------------------------
// HTML 보고서
// ---------------------------------------------------------------------------

const REPORT_CSS = `
:root{--fg:#1f2328;--muted:#59636e;--line:#d8dee4;--soft:#f6f8fa;--accent:#0b57d0}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:#eef1f4;color:var(--fg);font:16px/1.7 ${FONT};word-break:keep-all;overflow-wrap:anywhere}
.page{max-width:860px;margin:32px auto;background:#fff;border-radius:12px;box-shadow:0 1px 3px rgba(0,0,0,.08),0 8px 24px rgba(0,0,0,.05);padding:56px 64px}
.report-header{border-bottom:2px solid var(--fg);padding-bottom:18px;margin-bottom:28px}
.report-header h1{font-size:30px;line-height:1.3;margin:0 0 8px;letter-spacing:-.01em}
.report-meta{color:var(--muted);font-size:14px}
.toc{background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:16px 22px;margin:0 0 32px}
.toc-title{font-weight:700;font-size:14px;color:var(--muted);margin-bottom:6px}
.toc ol{margin:0;padding-left:20px}
.toc li{margin:2px 0}
.toc .lv3{margin-left:18px;list-style:circle}
.toc a{color:var(--fg);text-decoration:none}
.toc a:hover{color:var(--accent);text-decoration:underline}
.content h1,.content h2,.content h3,.content h4{line-height:1.35;margin:1.8em 0 .6em;scroll-margin-top:16px}
.content h1{font-size:26px}
.content h2{font-size:22px;padding-bottom:6px;border-bottom:1px solid var(--line)}
.content h3{font-size:18px}
.content h4{font-size:16px}
.content > :first-child{margin-top:0}
.content p{margin:0 0 1em}
.content ul,.content ol{padding-left:1.6em;margin:0 0 1em}
.content li{margin:.2em 0}
.content li:has(> input[type=checkbox]){list-style:none}
.content input[type=checkbox]{margin:0 .45em 0 0;vertical-align:-1px}
.content a{color:var(--accent)}
.content blockquote{margin:0 0 1em;padding:.4em 1em;border-left:4px solid var(--accent);background:#f4f7fd;color:#3b4552;border-radius:0 6px 6px 0}
.content blockquote > :last-child{margin-bottom:0}
.content code{font-family:${MONO};font-size:.88em;background:#eff1f3;padding:.12em .4em;border-radius:4px}
.content pre{background:#f6f8fa;border:1px solid var(--line);border-radius:8px;padding:14px 16px;overflow:auto;line-height:1.5}
.content pre code{background:none;padding:0;font-size:13.5px}
.table-wrap{overflow-x:auto;margin:0 0 1.2em}
.content table{border-collapse:collapse;width:100%;font-size:15px}
.content th,.content td{border:1px solid var(--line);padding:8px 12px;vertical-align:top}
.content thead th{background:#f0f3f6;font-weight:700;text-align:left}
.content tbody tr:nth-child(even){background:#fafbfc}
.content img{max-width:100%;border-radius:6px}
.content hr{border:none;border-top:1px solid var(--line);margin:2em 0}
.report-footer{margin-top:48px;padding-top:14px;border-top:1px solid var(--line);color:var(--muted);font-size:12px}
@media (max-width:720px){.page{margin:0;border-radius:0;padding:28px 18px}.report-header h1{font-size:24px}}
@media print{
  @page{margin:18mm 16mm}
  body{background:#fff;font-size:11pt}
  .page{box-shadow:none;margin:0;padding:0;max-width:none;border-radius:0}
  .toc a{color:var(--fg)}
  .content a{color:var(--fg);text-decoration:underline}
  h1,h2,h3,h4{break-after:avoid}
  pre,blockquote,table,img{break-inside:avoid}
  tr{break-inside:avoid}
  .table-wrap{overflow:visible}
}
`;

export function buildReportHtml(md, { title, includeToc = true, includeDate = true, renderOpts } = {}) {
  const root = renderDocFragment(md, renderOpts);
  // 본문 첫 제목이 보고서 제목과 같으면 중복되므로 빼낸다.
  const first = root.firstElementChild;
  if (first && first.tagName === 'H1' && first.textContent.trim() === String(title).trim()) first.remove();
  root.querySelectorAll('table').forEach((t) => {
    const wrap = document.createElement('div');
    wrap.className = 'table-wrap';
    t.replaceWith(wrap);
    wrap.appendChild(t);
  });
  root.querySelectorAll('a[target]').forEach((a) => a.removeAttribute('target'));

  let toc = '';
  const heads = [...root.querySelectorAll('h2,h3')];
  if (includeToc && heads.length >= 3) {
    toc =
      '<nav class="toc"><div class="toc-title">목차</div><ol>' +
      heads
        .map((h) => `<li class="lv${h.tagName[1]}"><a href="#${escapeHtml(h.id)}">${escapeHtml(h.textContent)}</a></li>`)
        .join('') +
      '</ol></nav>';
  }
  const now = new Date();
  const dateStr = `${now.getFullYear()}년 ${now.getMonth() + 1}월 ${now.getDate()}일`;
  const meta = includeDate ? `<div class="report-meta">${dateStr}</div>` : '';
  const safeTitle = escapeHtml(title || '문서');

  return `<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${safeTitle}</title>
<style>${REPORT_CSS}</style>
</head>
<body>
<main class="page">
<header class="report-header"><h1>${safeTitle}</h1>${meta}</header>
${toc}
<article class="content">
${root.innerHTML}
</article>
<footer class="report-footer">MD Studio에서 생성 · ${dateStr}</footer>
</main>
</body>
</html>
`;
}

// 보고서를 숨은 iframe에 띄우고 인쇄 창을 연다. 인쇄 창에서 "PDF로 저장"을 고르면 된다.
export function printHtml(html) {
  return new Promise((resolve) => {
    const iframe = document.createElement('iframe');
    iframe.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden;';
    iframe.srcdoc = html;
    iframe.onload = () => {
      const win = iframe.contentWindow;
      const cleanup = () => setTimeout(() => iframe.remove(), 500);
      win.addEventListener('afterprint', cleanup, { once: true });
      setTimeout(() => {
        win.focus();
        win.print();
        log.info('인쇄 창 열기');
        resolve();
        setTimeout(cleanup, 60_000);
      }, 150);
    };
    document.body.appendChild(iframe);
  });
}

// ---------------------------------------------------------------------------
// 붙여넣기: 웹/Google Docs/Notion에서 복사한 서식을 마크다운으로 바꾼다.
// ---------------------------------------------------------------------------

let turndown = null;
function getTurndown() {
  if (turndown) return turndown;
  turndown = new TurndownService({
    headingStyle: 'atx',
    codeBlockStyle: 'fenced',
    bulletListMarker: '-',
    emDelimiter: '*',
    strongDelimiter: '**',
    hr: '---',
  });
  turndown.use(gfm);
  turndown.remove(['style', 'script', 'meta', 'title', 'head']);
  // Google Docs는 문서 전체를 <b style="font-weight:normal">로 감싼다 → 굵게 처리하지 않는다.
  turndown.addRule('gdocsWrapper', {
    filter: (node) => node.nodeName === 'B' && /^docs-internal-guid/.test(node.id || ''),
    replacement: (content) => content,
  });
  // Google Docs는 굵게/기울임을 <span style>로 표현한다.
  turndown.addRule('styledSpan', {
    filter: (node) => node.nodeName === 'SPAN' && /font-weight:\s*(bold|[6-9]00)|font-style:\s*italic/.test(node.getAttribute('style') || ''),
    replacement: (content, node) => {
      if (!content.trim()) return content;
      const style = node.getAttribute('style') || '';
      let out = content;
      if (/font-style:\s*italic/.test(style)) out = `*${out}*`;
      if (/font-weight:\s*(bold|[6-9]00)/.test(style)) out = `**${out}**`;
      return out;
    },
  });
  return turndown;
}

const SEMANTIC_HTML = /<(h[1-6]|strong|b|em|i|ul|ol|li|table|a\s|code|pre|blockquote|img)\b|font-weight:\s*(bold|[6-9]00)/i;
const LOOKS_LIKE_MD = /(^|\n)\s{0,3}(#{1,6}\s|[-*+]\s|\d+\.\s|>\s|```|\|.*\|)|\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^)\s]+\)/;

// 붙여넣을 내용을 결정한다. null을 반환하면 브라우저 기본 붙여넣기를 쓴다.
export function convertPaste(html, text) {
  if (!html) return null;
  if (text && LOOKS_LIKE_MD.test(text)) {
    log.debug('붙여넣기: 텍스트가 이미 마크다운이라 그대로 사용');
    return null;
  }
  if (!SEMANTIC_HTML.test(html)) {
    log.debug('붙여넣기: 서식 정보가 없는 HTML이라 텍스트 사용');
    return null;
  }
  const done = log.time('붙여넣기 HTML → 마크다운');
  const clean = DOMPurify.sanitize(html, { FORBID_TAGS: ['style', 'script'] });
  const md = getTurndown()
    .turndown(clean)
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  done({ htmlLength: html.length, mdLength: md.length });
  return md || null;
}
