import {test} from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import http from 'node:http';
import {createGateway,verifyJwt} from '../gateway/server.mjs';
const secret=crypto.randomBytes(48).toString('hex'),issuer='http://reserva.local/auth/v1';
function token(role='authenticated',extra={},key=secret,alg='HS256'){
 const a=Buffer.from(JSON.stringify({alg,typ:'JWT'})).toString('base64url'),b=Buffer.from(JSON.stringify({role,iss:issuer,aud:'authenticated',sub:'00000000-0000-4000-8000-000000000001',exp:Math.floor(Date.now()/1000)+600,...extra})).toString('base64url');
 return a+'.'+b+'.'+crypto.createHmac('sha256',key).update(a+'.'+b).digest('base64url');
}
const anon=token('anon'),service=token('service_role');
async function fixture(options={}){
 let calls=[],controlCalls=[],returnServer=null,labServer=null;
 const makeUpstream=backend=>http.createServer((req,res)=>{calls.push(req.url);if(options.hang)return;res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({ok:true,path:req.url,backend}));});
 const upstream=makeUpstream('reserve');await new Promise(r=>upstream.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+upstream.address().port;
 let returnUrl,controlUrl;
 if(options.returnRest){returnServer=makeUpstream('return');await new Promise(r=>returnServer.listen(0,'127.0.0.1',r));returnUrl='http://127.0.0.1:'+returnServer.address().port;}
 if(options.lab){
  labServer=http.createServer(async(req,res)=>{
   let text='';for await(const c of req)text+=c;
   controlCalls.push({path:req.url,body:text?JSON.parse(text):null});res.setHeader('content-type','application/json');
   if(req.url==='/state'){res.end(JSON.stringify({sandbox_only:true,status:'ready',active_database:'florest_backend_teste_20261108',...options.lab.state}));return;}
   if(req.url==='/action'){const valid=req.headers['x-florest-test-control']==='synthetic-control-code';res.writeHead(valid?200:401);res.end(JSON.stringify({ok:valid}));return;}
   if(req.url==='/confirm'){res.writeHead(options.lab.reject?409:200);res.end(JSON.stringify(options.lab.reject?{error:'pending'}:{ok:true,pending_return:!!options.lab.pending}));return;}
   res.writeHead(404);res.end('{}');
  });await new Promise(r=>labServer.listen(0,'127.0.0.1',r));controlUrl='http://127.0.0.1:'+labServer.address().port;
 }
 const gateway=createGateway({secret,anonKey:anon,serviceKey:service,issuer,authUrl:url,restUrl:url,functionsUrl:url,returnRestUrl:returnUrl,controlUrl,allowedOrigins:['http://reserva.local'],timeoutMs:100,readonlyRpc:['contexto'],...options.config});
 await new Promise(r=>gateway.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+gateway.address().port;
 return {calls,controlCalls,base,headers:{apikey:anon,authorization:'Bearer '+token()},async close(){await new Promise(r=>gateway.close(r));await new Promise(r=>upstream.close(r));if(returnServer)await new Promise(r=>returnServer.close(r));if(labServer)await new Promise(r=>labServer.close(r));}};
}
test('JWT exige assinatura, emissor, audiência, validade e papel permitido',()=>{
 assert.equal(verifyJwt(token(),secret,issuer).role,'authenticated');
 for(const value of [token('authenticated',{},'outra-chave'),token('authenticated',{iss:'http://principal'}),token('authenticated',{aud:'outro'}),token('authenticated',{exp:1}),token('postgres'),token('authenticated',{},secret,'none'),'invalido'])assert.equal(verifyJwt(value,secret,issuer),null);
});
test('leitura com sessão válida preserva filtros e não usa o principal',async()=>{
 const f=await fixture();try{const r=await fetch(f.base+'/rest/v1/vendas?select=id&empresa_id=eq.a',{headers:f.headers});assert.equal(r.status,200);assert.equal((await r.json()).path,'/vendas?select=id&empresa_id=eq.a');assert.equal(r.headers.get('cache-control'),'no-store');}finally{await f.close();}
});
test('API recusa sessão expirada e origem não permitida antes de encaminhar',async()=>{
 const f=await fixture();try{
  assert.equal((await fetch(f.base+'/rest/v1/vendas',{headers:{...f.headers,authorization:'Bearer '+token('authenticated',{exp:1})}})).status,401);
  assert.equal((await fetch(f.base+'/rest/v1/vendas',{headers:{...f.headers,origin:'http://nao-permitido'}})).status,403);assert.equal(f.calls.length,0);
 }finally{await f.close();}
});
test('gravação, transmissão fiscal e RPC desconhecida ficam bloqueadas',async()=>{
 const f=await fixture();try{
  for(const [method,path]of [['POST','/rest/v1/vendas'],['PATCH','/rest/v1/produtos'],['DELETE','/rest/v1/vendas'],['POST','/rest/v1/rpc/venda_finalizar']])assert.equal((await fetch(f.base+path,{method,headers:f.headers,body:'{}'})).status,423);
  assert.equal((await fetch(f.base+'/functions/v1/fiscal-emitir-documento',{method:'POST',headers:f.headers,body:'{}'})).status,503);assert.equal(f.calls.length,0);
 }finally{await f.close();}
});
test('RPC de leitura exige nome explícito; login não libera administração do Auth',async()=>{
 const f=await fixture();try{
  assert.equal((await fetch(f.base+'/rest/v1/rpc/contexto',{method:'POST',headers:f.headers,body:'{}'})).status,200);
  assert.equal((await fetch(f.base+'/auth/v1/admin/users',{headers:f.headers})).status,403);
  assert.equal((await fetch(f.base+'/auth/v1/admin/users',{headers:{apikey:service,authorization:'Bearer '+service}})).status,200);
  assert.equal((await fetch(f.base+'/auth/v1/signup',{method:'POST',headers:f.headers,body:'{}'})).status,503);
 }finally{await f.close();}
});
test('caminhos com autoridade externa não recebem tokens nem requisições',async()=>{
 const f=await fixture();try{const r=await fetch(f.base+'/rest/v1//example.invalid/roubar',{headers:f.headers});assert.equal(r.status,400);assert.equal(f.calls.length,0);}finally{await f.close();}
});
test('falha ou timeout devolve erro limitado sem recorrer ao Supabase',async()=>{
 const f=await fixture({hang:true});try{const r=await fetch(f.base+'/rest/v1/vendas',{headers:f.headers});assert.equal(r.status,504);assert.equal((await r.json()).erro,'tempo_esgotado');assert.equal(f.calls.length,1);}finally{await f.close();}
});
test('corpo acima do limite é recusado sem encaminhar credenciais',async()=>{
 const f=await fixture({config:{maxBodyBytes:10}});try{const r=await fetch(f.base+'/functions/v1/florest-login',{method:'POST',headers:{apikey:anon},body:'x'.repeat(20)});assert.equal(r.status,413);assert.equal(f.calls.length,0);}finally{await f.close();}
});
test('sandbox permite venda e mantém emissão fiscal e administração protegidas',async()=>{
 const f=await fixture({config:{sandboxWrites:true,allowExistingUsers:true,readonlyRpc:['fiscal_contingencia_status']}});try{
  assert.equal((await fetch(f.base+'/rest/v1/rpc/registrar_venda_mista',{method:'POST',headers:f.headers,body:'{}'})).status,200);
  assert.equal((await fetch(f.base+'/rest/v1/vendas',{method:'POST',headers:f.headers,body:'{}'})).status,200);
  assert.equal((await fetch(f.base+'/rest/v1/rpc/fiscal_emitir_nota',{method:'POST',headers:f.headers,body:'{}'})).status,423);
  assert.equal((await fetch(f.base+'/rest/v1/rpc/fiscal_contingencia_status',{method:'POST',headers:f.headers,body:'{}'})).status,200);
  assert.equal((await fetch(f.base+'/rest/v1/contadores_fiscais',{method:'PATCH',headers:f.headers,body:'{}'})).status,423);
  assert.equal((await fetch(f.base+'/functions/v1/fiscal-emitir-documento',{method:'POST',headers:f.headers,body:'{}'})).status,503);
  assert.equal((await fetch(f.base+'/auth/v1/admin/users',{headers:f.headers})).status,403);
 }finally{await f.close();}
});
test('consulta de retorno exige sessão e recusa qualquer gravação ou RPC',async()=>{
 const f=await fixture();try{
  assert.equal((await fetch(f.base+'/retorno/rest/v1/vendas',{headers:{apikey:anon}})).status,401);
  assert.equal((await fetch(f.base+'/retorno/rest/v1/vendas',{headers:f.headers})).status,503);
 }finally{await f.close();}
});

test('retorno configurado consulta outro serviço e não permite mutações',async()=>{
 const f=await fixture({returnRest:true});try{
  const r=await fetch(f.base+'/retorno/rest/v1/vendas?numero_venda=eq.7',{headers:f.headers});assert.equal(r.status,200);assert.equal(r.headers.get('x-florest-environment'),'retorno-teste-isolado');assert.equal((await r.json()).path,'/vendas?numero_venda=eq.7');
  for(const [method,path]of [['POST','/retorno/rest/v1/vendas'],['PATCH','/retorno/rest/v1/vendas'],['GET','/retorno/rest/v1/rpc/registrar_venda_mista']])assert.equal((await fetch(f.base+path,{method,headers:f.headers})).status,423);
  assert.equal(f.calls.length,1);
 }finally{await f.close();}
});

test('laboratório indisponível falha fechado e não encaminha ao outro banco',async()=>{
 const f=await fixture({returnRest:true,lab:{state:{status:'primary_down',active_database:null}},config:{sandboxWrites:true}});try{
  const r=await fetch(f.base+'/rest/v1/vendas',{headers:f.headers});assert.equal(r.status,503);assert.equal(f.calls.length,0);
 }finally{await f.close();}
});
test('banco ativo e consultas fixas usam destinos distintos',async()=>{
 const f=await fixture({returnRest:true,lab:{state:{active_database:'florest_retorno_teste_20261108'}}});try{
  const active=await fetch(f.base+'/rest/v1/vendas',{headers:f.headers});assert.equal((await active.json()).backend,'return');
  const reserve=await fetch(f.base+'/reserva/rest/v1/vendas',{headers:f.headers});assert.equal((await reserve.json()).backend,'reserve');
 }finally{await f.close();}
});
test('venda espera comprovante do espelho e bloqueia cliente antigo',async()=>{
 const f=await fixture({returnRest:true,lab:{},config:{sandboxWrites:true}});try{
  const r=await fetch(f.base+'/rest/v1/rpc/florest_sandbox_registrar_venda_mista',{method:'POST',headers:f.headers,body:JSON.stringify({p_operacao:'00000000-0000-4000-8000-000000000002',p_args:{}})});
  assert.equal(r.status,200);assert.equal(r.headers.get('x-florest-test-receipt'),'shadow-confirmed');
  const receipt=f.controlCalls.find(x=>x.path==='/confirm');assert.equal(receipt.body.operation,'00000000-0000-4000-8000-000000000002');assert.equal(receipt.body.actor,'00000000-0000-4000-8000-000000000001');
  assert.equal((await fetch(f.base+'/rest/v1/rpc/registrar_venda_mista',{method:'POST',headers:f.headers,body:'{}'})).status,423);assert.equal(f.calls.length,1);
 }finally{await f.close();}
});
test('espelho pendente não se apresenta como venda confirmada nos dois bancos',async()=>{
 const f=await fixture({lab:{reject:true},config:{sandboxWrites:true}});try{
  const r=await fetch(f.base+'/rest/v1/vendas',{method:'POST',headers:f.headers,body:'{}'});assert.equal(r.status,503);assert.equal((await r.json()).code,'LAB_BACKUP_PENDING');assert.equal(f.calls.length,1);
 }finally{await f.close();}
});
test('controle encaminha código apenas ao controlador e não às APIs de dados',async()=>{
 const f=await fixture({lab:{}});try{
  assert.equal((await fetch(f.base+'/lab-control/v1/action',{method:'POST',headers:{'content-type':'application/json','x-florest-test-control':'wrong'},body:'{"action":"activate_reserve"}'})).status,401);
  assert.equal((await fetch(f.base+'/lab-control/v1/action',{method:'POST',headers:{'content-type':'application/json','x-florest-test-control':'synthetic-control-code'},body:'{"action":"activate_reserve"}'})).status,200);
  assert.equal(f.calls.length,0);
 }finally{await f.close();}
});

test('renovação de chaves mantém cliente válido e recusa chave expirada ou de usuário',async()=>{
 const f=await fixture();try{
  const oldValid=token('anon',{iat:Math.floor(Date.now()/1000)-600});
  assert.equal((await fetch(f.base+'/rest/v1/vendas',{headers:{...f.headers,apikey:oldValid}})).status,200);
  for(const key of [token('anon',{exp:1}),token('authenticated')])assert.equal((await fetch(f.base+'/rest/v1/vendas',{headers:{...f.headers,apikey:key}})).status,401);
 }finally{await f.close();}
});
