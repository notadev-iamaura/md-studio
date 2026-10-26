// 로컬 파일 저장소.
// 맥 앱(Electron): preload가 공개한 window.mdNative로 맥의 파일 시스템에 직접 읽고 쓴다.
// Chrome/Edge/Arc: File System Access API로 사용자가 고른 폴더에 직접 읽고 쓴다.
// Safari/Firefox: 파일 열기는 <input type=file>, 저장은 다운로드로 대체한다.
// 작성 중인 내용은 항상 브라우저 저장소에 임시본(draft)으로도 남겨 갑작스러운 종료에 대비한다.
import { createLogger } from './logger.js';

const log = createLogger('storage');

export const MD_EXT = /\.(md|markdown|mdown|mkd|txt)$/i;
const SKIP_DIRS = new Set(['node_modules', '.git', '.obsidian', '.trash', '.Trash']);
const MAX_DEPTH = 4;
const MAX_FILES = 2000;

export const native = typeof window !== 'undefined' ? window.mdNative || null : null;
export const isNative = !!native;
export const fsSupported = isNative || (typeof window !== 'undefined' && 'showDirectoryPicker' in window);
export const savePickerSupported = isNative || (typeof window !== 'undefined' && 'showSaveFilePicker' in window);

// ---------------------------------------------------------------------------
// 맥 앱용 핸들: 맥의 파일/폴더를 File System Access API 핸들과 같은 모양으로 감싼다.
// 덕분에 아래의 목록/읽기/쓰기/새 파일 코드를 브라우저와 앱이 함께 쓴다.
// ---------------------------------------------------------------------------
const joinPath = (dir, name) => `${dir.replace(/\/+$/, '')}/${name}`;
const baseName = (p) => p.split('/').filter(Boolean).pop() || p;

export class NativeFileHandle {
  constructor(path) {
    this.kind = 'file';
    this.path = path;
    this.name = baseName(path);
  }
  async getFile() {
    const r = await native.read(this.path);
    return { name: this.name, lastModified: r.lastModified, size: r.size, text: async () => r.text };
  }
  async createWritable() {
    let buf = '';
    return {
      write: async (chunk) => {
        buf += chunk;
      },
      close: async () => {
        await native.write(this.path, buf);
      },
    };
  }
  async queryPermission() {
    return 'granted';
  }
  async requestPermission() {
    return 'granted';
  }
}

export class NativeDirHandle {
  constructor(path, name) {
    this.kind = 'directory';
    this.path = path;
    this.name = name || baseName(path);
  }
  async *values() {
    for (const e of await native.list(this.path)) {
      const p = joinPath(this.path, e.name);
      yield e.kind === 'directory' ? new NativeDirHandle(p) : new NativeFileHandle(p);
    }
  }
  async getFileHandle(name, { create = false } = {}) {
    const p = joinPath(this.path, name);
    const st = await native.stat(p);
    if (st && st.kind === 'directory') throw new DOMException(`${name}은(는) 폴더입니다`, 'TypeMismatchError');
    if (st) return new NativeFileHandle(p);
    if (!create) throw new DOMException(`${name} 없음`, 'NotFoundError');
    const r = await native.create(this.path, name);
    if (r?.error === 'EEXIST') return new NativeFileHandle(p);
    return new NativeFileHandle(r.path);
  }
  async queryPermission() {
    return 'granted';
  }
  async requestPermission() {
    return 'granted';
  }
}

const abort = () => new DOMException('사용자가 취소했습니다', 'AbortError');

// ---------------------------------------------------------------------------
// IndexedDB: 폴더 핸들을 기억해 다음 실행 때 다시 열 수 있게 한다.
// ---------------------------------------------------------------------------
const DB_NAME = 'md-studio';
const STORE = 'handles';

function idb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

// 트랜잭션 하나를 실행하고 연결을 닫는다. (연결을 열어 두면 DB 정리/업그레이드가 막힌다)
async function idbRun(mode, fn) {
  const db = await idb();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, mode);
      const req = fn(tx.objectStore(STORE));
      tx.oncomplete = () => resolve(req?.result);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  } finally {
    db.close();
  }
}

const idbSet = (key, value) => idbRun('readwrite', (s) => s.put(value, key));
const idbGet = (key) => idbRun('readonly', (s) => s.get(key));
const idbDelete = (key) => idbRun('readwrite', (s) => s.delete(key));

// ---------------------------------------------------------------------------
// 폴더
// ---------------------------------------------------------------------------

export async function pickFolder() {
  if (isNative) {
    const r = await native.pickFolder();
    if (!r) throw abort();
    log.info(`폴더 열기: ${r.name}`);
    return new NativeDirHandle(r.path, r.name);
  }
  const dir = await window.showDirectoryPicker({ id: 'md-studio', mode: 'readwrite' });
  try {
    await idbSet('folder', dir);
  } catch (e) {
    log.warn('폴더 정보를 기억하지 못했습니다 (다음 실행 때 다시 선택 필요)', e);
  }
  log.info(`폴더 열기: ${dir.name}`);
  return dir;
}

export async function getRememberedFolder() {
  if (isNative) {
    const r = await native.lastFolder();
    return r ? new NativeDirHandle(r.path, r.name) : null;
  }
  if (!fsSupported) return null;
  try {
    return (await idbGet('folder')) || null;
  } catch (e) {
    log.warn('기억된 폴더를 불러오지 못했습니다', e);
    return null;
  }
}

export async function forgetFolder() {
  if (isNative) return native.forgetFolder();
  try {
    await idbDelete('folder');
  } catch (e) {
    log.warn('기억된 폴더 삭제 실패', e);
  }
}

// 권한이 이미 있으면 true. ask=true면 사용자 클릭 이벤트 안에서 권한을 요청한다.
export async function ensurePermission(handle, ask = false) {
  const opts = { mode: 'readwrite' };
  if ((await handle.queryPermission(opts)) === 'granted') return true;
  if (!ask) return false;
  const granted = (await handle.requestPermission(opts)) === 'granted';
  log.info(`폴더 권한 요청 결과: ${granted ? '허용' : '거부'}`, { folder: handle.name });
  return granted;
}

export async function listMarkdownFiles(dir) {
  const done = log.time('파일 목록 읽기');
  const out = [];
  async function walk(handle, prefix, depth) {
    for await (const entry of handle.values()) {
      if (out.length >= MAX_FILES) return;
      if (entry.name.startsWith('.')) continue;
      if (entry.kind === 'directory') {
        if (depth < MAX_DEPTH && !SKIP_DIRS.has(entry.name)) await walk(entry, `${prefix}${entry.name}/`, depth + 1);
      } else if (MD_EXT.test(entry.name)) {
        out.push({ path: `${prefix}${entry.name}`, name: entry.name, handle: entry, parent: handle });
      }
    }
  }
  await walk(dir, '', 0);
  out.sort((a, b) => a.path.localeCompare(b.path, 'ko'));
  if (out.length >= MAX_FILES) log.warn(`파일이 너무 많아 처음 ${MAX_FILES}개만 표시합니다`);
  done({ count: out.length });
  return out;
}

export async function createFileInFolder(dir, name) {
  // 같은 이름이 있으면 덮어쓰지 않도록 번호를 붙인다.
  const base = name.replace(MD_EXT, '');
  const ext = (name.match(MD_EXT) || ['.md'])[0];
  let candidate = `${base}${ext}`;
  for (let i = 2; i < 1000; i++) {
    try {
      await dir.getFileHandle(candidate);
      candidate = `${base} ${i}${ext}`;
    } catch (e) {
      if (e.name === 'NotFoundError') break;
      throw e;
    }
  }
  const handle = await dir.getFileHandle(candidate, { create: true });
  log.info(`새 파일 생성: ${candidate}`);
  return handle;
}

// ---------------------------------------------------------------------------
// 파일
// ---------------------------------------------------------------------------

export async function readHandle(handle) {
  const file = await handle.getFile();
  return { text: await file.text(), lastModified: file.lastModified, name: file.name };
}

export async function writeHandle(handle, text) {
  const writable = await handle.createWritable();
  try {
    await writable.write(text);
  } finally {
    await writable.close();
  }
  const file = await handle.getFile();
  log.info(`저장 완료: ${handle.name}`, { bytes: file.size });
  return file.lastModified;
}

export async function pickFileToOpen() {
  if (isNative) {
    const r = await native.openDialog();
    if (!r) throw abort();
    const handle = new NativeFileHandle(r.path);
    return { ...(await readHandle(handle)), handle };
  }
  if ('showOpenFilePicker' in window) {
    const [handle] = await window.showOpenFilePicker({
      id: 'md-studio-open',
      types: [{ description: 'Markdown', accept: { 'text/markdown': ['.md', '.markdown', '.txt'] } }],
    });
    const r = await readHandle(handle);
    return { ...r, handle };
  }
  // 대체 경로: 파일 선택창
  return new Promise((resolve, reject) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.md,.markdown,.txt,text/markdown,text/plain';
    input.onchange = async () => {
      const f = input.files?.[0];
      if (!f) return reject(new DOMException('취소됨', 'AbortError'));
      resolve({ text: await f.text(), lastModified: f.lastModified, name: f.name, handle: null });
    };
    input.click();
  });
}

export async function saveWithPicker(suggestedName, text, kind = 'md') {
  const types =
    kind === 'html'
      ? [{ description: 'HTML 문서', accept: { 'text/html': ['.html'] } }]
      : [{ description: 'Markdown', accept: { 'text/markdown': ['.md'] } }];
  if (isNative) {
    const r = await native.saveDialog(suggestedName, kind);
    if (!r) throw abort();
    const handle = new NativeFileHandle(r.path);
    const lastModified = await writeHandle(handle, text);
    return { handle, lastModified };
  }
  if (savePickerSupported) {
    const handle = await window.showSaveFilePicker({ id: `md-studio-save-${kind}`, suggestedName, types });
    const lastModified = await writeHandle(handle, text);
    return { handle, lastModified };
  }
  download(suggestedName, text, kind === 'html' ? 'text/html' : 'text/markdown');
  return { handle: null, lastModified: Date.now() };
}

export function download(name, text, mime = 'text/plain') {
  const blob = new Blob([text], { type: `${mime};charset=utf-8` });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
  log.info(`다운로드로 저장: ${name}`, { bytes: blob.size });
}

// ---------------------------------------------------------------------------
// 임시본 / 설정 (localStorage는 사생활 보호 모드 등에서 실패할 수 있어 모두 감싼다)
// ---------------------------------------------------------------------------

const DRAFT_PREFIX = 'md-studio:draft:';
const SETTINGS_KEY = 'md-studio:settings';

export function saveDraft(key, text) {
  try {
    localStorage.setItem(DRAFT_PREFIX + key, JSON.stringify({ text, at: Date.now() }));
  } catch (e) {
    log.warn('임시본 저장 실패', e);
  }
}

export function loadDraft(key) {
  try {
    const raw = localStorage.getItem(DRAFT_PREFIX + key);
    return raw ? JSON.parse(raw) : null;
  } catch (e) {
    log.warn('임시본 읽기 실패', e);
    return null;
  }
}

export function clearDraft(key) {
  try {
    localStorage.removeItem(DRAFT_PREFIX + key);
  } catch {
    /* 무시 */
  }
}

export function loadSettings(defaults) {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    return { ...defaults, ...(raw ? JSON.parse(raw) : {}) };
  } catch (e) {
    log.warn('설정 읽기 실패, 기본값 사용', e);
    return { ...defaults };
  }
}

export function saveSettings(settings) {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
  } catch (e) {
    log.warn('설정 저장 실패', e);
  }
}
