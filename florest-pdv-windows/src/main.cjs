'use strict';
const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('node:path');
const { openLocalDatabase } = require('./local-db.cjs');
let db;
function createWindow() {
  const win = new BrowserWindow({ width: 1366, height: 850, minWidth: 1024, minHeight: 680, webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: false } });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}
app.whenReady().then(() => {
  db = openLocalDatabase(app.getPath('userData'));
  ipcMain.handle('pdv:status', () => ({ localDb: true, pending: db.db.prepare("SELECT COUNT(*) AS n FROM vendas_locais WHERE estado_sync IN ('pendente','erro')").get().n }));
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('before-quit', () => { if (db) db.fechar(); });
