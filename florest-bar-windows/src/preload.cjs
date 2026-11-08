'use strict';
const{contextBridge,ipcRenderer}=require('electron');
const invoke=(name,arg)=>ipcRenderer.invoke('bar:'+name,arg);
const on=(event,callback)=>{const listener=(_e,value)=>callback(value);ipcRenderer.on(event,listener);return()=>ipcRenderer.removeListener(event,listener);};
const api={offlineSession:()=>invoke("offlineSession"),request:r=>invoke('request',r),status:()=>invoke('status'),saveDraft:r=>invoke('saveDraft',r),loadDraft:t=>invoke('loadDraft',t),agent:()=>invoke('agent'),update:()=>invoke('update'),storage:{getItem:key=>invoke('secureGet',key),setItem:(key,value)=>invoke('secureSet',{key,value}),removeItem:key=>invoke('secureRemove',key)},onStatus:fn=>on('bar:status',fn),onCommand:fn=>on('bar:command',fn),hasWork:()=>{}};
contextBridge.exposeInMainWorld('florestBar',api);
