"use strict";
function createUpdater({autoUpdater,hasSale,prepare,install,recover,onChange=()=>{}}) {
  let state={status:"idle"}, working=null;
  const set = next => {state=next;onChange();};
  autoUpdater.autoDownload=false;
  autoUpdater.autoInstallOnAppQuit=false;
  autoUpdater.allowDowngrade=false;
  autoUpdater.allowPrerelease=true;
  autoUpdater.on("update-available",info=>set({status:"available",version:info.version}));
  autoUpdater.on("download-progress",p=>set({...state,status:"downloading",percent:p.percent}));
  autoUpdater.on("update-downloaded",()=>set({...state,status:"ready"}));
  autoUpdater.on("error",e=>set({status:"error",message:e.message}));
  return {
    state:()=>state,
    check:()=>autoUpdater.checkForUpdates().catch(e=>set({status:"error",message:e.message})),
    install() {
      if (working) return working;
      working=(async()=>{
        if (await hasSale()) throw new Error("Conclua ou cancele a venda antes de atualizar.");
        if (state.status !== "ready") {
          if (state.status !== "available") {
            await autoUpdater.checkForUpdates();
            if (state.status !== "available") throw new Error("Nenhuma atualização disponível.");
          }
          set({...state,status:"downloading"});
          // electron-updater verifica SHA-512 do instalador antes de emitir update-downloaded.
          await autoUpdater.downloadUpdate();
          if (state.status !== "ready") throw new Error("Download não validado.");
        }
        if (await hasSale()) throw new Error("Venda em andamento. Atualização baixada; conclua a venda e tente novamente.");
        set({...state,status:"installing"});
        try { await prepare(); install(); autoUpdater.quitAndInstall(false,true); }
        catch(e) { recover?.(); throw e; }
      })().catch(e=>{ if (["downloading","installing"].includes(state.status)) set({status:"error",message:e.message}); throw e; }).finally(()=>working=null);
      return working;
    }
  };
}
module.exports={createUpdater};
