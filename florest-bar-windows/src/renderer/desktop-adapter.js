'use strict';
const originalFetch=window.fetch.bind(window);
window.florestBarFetch=async(input,options)=>{const req=new Request(input,options);if(new URL(req.url).origin!=='https://etulhyboogqhyyevpnlo.supabase.co')return originalFetch(input,options);const res=await window.florestBar.request({url:req.url,method:req.method,headers:Object.fromEntries(req.headers.entries()),body:['GET','HEAD'].includes(req.method)?'':await req.text()});return new Response([204,205,304].includes(res.status)?null:res.body,{status:res.status,headers:res.headers});};
window.fetch=window.florestBarFetch;
