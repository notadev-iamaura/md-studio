// MD Studio 진입점: 화면 요소와 편집기·변환기·저장소를 연결한다.
import { createLogger, onLog, getEntries, formatEntries, clearEntries, installGlobalHandlers } from './logger.js';
import { toPlainText, toSlackHtml, extractTitle, stats } from './convert.js';
import { sanitize, renderDocFragment, toRichCopyHtml, writeClipboard, buildReportHtml, printHtml } from './output.js';
import { createEditor } from './editor.js';
import * as store from './storage.js';
import { SAMPLE_DOC } from './sample.js';

/* global __APP_VERSION__ */
const VERSION = typeof __APP_VERSION__ !== 'undefined' ? __APP_VERSION__ : 'dev';
const log = createLogger('app');

const DEFAULT_SETTINGS = {
  tableMode: 'title',
  breaks: true,
  pasteConvert: true,
  autosave: true,
  syncScroll: true,
  lineWrap: true,
  editorFont: 'sans',
  editorFontSize: '15',
  theme: 'system',
  view: 'split',
  sidebar: true,
  previewTab: 'doc',
  lastFile: null,
  welcomed: false,
};

const state = {
  settings: { ...DEFAULT_SETTINGS },
  folder: null, // 열린 폴더 핸들
  files: [], // 폴더 안 마크다운 파일 목록
  file: null, // { handle, path, name, fromFolder } — handle이 없으면 브라우저 임시 문서
  fallbackName: null, // 핸들 없이 연 파일의 원래 이름 (Safari 등)
  savedText: '',
  lastModified: 0,
  saving: false,
  pendingSave: false,
  externalWarned: 0,
};

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => [...document.querySelectorAll(sel)];
let editor;

// ---------------------------------------------------------------------------
// 공통 UI 도구
// ---------------------------------------------------------------------------

function toast(message, type = 'info', ms = 2600) {
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.textContent = message;
  const wrap = $('#toasts');
  wrap.appendChild(el);
  while (wrap.children.length > 3) wrap.firstElementChild.remove();
  setTimeout(() => el.remove(), type === 'error' ? Math.max(ms, 5000) : ms);
}

function debounce(fn, ms) {
  let t;
  const wrapped = (...args) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
  wrapped.flush = (...args) => {
    clearTimeout(t);
    fn(...args);
  };
  wrapped.cancel = () => clearTimeout(t);
  return wrapped;
}

function askChoice(title, message, buttons) {
  const dlg = $('#dlg-confirm');
  $('#confirm-title').textContent = title;
  $('#confirm-msg').textContent = message;
  const actions = dlg.querySelector('.dlg-actions');
  actions.replaceChildren(
    ...buttons.map((b) => {
      const btn = document.createElement('button');
      btn.value = b.value;
      btn.className = `btn ${b.cls || ''}`;
      btn.textContent = b.label;
      return btn;
    }),
  );
  return new Promise((resolve) => {
    dlg.addEventListener('close', () => resolve(dlg.returnValue || 'cancel'), { once: true });
    dlg.returnValue = '';
    dlg.showModal();
    actions.lastElementChild?.focus();
  });
}

const ILLEGAL_NAME = /[\\/:*?"<>|\u0000-\u001f]/g;

function cleanFileName(name, ext = '.md') {
  let n = String(name || '').replace(ILLEGAL_NAME, '').replace(/\s+/g, ' ').trim().slice(0, 80);
  if (!n) n = '새 문서';
  if (ext === '.md' && !store.MD_EXT.test(n)) n += ext;
  if (ext === '.html' && !/\.html?$/i.test(n)) n += ext;
  if (ext === '.pdf' && !/\.pdf$/i.test(n)) n += ext;
  return n;
}

function askName(defaultName, hint) {
  const dlg = $('#dlg-name');
  const input = $('#name-input');
  $('#name-hint').textContent = hint || '열린 폴더에 저장합니다.';
  input.value = defaultName;
  return new Promise((resolve) => {
    dlg.addEventListener('close', () => resolve(dlg.returnValue === 'ok' ? cleanFileName(input.value) : null), { once: true });
    dlg.returnValue = '';
    dlg.showModal();
    input.focus();
    input.setSelectionRange(0, defaultName.replace(store.MD_EXT, '').length);
  });
}

function docBaseName() {
  if (state.file) return state.file.name.replace(store.MD_EXT, '');
  if (state.fallbackName) return state.fallbackName.replace(store.MD_EXT, '');
  return '';
}

function suggestName() {
  return cleanFileName(extractTitle(editor.getValue()) || docBaseName() || '새 문서');
}

function renderOpts() {
  return { tableMode: state.settings.tableMode, breaks: state.settings.breaks };
}

function draftKey() {
  if (state.file?.fromFolder && state.folder) return `file:${state.folder.name}/${state.file.path}`;
  if (state.file) return `file:${state.file.name}`;
  return 'untitled';
}

function isDirty() {
  return editor.getValue() !== state.savedText;
}

function fmtClock(d = new Date()) {
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

// ---------------------------------------------------------------------------
// 상태 표시
// ---------------------------------------------------------------------------

function updateTitleAndStatus() {
  const dirty = isDirty();
  const name = state.file?.name || state.fallbackName || '새 문서';
  $('#file-name').textContent = state.file?.fromFolder ? state.file.path : name;
  $('#dirty-dot').hidden = !dirty;
  document.title = `${dirty ? '• ' : ''}${name} — MD Studio`;
  const st = $('#st-save');
  if (!st.classList.contains('error') || !dirty) {
    st.classList.remove('error');
    if (dirty) {
      st.textContent = state.file?.handle && state.settings.autosave ? '변경됨 (곧 자동 저장)' : store.isNative ? '저장 안 됨 (임시 보관 중)' : '저장 안 됨 (브라우저에 임시 보관 중)';
      st.classList.add('unsaved');
    } else {
      st.classList.remove('unsaved');
      if (!st.dataset.savedAt) st.textContent = state.file ? '저장됨' : '빈 문서';
    }
  }
  const s = stats(editor.getValue());
  $('#st-stats').textContent = `${s.chars.toLocaleString()}자 · 단어 ${s.words.toLocaleString()} · ${s.lines.toLocaleString()}줄`;
}

function markSaved() {
  const st = $('#st-save');
  st.classList.remove('unsaved', 'error');
  st.dataset.savedAt = fmtClock();
  st.textContent = `저장됨 ${st.dataset.savedAt}`;
  updateTitleAndStatus();
}

function markSaveError(message) {
  const st = $('#st-save');
  st.classList.remove('unsaved');
  st.classList.add('error');
  st.textContent = `저장 실패: ${message}`;
}

function updateStorageStatus() {
  const el = $('#st-storage');
  if (state.folder) el.textContent = `폴더: ${state.folder.path || state.folder.name}`;
  else if (state.file?.handle) el.textContent = '파일에 직접 저장';
  else if (store.isNative) el.textContent = '폴더 미선택 · 임시 보관';
  else if (store.fsSupported) el.textContent = '폴더 미선택 · 브라우저 임시 보관';
  else el.textContent = '다운로드 방식 저장 (Chrome 권장)';
}

// ---------------------------------------------------------------------------
// 미리보기
// ---------------------------------------------------------------------------

function renderPreview() {
  const md = editor.getValue();
  const opts = renderOpts();
  const tab = state.settings.previewTab;
  const t0 = performance.now();
  try {
    if (tab === 'doc') {
      const frag = renderDocFragment(md, opts);
      $('#preview-doc').replaceChildren(...frag.childNodes);
    } else if (tab === 'slack') {
      $('#slack-content').innerHTML = sanitize(toSlackHtml(md, opts));
    } else {
      $('#preview-plain').textContent = toPlainText(md, opts);
    }
  } catch (e) {
    log.error('미리보기 렌더링 실패', e);
  }
  const ms = performance.now() - t0;
  if (ms > 80) log.debug(`미리보기 렌더링이 느립니다 (${ms.toFixed(0)}ms)`, { chars: md.length, tab });
}

const schedulePreview = debounce(renderPreview, 120);

function setPreviewTab(tab) {
  state.settings.previewTab = tab;
  store.saveSettings(state.settings);
  $$('.preview-tabs [data-tab]').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
  $('#preview-doc').hidden = tab !== 'doc';
  $('#preview-slack').hidden = tab !== 'slack';
  $('#preview-plain').hidden = tab !== 'plain';
  renderPreview();
}

function setView(view) {
  state.settings.view = view;
  store.saveSettings(state.settings);
  $('#app').dataset.view = view;
  $$('[data-view-btn]').forEach((b) => b.classList.toggle('active', b.dataset.viewBtn === view));
  if (view !== 'edit') renderPreview();
  if (view !== 'preview') requestAnimationFrame(() => editor.view.requestMeasure());
}

// ---------------------------------------------------------------------------
// 임시본 / 자동 저장
// ---------------------------------------------------------------------------

const scheduleDraft = debounce(() => {
  if (isDirty()) store.saveDraft(draftKey(), editor.getValue());
  else store.clearDraft(draftKey());
}, 700);

const scheduleAutosave = debounce(() => {
  if (state.settings.autosave && state.file?.handle && isDirty()) save({ silent: true });
}, 1500);

function onEditorChange() {
  updateTitleAndStatus();
  schedulePreview();
  scheduleDraft();
  scheduleAutosave();
}

// ---------------------------------------------------------------------------
// 파일 작업
// ---------------------------------------------------------------------------

async function save({ silent = false, forceNew = false } = {}) {
  if (state.saving) {
    state.pendingSave = true;
    return true;
  }
  state.saving = true;
  const text = editor.getValue();
  const oldKey = draftKey();
  try {
    if (state.file?.handle && !forceNew) {
      if (!(await store.ensurePermission(state.file.handle, !silent))) {
        if (silent) {
          log.warn('자동 저장 권한이 없어 건너뜁니다. 저장 버튼을 누르면 권한을 요청합니다.');
          return false;
        }
        throw new Error('파일 쓰기 권한이 거부되었습니다');
      }
      state.lastModified = await store.writeHandle(state.file.handle, text);
    } else if (state.folder && !forceNew) {
      const name = await askName(suggestName());
      if (!name) return false;
      const handle = await store.createFileInFolder(state.folder, name);
      state.lastModified = await store.writeHandle(handle, text);
      state.file = { handle, path: handle.name, name: handle.name, fromFolder: true };
      state.settings.lastFile = handle.name;
      store.saveSettings(state.settings);
      await refreshFolder();
    } else {
      const r = await store.saveWithPicker(suggestName(), text, 'md');
      if (r.handle) {
        state.file = { handle: r.handle, path: r.handle.name, name: r.handle.name, fromFolder: false };
        state.lastModified = r.lastModified;
      } else {
        state.fallbackName = suggestName();
        toast('다운로드 폴더에 저장했습니다. 폴더에 바로 저장하려면 Chrome에서 여세요.', 'info', 4000);
      }
    }
    state.savedText = text;
    store.clearDraft(oldKey);
    store.clearDraft(draftKey());
    markSaved();
    updateStorageStatus();
    renderFileList();
    if (!silent) toast('저장했습니다');
    return true;
  } catch (e) {
    if (e?.name === 'AbortError') {
      log.info('저장을 취소했습니다');
      return false;
    }
    log.error('저장 실패', e);
    markSaveError(e.message || '알 수 없는 오류');
    toast(`저장하지 못했습니다: ${e.message}. 작성 내용은 브라우저에 임시 보관되어 있습니다.`, 'error');
    return false;
  } finally {
    state.saving = false;
    if (state.pendingSave) {
      state.pendingSave = false;
      if (isDirty()) setTimeout(() => save({ silent: true }), 0);
    }
  }
}

// 현재 문서를 떠나도 되는지 확인 (저장 안 된 내용 보호)
async function confirmLeave() {
  if (!isDirty()) return true;
  scheduleAutosave.cancel();
  if (state.file?.handle && state.settings.autosave) return save({ silent: true });
  const name = state.file?.name || state.fallbackName || '새 문서';
  const choice = await askChoice('저장하지 않은 변경 사항', `"${name}"에 저장하지 않은 내용이 있습니다. 저장할까요?`, [
    { value: 'cancel', label: '취소' },
    { value: 'discard', label: '저장 안 함', cls: 'danger' },
    { value: 'save', label: '저장', cls: 'primary' },
  ]);
  if (choice === 'save') return save();
  if (choice === 'discard') {
    store.clearDraft(draftKey());
    log.info('변경 사항을 저장하지 않고 닫았습니다', { name });
    return true;
  }
  return false;
}

// restoreDraft: 'ask' = 임시본이 있으면 복구 여부를 묻는다, 'auto' = 묻지 않고 복구 (앱 시작 시 새 문서)
async function loadDoc({ text, file = null, lastModified = 0, fallbackName = null, restoreDraft = 'ask' }) {
  scheduleDraft.cancel();
  scheduleAutosave.cancel();
  state.file = file;
  state.fallbackName = fallbackName;
  state.savedText = text;
  state.lastModified = lastModified;
  state.externalWarned = 0;
  delete $('#st-save').dataset.savedAt;
  editor.setValue(text);

  // 저장하지 못한 임시본이 남아 있으면 복구를 제안한다.
  const draft = store.loadDraft(draftKey());
  if (draft && draft.text !== text && draft.at > lastModified && restoreDraft === 'auto') {
    editor.setValue(draft.text, { keepHistory: true });
    toast('지난번에 저장하지 않은 내용을 복구했습니다');
    log.info('임시본 자동 복구', { key: draftKey(), chars: draft.text.length });
  } else if (draft && draft.text !== text && draft.at > lastModified) {
    const choice = await askChoice(
      '저장하지 못한 내용이 있습니다',
      `이 문서에 ${new Date(draft.at).toLocaleString('ko-KR')}에 작성하고 저장하지 못한 내용이 남아 있습니다. 복구할까요?`,
      [
        { value: 'discard', label: '버리기', cls: 'danger' },
        { value: 'restore', label: '복구', cls: 'primary' },
      ],
    );
    if (choice === 'restore') {
      editor.setValue(draft.text, { keepHistory: true });
      log.info('임시본을 복구했습니다', { key: draftKey() });
    } else {
      store.clearDraft(draftKey());
    }
  }
  if (file?.fromFolder) {
    state.settings.lastFile = file.path;
    store.saveSettings(state.settings);
  }
  updateTitleAndStatus();
  updateStorageStatus();
  renderFileList();
  renderPreview();
  log.info(`문서 열기: ${file?.path || fallbackName || '새 문서'}`, { chars: text.length });
}

async function newDoc() {
  if (!(await confirmLeave())) return;
  store.clearDraft('untitled');
  await loadDoc({ text: '' });
  editor.focus();
}

async function newInFolder() {
  if (!state.folder) return newDoc();
  if (!(await confirmLeave())) return;
  const name = await askName('새 문서.md', `"${state.folder.name}" 폴더에 새 파일을 만듭니다.`);
  if (!name) return;
  try {
    const handle = await store.createFileInFolder(state.folder, name);
    await store.writeHandle(handle, '');
    await refreshFolder();
    const r = await store.readHandle(handle);
    await loadDoc({ text: r.text, lastModified: r.lastModified, file: { handle, path: handle.name, name: handle.name, fromFolder: true } });
    editor.focus();
  } catch (e) {
    log.error('새 파일 만들기 실패', e);
    toast(`새 파일을 만들지 못했습니다: ${e.message}`, 'error');
  }
}

async function openFile() {
  if (!(await confirmLeave())) return;
  try {
    const r = await store.pickFileToOpen();
    if (r.handle) {
      await loadDoc({ text: r.text, lastModified: r.lastModified, file: { handle: r.handle, path: r.name, name: r.name, fromFolder: false } });
    } else {
      await loadDoc({ text: r.text, lastModified: r.lastModified, fallbackName: r.name });
    }
  } catch (e) {
    if (e?.name === 'AbortError') return;
    log.error('파일 열기 실패', e);
    toast(`파일을 열지 못했습니다: ${e.message}`, 'error');
  }
}

async function openEntry(entry) {
  if (state.file?.fromFolder && state.file.path === entry.path) return;
  if (!(await confirmLeave())) return;
  try {
    const r = await store.readHandle(entry.handle);
    await loadDoc({ text: r.text, lastModified: r.lastModified, file: { handle: entry.handle, path: entry.path, name: entry.name, fromFolder: true } });
  } catch (e) {
    log.error(`파일 열기 실패: ${entry.path}`, e);
    toast(`파일을 열지 못했습니다: ${e.message}`, 'error');
    await refreshFolder();
  }
}

// 맥 앱: Finder에서 연 파일, 끌어다 놓은 파일을 실제 경로로 연다.
async function openNativePath(path, { dropped = false } = {}) {
  if (!path) return;
  if (dropped && !(await store.native.allowDropped(path))) return toast('.md 또는 .txt 파일만 열 수 있습니다', 'warn');
  const handle = new store.NativeFileHandle(path);
  const inFolder = state.folder?.path && path.startsWith(`${state.folder.path}/`);
  const rel = inFolder ? path.slice(state.folder.path.length + 1) : handle.name;
  try {
    const r = await store.readHandle(handle);
    await loadDoc({ text: r.text, lastModified: r.lastModified, file: { handle, path: rel, name: handle.name, fromFolder: !!inFolder } });
  } catch (e) {
    log.error(`파일 열기 실패: ${path}`, e);
    toast(`파일을 열지 못했습니다: ${e.message}`, 'error');
  }
}

// ---------------------------------------------------------------------------
// 폴더
// ---------------------------------------------------------------------------

async function setFolder(dir, { openLast = false } = {}) {
  state.folder = dir;
  $('#btn-reconnect').hidden = true;
  await refreshFolder();
  updateStorageStatus();
  if (openLast && state.settings.lastFile && !isDirty()) {
    const entry = state.files.find((f) => f.path === state.settings.lastFile);
    if (entry) await openEntry(entry);
  }
}

async function refreshFolder() {
  if (!state.folder) return;
  try {
    state.files = await store.listMarkdownFiles(state.folder);
  } catch (e) {
    log.error('폴더 목록을 읽지 못했습니다', e);
    toast(`폴더를 읽지 못했습니다: ${e.message}`, 'error');
    state.files = [];
  }
  renderFileList();
}

async function openFolder() {
  if (!store.fsSupported) {
    toast('이 브라우저는 폴더 열기를 지원하지 않습니다. Chrome, Arc, Edge에서 열어 주세요.', 'warn', 5000);
    return;
  }
  try {
    const dir = await store.pickFolder();
    if (state.file?.fromFolder && !(await confirmLeave())) return;
    if (state.file?.fromFolder) await loadDoc({ text: '' });
    await setFolder(dir);
    toast(`"${dir.name}" 폴더를 열었습니다`);
  } catch (e) {
    if (e?.name === 'AbortError') return;
    log.error('폴더 열기 실패', e);
    toast(`폴더를 열지 못했습니다: ${e.message}`, 'error');
  }
}

async function reconnectFolder() {
  const dir = await store.getRememberedFolder();
  if (!dir) return;
  try {
    if (await store.ensurePermission(dir, true)) await setFolder(dir, { openLast: true });
    else toast('폴더 접근을 허용해야 파일을 열 수 있습니다', 'warn');
  } catch (e) {
    log.error('지난 폴더 다시 열기 실패', e);
    toast('지난 폴더를 찾지 못했습니다. 폴더를 다시 선택해 주세요.', 'warn');
    await store.forgetFolder();
    $('#btn-reconnect').hidden = true;
  }
}

async function closeFolder() {
  if (state.file?.fromFolder && !(await confirmLeave())) return;
  const name = state.folder?.name;
  state.folder = null;
  state.files = [];
  await store.forgetFolder();
  if (state.file?.fromFolder) await loadDoc({ text: '' });
  renderFileList();
  updateStorageStatus();
  log.info(`폴더 닫기: ${name}`);
}

function renderFileList() {
  const hasFolder = !!state.folder;
  $('#folder-name').textContent = hasFolder ? state.folder.name : '폴더 없음';
  $('#sidebar-empty').hidden = hasFolder;
  $('#sidebar-foot').hidden = !hasFolder;
  $('#file-filter').hidden = !hasFolder || state.files.length < 8;
  $('#btn-new-in-folder').hidden = !hasFolder;
  $('#btn-refresh').hidden = !hasFolder;
  const list = $('#file-list');
  if (!hasFolder) return list.replaceChildren();
  const q = $('#file-filter').value.trim().toLowerCase();
  const items = state.files.filter((f) => !q || f.path.toLowerCase().includes(q));
  if (!items.length) {
    const li = document.createElement('li');
    li.className = 'muted';
    li.textContent = q ? '검색 결과가 없습니다' : '마크다운 파일이 없습니다. ＋로 새로 만드세요.';
    li.style.cursor = 'default';
    li.style.color = 'var(--muted)';
    return list.replaceChildren(li);
  }
  list.replaceChildren(
    ...items.map((f) => {
      const li = document.createElement('li');
      li.title = f.path;
      if (state.file?.fromFolder && state.file.path === f.path) li.classList.add('active');
      const name = document.createElement('span');
      name.className = 'fname';
      name.textContent = f.name.replace(/\.md$/i, '');
      li.appendChild(name);
      const dir = f.path.slice(0, -f.name.length).replace(/\/$/, '');
      if (dir) {
        const d = document.createElement('span');
        d.className = 'fdir';
        d.textContent = dir;
        li.appendChild(d);
      }
      li.addEventListener('click', () => openEntry(f));
      return li;
    }),
  );
}

// 다른 앱(예: Claude, VS Code)에서 파일이 바뀌었는지 창으로 돌아올 때 확인
async function checkExternalChange() {
  const handle = state.file?.handle;
  if (!handle || state.saving) return;
  try {
    if (!(await store.ensurePermission(handle, false))) return;
    const f = await handle.getFile();
    if (f.lastModified <= state.lastModified + 1 || f.lastModified === state.externalWarned) return;
    if (!isDirty()) {
      const text = await f.text();
      state.savedText = text;
      state.lastModified = f.lastModified;
      editor.setValue(text, { keepHistory: true });
      updateTitleAndStatus();
      renderPreview();
      toast('다른 앱에서 바뀐 내용을 불러왔습니다');
      log.info('외부 변경 감지 → 다시 불러옴', { file: state.file.name });
    } else {
      state.externalWarned = f.lastModified;
      toast('이 파일이 다른 곳에서도 바뀌었습니다. 저장하면 지금 화면의 내용으로 덮어씁니다.', 'warn', 6000);
      log.warn('외부 변경 감지 (편집 중이라 불러오지 않음)', { file: state.file.name });
    }
  } catch (e) {
    log.warn('외부 변경 확인 실패', e);
  }
}

// ---------------------------------------------------------------------------
// 복사 / 내보내기
// ---------------------------------------------------------------------------

function copySource() {
  const sel = editor.view.state.selection.main;
  if (!sel.empty) return { md: editor.view.state.sliceDoc(sel.from, sel.to), partial: true };
  return { md: editor.getValue(), partial: false };
}

const COPY_MESSAGES = {
  slack: 'Slack용으로 복사했습니다. Slack 입력창에 붙여넣으세요.',
  rich: '서식을 포함해 복사했습니다. Google Docs, Word, 메일에 붙여넣으세요.',
  plain: '텍스트로 복사했습니다.',
  md: '마크다운 원문을 복사했습니다.',
};

async function copy(kind) {
  const { md, partial } = copySource();
  if (!md.trim()) return toast('복사할 내용이 없습니다', 'warn');
  const opts = renderOpts();
  try {
    let payload;
    if (kind === 'slack') payload = { html: sanitize(toSlackHtml(md, opts)), text: toPlainText(md, opts) };
    else if (kind === 'rich') payload = { html: toRichCopyHtml(md, opts), text: toPlainText(md, opts) };
    else if (kind === 'plain') payload = { html: null, text: toPlainText(md, opts) };
    else payload = { html: null, text: md };
    const method = await writeClipboard(payload);
    toast(COPY_MESSAGES[kind] + (partial ? ' (선택한 부분만)' : ''));
    log.info(`복사: ${kind}`, { partial, chars: md.length, method, tableMode: opts.tableMode });
  } catch (e) {
    log.error(`복사 실패: ${kind}`, e);
    toast(`복사하지 못했습니다: ${e.message}`, 'error');
  }
}

function openExport(mode) {
  const dlg = $('#dlg-export');
  const md = editor.getValue();
  if (!md.trim()) return toast('내보낼 내용이 없습니다', 'warn');
  $('#export-title').textContent = mode === 'pdf' ? 'PDF로 저장' : 'HTML 보고서로 저장';
  $('#export-ok').textContent = mode === 'pdf' && !store.isNative ? '인쇄 창 열기' : '저장';
  $('#export-name').value = extractTitle(md) || docBaseName() || '보고서';
  dlg.returnValue = '';
  dlg.addEventListener(
    'close',
    async () => {
      const action = dlg.returnValue;
      if (action !== 'ok' && action !== 'preview') return;
      const title = $('#export-name').value.trim() || '보고서';
      try {
        const html = buildReportHtml(md, {
          title,
          includeToc: $('#export-toc').checked,
          includeDate: $('#export-date').checked,
          renderOpts: renderOpts(),
        });
        if (action === 'preview') {
          const url = URL.createObjectURL(new Blob([html], { type: 'text/html' }));
          window.open(url, '_blank');
          setTimeout(() => URL.revokeObjectURL(url), 60_000);
          log.info('보고서 미리보기 창 열기');
        } else if (mode === 'pdf' && store.isNative) {
          const r = await store.native.exportPdf(html, cleanFileName(title, '.pdf').replace(/\.html$/, '.pdf'));
          if (r) {
            toast(`"${r.name}"으로 저장했습니다`);
            log.info('PDF 저장', { name: r.name });
          }
        } else if (mode === 'pdf') {
          await printHtml(html);
          toast('인쇄 창에서 왼쪽 아래 "PDF"를 눌러 "PDF로 저장"을 고르세요.', 'info', 6000);
        } else {
          const r = await store.saveWithPicker(cleanFileName(title, '.html'), html, 'html');
          toast(r.handle ? `"${r.handle.name}"으로 저장했습니다` : 'HTML 보고서를 다운로드했습니다');
          log.info('HTML 보고서 저장', { bytes: html.length });
        }
      } catch (e) {
        if (e?.name === 'AbortError') return;
        log.error('내보내기 실패', e);
        toast(`내보내지 못했습니다: ${e.message}`, 'error');
      }
    },
    { once: true },
  );
  dlg.showModal();
  $('#export-name').select();
}

// ---------------------------------------------------------------------------
// 설정
// ---------------------------------------------------------------------------

function applySettings() {
  const s = state.settings;
  const root = document.documentElement;
  if (s.theme === 'system') root.removeAttribute('data-theme');
  else root.dataset.theme = s.theme;
  root.style.setProperty('--editor-font', s.editorFont === 'mono' ? 'var(--mono)' : 'var(--ui-font)');
  root.style.setProperty('--editor-font-size', `${s.editorFontSize}px`);
  $('#table-mode').value = s.tableMode;
  $('#app').classList.toggle('no-sidebar', !s.sidebar);
  editor?.setWrap(s.lineWrap);
  editor?.view.requestMeasure();
}

function openSettings() {
  $$('[data-setting]').forEach((el) => {
    const v = state.settings[el.dataset.setting];
    if (el.type === 'checkbox') el.checked = !!v;
    else el.value = String(v);
  });
  $('#dlg-settings').showModal();
}

function changeSetting(key, value) {
  state.settings[key] = value;
  store.saveSettings(state.settings);
  applySettings();
  renderPreview();
  updateTitleAndStatus();
  log.info(`설정 변경: ${key} = ${value}`);
}

// ---------------------------------------------------------------------------
// 로그 창
// ---------------------------------------------------------------------------

let errorCount = 0;

function renderLogs() {
  const showDebug = $('#log-debug').checked;
  const list = $('#log-list');
  const items = getEntries().filter((e) => showDebug || e.level !== 'debug');
  list.replaceChildren(
    ...items.slice(-400).map((e) => {
      const li = document.createElement('li');
      li.className = e.level;
      li.textContent = formatEntries([e]);
      return li;
    }),
  );
  list.scrollTop = list.scrollHeight;
}

// ---------------------------------------------------------------------------
// 스크롤 맞추기
// ---------------------------------------------------------------------------

function setupScrollSync() {
  const a = editor.view.scrollDOM;
  const b = $('#preview-scroll');
  let source = null;
  let release;
  const sync = (from, to, who) => {
    if (!state.settings.syncScroll || state.settings.view !== 'split') return;
    if (source && source !== who) return;
    source = who;
    clearTimeout(release);
    release = setTimeout(() => (source = null), 80);
    const max = from.scrollHeight - from.clientHeight;
    const ratio = max > 0 ? from.scrollTop / max : 0;
    to.scrollTop = ratio * (to.scrollHeight - to.clientHeight);
  };
  a.addEventListener('scroll', () => sync(a, b, 'editor'), { passive: true });
  b.addEventListener('scroll', () => sync(b, a, 'preview'), { passive: true });
}

// ---------------------------------------------------------------------------
// 끌어다 놓기
// ---------------------------------------------------------------------------

function setupDragDrop() {
  const overlay = $('#drop-overlay');
  let depth = 0;
  const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes('Files');
  window.addEventListener('dragenter', (e) => {
    if (!hasFiles(e)) return;
    depth++;
    overlay.hidden = false;
  });
  window.addEventListener('dragleave', () => {
    depth = Math.max(0, depth - 1);
    if (!depth) overlay.hidden = true;
  });
  window.addEventListener(
    'dragover',
    (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      e.stopPropagation();
    },
    true,
  );
  window.addEventListener(
    'drop',
    async (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      e.stopPropagation();
      depth = 0;
      overlay.hidden = true;
      const item = [...e.dataTransfer.items].find((i) => i.kind === 'file');
      if (!item) return;
      const handlePromise = item.getAsFileSystemHandle ? item.getAsFileSystemHandle() : null;
      const file = item.getAsFile();
      if (!file || !store.MD_EXT.test(file.name)) return toast('.md 또는 .txt 파일만 열 수 있습니다', 'warn');
      if (!(await confirmLeave())) return;
      try {
        if (store.isNative) {
          await openNativePath(store.native.getPathForFile(file), { dropped: true });
          return;
        }
        const handle = handlePromise ? await handlePromise : null;
        const text = await file.text();
        if (handle?.kind === 'file') {
          await loadDoc({ text, lastModified: file.lastModified, file: { handle, path: file.name, name: file.name, fromFolder: false } });
        } else {
          await loadDoc({ text, lastModified: file.lastModified, fallbackName: file.name });
        }
      } catch (err) {
        log.error('끌어다 놓은 파일 열기 실패', err);
        toast(`파일을 열지 못했습니다: ${err.message}`, 'error');
      }
    },
    true,
  );
}

// ---------------------------------------------------------------------------
// 이벤트 연결
// ---------------------------------------------------------------------------

const ACTIONS = {
  new: newDoc,
  open: openFile,
  save: () => save(),
  saveAs: () => save({ forceNew: true }),
  openFolder,
  reconnectFolder,
  closeFolder,
  refreshFolder,
  newInFolder,
  copySlack: () => copy('slack'),
  copyRich: () => copy('rich'),
  copyPlain: () => copy('plain'),
  copyMd: () => copy('md'),
  exportHtml: () => openExport('html'),
  exportPdf: () => openExport('pdf'),
  downloadMd: async () => {
    if (!store.isNative) return store.download(suggestName(), editor.getValue(), 'text/markdown');
    // 앱에서는 현재 문서는 그대로 두고 사본만 저장한다.
    try {
      const r = await store.saveWithPicker(suggestName(), editor.getValue(), 'md');
      toast(`사본을 "${r.handle.name}"으로 저장했습니다`);
    } catch (e) {
      if (e?.name !== 'AbortError') toast(`저장하지 못했습니다: ${e.message}`, 'error');
    }
  },
  viewEdit: () => setView('edit'),
  viewSplit: () => setView('split'),
  viewPreview: () => setView('preview'),
  cycleView: () => {
    const order = ['edit', 'split', 'preview'];
    setView(order[(order.indexOf(state.settings.view) + 1) % order.length]);
  },
  toggleSidebar: () => changeSetting('sidebar', !state.settings.sidebar),
  settings: openSettings,
  help: () => $('#dlg-help').showModal(),
  logs: () => {
    renderLogs();
    $('#dlg-log').showModal();
  },
  async loadSample() {
    $('#dlg-help').close();
    if (!(await confirmLeave())) return;
    await loadDoc({ text: SAMPLE_DOC });
  },
};

function wireUi() {
  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-action]');
    if (!el) return;
    const fn = ACTIONS[el.dataset.action];
    if (!fn) return log.warn(`알 수 없는 동작: ${el.dataset.action}`);
    $('#menu-export').hidden = true;
    Promise.resolve(fn()).catch((err) => log.error(`동작 실패: ${el.dataset.action}`, err));
  });

  $$('[data-cmd]').forEach((b) => b.addEventListener('click', () => editor.run(b.dataset.cmd)));
  $$('[data-view-btn]').forEach((b) => b.addEventListener('click', () => setView(b.dataset.viewBtn)));
  $$('.preview-tabs [data-tab]').forEach((b) => b.addEventListener('click', () => setPreviewTab(b.dataset.tab)));
  $('#table-mode').addEventListener('change', (e) => changeSetting('tableMode', e.target.value));
  $('#file-filter').addEventListener('input', renderFileList);

  $('#btn-sidebar').addEventListener('click', () => changeSetting('sidebar', !state.settings.sidebar));

  const exportBtn = $('#btn-export');
  exportBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    const menu = $('#menu-export');
    menu.hidden = !menu.hidden;
    exportBtn.setAttribute('aria-expanded', String(!menu.hidden));
  });
  document.addEventListener('click', (e) => {
    if (!e.target.closest('.menu-wrap')) $('#menu-export').hidden = true;
  });

  $$('[data-setting]').forEach((el) => {
    el.addEventListener('change', () => changeSetting(el.dataset.setting, el.type === 'checkbox' ? el.checked : el.value));
  });

  // 이름 입력창에서 Enter = 확인 (폼의 첫 버튼인 '취소'가 눌리지 않도록)
  $('#name-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.isComposing) {
      e.preventDefault();
      $('#dlg-name').close('ok');
    }
  });
  $('#export-name').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.isComposing) {
      e.preventDefault();
      $('#dlg-export').close('ok');
    }
  });

  $('#log-debug').addEventListener('change', renderLogs);
  $('#log-copy').addEventListener('click', async () => {
    try {
      await writeClipboard({ html: null, text: `MD Studio ${VERSION} / ${navigator.userAgent}\n${formatEntries()}` });
      toast('로그를 복사했습니다');
    } catch (e) {
      toast(`로그를 복사하지 못했습니다: ${e.message}`, 'error');
    }
  });
  $('#log-clear').addEventListener('click', () => {
    clearEntries();
    errorCount = 0;
    $('#st-log').classList.remove('has-error');
    $('#st-log').textContent = '로그';
    renderLogs();
  });
  onLog((entry) => {
    if (entry.level === 'error') {
      errorCount++;
      $('#st-log').classList.add('has-error');
      $('#st-log').textContent = `로그 (오류 ${errorCount})`;
    }
    if ($('#dlg-log').open) renderLogs();
  });

  window.addEventListener('keydown', (e) => {
    if (e.defaultPrevented || e.isComposing) return;
    const mod = e.metaKey || e.ctrlKey;
    if (!mod) return;
    const k = e.key.toLowerCase();
    if (k === 's') {
      e.preventDefault();
      save({ forceNew: e.shiftKey });
    } else if (k === 'o') {
      e.preventDefault();
      openFile();
    } else if (k === '\\') {
      e.preventDefault();
      const order = ['edit', 'split', 'preview'];
      setView(order[(order.indexOf(state.settings.view) + 1) % order.length]);
    } else if (k === '/') {
      e.preventDefault();
      $('#dlg-help').showModal();
    }
  });

  window.addEventListener('beforeunload', (e) => {
    if (isDirty()) {
      scheduleDraft.flush();
      e.preventDefault();
      e.returnValue = '';
    }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') {
      if (isDirty()) scheduleDraft.flush();
    } else {
      checkExternalChange();
    }
  });
  window.addEventListener('focus', checkExternalChange);
}

// ---------------------------------------------------------------------------
// 시작
// ---------------------------------------------------------------------------

async function init() {
  installGlobalHandlers();
  log.info(`MD Studio ${VERSION} 시작`, { fileSystemAccess: store.fsSupported, protocol: location.protocol, ua: navigator.userAgent });
  state.settings = store.loadSettings(DEFAULT_SETTINGS);

  editor = createEditor($('#editor'), {
    doc: '',
    onChange: onEditorChange,
    onSave: () => save(),
    getPasteConversion: () => state.settings.pasteConvert,
  });
  applySettings();
  wireUi();
  setupScrollSync();
  setupDragDrop();
  setView(state.settings.view);
  setPreviewTab(state.settings.previewTab);
  $('#fs-unsupported').hidden = store.fsSupported;
  if (!store.fsSupported) $('[data-action="openFolder"].primary').hidden = true;

  // 첫 문서: 저장 못 한 새 문서 임시본 → 처음 실행이면 예제 → 빈 문서
  const draft = store.loadDraft('untitled');
  if (draft?.text) {
    await loadDoc({ text: '', restoreDraft: 'auto' });
  } else if (!state.settings.welcomed) {
    state.settings.welcomed = true;
    store.saveSettings(state.settings);
    await loadDoc({ text: SAMPLE_DOC });
  } else {
    await loadDoc({ text: '' });
  }

  // 지난번에 연 폴더: 권한이 살아 있으면 바로 열고, 아니면 다시 열기 버튼을 보여준다.
  const remembered = await store.getRememberedFolder();
  if (remembered) {
    try {
      if (await store.ensurePermission(remembered, false)) {
        await setFolder(remembered, { openLast: !draft?.text });
      } else {
        const btn = $('#btn-reconnect');
        btn.hidden = false;
        btn.textContent = `"${remembered.name}" 폴더 다시 열기`;
      }
    } catch (e) {
      log.warn('기억된 폴더 확인 실패', e);
    }
  }
  if (store.isNative) await connectNative();
  updateStorageStatus();
  editor.focus();
}

// 맥 앱: 메뉴 막대 명령과 Finder에서 연 파일을 받는다.
async function connectNative() {
  document.documentElement.classList.add('native');
  store.native.onMenu((action) => {
    const fn = ACTIONS[action];
    if (!fn) return log.warn(`알 수 없는 메뉴 명령: ${action}`);
    log.debug(`메뉴: ${action}`);
    for (const d of $$('dialog[open]')) d.close();
    Promise.resolve(fn()).catch((e) => log.error(`메뉴 실행 실패: ${action}`, e));
  });
  const openFromFinder = async (path) => {
    if (!(await confirmLeave())) return;
    await openNativePath(path);
  };
  store.native.onOpenFile(openFromFinder);
  const pending = await store.native.takePendingFiles();
  if (pending.length) await openFromFinder(pending.at(-1));
  const info = await store.native.info();
  log.info('맥 앱 모드', info);
}

init().catch((e) => {
  log.error('시작 중 오류', e);
  toast(`시작 중 오류가 발생했습니다: ${e.message}`, 'error', 8000);
});
