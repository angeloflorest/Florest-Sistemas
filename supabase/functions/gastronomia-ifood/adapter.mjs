// Somente servidor. Sem agendamento; nenhuma conexão é ativada por padrão.
const base='https://merchant-api.ifood.com.br';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export async function verifySignature(raw,signature,secret){
 if(!secret||!signature||! /^[a-f0-9]{64}$/i.test(signature))return false;
 const bytes=typeof raw==='string'?new TextEncoder().encode(raw):raw;
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
 const sig=Uint8Array.from(signature.match(/../g),s=>parseInt(s,16));
 return crypto.subtle.verify('HMAC',key,sig,bytes);
}
export class IFoodError extends Error{constructor(message,{status=0,uncertain=false,retryAfter=0}={}){super(message);this.status=status;this.uncertain=uncertain;this.retryAfter=retryAfter}}
export function createIFoodClient({enabled=false,clientId,clientSecret,merchants=[],fetchImpl=fetch,now=Date.now,tokenStore=null,beforePoll=null}={}){
 let token=null,tokenUntil=0,tokenRequest=null,nextPoll=0;
 const allowed=new Set(merchants);
 const guard=()=>{if(!enabled||!clientId||!clientSecret||!allowed.size||[...allowed].some(id=>!uuid.test(id)))throw new IFoodError('Integração iFood desativada ou não configurada.');};
 async function request(path,{method='GET',body,headers={}}={}){
  try{return await fetchImpl(base+path,{method,headers,...(body!==undefined?{body}:{}),signal:AbortSignal.timeout(15000),redirect:'error'})}
  catch{throw new IFoodError('Falha de comunicação com o iFood.',{uncertain:method!=='GET'})}
 }
 async function checked(response,detail=false){
  if(!response.ok){const retry=response.headers.get('Retry-After');const seconds=Number(retry);const delay=retry?(Number.isFinite(seconds)?Math.max(0,seconds)*1000:Math.max(0,Date.parse(retry)-now())):0;let info='';if(detail){try{const raw=await response.json();if(detail==='order'){const data=raw.error&&typeof raw.error==='object'?raw.error:raw;info=' '+[data.code,data.message].filter(x=>typeof x==='string').join(': ').slice(0,400);for(const secret of [clientSecret,token])if(secret)info=info.split(secret).join('[oculto]');info=info.replace(/Bearer\s+[^\s]+/gi,'Bearer [oculto]')}else info=' '+JSON.stringify(raw).slice(0,600)}catch{}}throw new IFoodError('iFood retornou HTTP '+response.status+'.'+info,{status:response.status,uncertain:response.status>=500,retryAfter:Number.isFinite(delay)?delay:0})}
  if(response.status===204)return null;
  if(response.status===202){if(!detail)return null;const raw=await response.text();if(!raw.trim())return null;try{return JSON.parse(raw)}catch{throw new IFoodError('Resposta inválida do catálogo iFood.',{uncertain:true})}}
  try{return await response.json()}catch{throw new IFoodError('Resposta inválida do iFood.',{uncertain:true})}
 }
 async function getToken(){
  guard();if(token&&now()<tokenUntil)return token;
  if(!tokenRequest)tokenRequest=(async()=>{
   if(tokenStore){const cached=await tokenStore.get();if(cached?.accessToken&&Number(cached.expiresAt)>now()){token=cached.accessToken;tokenUntil=Number(cached.expiresAt);return token}
    if(!await tokenStore.acquire()){for(let i=0;i<25;i++){await new Promise(r=>setTimeout(r,200));const shared=await tokenStore.get();if(shared?.accessToken&&Number(shared.expiresAt)>now()){token=shared.accessToken;tokenUntil=Number(shared.expiresAt);return token}}throw new IFoodError('Autenticação iFood em atualização. Aguarde a próxima consulta.');}
   }
   try{const data=await checked(await request('/authentication/v1.0/oauth/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grantType:'client_credentials',clientId,clientSecret}).toString()}));if(!data?.accessToken||!Number.isFinite(Number(data.expiresIn))||Number(data.expiresIn)<=0)throw new IFoodError('Token iFood inválido.');token=data.accessToken;tokenUntil=now()+Number(data.expiresIn)*1000;if(tokenStore)await tokenStore.save({accessToken:token,expiresAt:tokenUntil});return token}catch(e){if(tokenStore)await tokenStore.release();throw e}
  })();
  try{return await tokenRequest}finally{tokenRequest=null}
 }
 async function api(path,options={},withStatus=false){const access=await getToken();const response=await request(path,{...options,headers:{Authorization:'Bearer '+access,'Content-Type':'application/json',...options.headers}});if(response.status===401){token=null;tokenUntil=0;if(tokenStore)await tokenStore.invalidate(access)}const value=await checked(response,path.startsWith('/catalog/')?true:path.endsWith('/requestCancellation')?'order':false);return withStatus?{status:response.status}:value}
 function merchant(id){guard();if(!allowed.has(id))throw new IFoodError('Loja fora do escopo autorizado.');}
 return {
  async poll(ids){guard();if(!Array.isArray(ids)||!ids.length||ids.length>100)throw new IFoodError('Informe de 1 a 100 lojas.');ids.forEach(merchant);if(now()<nextPoll)throw new IFoodError('Aguarde o intervalo de polling.',{retryAfter:nextPoll-now()});await getToken();if(beforePoll)await beforePoll();nextPoll=now()+30000;try{return await api('/events/v1.0/events:polling?categories=FOOD',{headers:{'x-polling-merchants':ids.join(',')}})||[]}catch(e){if(e.retryAfter)nextPoll=Math.max(nextPoll,now()+e.retryAfter);throw e}},
  async acknowledge(events){guard();if(!Array.isArray(events)||!events.length||events.length>2000)throw new IFoodError('Lote de eventos inválido.');events.forEach(e=>{merchant(e.merchantId);if(!uuid.test(e.id))throw new IFoodError('Evento inválido.');});return api('/events/v1.0/events/acknowledgment',{method:'POST',body:JSON.stringify(events.map(e=>({id:e.id})))})},
  async catalog(merchantId,action,{catalogId,id,payload}={}){
   merchant(merchantId);const root='/catalog/v2.0/merchants/'+merchantId;
   if(catalogId&&!uuid.test(catalogId)||id&&!(action==='batch'?/^[a-zA-Z0-9_-]{1,150}$/.test(id):uuid.test(id)))throw new IFoodError('Identificador de catálogo inválido.');
   const routes={categories:[root+'/catalogs/'+catalogId+'/categories','GET'],createCategory:[root+'/catalogs/'+catalogId+'/categories','POST'],updateCategory:[root+'/catalogs/'+catalogId+'/categories/'+id,'PATCH'],prices:[root+'/products/price','PATCH'],statuses:[root+'/products/status','PATCH'],putItem:[root+'/items','PUT'],item:[root+'/items/'+id+'/flat','GET'],status:[root+'/items/status','PATCH'],batch:[root+'/batch/'+id,'GET'],image:[root+'/image/upload','POST']};
   if(!routes[action])throw new IFoodError('Operação de catálogo inválida.');const [path,method]=routes[action];return api(path,{method,...(payload?{body:JSON.stringify(payload)}:{})});
  },
  async catalogs(merchantId){merchant(merchantId);return api('/catalog/v2.0/merchants/'+merchantId+'/catalogs')},
  async status(merchantId){merchant(merchantId);return api('/merchant/v1.0/merchants/'+merchantId+'/status')},
  async cancellationReasons(id,merchantId){merchant(merchantId);if(!uuid.test(id))throw new IFoodError('Pedido inválido.');return api('/order/v1.0/orders/'+id+'/cancellationReasons')},
  async command(id,merchantId,action,payload={}){
   merchant(merchantId);if(!uuid.test(id))throw new IFoodError('Pedido inválido.');
   const paths={confirmar:'confirm',preparar:'startPreparation',pronto:'readyToPickup',despachar:'dispatch',solicitar_cancelamento:'requestCancellation'};
   if(!paths[action])throw new IFoodError('Comando inválido.');
   if(action==='solicitar_cancelamento'){if(!/^[0-9]{3}$/.test(String(payload.cancellationCode||'')))throw new IFoodError('Código de cancelamento inválido.');payload={cancellationCode:String(payload.cancellationCode),reason:String(payload.reason||payload.cancellationCode).slice(0,250)}}
   return api('/order/v1.0/orders/'+id+'/'+paths[action],{method:'POST',...(Object.keys(payload).length?{body:JSON.stringify(payload)}:{})},true);
  },
  async dispute(disputeId,merchantId,action,payload={}){merchant(merchantId);if(!uuid.test(disputeId)||!['accept','reject','alternative'].includes(action))throw new IFoodError('Negociação inválida.');return api('/order/v1.0/disputes/'+disputeId+'/'+action,{method:'POST',body:JSON.stringify(payload)})},
  async order(id,merchantId){merchant(merchantId);if(!uuid.test(id))throw new IFoodError('Pedido inválido.');const data=await api('/order/v1.0/orders/'+id);if(data?.merchant?.id!==merchantId)throw new IFoodError('Pedido pertence a outra loja.');return data},
 };
}
