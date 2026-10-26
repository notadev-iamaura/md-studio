// 화면(렌더러)에 공개하는 기능 목록. 화면은 이 함수들로만 맥의 기능을 쓸 수 있다.
const { contextBridge, ipcRenderer, webUtils } = require('electron');

function subscribe(channel, cb) {
  const listener = (_e, ...args) => cb(...args);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

contextBridge.exposeInMainWorld('mdNative', {
  info: () => ipcRenderer.invoke('app:info'),
  pickFolder: () => ipcRenderer.invoke('folder:pick'),
  lastFolder: () => ipcRenderer.invoke('folder:last'),
  forgetFolder: () => ipcRenderer.invoke('folder:forget'),
  list: (dir) => ipcRenderer.invoke('fs:list', dir),
  stat: (p) => ipcRenderer.invoke('fs:stat', p),
  read: (p) => ipcRenderer.invoke('fs:read', p),
  write: (p, text) => ipcRenderer.invoke('fs:write', p, text),
  create: (dir, name) => ipcRenderer.invoke('fs:create', dir, name),
  openDialog: () => ipcRenderer.invoke('dialog:open'),
  saveDialog: (suggestedName, kind) => ipcRenderer.invoke('dialog:save', suggestedName, kind),
  allowDropped: (p) => ipcRenderer.invoke('file:allowDropped', p),
  writeClipboard: (payload) => ipcRenderer.invoke('clipboard:write', payload),
  exportPdf: (html, suggestedName) => ipcRenderer.invoke('pdf:export', html, suggestedName),
  showLogs: () => ipcRenderer.invoke('shell:showLogs'),
  reveal: (p) => ipcRenderer.invoke('shell:reveal', p),
  takePendingFiles: () => ipcRenderer.invoke('app:takePendingFiles'),
  getPathForFile: (file) => webUtils.getPathForFile(file),
  onMenu: (cb) => subscribe('menu', cb),
  onOpenFile: (cb) => subscribe('open-file', cb),
});
