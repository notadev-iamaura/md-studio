// 마크다운 → (플레인 텍스트 | Slack용 HTML | 문서용 HTML) 변환 로직.
// 브라우저와 Node 양쪽에서 동작하도록 DOM에 의존하지 않는다.
import { Marked } from 'marked';

export const DEFAULT_OPTIONS = Object.freeze({
  // 표 변환 방식: 'title'(제목형) | 'inline'(한 줄형) | 'grid'(고정폭 표)
  tableMode: 'title',
  // 문단 안의 줄바꿈 한 번을 실제 줄바꿈으로 취급할지 (GitHub 댓글/Slack 사용 습관과 동일)
  breaks: true,
});

const BULLETS = ['•', '◦', '▪'];
const INDENT = '   ';
const HR_TEXT = '────────────────────';

export function createMarked(opts = {}) {
  const o = { ...DEFAULT_OPTIONS, ...opts };
  return new Marked({ gfm: true, breaks: !!o.breaks });
}

export function lex(md, opts = {}) {
  return createMarked(opts).lexer(String(md ?? ''));
}

// ---------------------------------------------------------------------------
// 공통 유틸
// ---------------------------------------------------------------------------

const NAMED_ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', '#39': "'" };

export function decodeEntities(s) {
  return String(s).replace(/&(#x[0-9a-f]+|#\d+|[a-z]+\d*|#39);/gi, (m, code) => {
    const lower = code.toLowerCase();
    if (lower[0] === '#') {
      const n = lower[1] === 'x' ? parseInt(lower.slice(2), 16) : parseInt(lower.slice(1), 10);
      return Number.isFinite(n) && n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : m;
    }
    return NAMED_ENTITIES[lower] ?? m;
  });
}

// 이미 엔티티로 쓰인 부분(&amp; 등)은 다시 이스케이프하지 않는다.
export function escapeHtml(s) {
  return String(s)
    .replace(/&(?!(#x[0-9a-f]+|#\d+|[a-z]+\d*);)/gi, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function escapeAttr(s) {
  return escapeHtml(s).replace(/'/g, '&#39;');
}

function stripTags(html) {
  return decodeEntities(String(html).replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]*>/g, ''));
}

function isBrHtml(raw) {
  return /^<br\s*\/?>$/i.test(String(raw).trim());
}

// 안전하지 않은 링크 프로토콜 차단 (javascript: 등)
function safeHref(href) {
  const h = String(href || '').trim();
  if (/^(javascript|vbscript|data):/i.test(h.replace(/\s+/g, ''))) return '';
  return h;
}

// 한글/한자/전각 문자는 고정폭 글꼴에서 2칸을 차지한다.
export function textWidth(s) {
  let w = 0;
  for (const ch of String(s)) {
    const c = ch.codePointAt(0);
    if (c === 0x200b || (c >= 0x300 && c <= 0x36f)) continue;
    const wide =
      (c >= 0x1100 && c <= 0x115f) ||
      (c >= 0x2e80 && c <= 0xa4cf) ||
      (c >= 0xac00 && c <= 0xd7a3) ||
      (c >= 0xf900 && c <= 0xfaff) ||
      (c >= 0xfe30 && c <= 0xfe4f) ||
      (c >= 0xff00 && c <= 0xff60) ||
      (c >= 0xffe0 && c <= 0xffe6) ||
      (c >= 0x1f300 && c <= 0x1faff);
    w += wide ? 2 : 1;
  }
  return w;
}

function padEnd(s, width) {
  return s + ' '.repeat(Math.max(0, width - textWidth(s)));
}

// ---------------------------------------------------------------------------
// 인라인 렌더러
// ---------------------------------------------------------------------------

function inlinePlain(tokens, ctx = {}) {
  if (!tokens) return '';
  let out = '';
  for (const t of tokens) {
    switch (t.type) {
      case 'text':
        out += t.tokens ? inlinePlain(t.tokens, ctx) : decodeEntities(t.text);
        break;
      case 'escape':
        out += decodeEntities(t.text);
        break;
      case 'strong':
      case 'em':
      case 'del':
        out += inlinePlain(t.tokens, ctx);
        break;
      case 'codespan':
        out += decodeEntities(t.text);
        break;
      case 'br':
        out += ctx.inCell ? ' / ' : '\n';
        break;
      case 'link': {
        const label = inlinePlain(t.tokens, ctx);
        const href = safeHref(t.href);
        out += !href || label === href || `mailto:${label}` === href ? label : `${label} (${href})`;
        break;
      }
      case 'image':
        out += t.text ? `[이미지: ${decodeEntities(t.text)}]` : '[이미지]';
        break;
      case 'html':
        out += isBrHtml(t.raw ?? t.text) ? (ctx.inCell ? ' / ' : '\n') : stripTags(t.text);
        break;
      case 'checkbox':
        break;
      default:
        out += t.tokens ? inlinePlain(t.tokens, ctx) : decodeEntities(t.text ?? '');
    }
  }
  return out;
}

function inlineSlack(tokens) {
  if (!tokens) return '';
  let out = '';
  for (const t of tokens) {
    switch (t.type) {
      case 'text':
        out += t.tokens ? inlineSlack(t.tokens) : escapeHtml(t.text).replace(/\n/g, ' ');
        break;
      case 'escape':
        out += escapeHtml(t.text);
        break;
      case 'strong':
        out += `<b>${inlineSlack(t.tokens)}</b>`;
        break;
      case 'em':
        out += `<i>${inlineSlack(t.tokens)}</i>`;
        break;
      case 'del':
        out += `<s>${inlineSlack(t.tokens)}</s>`;
        break;
      case 'codespan':
        out += `<code>${escapeHtml(t.text)}</code>`;
        break;
      case 'br':
        out += '<br>';
        break;
      case 'link': {
        const href = safeHref(t.href);
        const label = inlineSlack(t.tokens);
        out += href ? `<a href="${escapeAttr(href)}">${label}</a>` : label;
        break;
      }
      case 'image': {
        const href = safeHref(t.href);
        const label = escapeHtml(t.text ? `[이미지: ${t.text}]` : '[이미지]');
        out += href ? `<a href="${escapeAttr(href)}">${label}</a>` : label;
        break;
      }
      case 'html':
        out += isBrHtml(t.raw ?? t.text) ? '<br>' : escapeHtml(stripTags(t.text));
        break;
      case 'checkbox':
        break;
      default:
        out += t.tokens ? inlineSlack(t.tokens) : escapeHtml(t.text ?? '');
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 표 → 목록 구조
// 결과 형태: [{ inline: [{kind:'bold'|'text', tokens|text}], children: [...] }]
// 인라인 조각을 토큰 그대로 들고 있어 플레인/Slack 렌더러가 각자 서식을 입힌다.
// ---------------------------------------------------------------------------

function cellIsEmpty(cell) {
  return !cell || inlinePlain(cell.tokens, { inCell: true }).trim() === '';
}

export function tableToItems(table, mode = 'title') {
  const headers = table.header || [];
  const rows = table.rows || [];
  const cols = headers.length;
  const headerText = (i) => inlinePlain(headers[i]?.tokens, { inCell: true }).trim() || `항목 ${i + 1}`;
  const items = [];

  rows.forEach((row, ri) => {
    const first = row[0];
    const titleParts = cellIsEmpty(first)
      ? [{ kind: 'bold', text: `${headerText(0)} ${ri + 1}` }]
      : [{ kind: 'bold', tokens: first.tokens }];

    if (cols <= 1) {
      if (!cellIsEmpty(first)) items.push({ inline: [{ kind: 'cell', tokens: first.tokens }], children: [] });
      return;
    }

    const rest = [];
    for (let i = 1; i < cols; i++) {
      if (cellIsEmpty(row[i])) continue;
      rest.push({ label: headerText(i), tokens: row[i].tokens });
    }

    if (cols === 2) {
      // 2열 표는 "키: 값" 한 줄이 가장 읽기 좋다.
      const inline = [...titleParts];
      if (rest.length) inline.push({ kind: 'text', text: ': ' }, { kind: 'cell', tokens: rest[0].tokens });
      items.push({ inline, children: [] });
      return;
    }

    if (mode === 'inline') {
      const inline = [...titleParts];
      rest.forEach((r, idx) => {
        inline.push({ kind: 'text', text: idx === 0 ? ' — ' : ' · ' });
        inline.push({ kind: 'text', text: `${r.label}: ` }, { kind: 'cell', tokens: r.tokens });
      });
      items.push({ inline, children: [] });
      return;
    }

    items.push({
      inline: titleParts,
      children: rest.map((r) => ({
        inline: [{ kind: 'text', text: `${r.label}: ` }, { kind: 'cell', tokens: r.tokens }],
        children: [],
      })),
    });
  });
  return items;
}

function partsPlain(parts) {
  return parts
    .map((p) => (p.tokens ? inlinePlain(p.tokens, { inCell: true }) : p.text))
    .join('')
    .trim();
}

function partsSlack(parts) {
  return parts
    .map((p) => {
      const html = p.tokens ? inlineSlack(p.tokens) : escapeHtml(p.text);
      return p.kind === 'bold' ? `<b>${html}</b>` : html;
    })
    .join('');
}

// 고정폭 정렬 표 (Slack 코드블록에 넣으면 표 모양이 유지된다)
export function tableToGrid(table) {
  const headers = (table.header || []).map((c) => inlinePlain(c.tokens, { inCell: true }).trim());
  const rows = (table.rows || []).map((r) => r.map((c) => inlinePlain(c?.tokens, { inCell: true }).trim()));
  const cols = headers.length;
  const widths = headers.map((h, i) => Math.max(textWidth(h), ...rows.map((r) => textWidth(r[i] ?? '')), 3));
  const line = (cells) => cells.map((c, i) => padEnd(c ?? '', widths[i])).join(' │ ').trimEnd();
  const sep = widths.map((w) => '─'.repeat(w)).join('─┼─');
  return [line(headers), sep, ...rows.map((r) => line(Array.from({ length: cols }, (_, i) => r[i] ?? '')))].join('\n');
}

// ---------------------------------------------------------------------------
// 플레인 텍스트 렌더러
// ---------------------------------------------------------------------------

function itemsPlain(items, depth) {
  const lines = [];
  for (const it of items) {
    lines.push(`${INDENT.repeat(depth)}${BULLETS[depth % BULLETS.length]} ${partsPlain(it.inline)}`);
    if (it.children.length) lines.push(...itemsPlain(it.children, depth + 1));
  }
  return lines;
}

function indentLines(text, prefix) {
  return text
    .split('\n')
    .map((l) => (l ? prefix + l : l))
    .join('\n');
}

function listPlain(list, depth, opts) {
  const lines = [];
  const start = Number(list.start) || 1;
  list.items.forEach((item, idx) => {
    let marker = list.ordered ? `${start + idx}.` : BULLETS[depth % BULLETS.length];
    if (item.task) marker = item.checked ? '☑' : '☐';
    const pad = INDENT.repeat(depth);
    const contPad = pad + ' '.repeat(textWidth(marker) + 1);
    let firstDone = false;
    for (const child of item.tokens || []) {
      if (child.type === 'list') {
        lines.push(listPlain(child, depth + 1, opts));
        continue;
      }
      if (child.type === 'space' || child.type === 'checkbox') continue;
      const body = blockPlain(child, opts);
      if (body === '') continue;
      if (!firstDone) {
        const [head, ...tail] = body.split('\n');
        lines.push(`${pad}${marker} ${head}`);
        if (tail.length) lines.push(indentLines(tail.join('\n'), contPad));
        firstDone = true;
      } else {
        lines.push(indentLines(body, contPad));
      }
    }
    if (!firstDone) lines.push(`${pad}${marker}`);
  });
  return lines.join('\n');
}

function blockPlain(t, opts) {
  switch (t.type) {
    case 'heading': {
      const text = inlinePlain(t.tokens);
      return t.depth <= 2 ? `■ ${text}` : `□ ${text}`;
    }
    case 'paragraph':
    case 'text':
      return t.tokens ? inlinePlain(t.tokens) : decodeEntities(t.text);
    case 'list':
      return listPlain(t, 0, opts);
    case 'table':
      if (opts.tableMode === 'grid') return tableToGrid(t);
      return itemsPlain(tableToItems(t, opts.tableMode), 0).join('\n');
    case 'code':
      return t.text;
    case 'blockquote':
      return indentLines(blocksPlain(t.tokens, opts), '│ ');
    case 'hr':
      return HR_TEXT;
    case 'html':
      return stripTags(t.text).trim();
    case 'space':
    case 'def':
      return '';
    default:
      return t.tokens ? inlinePlain(t.tokens) : decodeEntities(t.text ?? '');
  }
}

function blocksPlain(tokens, opts) {
  const parts = [];
  let prevType = null;
  for (const t of tokens) {
    const text = blockPlain(t, opts);
    if (text === '') continue;
    // 제목 바로 아래는 빈 줄 없이 붙여서 묶음이 보이게 한다.
    if (parts.length) parts.push(prevType === 'heading' ? '\n' : '\n\n');
    parts.push(text);
    prevType = t.type;
  }
  return parts.join('');
}

export function toPlainText(md, opts = {}) {
  const o = { ...DEFAULT_OPTIONS, ...opts };
  const result = blocksPlain(lex(md, o), o);
  return result.replace(/[ \t]+$/gm, '').replace(/\n{3,}/g, '\n\n').trim() + '\n';
}

// ---------------------------------------------------------------------------
// Slack용 HTML 렌더러
// Slack 입력창은 붙여넣은 HTML 중 b/i/s/code/pre/a/ul/ol/li/blockquote만 살린다.
// 그래서 제목은 굵은 문단으로, 표는 목록 또는 고정폭 블록으로 바꾼다.
// ---------------------------------------------------------------------------

function itemsSlack(items) {
  if (!items.length) return '';
  return (
    '<ul>' +
    items.map((it) => `<li>${partsSlack(it.inline)}${it.children.length ? itemsSlack(it.children) : ''}</li>`).join('') +
    '</ul>'
  );
}

function listSlack(list, o) {
  const tag = list.ordered ? 'ol' : 'ul';
  const start = Number(list.start) || 1;
  const startAttr = list.ordered && start !== 1 ? ` start="${start}"` : '';
  const lis = list.items
    .map((item) => {
      let html = item.task ? (item.checked ? '☑ ' : '☐ ') : '';
      let first = true;
      for (const child of item.tokens || []) {
        if (child.type === 'checkbox' || child.type === 'space') continue;
        if (child.type === 'list') {
          html += listSlack(child, o);
          continue;
        }
        if (child.type === 'text' || child.type === 'paragraph') {
          html += (first ? '' : '<br>') + inlineSlack(child.tokens ?? [{ type: 'text', text: child.text }]);
        } else {
          html += blockSlack(child, o);
        }
        first = false;
      }
      return `<li>${html}</li>`;
    })
    .join('');
  return `<${tag}${startAttr}>${lis}</${tag}>`;
}

function blockSlack(t, o) {
  switch (t.type) {
    case 'heading':
      return `<p><b>${inlineSlack(t.tokens)}</b></p>`;
    case 'paragraph':
      return `<p>${inlineSlack(t.tokens)}</p>`;
    case 'text':
      return `<p>${t.tokens ? inlineSlack(t.tokens) : escapeHtml(t.text)}</p>`;
    case 'list':
      return listSlack(t, o);
    case 'table':
      if (o.tableMode === 'grid') return `<pre>${escapeHtml(tableToGrid(t))}</pre>`;
      return itemsSlack(tableToItems(t, o.tableMode));
    case 'code':
      return `<pre>${escapeHtml(t.text)}</pre>`;
    case 'blockquote':
      return `<blockquote>${t.tokens.map((c) => blockSlack(c, o)).join('')}</blockquote>`;
    case 'hr':
      return `<p>${HR_TEXT}</p>`;
    case 'html': {
      const text = stripTags(t.text).trim();
      return text ? `<p>${escapeHtml(text)}</p>` : '';
    }
    case 'space':
    case 'def':
      return '';
    default:
      return t.tokens ? `<p>${inlineSlack(t.tokens)}</p>` : '';
  }
}

// 블록 사이에는 빈 줄을 넣는다. Slack은 붙여넣은 문단/목록 사이 간격을 없애서,
// 넣지 않으면 연속된 두 목록이 하나로 합쳐져 보인다. 제목 바로 아래는 붙여서 묶음이 보이게 한다.
const SLACK_GAP = '<p><br></p>';

export function toSlackHtml(md, opts = {}) {
  const o = { ...DEFAULT_OPTIONS, ...opts };
  let out = '';
  let prevType = null;
  for (const t of lex(md, o)) {
    const html = blockSlack(t, o);
    if (!html) continue;
    if (prevType && prevType !== 'heading') out += SLACK_GAP;
    out += html;
    prevType = t.type;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 문서용 HTML (미리보기, Google Docs/Word/메일 붙여넣기, 보고서 내보내기의 원본)
// 결과는 반드시 호출 측에서 sanitize 한다.
// ---------------------------------------------------------------------------

export function toDocHtml(md, opts = {}) {
  return createMarked(opts).parse(String(md ?? ''));
}

// 첫 번째 제목을 문서 제목 후보로 사용
export function extractTitle(md) {
  const tokens = lex(md);
  const h = tokens.find((t) => t.type === 'heading');
  return h ? inlinePlain(h.tokens).trim() : '';
}

export function stats(md) {
  const text = String(md ?? '');
  const chars = text.replace(/\s/g, '').length;
  const words = (text.match(/\S+/g) || []).length;
  const lines = text === '' ? 0 : text.split('\n').length;
  return { chars, words, lines };
}
