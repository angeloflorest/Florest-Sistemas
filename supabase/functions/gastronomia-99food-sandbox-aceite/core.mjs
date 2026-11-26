// Protocolo nativo 99Food. IDs de 64 bits nunca passam por Number().
export const binding=Object.freeze({company:'773dfacb-c0e7-4bd9-8eb4-5208818b1848',appId:'5764607791191296200',appShopId:'florest-gastronomia-teste-01',shopId:'5764619883330929453'});
export const validId=id=>typeof id==='string'&&/^[1-9]\d{0,18}$/.test(id);
export function parseJSON(raw){return JSON.parse(raw.replace(/"(?:\\[\s\S]|[^"\\])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/g,v=>v.startsWith('"')||/[.eE]/.test(v)||Number.isSafeInteger(Number(v))?v:JSON.stringify(v)))}
export class FoodError extends Error{constructor(message,{code=0,uncertain=false,retryAfter=0}={}){super(message);Object.assign(this,{code,uncertain,retryAfter})}}
export const terminal=s=>s===600||s>=900;
export function detailOf(data,id,shopId=binding.shopId){const d=data?.order_info??data;if(!validId(id)||String(d?.order_id)!==id||String(d?.shop?.shop_id??d?.shop_id)!==shopId||!Number.isInteger(d?.status))throw new FoodError('A 99Food retornou dados de outro pedido ou loja.');return d}
export function createAPI({secret,rpc,fetchImpl=fetch,now=Date.now,connection=binding}){
 async function request(path,params={},method='GET'){
  if(!validId(connection.appId)||!validId(connection.shopId)||!connection.appShopId||!secret)throw new FoodError('Credencial da loja de teste indisponível.');
  const url=new URL('https://openapi.99food.com'+path),options={method,redirect:'error',signal:AbortSignal.timeout(5000)};
  if(method==='GET')url.search=new URLSearchParams(params).toString();else{
   options.headers={'Content-Type':'application/json'};
   // Serializar identificadores como inteiros JSON exatos, sem arredondar.
   const {order_id,apply_id,...rest}=params;
   if((!validId(order_id)&&path!=='/v1/shop/apply/set')||(apply_id!==undefined&&!validId(apply_id)))throw new FoodError('Identificador inválido.');
   options.body=path==='/v1/shop/apply/set'?JSON.stringify(params):JSON.stringify(rest).slice(0,-1)+',"order_id":'+order_id+(apply_id?',"apply_id":'+apply_id:'')+'}';
  }
  let response,data;
  try{response=await fetchImpl(url.toString(),options)}catch{throw new FoodError('Falha de comunicação com a 99Food.',{uncertain:method==='POST'})}
  if(!response.ok)throw new FoodError('A 99Food retornou HTTP '+response.status+'.',{uncertain:method==='POST'});
  try{data=parseJSON(await response.text())}catch{throw new FoodError('Resposta inválida da 99Food.',{uncertain:method==='POST'})}
  if(data?.errno!==0)throw new FoodError(data?.errno===12004?'Pedido não disponível para consulta pela API (12004). Simulações de callback podem não representar pedidos consultáveis. Use a ferramenta de pedidos de teste e confira o vínculo da loja se o erro persistir.':'A 99Food recusou a operação. Código '+data?.errno+'.',{code:Number(data?.errno)||0});
  return {data:data.data,requestId:String(data.requestId??data.request_id??'').slice(0,120)};
 }
 async function token(){
  const state=await rpc('token');
  if(state?.token&&Date.parse(state.expira_em)>now()+5000)return state.token;
  if(!await rpc('token_reservar'))throw new FoodError('Aguardando o intervalo de consulta do token.',{retryAfter:30000});
  const q={app_id:connection.appId,app_secret:secret,app_shop_id:connection.appShopId};
  try{
   const {data}=await request('/v1/auth/authtoken/get',q);
   if(String(data?.app_id)!==connection.appId||data?.app_shop_id!==connection.appShopId||typeof data?.auth_token!=='string')throw new FoodError('Token de outra loja.');
   const expiry=Number(data.token_expiration_time)*1000;
   if(!Number.isFinite(expiry)||expiry<=now())throw new FoodError('Token expirado.',{code:10102});
   await rpc('token_salvar',{token:data.auth_token,expira_em:new Date(expiry).toISOString()});return data.auth_token;
  }catch(error){
   if(error.code===10102&&await rpc('token_renovar')){
    const result=await request('/v1/auth/authtoken/refresh',q);
    if(result.data!==true)throw new FoodError('A 99Food não confirmou a renovação do token.');
    await rpc('token_erro',{erro:'Token renovado. Nova consulta após o intervalo de 30 segundos.'});
    throw new FoodError('Token renovado. A consulta será retomada automaticamente.',{retryAfter:30000});
   }
   await rpc('token_erro',{erro:safeError(error)});throw error;
  }
 }
 async function authorized(path,params,method='GET'){
  const auth_token=await token();
  try{return await request(path,{...params,auth_token},method)}catch(error){if(error.code===10102)await rpc('token_erro',{erro:'Token expirou; renovação será retomada.'});throw error}
 }
 return {token,configureRequests:()=>authorized('/v1/shop/apply/set',{receive_cancel_apply:1,receive_refund_apply:1},'POST'),order:async id=>{if(!validId(id))throw new FoodError('Pedido inválido.');return detailOf((await authorized('/v1/order/order/detail',{order_id:id})).data,id,connection.shopId)},store:async()=>{const result=await authorized('/v1/shop/shop/detail',{});return result.data},send:(path,id,payload={})=>authorized(path,{...payload,order_id:id},'POST')};
}
export function safeError(error){return error instanceof FoodError?error.message:'Não foi possível confirmar o resultado. Consulte novamente antes de repetir.'}
const reasons=new Set([1010,1020,1030,1040,1050,1060,1070,1071,1072,1073,1074,1080]);
export function commandSpec(cmd,order,now=Date.now()){
 const d=order.detalhe??{},s=d.status,p=cmd.payload??{},self=d.delivery_type===2,pickup=d.fulfillment_mode===1||d.delivery_type===0;
 if(terminal(s)&&!['responder_reembolso','confirmar_dinheiro'].includes(cmd.acao))throw new FoodError('Pedido encerrado na 99Food.');
 const spec=(path,payload={})=>({path,payload});
 switch(cmd.acao){
  case 'confirmar':if(s!==100)throw new FoodError('O pedido não está aguardando aceite.');return spec('/v1/order/order/confirm');
  case 'pronto':if(s!==200)throw new FoodError('Confirme o pedido antes de informar que está pronto.');return spec('/v1/order/order/ready');
  case 'retirada':if(!pickup||s!==200)throw new FoodError('Esta ação exige pedido de retirada confirmado.');return spec('/v1/order/order/finish');
  case 'despachar':{
   if(!self||pickup||s!==200)throw new FoodError('O despacho manual exige entrega da loja e pedido confirmado.');
   const name=String(p.nome??'').trim(),phone=String(p.telefone??'').replace(/\D/g,''),minutes=Number(p.minutos);
   if(name.split(/\s+/).length<2||name.length>120||!/^\d{10,11}$/.test(phone)||!Number.isInteger(minutes)||minutes<1||minutes>240)throw new FoodError('Informe nome completo e telefone do entregador e prazo de 1 a 240 minutos.');
   const parts=name.split(/\s+/),ts=Math.floor(now/1000);
   return spec('/v1/order/selfdelivery/dispatch',{courier_info:{courier_name:name,courier_first_name:parts[0],courier_last_name:parts.slice(1).join(' '),courier_phone_code:'+55',courier_phone:phone},limit_time:{pickup_time:ts,delivery_time:ts+minutes*60}});
  }
  case 'entregue':if(!self||pickup||![400,500].includes(s))throw new FoodError('Informe entrega somente após o despacho da entrega própria.');return spec('/v1/order/selfdelivery/delivered');
  case 'concluir':if(!self||pickup||![400,500].includes(s)||!/^\d{4}$/.test(String(p.codigo??'')))throw new FoodError('Informe os quatro dígitos do código do cliente para a entrega própria.');return spec('/v1/order/selfdelivery/verifyDeliveryCode',{delivery_code:Number(p.codigo)});
  case 'confirmar_dinheiro':if(s!==200||d.delivery_type!==1||d.pay_type!==2||!order.recebimento_confirmado||!(d.price?.shop_paid_money>0))throw new FoodError('Confirme o recebimento real do entregador no caixa antes de informar à 99Food.');return spec('/v1/order/order/payConfirm');
  case 'cancelar':{
   const reason=String(p.motivo??'').trim(),code=Number(p.motivo_id);
   if(!reasons.has(code)||(!self&&[1060,1071,1072].includes(code))||reason.length>500||(code===1080&&reason.length<5))throw new FoodError('Selecione um motivo válido e descreva o cancelamento.');
   return spec('/v1/order/order/cancel',{reason_id:code,reason});
  }
  case 'responder_cancelamento':case 'responder_reembolso':{
   if(!validId(p.apply_id)||typeof p.concordar!=='boolean')throw new FoodError('Solicitação ou resposta inválida.');
   const request=order.solicitacoes?.find(e=>String(e.apply_id)===p.apply_id&&e.tipo===(cmd.acao==='responder_cancelamento'?'orderCancelApply':'orderRefundApply'));
   if(!request)throw new FoodError('A solicitação não pertence a este pedido.');
   if(cmd.acao==='responder_cancelamento'){
    if(!p.concordar&&!request.reason_list?.some(r=>r.reason===p.motivo))throw new FoodError('Selecione um motivo oferecido pela 99Food.');
    return spec('/v1/order/apply/cancel',{apply_id:p.apply_id,agree:p.concordar,...(!p.concordar?{reason:p.motivo}:{})});
   }
   const reason=request.base_reason_list?.find(r=>String(r.base_reason_id)===String(p.motivo_id));
   if(!p.concordar&&!reason)throw new FoodError('Selecione um motivo oferecido pela 99Food.');
   return spec('/v1/order/apply/refund',{apply_id:p.apply_id,agree:p.concordar,...(!p.concordar?{base_reason_id:String(reason.base_reason_id),base_reason:reason.base_reason,custom_reason:String(p.motivo??'').slice(0,500)}:{})});
  }
  default:throw new FoodError('Operação indisponível.');
 }
}
export function achieved(cmd,order){const s=order.status_99food;
 if(cmd.acao==='confirmar')return [200,400,500,600].includes(s);
 if(cmd.acao==='pronto')return order.pronto===true;
 if(cmd.acao==='despachar')return [400,500,600].includes(s);
 if(cmd.acao==='retirada'||cmd.acao==='concluir')return s===600;
 if(cmd.acao==='cancelar')return s>=900;
 // 500 significa chegada ao endereço, não comprova uma entrega concluída.
 if(cmd.acao==='entregue')return s===600;
 return false;
}
