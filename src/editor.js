// CodeMirror 6 기반 마크다운 편집기와 서식 명령
import { EditorState, EditorSelection, Compartment } from '@codemirror/state';
import { EditorView, keymap, placeholder, drawSelection, highlightActiveLine, dropCursor } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { markdown, markdownLanguage, markdownKeymap } from '@codemirror/lang-markdown';
import { syntaxHighlighting, HighlightStyle, indentUnit } from '@codemirror/language';
import { search, searchKeymap, highlightSelectionMatches } from '@codemirror/search';
import { tags as t } from '@lezer/highlight';
import { convertPaste } from './output.js';
import { createLogger } from './logger.js';

const log = createLogger('editor');

const mdHighlight = HighlightStyle.define([
  { tag: t.heading1, fontSize: '1.35em', fontWeight: '700' },
  { tag: t.heading2, fontSize: '1.2em', fontWeight: '700' },
  { tag: t.heading3, fontSize: '1.08em', fontWeight: '700' },
  { tag: [t.heading4, t.heading5, t.heading6], fontWeight: '700' },
  { tag: t.strong, fontWeight: '700' },
  { tag: t.emphasis, fontStyle: 'italic' },
  { tag: t.strikethrough, textDecoration: 'line-through' },
  { tag: t.link, color: 'var(--accent)' },
  { tag: t.url, color: 'var(--muted)', textDecoration: 'underline' },
  { tag: t.monospace, fontFamily: 'var(--mono)', color: 'var(--code-fg)' },
  { tag: t.quote, color: 'var(--muted)', fontStyle: 'italic' },
  // 글머리 기호(-, 1.), #, ** 같은 마크다운 기호는 흐리게 표시해 본문이 먼저 읽히게 한다.
  { tag: [t.processingInstruction, t.contentSeparator, t.meta], color: 'var(--syntax)' },
]);

const baseTheme = EditorView.theme({
  '&': { height: '100%', fontSize: 'var(--editor-font-size, 15px)', backgroundColor: 'var(--bg)', color: 'var(--fg)' },
  '.cm-scroller': { fontFamily: 'var(--editor-font)', lineHeight: '1.7', padding: '18px 0 40vh' },
  '.cm-content': { padding: '0 28px', caretColor: 'var(--fg)', maxWidth: '900px' },
  '.cm-activeLine': { backgroundColor: 'var(--active-line)' },
  '.cm-cursor': { borderLeftColor: 'var(--fg)' },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': { backgroundColor: 'var(--selection) !important' },
  '.cm-placeholder': { color: 'var(--muted)' },
  '.cm-panels': { backgroundColor: 'var(--panel)', color: 'var(--fg)', borderColor: 'var(--line)' },
  '.cm-searchMatch': { backgroundColor: 'var(--search-match)' },
  '.cm-textfield, .cm-button': { fontSize: '13px' },
});

// ---------------------------------------------------------------------------
// 서식 명령
// ---------------------------------------------------------------------------

function wrap(view, before, after = before, placeholderText = '') {
  const { state } = view;
  const tr = state.changeByRange((range) => {
    const selected = state.sliceDoc(range.from, range.to);
    const outerFrom = range.from - before.length;
    const outerTo = range.to + after.length;
    // 이미 감싸져 있으면 해제
    if (outerFrom >= 0 && state.sliceDoc(outerFrom, range.from) === before && state.sliceDoc(range.to, outerTo) === after) {
      return {
        changes: [
          { from: outerFrom, to: range.from, insert: '' },
          { from: range.to, to: outerTo, insert: '' },
        ],
        range: EditorSelection.range(outerFrom, range.to - before.length),
      };
    }
    if (selected.startsWith(before) && selected.endsWith(after) && selected.length >= before.length + after.length) {
      const inner = selected.slice(before.length, selected.length - after.length);
      return { changes: { from: range.from, to: range.to, insert: inner }, range: EditorSelection.range(range.from, range.from + inner.length) };
    }
    const text = selected || placeholderText;
    return {
      changes: { from: range.from, to: range.to, insert: before + text + after },
      range: EditorSelection.range(range.from + before.length, range.from + before.length + text.length),
    };
  });
  view.dispatch(state.update(tr, { scrollIntoView: true, userEvent: 'input.format' }));
  view.focus();
  return true;
}

const BLOCK_PREFIX = /^(\s*)(#{1,6}\s+|>\s?|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)/;

function toggleLinePrefix(view, kind, level = 1) {
  const { state } = view;
  const lines = new Set();
  for (const r of state.selection.ranges) {
    for (let pos = r.from; pos <= r.to; ) {
      const line = state.doc.lineAt(pos);
      lines.add(line.number);
      pos = line.to + 1;
    }
  }
  const nums = [...lines].sort((a, b) => a - b);
  const prefixFor = (i) => {
    switch (kind) {
      case 'heading':
        return '#'.repeat(level) + ' ';
      case 'ul':
        return '- ';
      case 'ol':
        return `${i + 1}. `;
      case 'task':
        return '- [ ] ';
      case 'quote':
        return '> ';
      default:
        return '';
    }
  };
  const isKind = (prefix) => {
    if (!prefix) return false;
    if (kind === 'heading') return prefix.trim() === '#'.repeat(level);
    if (kind === 'task') return /\[[ xX]\]/.test(prefix);
    if (kind === 'ul') return /^[-*+]\s+$/.test(prefix);
    if (kind === 'ol') return /^\d+[.)]\s+$/.test(prefix);
    if (kind === 'quote') return prefix.startsWith('>');
    return false;
  };
  // 선택한 줄이 모두 같은 형식이면 해제, 아니면 적용
  const allSame = nums.every((n) => {
    const m = state.doc.line(n).text.match(BLOCK_PREFIX);
    return m && isKind(m[2]);
  });
  const changes = nums.map((n, i) => {
    const line = state.doc.line(n);
    const m = line.text.match(BLOCK_PREFIX);
    const indent = m ? m[1] : (line.text.match(/^\s*/) || [''])[0];
    const from = line.from;
    const to = line.from + (m ? m[0].length : indent.length);
    return { from, to, insert: indent + (allSame ? '' : prefixFor(i)) };
  });
  view.dispatch({ changes, userEvent: 'input.format', scrollIntoView: true });
  view.focus();
  return true;
}

function insertBlock(view, text, cursorOffset = null) {
  const { state } = view;
  const range = state.selection.main;
  const line = state.doc.lineAt(range.from);
  const needsLeadingBreak = line.text.trim() !== '' ? '\n\n' : '';
  const insert = needsLeadingBreak + text + '\n';
  const from = needsLeadingBreak ? line.to : line.from;
  const to = needsLeadingBreak ? line.to : line.to;
  const anchor = from + needsLeadingBreak.length + (cursorOffset ?? text.length);
  view.dispatch({ changes: { from, to, insert }, selection: { anchor }, userEvent: 'input.format', scrollIntoView: true });
  view.focus();
  return true;
}

export const commands = {
  bold: (v) => wrap(v, '**', '**', '굵은 글씨'),
  italic: (v) => wrap(v, '*', '*', '기울임'),
  strike: (v) => wrap(v, '~~', '~~', '취소선'),
  code: (v) => wrap(v, '`', '`', 'code'),
  h1: (v) => toggleLinePrefix(v, 'heading', 1),
  h2: (v) => toggleLinePrefix(v, 'heading', 2),
  h3: (v) => toggleLinePrefix(v, 'heading', 3),
  ul: (v) => toggleLinePrefix(v, 'ul'),
  ol: (v) => toggleLinePrefix(v, 'ol'),
  task: (v) => toggleLinePrefix(v, 'task'),
  quote: (v) => toggleLinePrefix(v, 'quote'),
  link(view) {
    const { state } = view;
    const r = state.selection.main;
    const selected = state.sliceDoc(r.from, r.to);
    const isUrl = /^https?:\/\/\S+$/.test(selected);
    const label = isUrl ? '링크 텍스트' : selected || '링크 텍스트';
    const url = isUrl ? selected : 'https://';
    const insert = `[${label}](${url})`;
    // 텍스트를 골랐으면 URL 부분을, URL을 골랐으면 텍스트 부분을 선택해 바로 입력하게 한다.
    const selFrom = isUrl || !selected ? r.from + 1 : r.from + label.length + 3;
    const selTo = isUrl || !selected ? r.from + 1 + label.length : r.from + label.length + 3 + url.length;
    view.dispatch({ changes: { from: r.from, to: r.to, insert }, selection: { anchor: selFrom, head: selTo }, userEvent: 'input.format' });
    view.focus();
    return true;
  },
  codeBlock(view) {
    const r = view.state.selection.main;
    const selected = view.state.sliceDoc(r.from, r.to);
    if (selected.includes('\n')) {
      view.dispatch({ changes: { from: r.from, to: r.to, insert: '```\n' + selected + '\n```' }, userEvent: 'input.format' });
      view.focus();
      return true;
    }
    return insertBlock(view, '```\n' + (selected || '') + '\n```', 4);
  },
  table: (v) => insertBlock(v, '| 항목 | 내용 | 비고 |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |', 2),
  hr: (v) => insertBlock(v, '---'),
};

// ---------------------------------------------------------------------------
// 편집기 생성
// ---------------------------------------------------------------------------

export function createEditor(parent, { doc = '', onChange, onSave, getPasteConversion }) {
  const wrapCompartment = new Compartment();
  const extensions = [
        history(),
        drawSelection(),
        dropCursor(),
        highlightActiveLine(),
        highlightSelectionMatches(),
        search({ top: true }),
        indentUnit.of('  '),
        EditorState.tabSize.of(2),
        wrapCompartment.of(EditorView.lineWrapping),
        markdown({ base: markdownLanguage }),
        syntaxHighlighting(mdHighlight),
        baseTheme,
        placeholder('여기에 마크다운을 쓰거나 붙여넣으세요.  AI가 쓴 문서를 그대로 붙여넣어도 됩니다.'),
        keymap.of([
          { key: 'Mod-s', preventDefault: true, run: () => (onSave?.(), true) },
          { key: 'Mod-b', run: commands.bold },
          { key: 'Mod-i', run: commands.italic },
          { key: 'Mod-Shift-x', run: commands.strike },
          { key: 'Mod-e', run: commands.code },
          { key: 'Mod-k', run: commands.link },
          { key: 'Mod-Alt-1', run: commands.h1 },
          { key: 'Mod-Alt-2', run: commands.h2 },
          { key: 'Mod-Alt-3', run: commands.h3 },
          { key: 'Mod-Shift-8', run: commands.ul },
          { key: 'Mod-Shift-7', run: commands.ol },
          ...markdownKeymap,
          ...searchKeymap,
          ...historyKeymap,
          indentWithTab,
          ...defaultKeymap,
        ]),
        EditorView.updateListener.of((u) => {
          if (u.docChanged) onChange?.(u.state.doc.toString(), u);
        }),
        EditorView.domEventHandlers({
          paste(event, v) {
            if (!getPasteConversion?.()) return false;
            const html = event.clipboardData?.getData('text/html');
            const text = event.clipboardData?.getData('text/plain') || '';
            let md = null;
            try {
              md = convertPaste(html, text);
            } catch (e) {
              log.error('붙여넣기 변환 실패, 원문 텍스트로 붙여넣습니다', e);
            }
            if (!md) return false;
            event.preventDefault();
            v.dispatch(v.state.replaceSelection(md), { userEvent: 'input.paste', scrollIntoView: true });
            log.info('서식 있는 붙여넣기를 마크다운으로 변환했습니다', { chars: md.length });
            return true;
          },
        }),
  ];
  const view = new EditorView({ parent, state: EditorState.create({ doc, extensions }) });

  return {
    view,
    getValue: () => view.state.doc.toString(),
    setValue(text, { keepHistory = false } = {}) {
      if (keepHistory) {
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
      } else {
        // 다른 파일을 열면 실행 취소 기록을 새로 시작한다. (줄바꿈 설정은 유지)
        const wrapOn = wrapCompartment.get(view.state);
        view.setState(EditorState.create({ doc: text, extensions }));
        view.dispatch({ effects: wrapCompartment.reconfigure(wrapOn ?? EditorView.lineWrapping) });
      }
    },
    run(name) {
      const cmd = commands[name];
      if (!cmd) return log.warn(`알 수 없는 서식 명령: ${name}`);
      cmd(view);
    },
    focus: () => view.focus(),
    setWrap(on) {
      view.dispatch({ effects: wrapCompartment.reconfigure(on ? EditorView.lineWrapping : []) });
    },
  };
}
