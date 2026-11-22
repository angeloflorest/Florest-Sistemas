// Proteção local ao processo: não persiste dados e não limita confirmações de pedidos.
export function createCatalogGuard({now=Date.now,limit=240,windowMs=60000,maxEntries=4096}={}){
 const windows=new Map(),pending=new Map();
 return {
  allow(token,ip){
   const time=now(),key=token+'|'+String(ip||'origem-indisponivel').slice(0,128);
   let entry=windows.get(key);
   if(!entry||entry.until<=time){
    if(windows.size>=maxEntries)windows.delete(windows.keys().next().value);
    entry={count:0,until:time+windowMs};windows.set(key,entry);
   }
   if(entry.count>=limit)return false;
   entry.count++;return true;
  },
  read(token,load){
   if(pending.has(token))return pending.get(token);
   const promise=Promise.resolve().then(load);pending.set(token,promise);
   promise.finally(()=>{if(pending.get(token)===promise)pending.delete(token)}).catch(()=>{});
   return promise;
  }
 };
}
