import {createHash,timingSafeEqual} from 'node:crypto';
const appId='5764607791191296200',appShopId='florest-gastronomia-teste-01',shopId='5764619883330929453';
const reply=(status:number,errno:number,errmsg:string)=>Response.json({errno,errmsg},{status,headers:{'Cache-Control':'no-store'}});
function parse(raw:string){return JSON.parse(raw.replace(/"(?:\\[\s\S]|[^"\\])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/g,v=>v.startsWith('"')||/[.eE]/.test(v)||Number.isSafeInteger(Number(v))?v:JSON.stringify(v)))}
Deno.serve(async(req:Request)=>{
 if(['GET','HEAD'].includes(req.method))return reply(200,0,'Webhook 99Food de teste.');
 if(req.method!=='POST')return reply(405,1,'Método inválido.');
 const secret=Deno.env.get('FOOD99_SANDBOX_APP_SECRET'),signature=req.headers.get('didi-header-sign')??'';
 if(!secret)return reply(503,1,'Configuração indisponível.');
 if(!/^[a-f\d]{32}$/i.test(signature))return reply(401,1,'Assinatura inválida.');
 try{
  const reader=req.body?.getReader();if(!reader)return reply(400,1,'Corpo ausente.');
  const chunks:Uint8Array[]=[];let size=0;
  while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>256*1024){await reader.cancel();return reply(413,1,'Dados excessivos.')}chunks.push(value)}
  const raw=new Uint8Array(size);let offset=0;for(const chunk of chunks){raw.set(chunk,offset);offset+=chunk.length}
  const digest=createHash('md5').update(raw).update(secret).digest();
  if(!timingSafeEqual(digest,Uint8Array.from(signature.match(/../g)!,part=>Number.parseInt(part,16))))return reply(401,1,'Assinatura inválida.');
  let event;try{event=parse(new TextDecoder('utf-8',{fatal:true}).decode(raw))}catch{return reply(400,1,'JSON inválido.')}
  if(String(event.app_id)!==appId||event.app_shop_id!==appShopId||typeof event.type!=='string'||!event.type||event.type.length>100)return reply(403,1,'Vínculo inválido.');
  if(typeof event.data==='string')try{event.data=parse(event.data)}catch{return reply(400,1,'Dados inválidos.')}
  const inner=event.data?.order_info,orderId=String(event.data?.order_id??inner?.order_id??'');
  if(inner?.shop?.shop_id!==undefined&&String(inner.shop.shop_id)!==shopId)return reply(403,1,'Loja inválida.');
  if(inner?.order_id!==undefined&&String(inner.order_id)!==orderId)return reply(400,1,'Pedido divergente.');
  const id=/^[1-9]\d{0,18}$/.test(orderId)?orderId:'';
  // Eventos sem pedido (por exemplo notificações da loja) também recebem ACK após persistência.
  if(event.type.startsWith('order')&&!id)return reply(400,1,'Pedido inválido.');
  const project=Deno.env.get('SUPABASE_URL'),key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if(!project||!key)return reply(503,1,'Servidor indisponível.');
  const res=await fetch(project+'/rest/v1/rpc/gastronomia_99food_sandbox_worker',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({p_acao:'evento',p_dados:{id:createHash('sha256').update(raw).digest('hex'),order_id:id,payload:event}}),signal:AbortSignal.timeout(3500)});
  if(!res.ok){console.error('99food_persistencia_http',res.status);return reply(503,1,'Persistência indisponível.');}
  return reply(200,0,'ok');
 }catch(error){console.error('99food_webhook_falha',error instanceof Error?error.name:'Erro');return reply(503,1,'Não foi possível registrar o evento.')}
});
