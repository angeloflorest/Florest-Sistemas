// Somente servidor. Nenhum consumidor/cron importa este adaptador nesta preparação.
import {createHash,timingSafeEqual} from 'node:crypto';
const base='https://openapi.99food.com';
const md5=value=>createHash('md5').update(value).digest('hex');
export function verify99FoodSignature(raw,signature,secret){
 if(typeof secret!=='string'||!secret||typeof signature!=='string'||! /^[a-f0-9]{32}$/i.test(signature))return false;
 return timingSafeEqual(Buffer.from(md5(Buffer.concat([Buffer.from(raw),Buffer.from(secret)])),'hex'),Buffer.from(signature,'hex'));
}
// Preserve os IDs longos documentados pela 99Food, inclusive dentro de arrays.
export function parse99FoodJSON(raw){
 const protectedJSON=raw.replace(/"(?:\\[\s\S]|[^"\\])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/g,token=>{
  if(token[0]==='"'||/[.eE]/.test(token))return token;
  return Number.isSafeInteger(Number(token))?token:JSON.stringify(token);
 });
 return JSON.parse(protectedJSON);
}
export class Food99Error extends Error{constructor(message,{status=0,code=0,uncertain=false,retryAfter=0}={}){super(message);this.status=status;this.code=code;this.uncertain=uncertain;this.retryAfter=retryAfter}}
export function create99FoodClient({enabled=false,appId,appSecret,appShopId,shopId,fetchImpl=fetch,now=Date.now}={}){
 let token,until=0,refreshAfter=0,tokenAfter=0,pending;
 const next=new Map();
 function guard(){if(!enabled||typeof appId!=='string'||! /^[1-9][0-9]{0,18}$/.test(appId)||!appSecret||!appShopId||typeof shopId!=='string'||! /^[1-9][0-9]{0,18}$/.test(shopId))throw new Food99Error('Integração 99Food desativada ou não configurada.');}
 async function request(path,params,method='GET',interval=0){
  guard();if(now()<(next.get(path)||0))throw new Food99Error('Aguarde o limite de requisições da 99Food.',{retryAfter:next.get(path)-now()});next.set(path,now()+interval);
  const url=new URL(base+path),options={method,redirect:'error',signal:AbortSignal.timeout(15000)};
  if(method==='GET')url.search=new URLSearchParams(params).toString();else{options.headers={'Content-Type':'application/json'};options.body=JSON.stringify(params)}
  let response;try{response=await fetchImpl(url.toString(),options)}catch{throw new Food99Error('Falha de comunicação com a 99Food.',{uncertain:method!=='GET'})}
  if(!response.ok){const retryAfter=Math.max(0,Number(response.headers.get('Retry-After'))||0)*1000;throw new Food99Error('99Food retornou HTTP '+response.status+'.',{status:response.status,retryAfter,uncertain:method!=='GET'&&response.status>=500})}
  let data;try{data=parse99FoodJSON(await response.text())}catch{throw new Food99Error('Resposta inválida da 99Food.',{uncertain:method!=='GET'})}
  if(data.errno!==0)throw new Food99Error('99Food recusou a operação (código '+data.errno+').',{code:data.errno});return data.data;
 }
 async function getToken(){
  guard();if(token&&now()<until)return token;
  if(pending)return pending;
  pending=(async()=>{
   if(now()<tokenAfter)throw new Food99Error('Aguarde a consulta de token da 99Food.',{retryAfter:tokenAfter-now()});tokenAfter=now()+30000;
   const params={app_id:appId,app_secret:appSecret,app_shop_id:appShopId};
   let data;try{data=await request('/v1/auth/authtoken/get',params)}catch(error){
    if(error.code!==10102)throw error;
    if(now()<refreshAfter)throw new Food99Error('Aguarde a renovação do token 99Food.',{retryAfter:refreshAfter-now()});refreshAfter=now()+120000;
    await request('/v1/auth/authtoken/refresh',params);
    // get tem intervalo mínimo de 30s: o worker deverá reagendar sem bloquear a requisição.
    throw new Food99Error('Token renovado; consulte novamente após o intervalo da 99Food.',{retryAfter:30000});
   }
   if(String(data?.app_id)!==appId||data?.app_shop_id!==appShopId||!data?.auth_token||!Number.isFinite(data.token_expiration_time)||data.token_expiration_time*1000<=now())throw new Food99Error('Token 99Food inválido ou de outra loja.');
   token=data.auth_token;until=data.token_expiration_time*1000;return token;
  })();try{return await pending}finally{pending=null}
 }
 async function api(path,params={},method='GET',interval=0){const auth_token=await getToken();try{return await request(path,{...params,auth_token},method,interval)}catch(error){if(error.code===10102){token=null;until=0}throw error}}
 return {
  getToken,
  async menu(){return api('/v3/item/item/list',{},'GET',60000)},
  async order(id){if(typeof id!=='string'||! /^[1-9][0-9]{0,18}$/.test(id))throw new Food99Error('ID do pedido inválido.');const data=await api('/v1/order/order/detail',{order_id:id},'GET',1000);if(String(data?.shop_id)!==shopId||String(data?.order_id)!==id)throw new Food99Error('Pedido pertence a outra loja ou diverge do solicitado.');return data},
  async availability(ids,available){if(!Array.isArray(ids)||!ids.length||ids.length>100||ids.some(id=>typeof id!=='string'||!id.trim()||id.length>100)||typeof available!=='boolean')throw new Food99Error('Itens ou disponibilidade inválidos.');return api('/v3/item/item/updateItemStatus',{app_item_ids:[...new Set(ids)],status:available?1:2},'POST',100)},
 };
}
