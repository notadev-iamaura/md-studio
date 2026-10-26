// MD Studio 데스크톱 앱 (Electron 메인 프로세스)
// 화면(렌더러)은 파일 시스템에 직접 접근하지 못하고, preload가 공개한 정해진 요청만 여기로 보낸다.
// 여기서는 사용자가 선택 창으로 직접 고른 폴더·파일 안에서만 읽고 쓴다.
const { app, BrowserWindow, Menu, dialog, ipcMain, clipboard, ClipboardItem, shell, nativeTheme, session } = require('electron');
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const os = require('node:os');

const MD_EXT = /\.(md|markdown|mdown|mkd|txt)$/i;
const RENDERER = path.join(__dirname, '..', 'dist', 'MD-Studio.html');

// ---------------------------------------------------------------------------
// 로그: ~/Library/Logs/MD Studio/main.log
// ---------------------------------------------------------------------------
let logFile = null;
function log(level, message, data) {
  const line = `[${new Date().toISOString()}] ${level.toUpperCase()} ${message}${data === undefined ? '' : ` ${safeJson(data)}`}`;
  (level === 'error' ? console.error : console.log)(line);
  try {
    if (!logFile) {
      fs.mkdirSync(app.getPath('logs'), { recursive: true });
      logFile = path.join(app.getPath('logs'), 'main.log');
      // 로그가 1MB를 넘으면 새로 시작한다
      if (fs.existsSync(logFile) && fs.statSync(logFile).size > 1024 * 1024) fs.renameSync(logFile, `${logFile}.old`);
    }
    fs.appendFileSync(logFile, `${line}\n`);
  } catch {
    /* 로그 실패가 앱을 멈추지 않게 한다 */
  }
}
function safeJson(d) {
  if (d instanceof Error) return `${d.name}: ${d.message}`;
  try {
    return JSON.stringify(d);
  } catch {
    return String(d);
  }
}

// ---------------------------------------------------------------------------
// 설정 (마지막 폴더, 창 크기)
// ---------------------------------------------------------------------------
const configPath = () => path.join(app.getPath('userData'), 'config.json');
let config = {};
function loadConfig() {
  try {
    config = JSON.parse(fs.readFileSync(configPath(), 'utf8'));
  } catch {
    config = {};
  }
}
function saveConfig() {
  try {
    fs.writeFileSync(configPath(), JSON.stringify(config, null, 2));
  } catch (e) {
    log('warn', '설정 저장 실패', e);
  }
}

// ---------------------------------------------------------------------------
// 접근 허용 목록: 사용자가 고른 폴더(하위 포함)와 파일만
// ---------------------------------------------------------------------------
const allowedRoots = new Set();
const allowedFiles = new Set();

function normalize(p) {
  if (typeof p !== 'string' || !path.isAbsolute(p)) throw new Error('잘못된 경로입니다');
  return path.resolve(p);
}
function isAllowed(p) {
  if (allowedFiles.has(p)) return true;
  for (const root of allowedRoots) if (p === root || p.startsWith(root + path.sep)) return true;
  return false;
}
function checked(p) {
  const n = normalize(p);
  if (!isAllowed(n)) {
    log('warn', '허용되지 않은 경로 접근 차단', { path: n });
    throw new Error('이 위치에 접근할 권한이 없습니다. 폴더나 파일을 다시 선택해 주세요.');
  }
  return n;
}

// ---------------------------------------------------------------------------
// 창
// ---------------------------------------------------------------------------
let win = null;
let rendererReady = false;
const pendingOpenFiles = [];

function createWindow() {
  const bounds = config.window || {};
  win = new BrowserWindow({
    width: bounds.width || 1440,
    height: bounds.height || 900,
    x: bounds.x,
    y: bounds.y,
    minWidth: 720,
    minHeight: 480,
    title: 'MD Studio',
    show: false,
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#0f1216' : '#ffffff',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      spellcheck: false,
    },
  });
  if (bounds.maximized) win.maximize();

  win.once('ready-to-show', () => win.show());
  win.webContents.on('did-finish-load', () => {
    rendererReady = true;
    log('info', '화면 로드 완료');
  });

  // 링크는 기본 브라우저로, 보고서 미리보기(blob:)만 새 창으로 연다.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('blob:')) {
      return {
        action: 'allow',
        overrideBrowserWindowOptions: { width: 1000, height: 820, webPreferences: { sandbox: true, contextIsolation: true } },
      };
    }
    if (/^(https?|mailto):/i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e, url) => {
    if (url === win.webContents.getURL()) return;
    e.preventDefault();
    if (/^(https?|mailto):/i.test(url)) shell.openExternal(url);
  });

  // 저장하지 않은 변경 사항이 있을 때 창을 닫으려 하면 확인한다. (화면의 beforeunload가 막은 경우)
  win.webContents.on('will-prevent-unload', (e) => {
    const choice = dialog.showMessageBoxSync(win, {
      type: 'warning',
      buttons: ['저장하지 않고 닫기', '취소'],
      defaultId: 1,
      cancelId: 1,
      message: '저장하지 않은 변경 사항이 있습니다.',
      detail: '그래도 닫으면 내용은 임시본으로 보관되어, 다음에 열 때 복구할 수 있습니다.',
    });
    if (choice === 0) {
      log('info', '저장하지 않은 상태로 닫기 선택');
      e.preventDefault();
    }
  });

  win.webContents.on('render-process-gone', (_e, details) => {
    log('error', '화면 프로세스 종료', details);
    if (details.reason !== 'clean-exit') win.reload();
  });

  win.on('close', () => {
    config.window = { ...win.getNormalBounds(), maximized: win.isMaximized() };
    saveConfig();
  });
  win.on('closed', () => {
    win = null;
    rendererReady = false;
  });

  win.loadFile(RENDERER);
}

function sendToRenderer(channel, ...args) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, ...args);
}

// ---------------------------------------------------------------------------
// IPC: 화면이 요청할 수 있는 작업 목록
// ---------------------------------------------------------------------------
function handle(channel, fn) {
  ipcMain.handle(channel, async (event, ...args) => {
    if (!win || event.sender !== win.webContents) throw new Error('허용되지 않은 요청입니다');
    try {
      return await fn(...args);
    } catch (e) {
      log('error', `${channel} 실패`, e);
      throw e;
    }
  });
}

async function fileInfo(p) {
  const st = await fsp.stat(p);
  return { lastModified: Math.floor(st.mtimeMs), size: st.size, kind: st.isDirectory() ? 'directory' : 'file' };
}

function registerIpc() {
  handle('app:info', () => ({ version: app.getVersion(), platform: process.platform }));

  handle('folder:pick', async () => {
    const r = await dialog.showOpenDialog(win, {
      title: '폴더 열기',
      buttonLabel: '이 폴더 열기',
      properties: ['openDirectory', 'createDirectory'],
      defaultPath: config.lastFolder || app.getPath('documents'),
    });
    if (r.canceled || !r.filePaths[0]) return null;
    const dir = path.resolve(r.filePaths[0]);
    allowedRoots.add(dir);
    config.lastFolder = dir;
    saveConfig();
    log('info', '폴더 열기', { dir });
    return { path: dir, name: path.basename(dir) };
  });

  handle('folder:last', async () => {
    const dir = config.lastFolder;
    if (!dir) return null;
    try {
      if ((await fsp.stat(dir)).isDirectory()) {
        allowedRoots.add(dir);
        return { path: dir, name: path.basename(dir) };
      }
    } catch {
      log('warn', '지난 폴더를 찾을 수 없음', { dir });
    }
    return null;
  });

  handle('folder:forget', () => {
    if (config.lastFolder) allowedRoots.delete(config.lastFolder);
    delete config.lastFolder;
    saveConfig();
  });

  handle('fs:list', async (dir) => {
    const d = checked(dir);
    const entries = await fsp.readdir(d, { withFileTypes: true });
    return entries
      .filter((e) => e.isFile() || e.isDirectory())
      .map((e) => ({ name: e.name, kind: e.isDirectory() ? 'directory' : 'file' }));
  });

  handle('fs:stat', async (p) => {
    try {
      return await fileInfo(checked(p));
    } catch (e) {
      if (e.code === 'ENOENT') return null;
      throw e;
    }
  });

  handle('fs:read', async (p) => {
    const f = checked(p);
    const [text, info] = await Promise.all([fsp.readFile(f, 'utf8'), fileInfo(f)]);
    return { text, ...info };
  });

  // 임시 파일에 먼저 쓰고 바꿔치기한다. 쓰는 도중 앱이 꺼져도 원본이 반쯤 지워지지 않는다.
  handle('fs:write', async (p, text) => {
    const f = checked(p);
    if (typeof text !== 'string') throw new Error('저장할 내용이 올바르지 않습니다');
    const tmp = path.join(path.dirname(f), `.${path.basename(f)}.mdstudio-tmp`);
    await fsp.writeFile(tmp, text, 'utf8');
    await fsp.rename(tmp, f);
    const info = await fileInfo(f);
    log('info', '저장', { file: f, bytes: info.size });
    return info.lastModified;
  });

  handle('fs:create', async (dir, name) => {
    const d = checked(dir);
    if (typeof name !== 'string' || !name || name.includes('/') || name.includes('\\') || name.startsWith('.')) {
      throw new Error('파일 이름이 올바르지 않습니다');
    }
    const f = path.join(d, name);
    try {
      await fsp.writeFile(f, '', { flag: 'wx' });
    } catch (e) {
      if (e.code === 'EEXIST') return { error: 'EEXIST' };
      throw e;
    }
    log('info', '새 파일', { file: f });
    return { path: f };
  });

  handle('dialog:open', async () => {
    const r = await dialog.showOpenDialog(win, {
      title: '파일 열기',
      properties: ['openFile'],
      defaultPath: config.lastFolder || app.getPath('documents'),
      filters: [
        { name: 'Markdown', extensions: ['md', 'markdown', 'txt'] },
        { name: '모든 파일', extensions: ['*'] },
      ],
    });
    if (r.canceled || !r.filePaths[0]) return null;
    const f = path.resolve(r.filePaths[0]);
    allowedFiles.add(f);
    return { path: f, name: path.basename(f) };
  });

  handle('dialog:save', async (suggestedName, kind) => {
    const ext = kind === 'html' ? 'html' : kind === 'pdf' ? 'pdf' : 'md';
    const label = { html: 'HTML 문서', pdf: 'PDF', md: 'Markdown' }[ext];
    const r = await dialog.showSaveDialog(win, {
      title: '저장',
      defaultPath: path.join(config.lastFolder || app.getPath('documents'), String(suggestedName || `문서.${ext}`)),
      filters: [{ name: label, extensions: [ext] }],
      properties: ['createDirectory', 'showOverwriteConfirmation'],
    });
    if (r.canceled || !r.filePath) return null;
    const f = path.resolve(r.filePath);
    allowedFiles.add(f);
    return { path: f, name: path.basename(f) };
  });

  // 끌어다 놓은 파일: 마크다운/텍스트 파일만 허용 목록에 추가한다.
  handle('file:allowDropped', async (p) => {
    const f = normalize(p);
    if (!MD_EXT.test(f)) return false;
    const st = await fsp.stat(f);
    if (!st.isFile()) return false;
    allowedFiles.add(f);
    return true;
  });

  // Electron 44부터 클립보드는 W3C와 같은 ClipboardItem 방식이다. HTML과 텍스트를 한 항목에 함께 넣는다.
  handle('clipboard:write', async ({ html, text }) => {
    const data = { 'text/plain': String(text ?? '') };
    if (html) data['text/html'] = String(html);
    await clipboard.write([new ClipboardItem(data)]);
    return true;
  });

  handle('pdf:export', async (html, suggestedName) => {
    const r = await dialog.showSaveDialog(win, {
      title: 'PDF로 저장',
      defaultPath: path.join(config.lastFolder || app.getPath('documents'), String(suggestedName || '보고서.pdf')),
      filters: [{ name: 'PDF', extensions: ['pdf'] }],
      properties: ['createDirectory', 'showOverwriteConfirmation'],
    });
    if (r.canceled || !r.filePath) return null;
    const out = path.resolve(r.filePath);
    const tmpHtml = path.join(os.tmpdir(), `mdstudio-${process.pid}-${Date.now()}.html`);
    await fsp.writeFile(tmpHtml, String(html), 'utf8');
    // 보고서 HTML은 스크립트가 없는 정적 문서라 JavaScript를 끈 숨은 창에서 렌더링한다.
    const pdfWin = new BrowserWindow({ show: false, webPreferences: { javascript: false, sandbox: true } });
    try {
      await pdfWin.loadFile(tmpHtml);
      const data = await pdfWin.webContents.printToPDF({ printBackground: true, pageSize: 'A4', preferCSSPageSize: true });
      await fsp.writeFile(out, data);
      log('info', 'PDF 저장', { file: out, bytes: data.length });
      return { path: out, name: path.basename(out) };
    } finally {
      pdfWin.destroy();
      fsp.unlink(tmpHtml).catch(() => {});
    }
  });

  handle('shell:showLogs', () => shell.openPath(app.getPath('logs')));
  handle('shell:reveal', (p) => shell.showItemInFolder(checked(p)));

  handle('app:takePendingFiles', () => pendingOpenFiles.splice(0));
}

// ---------------------------------------------------------------------------
// Finder에서 .md 파일을 "MD Studio로 열기" 했을 때
// ---------------------------------------------------------------------------
function openFromOS(p) {
  const f = path.resolve(p);
  allowedFiles.add(f);
  log('info', 'Finder에서 파일 열기', { file: f });
  if (win && rendererReady) {
    sendToRenderer('open-file', f);
    if (win.isMinimized()) win.restore();
    win.focus();
  } else {
    pendingOpenFiles.push(f);
    if (app.isReady() && !win) createWindow();
  }
}
app.on('open-file', (e, p) => {
  e.preventDefault();
  openFromOS(p);
});

// ---------------------------------------------------------------------------
// 메뉴 막대
// ---------------------------------------------------------------------------
function buildMenu() {
  const act = (action) => () => sendToRenderer('menu', action);
  // registerAccelerator:false 는 화면이 이미 처리하는 단축키라 메뉴에는 표시만 한다(두 번 실행 방지).
  const shown = (accelerator) => ({ accelerator, registerAccelerator: false });
  const template = [
    {
      label: 'MD Studio',
      submenu: [
        { role: 'about', label: 'MD Studio 정보' },
        { type: 'separator' },
        { label: '설정…', accelerator: 'CmdOrCtrl+,', click: act('settings') },
        { type: 'separator' },
        { role: 'hide', label: 'MD Studio 가리기' },
        { role: 'hideOthers', label: '기타 가리기' },
        { role: 'unhide', label: '모두 보기' },
        { type: 'separator' },
        { role: 'quit', label: 'MD Studio 종료' },
      ],
    },
    {
      label: '파일',
      submenu: [
        { label: '새 문서', accelerator: 'CmdOrCtrl+N', click: act('new') },
        { label: '열기…', ...shown('CmdOrCtrl+O'), click: act('open') },
        { label: '폴더 열기…', accelerator: 'CmdOrCtrl+Shift+O', click: act('openFolder') },
        { type: 'separator' },
        { label: '저장', ...shown('CmdOrCtrl+S'), click: act('save') },
        { label: '다른 이름으로 저장…', ...shown('CmdOrCtrl+Shift+S'), click: act('saveAs') },
        { type: 'separator' },
        { label: 'HTML 보고서로 내보내기…', click: act('exportHtml') },
        { label: 'PDF로 내보내기…', accelerator: 'CmdOrCtrl+P', click: act('exportPdf') },
        { type: 'separator' },
        { role: 'close', label: '창 닫기' },
      ],
    },
    {
      label: '편집',
      submenu: [
        { role: 'undo', label: '실행 취소' },
        { role: 'redo', label: '실행 복귀' },
        { type: 'separator' },
        { role: 'cut', label: '오려두기' },
        { role: 'copy', label: '복사하기' },
        { role: 'paste', label: '붙여넣기' },
        { role: 'pasteAndMatchStyle', label: '서식 없이 붙여넣기' },
        { role: 'selectAll', label: '전체 선택' },
        { type: 'separator' },
        { label: 'Slack용으로 복사', accelerator: 'CmdOrCtrl+Shift+C', click: act('copySlack') },
        { label: '서식 포함 복사 (Docs·메일)', accelerator: 'CmdOrCtrl+Alt+Shift+C', click: act('copyRich') },
        { label: '텍스트로 복사', accelerator: 'CmdOrCtrl+Shift+T', click: act('copyPlain') },
        { label: '마크다운 원문 복사', click: act('copyMd') },
      ],
    },
    {
      label: '보기',
      submenu: [
        { label: '편집만', click: act('viewEdit') },
        { label: '편집 + 미리보기', click: act('viewSplit') },
        { label: '미리보기만', click: act('viewPreview') },
        { label: '보기 전환', ...shown('CmdOrCtrl+\\'), click: act('cycleView') },
        { label: '파일 목록 보이기/숨기기', click: act('toggleSidebar') },
        { type: 'separator' },
        { role: 'resetZoom', label: '실제 크기' },
        { role: 'zoomIn', label: '확대' },
        { role: 'zoomOut', label: '축소' },
        { type: 'separator' },
        { role: 'togglefullscreen', label: '전체 화면' },
        { type: 'separator' },
        { role: 'reload', label: '화면 새로고침' },
        { role: 'toggleDevTools', label: '개발자 도구' },
      ],
    },
    { role: 'windowMenu', label: '윈도우' },
    {
      role: 'help',
      label: '도움말',
      submenu: [
        { label: '사용법과 단축키', ...shown('CmdOrCtrl+/'), click: act('help') },
        { label: '로그 보기', click: act('logs') },
        { label: '로그 폴더 열기', click: () => shell.openPath(app.getPath('logs')) },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---------------------------------------------------------------------------
// 시작
// ---------------------------------------------------------------------------
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (!win) return;
    if (win.isMinimized()) win.restore();
    win.focus();
  });

  app.whenReady().then(() => {
    loadConfig();
    log('info', `MD Studio ${app.getVersion()} 시작`, { electron: process.versions.electron, os: `${process.platform} ${os.release()}` });
    app.setAboutPanelOptions({ applicationName: 'MD Studio', applicationVersion: app.getVersion(), copyright: '로컬 마크다운 편집기' });
    // 화면은 카메라·마이크·위치 등 어떤 권한도 필요 없다. (클립보드는 메인 프로세스가 처리)
    session.defaultSession.setPermissionRequestHandler((_wc, _perm, cb) => cb(false));
    registerIpc();
    buildMenu();
    createWindow();
  });

  app.on('activate', () => {
    if (!win) createWindow();
  });
  app.on('window-all-closed', () => app.quit());
  process.on('uncaughtException', (e) => log('error', '처리되지 않은 오류', e));
  process.on('unhandledRejection', (e) => log('error', '처리되지 않은 비동기 오류', e));
}
