import {createHash,timingSafeEqual} from 'node:crypto';
import {createAPI,parseJSON,validId,safeError} from './core.mjs';
import {runWorker} from './worker.mjs';
import {normalizeOrder} from './normalize.mjs';
const project=Deno.env.get('SUPABASE_URL')??'',key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')??'',anon=Deno.env.get('SUPABASE_ANON_KEY')??'';
const origins=new Set(['https://erp.florestsistemas.com.br','http://localhost:4173']);
async function db(name:string,body:unknown,authorization='Bearer '+key,timeout=6000){
 const response=await fetch(project+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:authorization==='Bearer '+key?key:anon,Authorization:authorization,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(timeout)});
 if(!response.ok)throw Error('Operação recusada. Confira a empresa, as permissões, os vínculos ou a configuração da impressora.');return await response.json();
}
const rpc=(company:string|null,action:string,data={})=>db('gastronomia_99food_operacao_worker',{p_empresa:company,p_acao:action,p_dados:data});
const connection=(c:any)=>({company:c.empresa_id,appId:c.app_id,appShopId:c.app_shop_id,shopId:c.shop_id});
async function sync(company:string){const c=await rpc(company,'config');if(!c?.habilitada)return {erro:'Loja não conectada.'};return runWorker({rpc:(a:string,d={})=>rpc(company,a,d),secret:c.segredo,connection:connection(c),normalize:normalizeOrder});}
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('Origin')??'',headers:Record<string,string>={'Cache-Control':'no-store','Vary':'Origin'};
 if(origins.has(origin))Object.assign(headers,{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, x-client-info, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'});
 const reply=(data:unknown,status=200)=>Response.json(data,{status,headers});
 if(origin&&!origins.has(origin))return reply({erro:'Origem inválida.'},403);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply({erro:'Método inválido.'},405);
 try{
  const reader=req.body?.getReader();if(!reader)return reply({erro:'Corpo ausente.'},400);const chunks:Uint8Array[]=[];let size=0;
  while(true){const r=await reader.read();if(r.done)break;size+=r.value.length;if(size>256*1024){await reader.cancel();return reply({erro:'Corpo excessivo.'},413)}chunks.push(r.value)}
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length}
  const raw=new TextDecoder('utf-8',{fatal:true}).decode(bytes),data=parseJSON(raw);
  if(req.headers.has('didi-header-sign')){
   const signature=req.headers.get('didi-header-sign')??'';if(!/^[a-f\d]{32}$/i.test(signature))return reply({errno:1,errmsg:'Assinatura inválida.'},401);
   const match=await db('gastronomia_99food_operacao_worker',{p_empresa:null,p_acao:'resolver',p_dados:{app_id:String(data.app_id),app_shop_id:data.app_shop_id}},'Bearer '+key,1800);if(!match)return reply({errno:1,errmsg:'Loja não autorizada.'},403);
   const c=match;const expected=createHash('md5').update(bytes).update(c.segredo).digest(),actual=Uint8Array.from(signature.match(/../g)!,s=>Number.parseInt(s,16));
   if(!timingSafeEqual(expected,actual))return reply({errno:1,errmsg:'Assinatura inválida.'},401);
   if(typeof data.type!=='string'||!data.type||data.type.length>100)return reply({errno:1,errmsg:'Evento inválido.'},400);
   if(typeof data.data==='string')data.data=parseJSON(data.data);
   const id=String(data.data?.order_id??data.data?.order_info?.order_id??'');
   if(data.type.startsWith('order')&&!validId(id))return reply({errno:1,errmsg:'Pedido inválido.'},400);
   if(data.data?.order_info?.order_id!==undefined&&String(data.data.order_info.order_id)!==id)return reply({errno:1,errmsg:'Pedido divergente.'},400);
   await db('gastronomia_99food_operacao_worker',{p_empresa:c.empresa_id,p_acao:'evento',p_dados:{id:createHash('sha256').update(bytes).digest('hex'),order_id:validId(id)?id:'',payload:data}},'Bearer '+key,3000);return reply({errno:0,errmsg:'ok'});
  }
  if(data.acao==='worker'){
   const allowed=await db('gastronomia_99food_sandbox_worker',{p_acao:'validar_cron',p_dados:{momento:req.headers.get('x-99food-momento')??'',assinatura:req.headers.get('x-99food-assinatura')??'',corpo:raw}});
   if(!allowed)return reply({erro:'Não autorizado.'},401);
   const companies=await rpc(null,'listar'),results=[];for(const company of companies)try{results.push({empresa_id:company,...await sync(company)})}catch{results.push({empresa_id:company,erro:'Confira o estado da conexão.'})}return reply({resultados:results});
  }
  const auth=req.headers.get('Authorization')??'';if(!auth.startsWith('Bearer '))return reply({erro:'Entre no ERP.'},401);
  const company=data.empresa_id,body={p_empresa:company,p_acao:'pedidos',p_dados:{data:data.data}};
  if(['configurar','conectar','estado','desconectar','autorizacao'].includes(data.acao)){
   const state=await db('gastronomia_99food_operacao_admin',{p_empresa:company,p_acao:'estado'},auth);
   if(data.acao==='estado')return reply(state);
   if(data.acao==='desconectar')return reply(await db('gastronomia_99food_operacao_admin',{p_empresa:company,p_acao:'desconectar'},auth));
   if(data.acao==='configurar'){await rpc(company,'configurar',{app_id:data.app_id,app_shop_id:data.app_shop_id,shop_id:data.shop_id,segredo:data.segredo,usuario:state.usuario});return reply({ok:true})}
   const c=await rpc(company,'config');if(!c)return reply({erro:'Cadastre o aplicativo de produção.'},400);
   if(data.acao==='autorizacao'){
    const res=await fetch('https://openapi.99food.com/v1/auth/authorizationpage/getUrl',{method:'POST',headers:{'Content-Type':'application/json'},body:'{"app_id":'+c.app_id+'}',signal:AbortSignal.timeout(5000)}),value=parseJSON(await res.text());
    if(!res.ok||value.errno!==0)throw Error('Autorização indisponível. Confira o aplicativo de produção no portal 99Food.');
    const url=new URL(value.data?.url);if(url.protocol!=='https:'||!(url.hostname==='99app.com'||url.hostname.endsWith('.99app.com')))throw Error('Endereço de autorização inválido.');return reply({url:url.href});
   }
   const api=createAPI({secret:c.segredo,rpc:(a:string,d={})=>rpc(company,a,d),connection:connection(c)}),store=await api.store();
   if(String(store?.shop_id??store?.shop_info?.shop_id)!==c.shop_id||store?.app_shop_id!==c.app_shop_id)return reply({erro:'A autorização retornou outra loja.'},403);
   await api.configureRequests();
   await rpc(company,'conectar',{nome_loja:store.name??store.shop_name??store.shop_info?.shop_name??''});return reply({ok:true});
  }
  await db('gastronomia_99food_operacao_admin',body,auth);
  if(data.acao==='sincronizar')return reply(await sync(company));
  const action=data.acao==='imprimir'?'reimprimir':data.acao;
  const result=await db('gastronomia_99food_operacao_admin',{p_empresa:company,p_acao:action,p_dados:{...data.payload,order_id:data.order_id,chave:data.chave,payload:data.payload??{}}},auth);
  if(['reimprimir','receber'].includes(action))return reply({ok:true});return reply({comando:result,...await sync(company)});
 }catch(error){return reply({erro:error instanceof Error&&error.message.startsWith('Operação recusada')?error.message:safeError(error)},502)}
});
