"use strict";
const { contextBridge, ipcRenderer } = require("electron");
const api = {};
for (const name of [
  "state",
  "login",
  "sync",
  "draft",
  "sale",
  "cash",
  "remote",
  "print",
  "history",
])
  api[name] = (arg) => ipcRenderer.invoke("pdv:" + name, arg);
api.onChange = (callback) => {
  const listener = (_event, state) => callback(state);
  ipcRenderer.on("pdv:changed", listener);
  return () => ipcRenderer.removeListener("pdv:changed", listener);
};
contextBridge.exposeInMainWorld("florestDesktop", api);
