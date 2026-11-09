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
export function createIFoodClient({enabled=false,clientId,clientSecret,merchants=[],fetchImpl=fetch,now=Date.now}={}){
 let token=null,tokenUntil=0,tokenRequest=null,nextPoll=0;
 const allowed=new Set(merchants);
 const guard=()=>{if(!enabled||!clientId||!clientSecret||!allowed.size||[...allowed].some(id=>!uuid.test(id)))throw new IFoodError('Integração iFood desativada ou não configurada.');};
 async function request(path,{method='GET',body,headers={}}={}){
  try{return await fetchImpl(base+path,{method,headers,...(body!==undefined?{body}:{}),signal:AbortSignal.timeout(15000),redirect:'error'})}
  catch{throw new IFoodError('Falha de comunicação com o iFood.',{uncertain:method!=='GET'})}
 }
 async function checked(response){
  if(!response.ok){const retry=response.headers.get('Retry-After');const seconds=Number(retry);const delay=retry?(Number.isFinite(seconds)?Math.max(0,seconds)*1000:Math.max(0,Date.parse(retry)-now())):0;throw new IFoodError('iFood retornou HTTP '+response.status+'.',{status:response.status,uncertain:response.status>=500,retryAfter:Number.isFinite(delay)?delay:0})}
  if(response.status===204||response.status===202)return null;
  try{return await response.json()}catch{throw new IFoodError('Resposta inválida do iFood.',{uncertain:true})}
 }
 async function getToken(){
  guard();if(token&&now()<tokenUntil)return token;
  if(!tokenRequest)tokenRequest=(async()=>{const data=await checked(await request('/authentication/v1.0/oauth/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grantType:'client_credentials',clientId,clientSecret}).toString()}));if(!data?.accessToken||!Number.isFinite(Number(data.expiresIn))||Number(data.expiresIn)<=0)throw new IFoodError('Token iFood inválido.');token=data.accessToken;tokenUntil=now()+Math.max(0,Number(data.expiresIn)*1000-60000);return token})();
  try{return await tokenRequest}finally{tokenRequest=null}
 }
 async function api(path,options={}){const access=await getToken();const response=await request(path,{...options,headers:{Authorization:'Bearer '+access,'Content-Type':'application/json',...options.headers}});if(response.status===401){token=null;tokenUntil=0}return checked(response)}
 function merchant(id){guard();if(!allowed.has(id))throw new IFoodError('Loja fora do escopo autorizado.');}
 return {
  async poll(ids){guard();if(!Array.isArray(ids)||!ids.length||ids.length>100)throw new IFoodError('Informe de 1 a 100 lojas.');ids.forEach(merchant);if(now()<nextPoll)throw new IFoodError('Aguarde o intervalo de polling.',{retryAfter:nextPoll-now()});nextPoll=now()+30000;try{return await api('/events/v1.0/events:polling?categories=FOOD',{headers:{'x-polling-merchants':ids.join(',')}})||[]}catch(e){if(e.retryAfter)nextPoll=Math.max(nextPoll,now()+e.retryAfter);throw e}},
  async acknowledge(events){guard();if(!Array.isArray(events)||!events.length||events.length>2000)throw new IFoodError('Lote de eventos inválido.');events.forEach(e=>{merchant(e.merchantId);if(!uuid.test(e.id))throw new IFoodError('Evento inválido.');});return api('/events/v1.0/events/acknowledgment',{method:'POST',body:JSON.stringify(events.map(e=>({id:e.id})))})},
  async order(id,merchantId){merchant(merchantId);if(!uuid.test(id))throw new IFoodError('Pedido inválido.');const data=await api('/order/v1.0/orders/'+id);if(data?.merchant?.id!==merchantId)throw new IFoodError('Pedido pertence a outra loja.');return data},
 };
}
