import http from 'node:http';
import fs from 'node:fs';
import pathModule from 'node:path';
import https from 'node:https';
import crypto from 'node:crypto';
import {pathToFileURL} from 'node:url';

const json=(res,status,body)=>{res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store','x-content-type-options':'nosniff'});res.end(JSON.stringify(body));};
export function verifyJwt(token,secret,issuer,now=Math.floor(Date.now()/1000)){
 try{
  const parts=String(token).split('.');if(parts.length!==3)return null;
  const header=JSON.parse(Buffer.from(parts[0],'base64url'));if(header.alg!=='HS256')return null;
  const expected=crypto.createHmac('sha256',secret).update(parts[0]+'.'+parts[1]).digest();
  const actual=Buffer.from(parts[2],'base64url');if(actual.length!==expected.length||!crypto.timingSafeEqual(expected,actual))return null;
  const claims=JSON.parse(Buffer.from(parts[1],'base64url'));
  if(!Number.isFinite(claims.exp)||claims.exp<=now||claims.iss!==issuer||claims.aud!=='authenticated'||(claims.nbf&&claims.nbf>now+5))return null;
  return ['anon','authenticated','service_role'].includes(claims.role)?claims:null;
 }catch{return null;}
}
function equal(a,b){const x=Buffer.from(String(a??'')),y=Buffer.from(String(b??''));return x.length===y.length&&crypto.timingSafeEqual(x,y);}
function endpoint(value){const u=new URL(value);if(!['http:','https:'].includes(u.protocol)||u.username||u.password||u.search||u.hash)throw Error('Endereço interno inválido');return u;}
export function createGateway(config){
 const {secret,anonKey,serviceKey,issuer}=config;
 if(!secret||secret.length<32||!anonKey||!serviceKey)throw Error('Configuração do gateway incompleta');
 const auth=endpoint(config.authUrl),rest=endpoint(config.restUrl),functions=endpoint(config.functionsUrl),returnRest=config.returnRestUrl?endpoint(config.returnRestUrl):null;
 const allowedOrigins=new Set(config.allowedOrigins||[]),readonlyRpc=new Set(config.readonlyRpc||[]);
 const preview=config.preview!==false,sandboxWrites=config.sandboxWrites===true,limit=config.maxBodyBytes||16384,timeout=config.timeoutMs||15000;
 const attempts=new Map();
 const control=config.controlUrl?endpoint(config.controlUrl):null;
 const server=http.createServer(async(req,res)=>{
  const origin=req.headers.origin;
  if(origin&&!allowedOrigins.has(origin))return json(res,403,{erro:'origem_nao_permitida'});
  res.setHeader('vary','Origin');
  if(origin)res.setHeader('access-control-allow-origin',origin);
  res.setHeader('access-control-allow-methods',sandboxWrites?'GET,HEAD,POST,PATCH,PUT,DELETE,OPTIONS':'GET,HEAD,POST,OPTIONS');
  res.setHeader('access-control-allow-headers','authorization,apikey,content-type,x-client-info,prefer,range,accept-profile,content-profile,x-florest-test-control');
  res.setHeader('access-control-expose-headers','content-range,range-unit');
  if(req.method==='OPTIONS'){res.writeHead(204);res.end();return;}
  let u;try{u=new URL(req.url,'http://gateway');}catch{return json(res,400,{erro:'caminho_invalido'});}
  if(control&&['/lab-control/v1/state','/lab-control/v1/action'].includes(u.pathname)){
   const action=u.pathname.endsWith('/action');
   if(req.method!==(action?'POST':'GET'))return json(res,405,{erro:'metodo_nao_permitido'});
   let body=Buffer.alloc(0);
   if(action){try{let size=0,parts=[];for await(const c of req){size+=c.length;if(size>4096)return json(res,413,{erro:'corpo_muito_grande'});parts.push(c);}body=Buffer.concat(parts);}catch{return json(res,400,{erro:'corpo_invalido'});}}
   try{
    const response=await fetch(new URL(action?'/action':'/state',control),{method:req.method,headers:{'content-type':'application/json','x-florest-test-control':String(req.headers['x-florest-test-control']||'')},body:action?body:undefined,signal:AbortSignal.timeout(action?60000:4000)});
    return json(res,response.status,await response.json());
   }catch{return json(res,503,{erro:'controle_de_teste_indisponivel',message:'O controle do ensaio não respondeu. Consulte o estado antes de repetir a troca.'});}
  }
  if(config.webRoot&&['GET','HEAD'].includes(req.method)&&!u.pathname.startsWith('/auth/')&&!u.pathname.startsWith('/rest/')&&!u.pathname.startsWith('/functions/')&&!u.pathname.startsWith('/retorno/rest/')&&!u.pathname.startsWith('/reserva/rest/')&&u.pathname!=='/healthz'){
   if(u.pathname==='/preview-config.js'){
    res.writeHead(200,{'content-type':'text/javascript; charset=utf-8','cache-control':'no-store'});
    return res.end('window.FLOREST_PREVIEW='+JSON.stringify({url:config.publicUrl,anonKey,sandboxWrites,sourceDate:'07/11/2026'})+';');
   }
   let relative;try{relative=decodeURIComponent(u.pathname);}catch{return json(res,400,{erro:'caminho_invalido'});}
   if(relative==='/'){res.writeHead(302,{location:'/erp/'});res.end();return;}
   if(relative.endsWith('/'))relative+='index.html';
   const file=pathModule.resolve(config.webRoot,'.'+relative),root=pathModule.resolve(config.webRoot);
   if(!file.startsWith(root+pathModule.sep))return json(res,404,{erro:'arquivo_indisponivel'});
   const types={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.png':'image/png','.webp':'image/webp','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon'};
   const type=types[pathModule.extname(file)];if(!type||!fs.existsSync(file)||!fs.statSync(file).isFile())return json(res,404,{erro:'arquivo_indisponivel'});
   res.writeHead(200,{'content-type':type,'cache-control':'no-store','x-content-type-options':'nosniff'});
   if(req.method==='HEAD')return res.end();fs.createReadStream(file).pipe(res);return;
  }
  if(u.pathname==='/healthz'){
   if(req.method!=='GET')return json(res,405,{erro:'metodo_nao_permitido'});
   const checks=await Promise.allSettled([fetch(new URL('/health',auth),{signal:AbortSignal.timeout(timeout)}),fetch(new URL('/',rest),{signal:AbortSignal.timeout(timeout)})]);
   const ok=checks.every(x=>x.status==='fulfilled'&&x.value.ok);
   for(const r of checks)if(r.status==='fulfilled')r.value.body?.cancel().catch(()=>{});
   return json(res,ok?200:503,{ok,mode:sandboxWrites?'sandbox_write':(preview?'preview_read_only':'operational'),production_switched:false,auth:checks[0].status==='fulfilled'&&checks[0].value.ok,rest:checks[1].status==='fulfilled'&&checks[1].value.ok});
  }
  const apiKey=req.headers.apikey;
  const apiClaims=verifyJwt(apiKey,secret,issuer);
  if(!apiClaims||!['anon','service_role'].includes(apiClaims.role))return json(res,401,{erro:'apikey_invalida'});
  const bearer=String(req.headers.authorization||'').replace(/^Bearer\s+/i,'');
  const claims=verifyJwt(bearer,secret,issuer);
  let upstream,path=u.pathname,activeDatabase=null;
  if(path.startsWith('/auth/v1/')){
   upstream=auth;path=path.slice('/auth/v1'.length);
   if(path.startsWith('/admin/')&&claims?.role!=='service_role')return json(res,403,{erro:'administracao_restrita'});
   const publicAuth=(path==='/token'&&req.method==='POST')||(path==='/logout'&&req.method==='POST')||(['/health','/settings','/user'].includes(path)&&req.method==='GET');
   const internalAdmin=path.startsWith('/admin/')&&claims?.role==='service_role';
   if(!publicAuth&&!internalAdmin)return json(res,503,{erro:'recurso_nao_habilitado_na_previa',mensagem:'Cadastro, recuperação e alterações de conta não estão habilitados neste teste.'});
  }else if(path.startsWith('/reserva/rest/v1/')){
   if(!claims)return json(res,401,{erro:'sessao_invalida'});
   path=path.slice('/reserva/rest/v1'.length);
   if(!['GET','HEAD'].includes(req.method)||!/^\/(vendas|itens_venda)$/.test(path))return json(res,423,{erro:'reserva_somente_consulta'});
   upstream=rest;res.setHeader('x-florest-environment','aws-reserva-teste');
  }else if(path.startsWith('/retorno/rest/v1/')){
   if(!claims)return json(res,401,{erro:'sessao_invalida'});
   if(!returnRest)return json(res,503,{erro:'retorno_de_teste_nao_habilitado'});
   path=path.slice('/retorno/rest/v1'.length);
   if(!['GET','HEAD'].includes(req.method)||!/^\/(vendas|itens_venda)$/.test(path))return json(res,423,{erro:'retorno_somente_consulta'});
   upstream=returnRest;res.setHeader('x-florest-environment','retorno-teste-isolado');
  }else if(path.startsWith('/rest/v1/')){
   if(!claims)return json(res,401,{erro:'sessao_invalida'});
   upstream=rest;path=path.slice('/rest/v1'.length);
   if(control){
    try{
     const response=await fetch(new URL('/state',control),{signal:AbortSignal.timeout(4000)}),state=await response.json();
     if(!response.ok||!state.sandbox_only||state.status!=='ready')return json(res,503,{code:'LAB_SWITCHING',message:'O principal de teste está indisponível ou em troca. Abra o simulador para assumir na reserva.'});
     activeDatabase=state.active_database;
     if(activeDatabase==='florest_backend_teste_20261108')upstream=rest;
     else if(activeDatabase==='florest_retorno_teste_20261108'&&returnRest)upstream=returnRest;
     else return json(res,503,{code:'LAB_NO_WRITER',message:'Nenhum banco de teste foi confirmado para gravação.'});
    }catch{return json(res,503,{code:'LAB_CONTROL_UNAVAILABLE',message:'Controle do ensaio indisponível; nenhuma operação foi encaminhada ao Supabase real.'});}
    if(req.method==='POST'&&path==='/rpc/registrar_venda_mista')return json(res,423,{code:'LAB_RELOAD_REQUIRED',message:'Recarregue o ERP de teste para usar a venda protegida contra repetição.'});
   }
   if(sandboxWrites){
    const fiscal=path.match(/^\/rpc\/(fiscal_[a-z0-9_]+|dadosjah_[a-z0-9_]+)$/)?.[1];
    if(fiscal&&!readonlyRpc.has(fiscal))return json(res,423,{erro:'fiscal_bloqueado_no_teste',mensagem:'Venda de teste liberada; emissão e alterações fiscais bloqueadas.'});
    if(!['GET','HEAD'].includes(req.method)&&/^\/(documentos_fiscais|contadores_fiscais|fiscal_[^/]*|nfce_[^/]*)(?:$|\/)/.test(path))return json(res,423,{erro:'fiscal_bloqueado_no_teste'});
   }
   if(preview&&!sandboxWrites&&!['GET','HEAD'].includes(req.method)){
    const name=path.match(/^\/rpc\/([a-z][a-z0-9_]*)$/)?.[1];
    if(req.method!=='POST'||!name||!readonlyRpc.has(name))return json(res,423,{erro:'previa_somente_leitura',mensagem:'Operações de gravação estão bloqueadas no ambiente de teste.'});
   }
  }else if(path==='/functions/v1/florest-login'){
   if(req.method!=='POST')return json(res,405,{erro:'metodo_nao_permitido'});
   upstream=functions;
  }else if(path.startsWith('/functions/v1/')){
   return json(res,503,{erro:'funcao_ainda_nao_implantada',mensagem:'Este serviço ainda não está disponível no reserva; nenhuma chamada foi enviada ao principal.'});
  }else return json(res,404,{erro:'rota_nao_disponivel'});
  if((path==='/token'||u.pathname==='/functions/v1/florest-login')&&req.method==='POST'){
   const key=req.socket.remoteAddress||'local',now=Date.now(),old=attempts.get(key);
   const current=old&&now-old.start<60000?old:{start:now,count:0};current.count++;attempts.set(key,current);
   if(attempts.size>10000)for(const [k,v]of attempts)if(now-v.start>60000)attempts.delete(k);
   if(current.count>40){res.setHeader('retry-after','60');return json(res,429,{erro:'muitas_tentativas'});}
  }
  const declared=Number(req.headers['content-length']||0);
  if(!Number.isFinite(declared)||declared>limit)return json(res,413,{erro:'corpo_muito_grande'});
  let chunks=[],size=0;
  try{
   for await(const chunk of req){size+=chunk.length;if(size>limit){json(res,413,{erro:'corpo_muito_grande'});return;}chunks.push(chunk);}
  }catch{return json(res,400,{erro:'corpo_invalido'});}
  if(preview&&!config.allowExistingUsers&&req.method==='POST'&&(u.pathname==='/functions/v1/florest-login'||u.pathname==='/auth/v1/token'||u.pathname==='/auth/v1/admin/users')){
   let input;try{input=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{return json(res,400,{erro:'json_invalido'});}
   if(u.pathname==='/functions/v1/florest-login'&&!String(input.usuario||'').startsWith('florest-preview-'))return json(res,403,{erro:'somente_operadores_tecnicos',mensagem:'Esta prévia aceita somente operadores técnicos de teste.'});
   const passwordGrant=u.pathname==='/auth/v1/token'&&u.searchParams.get('grant_type')==='password';
   if((passwordGrant||u.pathname==='/auth/v1/admin/users')&&!/@florest-test[.]invalid$/i.test(String(input.email||'')))return json(res,403,{erro:'somente_identidades_de_teste'});
  }
  if(!path.startsWith('/')||path.startsWith('//')||path.includes('\\'))return json(res,400,{erro:'caminho_invalido'});
  const target=new URL(path+u.search,upstream),headers={};
  if(target.origin!==upstream.origin)return json(res,400,{erro:'destino_invalido'});
  for(const key of ['authorization','apikey','content-type','accept','prefer','range','accept-profile','content-profile','x-client-info','origin'])if(req.headers[key])headers[key]=req.headers[key];
  headers.host=target.host;
  const body=Buffer.concat(chunks);headers['content-length']=String(body.length);
  let settled=false;
  const client=(target.protocol==='https:'?https:http).request(target,{method:req.method,headers},incoming=>{
   const barrier=control&&activeDatabase&&!['GET','HEAD'].includes(req.method)&&incoming.statusCode>=200&&incoming.statusCode<300;
   if(barrier){
    const chunks=[];let size=0;
    incoming.on('data',c=>{size+=c.length;if(size>2097152)client.destroy(Error('upstream_response_too_large'));else chunks.push(c);});
    incoming.on('end',async()=>{
     clearTimeout(deadline);const original=Buffer.concat(chunks);
     try{
      let input={};try{input=JSON.parse(body.toString('utf8'));}catch{}
      const confirmation=await fetch(new URL('/confirm',control),{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({source:activeDatabase,actor:claims?.sub,operation:path==='/rpc/florest_sandbox_registrar_venda_mista'?input.p_operacao:null}),signal:AbortSignal.timeout(25000)});
      if(!confirmation.ok)throw Error('backup_pending');
      const receipt=await confirmation.json();if(!receipt.ok)throw Error('backup_pending');
      if(res.destroyed)return;settled=true;
      for(const [key,value]of Object.entries(incoming.headers))if(value&&!['connection','transfer-encoding','access-control-allow-origin','access-control-allow-headers','access-control-allow-methods','content-security-policy'].includes(key))res.setHeader(key,value);
      res.setHeader('cache-control','no-store');res.setHeader('x-florest-test-receipt',receipt.pending_return?'durable-reserve-pending-return':'shadow-confirmed');
      res.writeHead(incoming.statusCode);res.end(original);
     }catch{if(!res.destroyed)json(res,503,{code:'LAB_BACKUP_PENDING',message:'A operação pode já estar gravada no banco ativo, mas o espelho não confirmou. Consulte o histórico antes de repetir. A mesma tentativa de venda mantém seu identificador.'});}
    });
    return;
   }
   settled=true;
   for(const [key,value]of Object.entries(incoming.headers))if(value&&!['connection','transfer-encoding','access-control-allow-origin','access-control-allow-headers','access-control-allow-methods','content-security-policy'].includes(key))res.setHeader(key,value);
   res.setHeader('cache-control','no-store');res.setHeader('x-content-type-options','nosniff');
   res.writeHead(incoming.statusCode);incoming.pipe(res);
   incoming.on('end',()=>clearTimeout(deadline));
  });
  const deadline=setTimeout(()=>client.destroy(Error('upstream_timeout')),timeout);
  client.setTimeout(timeout,()=>client.destroy(Error('upstream_timeout')));
  client.on('error',error=>{clearTimeout(deadline);if(!settled&&!res.headersSent)json(res,error.message==='upstream_timeout'?504:503,{erro:error.message==='upstream_timeout'?'tempo_esgotado':'servico_indisponivel',mensagem:'O serviço de teste não respondeu. Nenhuma operação foi redirecionada ao principal.'});else res.destroy();});
  req.on('aborted',()=>client.destroy());client.end(body);
 });
 server.requestTimeout=timeout+2000;server.headersTimeout=10000;return server;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const env=process.env;
 const server=createGateway({secret:env.JWT_SECRET,anonKey:env.ANON_KEY,serviceKey:env.SERVICE_ROLE_KEY,issuer:env.JWT_ISSUER,authUrl:env.AUTH_URL,restUrl:env.REST_URL,functionsUrl:env.FUNCTIONS_URL,returnRestUrl:env.RETURN_REST_URL,controlUrl:env.LAB_CONTROL_URL,allowedOrigins:(env.ALLOWED_ORIGINS||'').split(',').filter(Boolean),preview:true,sandboxWrites:env.SANDBOX_WRITES==='true',allowExistingUsers:env.ALLOW_EXISTING_USERS==='true',webRoot:env.WEB_ROOT,publicUrl:env.PUBLIC_URL,readonlyRpc:(env.READONLY_RPC_NAMES||'').split(',').filter(Boolean)});
 server.listen(Number(env.PORT||8080),'0.0.0.0',()=>console.log('Gateway de teste iniciado; produção permanece no principal.'));
}
