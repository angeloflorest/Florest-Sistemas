import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.49.8';
import {serverClient} from './runtime.mjs';
import {syncCatalog} from './catalog.mjs';
import {syncCompany} from './worker.mjs';
const allowedOrigins=new Set(['https://erp.florestsistemas.com.br','http://localhost:4173']);
const url=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
async function rpc(action:string,empresa:string|null=null,data:Record<string,unknown>={}){
 const {data:result,error}=await admin.rpc(action.startsWith('h_')?'gastronomia_ifood_homologacao_worker':action.startsWith('catalogo_')?'gastronomia_ifood_catalogo_worker':'gastronomia_ifood_worker',{p_acao:action.startsWith('h_')?action.slice(2):action.startsWith('catalogo_')?action.slice(9):action,p_empresa:empresa,p_dados:data});
 if(error)throw Error(error.message);return result;
}
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('origin')||'';
 const headers:Record<string,string>={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};
 if(allowedOrigins.has(origin))Object.assign(headers,{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'});
 const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply({erro:'Método não permitido.'},405);
 try{
  if(origin&&!allowedOrigins.has(origin))return reply({erro:'Origem não permitida.'},403);
  if(Number(req.headers.get('content-length')||0)>12000)return reply({erro:'Solicitação muito grande.'},413);
  const raw=await req.text();if(raw.length>12000)return reply({erro:'Solicitação muito grande.'},413);
  const body=JSON.parse(raw);
  if(body.acao==='cron'){
   if(!await rpc('cron_validar',null,{assinatura:req.headers.get('x-ifood-worker')||'',momento:req.headers.get('x-ifood-momento')||'',corpo:raw}))return reply({erro:'Não autorizado.'},401);
   if(body.catalogo_empresa){const cfg=await rpc('config',body.catalogo_empresa);const api=serverClient({cfg,empresa:body.catalogo_empresa,rpc});await syncCatalog({empresa:body.catalogo_empresa,merchant:cfg.merchant_id,api,rpc,bulk:true,deadline:Date.now()+50000});return reply({ok:true})}
   if(body.validar_empresa){
    const cfg=await rpc('config',body.validar_empresa);
    const api=serverClient({cfg,empresa:body.validar_empresa,rpc});
    if(body.consultar_catalogo===true){const catalogos=await api.catalogs(cfg.merchant_id);return reply({catalogos,categorias:await api.catalog(cfg.merchant_id,'categories',{catalogId:catalogos[0].catalogId}),...(body.item_id?{item:await api.catalog(cfg.merchant_id,'item',{id:body.item_id})}:{})})}
    const status=await api.status(cfg.merchant_id);
    if(body.ativar===true)await rpc('conectar',body.validar_empresa);
    return reply({ok:true,status_loja:status});
   }
   const companies=await rpc('listar');const results=[];
   for(const empresa of companies){try{results.push({empresa,...await syncCompany({empresa,rpc})})}catch{results.push({empresa,erro:'Consulte o estado na configuração iFood.'})}}
   return reply({resultados:results});
  }
  const authorization=req.headers.get('authorization')||'';
  const token=authorization.replace(/^Bearer\s+/i,'');
  const {data:user,error:authError}=await admin.auth.getUser(token);
  if(authError||!user.user)return reply({erro:'Sessão inválida.'},401);
  const client=createClient(url,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data:state,error}=await client.rpc('gastronomia_ifood_admin',{p_acao:body.acao==='motivos_cancelamento'?'pedidos':'obter',p_dados:{empresa_esperada:body.empresa_id}});
  if(error||state?.empresa_id!==body.empresa_id)return reply({erro:'Empresa ou permissão indisponível.'},403);
  const empresa=state.empresa_id;
  if(body.acao==='sincronizar')return reply(await syncCompany({empresa,rpc}));
  const cfg=await rpc('config',empresa);
  const api=serverClient({cfg,empresa,rpc});
  if(body.acao==='catalogos'){const catalogs=await api.catalogs(cfg.merchant_id);return reply({contextos:[...new Set(catalogs.filter((c:any)=>c.status==='AVAILABLE').flatMap((c:any)=>c.context||[]))]})}
  if(body.acao==='conectar'){
   const status=await api.status(cfg.merchant_id);await rpc('conectar',empresa);return reply({ok:true,status_loja:status});
  }
  if(body.acao==='motivos_cancelamento'){
   if(!state.pedidos.some((p:{pedido_id:string})=>p.pedido_id===body.pedido_id))return reply({erro:'Pedido de outra empresa.'},403);
   return reply({motivos:await api.cancellationReasons(body.pedido_id,cfg.merchant_id)});
  }
  return reply({erro:'Ação inválida.'},400);
 }catch(e){const msg=e instanceof Error?e.message:'Falha de comunicação.';return reply({erro:msg},502);}
});
