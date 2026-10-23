'use strict';
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('florestDesktop', Object.freeze({ status: () => ipcRenderer.invoke('pdv:status') }));
