const base=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
async function rpc(acao:string,dados:unknown={}){const r=await fetch(base+'/rest/v1/rpc/gastronomia_whatsapp_worker',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({p_acao:acao,p_dados:dados})});if(!r.ok)throw Error('Falha no registro da fila.');return r.json()}
async function signed(body:string,signature:string){const s=Deno.env.get('META_APP_SECRET');if(!s)return false;const k=await crypto.subtle.importKey('raw',new TextEncoder().encode(s),{name:'HMAC',hash:'SHA-256'},false,['sign']);const h=new Uint8Array(await crypto.subtle.sign('HMAC',k,new TextEncoder().encode(body)));const expected='sha256='+Array.from(h).map(x=>x.toString(16).padStart(2,'0')).join('');if(signature.length!==expected.length)return false;let d=0;for(let i=0;i<signature.length;i++)d|=signature.charCodeAt(i)^expected.charCodeAt(i);return d===0}
Deno.serve(async(req:Request)=>{
 const url=new URL(req.url),headers={'Content-Type':'application/json','Cache-Control':'no-store'};
 if(req.method==='GET'){const secret=Deno.env.get('META_VERIFY_TOKEN');return new Response(secret&&url.searchParams.get('hub.verify_token')===secret?url.searchParams.get('hub.challenge'):'Negado',{status:secret&&url.searchParams.get('hub.verify_token')===secret?200:403})}
 if(req.method!=='POST')return new Response('Negado',{status:405});
 const body=await req.text();if(body.length>200000)return new Response('Muito grande',{status:413});
 if(req.headers.has('x-hub-signature-256')){
  if(!await signed(body,req.headers.get('x-hub-signature-256')||''))return new Response('Negado',{status:403});
  try{const event=JSON.parse(body);for(const e of event.entry||[])for(const c of e.changes||[])for(const s of c.value?.statuses||[]){const estado=({delivered:'entregue',read:'lida',failed:'falha'} as Record<string,string>)[s.status];if(estado)await rpc('webhook',{provedor_id:s.id,estado,erro:s.errors?.map((x:{title:string})=>x.title).join('; ')})}return new Response('{"ok":true}',{headers})}catch{return new Response('Falha',{status:500})}
 }
 const secret=Deno.env.get('GASTRONOMIA_WORKER_SECRET');if(!secret||req.headers.get('x-worker-secret')!==secret)return new Response('Negado',{status:403});
 let processed=0;for(let i=0;i<10;i++){
  let w;try{w=await rpc('reservar')}catch{return new Response('Falha de fila',{status:500})}if(!w.id)break;
  const configs=JSON.parse(Deno.env.get('GASTRONOMIA_WHATSAPP_CONTAS')||'{}'),cfg=configs[w.empresa_id];
  if(!cfg?.token||!cfg?.phone_number_id||!cfg?.template_retirada||!cfg?.template_entrega){await rpc('resultado',{id:w.id,empresa_id:w.empresa_id,estado:'falha',erro:'WhatsApp da empresa não conectado ou modelos não configurados.'});continue}
  try{
   let to=String(w.telefone).replace(/\D/g,'');if(to.length===10||to.length===11)to='55'+to;
   const template=w.mensagem.includes('retirada')?cfg.template_retirada:cfg.template_entrega;
   const version=Deno.env.get('META_GRAPH_VERSION');if(!version||!/^v\d+\.\d+$/.test(version))throw Error('Configure META_GRAPH_VERSION para a versão vigente da sua aplicação Meta.');
   const r=await fetch('https://graph.facebook.com/'+version+'/'+encodeURIComponent(cfg.phone_number_id)+'/messages',{method:'POST',headers:{Authorization:'Bearer '+cfg.token,'Content-Type':'application/json'},body:JSON.stringify({messaging_product:'whatsapp',to,type:'template',template:{name:template,language:{code:cfg.language||'pt_BR'}}}),signal:AbortSignal.timeout(15000)});
   const data=await r.json();const id=data.messages?.[0]?.id;
   await rpc('resultado',{id:w.id,empresa_id:w.empresa_id,estado:r.ok&&id?'aceita_provedor':r.status>=500?'incerto':'falha',provedor_id:id,erro:r.ok&&id?null:(data.error?.message||'Resposta do provedor sem confirmação.')});processed++;
  }catch(e){await rpc('resultado',{id:w.id,empresa_id:w.empresa_id,estado:'incerto',erro:'Envio sem confirmação. Conferir o provedor antes de repetir: '+String(e).slice(0,180)})}
 }
 return new Response(JSON.stringify({processados:processed}),{headers});
});
