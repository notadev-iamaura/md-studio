// 앱 전체에서 쓰는 로거. 브라우저 콘솔과 화면의 로그 패널에 동시에 남긴다.
const MAX_ENTRIES = 1000;
const entries = [];
const listeners = new Set();

function fmtTime(d) {
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

function serialize(data) {
  if (data === undefined) return '';
  if (data instanceof Error) return `${data.name}: ${data.message}${data.stack ? `\n${data.stack}` : ''}`;
  try {
    return JSON.stringify(data);
  } catch {
    return String(data);
  }
}

function write(level, scope, message, data) {
  const entry = { time: new Date(), level, scope, message, data: serialize(data) };
  entries.push(entry);
  if (entries.length > MAX_ENTRIES) entries.shift();
  const line = `[${fmtTime(entry.time)}] ${level.toUpperCase()} [${scope}] ${message}`;
  const fn = level === 'error' ? console.error : level === 'warn' ? console.warn : level === 'debug' ? console.debug : console.info;
  data === undefined ? fn(line) : fn(line, data);
  listeners.forEach((l) => {
    try {
      l(entry);
    } catch {
      /* 로그 리스너 오류가 앱을 멈추지 않게 한다 */
    }
  });
  return entry;
}

export function createLogger(scope) {
  return {
    debug: (m, d) => write('debug', scope, m, d),
    info: (m, d) => write('info', scope, m, d),
    warn: (m, d) => write('warn', scope, m, d),
    error: (m, d) => write('error', scope, m, d),
    // 소요 시간 측정: const done = log.time('변환'); ... done({추가정보})
    time(label) {
      const t0 = performance.now();
      return (extra) => write('debug', scope, `${label} 완료 (${(performance.now() - t0).toFixed(1)}ms)`, extra);
    },
  };
}

export function onLog(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function getEntries() {
  return entries.slice();
}

export function formatEntries(list = entries) {
  return list
    .map((e) => `[${fmtTime(e.time)}] ${e.level.toUpperCase()} [${e.scope}] ${e.message}${e.data ? ` ${e.data}` : ''}`)
    .join('\n');
}

export function clearEntries() {
  entries.length = 0;
}

export function installGlobalHandlers() {
  const log = createLogger('global');
  window.addEventListener('error', (e) => log.error(`처리되지 않은 오류: ${e.message}`, e.error || { file: e.filename, line: e.lineno }));
  window.addEventListener('unhandledrejection', (e) => log.error('처리되지 않은 비동기 오류', e.reason));
}
