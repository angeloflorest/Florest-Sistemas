import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const enabled=process.env.FLOREST_RUN_LOCAL_INTEGRATION==='1'&&fs.existsSync(path.join(root,'.runtime/test-context.json'));
const ctx=enabled?JSON.parse(fs.readFileSync(path.join(root,'.runtime/test-context.json'),'utf8')):{public_url:'http://127.0.0.1:18180'},base=ctx.public_url;
const anonHeaders={apikey:ctx.anon_key,authorization:'Bearer '+ctx.anon_key,'content-type':'application/json',origin:base};
const adminHeaders={...anonHeaders,apikey:ctx.service_key,authorization:'Bearer '+ctx.service_key};
function sql(text){
 const env={...process.env};for(const k of ['DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH'])delete env[k];
 const r=spawnSync('docker',['--host=unix:///var/run/docker.sock','compose','-p','florest-reserva-preview','--env-file',path.join(root,'.runtime/local.env'),'-f',path.join(root,'compose.yml'),'-f',path.join(root,'compose.local.yml'),'exec','-T','postgres','psql','-X','-q','-A','-t','-U','postgres','-d','florest_preview','-v','ON_ERROR_STOP=1'],{env,input:text,encoding:'utf8'});
 if(r.status!==0)throw Error('SQL da fixture falhou: '+r.stderr.slice(0,300));
 return r.stdout.trim();
}
async function call(url,options={}){
 const r=await fetch(base+url,{headers:anonHeaders,...options,signal:AbortSignal.timeout(20000)});
 let data;try{data=await r.json();}catch{data=null;}return {status:r.status,data};
}
async function user(email){
 const password='Teste_'+crypto.randomBytes(18).toString('hex');
 const r=await call('/auth/v1/admin/users',{method:'POST',headers:adminHeaders,body:JSON.stringify({email,password,email_confirm:true})});
 assert.equal(r.status,200,'Auth deve criar somente a conta sintética solicitada pelo teste');
 assert.match(r.data.id,/^[a-f0-9-]{36}$/);return {id:r.data.id,email,password};
}
async function login(empresa,password,usuario='florest-preview-operador'){
 return call('/functions/v1/florest-login',{method:'POST',body:JSON.stringify({empresa,usuario,senha:password,superficie:'erp'})});
}
test('integração real: Auth, PostgREST e login original sem Supabase hospedado',{skip:!enabled},async t=>{
 const a=await user('operador-a@florest-test.invalid'),b=await user('operador-b@florest-test.invalid'),g=await user('garcom-a@florest-test.invalid'),i=await user('inativo-a@florest-test.invalid');
 const ca=crypto.randomUUID(),cb=crypto.randomUUID();
 const rows=[
  [a.id,ca,'Operador A','florest-preview-operador','proprietario','erp','true'],
  [b.id,cb,'Operador B','florest-preview-operador','proprietario','erp','true'],
  [g.id,ca,'Garçom sintético','florest-preview-garcom','funcionario','garcom','true'],
  [i.id,ca,'Inativo sintético','florest-preview-inativo','funcionario','erp','false'],
 ].map(x=>'('+x.slice(0,6).map(v=>"'"+v+"'").join(',')+','+x[6]+')').join(',');
 sql([
  "CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(coalesce(current_setting('request.jwt.claim.sub',true),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub'),'')::uuid $$;",
  "INSERT INTO public.empresas(id,nome,email,status_conta)VALUES ('"+ca+"','Empresa sintética A','empresa-a@florest-test.invalid','aprovado'),('"+cb+"','Empresa sintética B','empresa-b@florest-test.invalid','aprovado');",
  "INSERT INTO public.perfis(id,empresa_id,nome,usuario,papel,tipo_acesso,ativo)VALUES "+rows+";",
  "INSERT INTO public.vendas(id,empresa_id,numero_venda,total)VALUES ('"+crypto.randomUUID()+"','"+ca+"',1,10.00),('"+crypto.randomUUID()+"','"+cb+"',1,20.00);",
  "NOTIFY pgrst,'reload schema';",
 ].join('\n'));
 let sessionA,sessionB;
 await t.test('serviços saudáveis e modo de leitura explícito',async()=>{
  const r=await call('/healthz');assert.equal(r.status,200);assert.equal(r.data.mode,'preview_read_only');assert.equal(r.data.production_switched,false);
 });
 await t.test('login da empresa A resolve empresa e perfil pelo fluxo original',async()=>{
  const r=await login('empresa-a@florest-test.invalid',a.password);assert.equal(r.status,200,'Login original deve autenticar no Auth independente');assert.equal(r.data.ok,true);assert.equal(r.data.empresa.id,ca);assert.equal(r.data.perfil.id,a.id);sessionA=r.data.session;
 });
 await t.test('mesmo nome de usuário na empresa B mantém a identidade correta',async()=>{
  const r=await login('empresa-b@florest-test.invalid',b.password);assert.equal(r.status,200);assert.equal(r.data.empresa.id,cb);assert.equal(r.data.perfil.id,b.id);sessionB=r.data.session;
 });
 await t.test('sessão emitida permite consultar o próprio usuário no Auth',async()=>{
  assert.ok(sessionA?.access_token,'Sessão A precisa existir');
  const r=await call('/auth/v1/user',{headers:{...anonHeaders,authorization:'Bearer '+sessionA.access_token}});assert.equal(r.status,200);assert.equal(r.data.id,a.id);
 });
 await t.test('RLS mostra uma venda própria para cada empresa',async()=>{
  for(const [session,company,total]of [[sessionA,ca,10],[sessionB,cb,20]]){
   assert.ok(session?.access_token,'Sessão autenticada precisa existir');
   const r=await call('/rest/v1/vendas?select=empresa_id,total',{headers:{...anonHeaders,authorization:'Bearer '+session.access_token}});assert.equal(r.status,200);assert.equal(r.data.length,1);assert.equal(r.data[0].empresa_id,company);assert.equal(Number(r.data[0].total),total);
  }
 });
 await t.test('forçar o filtro da outra empresa não revela nenhuma venda',async()=>{
  assert.ok(sessionA?.access_token);const r=await call('/rest/v1/vendas?empresa_id=eq.'+cb,{headers:{...anonHeaders,authorization:'Bearer '+sessionA.access_token}});assert.equal(r.status,200);assert.equal(r.data.length,0);
 });
 await t.test('RPC de leitura trabalha com o contexto da sessão',async()=>{
  assert.ok(sessionA?.access_token);const r=await call('/rest/v1/rpc/contexto',{method:'POST',headers:{...anonHeaders,authorization:'Bearer '+sessionA.access_token},body:'{}'});assert.equal(r.status,200);assert.equal(r.data.empresa_id,ca);
 });
 await t.test('senha de outra empresa e usuário desativado não autenticam',async()=>{
  assert.equal((await login('empresa-a@florest-test.invalid',b.password)).status,401);
  assert.equal((await login('empresa-a@florest-test.invalid',i.password,'florest-preview-inativo')).status,401);
 });
 await t.test('usuário do Garçom não entra pela superfície ERP',async()=>{
  assert.equal((await login('empresa-a@florest-test.invalid',g.password,'florest-preview-garcom')).status,401);
 });
 await t.test('gravação e emissão fiscal estão bloqueadas e dados permanecem iguais',async()=>{
  assert.ok(sessionA?.access_token);const headers={...anonHeaders,authorization:'Bearer '+sessionA.access_token};
  assert.equal((await call('/rest/v1/vendas',{method:'POST',headers,body:'{}'})).status,423);
  assert.equal((await call('/functions/v1/fiscal-nfe55',{method:'POST',headers,body:'{"acao":"emitir"}'})).status,503);
  assert.equal(sql('select count(*) from public.vendas;'),'2');
 });
 await t.test('sem sessão não há leitura nem acesso administrativo',async()=>{
  assert.equal((await call('/rest/v1/vendas')).status,401);
  assert.equal((await call('/auth/v1/admin/users',{headers:anonHeaders})).status,403);
 });
 await t.test('renovação de sessão funciona no Auth independente',async()=>{
  assert.ok(sessionA?.refresh_token);const r=await call('/auth/v1/token?grant_type=refresh_token',{method:'POST',body:JSON.stringify({refresh_token:sessionA.refresh_token})});assert.equal(r.status,200);assert.equal(r.data.user.id,a.id);assert.ok(r.data.access_token);
 });
 await t.test('prévia recusa operadores e e-mails fora das identidades técnicas',async()=>{
  assert.equal((await login('empresa-a@florest-test.invalid','senha-qualquer','operador-normal')).status,403);
  assert.equal((await call('/auth/v1/token?grant_type=password',{method:'POST',body:JSON.stringify({email:'cliente@exemplo.com',password:'senha-qualquer'})})).status,403);
 });
});
