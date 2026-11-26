import {createHash} from 'node:crypto';
import {binding,validId,safeError} from './core.mjs';
import {normalizeOrder} from './normalize.mjs';
import {runWorker} from './worker.mjs';
const project=Deno.env.get('SUPABASE_URL')??'',key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')??'',anon=Deno.env.get('SUPABASE_ANON_KEY')??'';
const origins=new Set(['https://erp.florestsistemas.com.br','http://localhost:4173']);
async function db(name:string,body:unknown,authorization='Bearer '+key){
 const response=await fetch(project+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:authorization==='Bearer '+key?key:anon,Authorization:authorization,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(5000)});
 if(!response.ok)throw Error('Operação indisponível para esta sessão ou pedido.');return await response.json();
}
const rpc=(action:string,data={})=>db('gastronomia_99food_sandbox_worker',{p_acao:action,p_dados:data});
Deno.serve(async(request:Request)=>{
 const origin=request.headers.get('Origin')??'',headers:Record<string,string>={'Cache-Control':'no-store','Vary':'Origin'};
 if(origins.has(origin))Object.assign(headers,{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, x-client-info, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'});
 const reply=(data:unknown,status=200)=>Response.json(data,{status,headers});
 if(origin&&!origins.has(origin))return reply({erro:'Origem não permitida.'},403);
 if(request.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(request.method!=='POST')return reply({erro:'Método inválido.'},405);
 try{
  if(Number(request.headers.get('content-length')||0)>12000)return reply({erro:'Dados excessivos.'},413);
  const raw=await request.text();if(raw.length>12000)return reply({erro:'Dados excessivos.'},413);
  const data=JSON.parse(raw),action=data.acao??'confirmar';
  if(action==='worker'){
   if(!await rpc('validar_cron',{momento:request.headers.get('x-99food-momento')??'',assinatura:request.headers.get('x-99food-assinatura')??'',corpo:raw}))return reply({erro:'Não autorizado.'},401);
   if(data.verificar_receptor===true){
    const secret=Deno.env.get('FOOD99_SANDBOX_APP_SECRET');if(!secret)return reply({erro:'Credencial indisponível.'},503);
    // Diagnóstico técnico sem pedido, cliente, aceite ou efeito financeiro.
    const payload=JSON.stringify({app_id:binding.appId,app_shop_id:binding.appShopId,type:'florestReceiverCheck',timestamp:Math.floor(Date.now()/1000),data:{verificacao:'assinatura_e_persistencia'}});
    const response=await fetch(project+'/functions/v1/gastronomia-99food-sandbox',{method:'POST',headers:{'Content-Type':'application/json','didi-header-sign':createHash('md5').update(payload).update(secret).digest('hex')},body:payload,signal:AbortSignal.timeout(5000)});
    const result=await response.json();return reply({receptor_ok:response.ok&&result.errno===0,status:response.status});
   }
   return reply(await runWorker({rpc,secret:Deno.env.get('FOOD99_SANDBOX_APP_SECRET')}));
  }
  const authorization=request.headers.get('Authorization')??'';
  if(!authorization.startsWith('Bearer '))return reply({erro:'Entre no ERP.'},401);
  if(data.empresa_id!==binding.company)return reply({erro:'Esta conexão é exclusiva da loja de teste.'},403);
  // RPC com JWT do usuário valida empresa ativa e permissão antes de qualquer chamada externa.
  const state=await db('gastronomia_99food_sandbox_admin',{p_empresa:binding.company,p_acao:'estado'},authorization);
  if(action==='estado')return reply(state);
  if(action==='imprimir'){
   if(!validId(data.order_id)||typeof data.chave!=='string')return reply({erro:'Pedido inválido.'},400);
   const orders=await db('gastronomia_99food_sandbox_pedidos',{p_empresa:binding.company,p_order_id:data.order_id},authorization),order=orders[0];if(!order?.detalhe)return reply({erro:'Atualize os detalhes do pedido.'},400);
   try{await db('gastronomia_99food_sandbox_imprimir',{p_empresa:binding.company,p_pedido:data.order_id,p_normalizado:normalizeOrder(order.detalhe),p_chave:data.chave});return reply({ok:true})}catch{return reply({erro:'Configure a impressora da Gastronomia e conecte o Print Agent antes de imprimir.'},409)}
  }
  if(action==='sincronizar')return reply(await runWorker({rpc,secret:Deno.env.get('FOOD99_SANDBOX_APP_SECRET')}));
  if(!validId(data.order_id)||typeof data.chave!=='string')return reply({erro:'Pedido ou chave inválidos.'},400);
  const command=await db('gastronomia_99food_sandbox_admin',{p_empresa:binding.company,p_acao:action,p_dados:{order_id:data.order_id,chave:data.chave,payload:data.payload??{}}},authorization);
  const result=await runWorker({rpc,secret:Deno.env.get('FOOD99_SANDBOX_APP_SECRET')});
  return reply({comando:command,...result});
 }catch(error){return reply({erro:error instanceof Error&&error.message.startsWith('Operação indisponível')?error.message:safeError(error)},502)}
});
