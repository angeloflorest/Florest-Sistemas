import decode,{init} from 'npm:@jsquash/webp@1.5.0/decode.js';
import {encode} from 'npm:fast-png@6.2.0';
let ready;
export async function catalogImage(url,empresa,produto){
 const u=new URL(url),prefix='/storage/v1/object/public/gastronomia-fotos/'+empresa+'/'+produto+'/';if(u.origin!=='https://etulhyboogqhyyevpnlo.supabase.co'||!u.pathname.startsWith(prefix))throw Error('Foto fora do armazenamento da empresa.');
 const response=await fetch(u,{signal:AbortSignal.timeout(10000),redirect:'error'});if(!response.ok||Number(response.headers.get('content-length'))>5000000)throw Error('Foto indisponível ou muito grande.');let bytes=new Uint8Array(await response.arrayBuffer());if(bytes.length>5000000)throw Error('Foto muito grande.');let type=response.headers.get('content-type')?.split(';')[0];
 if(type==='image/webp'){
  if(!ready)ready=(async()=>{const r=await fetch('https://cdn.jsdelivr.net/npm/@jsquash/webp@1.5.0/codec/dec/webp_dec.wasm',{signal:AbortSignal.timeout(10000)});const wasm=await r.arrayBuffer(),hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',wasm))].map(x=>x.toString(16).padStart(2,'0')).join('');if(hash!=='30fb52fa2a80166d25ba7debf902218904ba1f05ccce9f959f722beff9e2f344')throw Error('Conversor de foto inválido.');await init(await WebAssembly.compile(wasm));})();
  await ready;const decoded=await decode(bytes.buffer);if(decoded.width>2048||decoded.height>2048)throw Error('Dimensões da foto excedem o limite.');bytes=encode({width:decoded.width,height:decoded.height,data:decoded.data,channels:4});type='image/png';
 }
 if(!['image/png','image/jpeg'].includes(type)||bytes.length>5000000)throw Error('Formato da foto não aceito pelo iFood.');let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));return 'data:'+type+';base64,'+btoa(binary);
}
