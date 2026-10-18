import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

const here=new URL('./',import.meta.url), erp=new URL('../../',here);
const read=(p)=>fs.readFile(new URL(p,here),'utf8');
const baseline=JSON.parse(await read('baseline-schema.json'));
const up=await fs.readFile(new URL('supabase/migrations/'+baseline.migration,erp),'utf8');
const down=await fs.readFile(new URL('supabase/rollback/maria_acesso_independente.sql',erp),'utf8');
const html=await fs.readFile(new URL('sistema/index.html',erp),'utf8');
const edge=await fs.readFile(new URL('supabase/functions/maria-chat/index.ts',erp),'utf8');
const db=new PGlite();
const U='00000000-0000-4000-8000-000000000001',E='00000000-0000-4000-8000-000000000101',OTHER='00000000-0000-4000-8000-000000000102';
const context=Object.fromEntries(baseline.context.map(x=>[x.proname,x]));
const fnSign=(f)=>f.schema+'.'+f.proname+'('+f.arguments.replace(/\b\w+\s+(?=(?:uuid|text|integer|date|bigint|boolean|jsonb)\b)/g,'')+')';

await db.exec(`create schema auth;create schema private;create role anon;create role authenticated;create role service_role;
 create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 set check_function_bodies=off;`);
const tables=new Map();
for(const c of baseline.columns){const cols=tables.get(c.table_name)||[];cols.push('"'+c.column_name+'" '+c.data_type);tables.set(c.table_name,cols);}
for(const [n,cols] of tables)await db.exec('create table public."'+n+'"('+cols.join(',')+');');
await db.exec('alter table public.perfis add constraint perfis_permissoes_ck '+baseline.constraint+';');
for(const f of [...baseline.context,...baseline.private,...baseline.public])await db.exec(f.definition);
// Definição auxiliar copiada do snapshot para o teste de Bar; não é alteração proposta.
await db.exec(`create function private.empresa_tem_modulo(p_modulo text) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select true from public.empresa_modulos m where m.empresa_id=private.empresa_id_ativa() and m.modulo=lower(btrim(coalesce(p_modulo,''))) and m.ativo),false) $$;
 grant usage on schema auth,public,private to authenticated;grant select on all tables in schema public to authenticated;
 grant execute on function auth.uid() to authenticated;
 revoke all on function private.exigir_empresa_ativa() from public;
 grant execute on function private.maria_empresa(),private.perm(text),private.perm_alguma(text[]),private.maria_exigir(text[],text),private.empresa_tem_modulo(text),private.maria_lim(integer,integer,integer),private.maria_periodo(date,date,integer) to authenticated;
 insert into public.empresas(id,status_conta,bloqueado) values('${E}','aprovado',false),('${OTHER}','aprovado',false);
 insert into public.perfis(id,empresa_id,papel,tipo_acesso,ativo,permissoes) values('${U}','${E}','funcionario','erp',true,'{}');
 insert into public.empresa_modulos(empresa_id,modulo,ativo) values('${E}','bar',true);
 insert into public.vendas(id,empresa_id,total,criado_em,cancelada_em) values('00000000-0000-4000-8000-000000000201','${E}',25,now(),null),('00000000-0000-4000-8000-000000000202','${OTHER}',9000,now(),null);`);
await db.exec(up);
// Usa as políticas SELECT reais do snapshot em cinco tabelas, sem copiar dados de produção.
for(const name of ['perfis','produtos','vendas','despesas','bar_mesas'])await db.exec(`alter table public.${name} enable row level security;`);
for(const p of JSON.parse(await read('baseline-policies.json'))){
 await db.exec(`create policy "${p.policyname}" on public.${p.tablename} as ${p.permissive} for select to authenticated using (${p.qual});`);
}

async function profile(perms=[],{papel='funcionario',ativo=true,tipo='erp',empresa=E,bloqueado=false}={}){
 await db.exec('reset role;');
 await db.query('update public.perfis set permissoes=$1,papel=$2,ativo=$3,tipo_acesso=$4,empresa_id=$5 where id=$6',[perms,papel,ativo,tipo,empresa,U]);
 await db.query('update public.empresas set bloqueado=$1 where id=$2',[bloqueado,empresa]);
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[U]);
 await db.exec('set role authenticated;');
}
const q=async(sql,args=[]) => (await db.query(sql,args)).rows;
async function denied(sql,args=[]){await assert.rejects(()=>db.query(sql,args),e=>/42501|28000/.test(e.code)||/permiss|bloquead|desativad/i.test(e.message));}

await test('SQL: migração não concede maria a nenhum perfil existente',async()=>{
 await profile();assert.equal((await q('select permissoes from public.perfis where id=$1',[U]))[0].permissoes.length,0);
 await denied('select public.maria_autorizar()');
});
await test('SQL: proprietário autorizado pela regra administrativa proposta',async()=>{
 await profile([],{papel:'proprietario'});assert.equal((await q('select public.maria_autorizar() as ok'))[0].ok,true);
});
await test('SQL: funcionário precisa de concessão explícita; garçom padrão não recebe IA',async()=>{
 for(const perms of [['bar_visualizar'],['pdv'],['produtos'],['relatorios'],['usuarios'],[]]){await profile(perms);await denied('select public.maria_autorizar()');}
 await profile(['bar_visualizar','bar_mesas','bar_pedidos'],{tipo:'garcom'});await denied('select public.maria_autorizar()');
 await profile(['maria']);assert.equal((await q('select public.maria_autorizar() as ok'))[0].ok,true);
});
await test('SQL: usuário inativo ou empresa bloqueada não usa IA, inclusive proprietário',async()=>{
 for(const state of [{ativo:false},{bloqueado:true},{papel:'proprietario',ativo:false}]){await profile(['maria'],state);await denied('select public.maria_autorizar()');}
 await profile(['maria']);
});
await test('SQL: todas as 37 entradas IA protegidas negam acesso direto sem maria',async(t)=>{
 await profile(['bar_visualizar','bar_pedidos']);
 for(const f of baseline.public.filter(x=>x.proname!=='maria_uso_finalizar')){
  await t.test(f.proname,async()=>{
   const args=f.arguments ? f.arguments.split(', ').map(s=>'null::'+s.slice(s.indexOf(' ')+1)).join(',') : '';
   await denied(`select public.${f.proname}(${args})`);
  });
 }
});
await test('SQL: maria não concede financeiro, relatório, custo ou margem ao Bar',async()=>{
 await profile(['maria','bar_visualizar','bar_pedidos']);
 await denied('select public.maria_financeiro_resumo()');
 await denied('select public.maria_panorama()');
 await denied('select public.maria_produto_detalhe()');
 for(const focus of ['margem','valor_estoque','lucro_bruto','abaixo_minimo'])await denied('select public.maria_estoque_analise($1)',[focus]);
 for(const focus of ['periodo','produtos','horarios','pagamentos','destino'])await denied('select public.maria_bar_analise($1)',[focus]);
 const bar=(await q("select public.maria_bar_analise('agora') as data"))[0].data;assert.equal(bar.mesas_total,0);
});
await test('SQL: permissão MARIA não substitui relatorios nem pdv; tenant A não lê B',async()=>{
 await profile(['maria','pdv']);await denied('select public.maria_resumo_vendas_hoje()');
 await profile(['maria','relatorios']);await denied('select public.maria_resumo_vendas_hoje()');
 await profile(['maria','relatorios','pdv']);const a=(await q('select public.maria_resumo_vendas_hoje() as data'))[0].data;assert.equal(Number(a.total_vendido),25);
 await profile(['maria','relatorios','pdv'],{empresa:OTHER});const b=(await q('select public.maria_resumo_vendas_hoje() as data'))[0].data;assert.equal(Number(b.total_vendido),9000);
 await profile(['maria','financeiro']);assert.ok((await q('select public.maria_financeiro_resumo() as data'))[0].data);
});
await test('SQL: revogar maria bloqueia a próxima requisição, sem refresh de JWT',async()=>{
 await profile(['maria']);await q('select public.maria_autorizar()');await db.exec('reset role;');
 await db.query("update public.perfis set permissoes='{}' where id=$1",[U]);await db.exec('set role authenticated;');await denied('select public.maria_autorizar()');
});
await test('SQL: valida chaves existentes e rejeita novas chaves inventadas',async()=>{
 await profile();await db.exec('reset role;');
 await assert.rejects(()=>db.query("update public.perfis set permissoes=array['chave_inventada'] where id=$1",[U]),e=>e.code==='23514');
});

function loadEdge({auth=true,authorized=true,gateError=false,maliciousTool=false}={}){
 const calls=[],groq=[];let handler;
 const rpc=async(name,args)=>{calls.push(name);if(name==='maria_autorizar')return{data:authorized,error:gateError?{code:'42501'}:null};if(name==='maria_uso_iniciar')return{data:{permitido:true,consultoria:true,acoes:false,modulos:{bar:true},permissoes:{bar:true}},error:null};return{data:{ok:true},error:null};};
 const sandbox={Request,Response,Headers,AbortSignal,URL,crypto,TextEncoder,TextDecoder,setTimeout,clearTimeout,console:{error:()=>{}},createClient:()=>({auth:{getUser:async()=>({data:{user:auth?{id:U}:null},error:null})},rpc}),fetch:async(url,opts)=>{groq.push(url);const message=maliciousTool&&groq.length===1?{tool_calls:[{id:'test-call',function:{name:'financeiro_resumo',arguments:'{}'}}]}:{content:'Resposta de teste sem dados reais.'};return new Response(JSON.stringify({choices:[{message}],usage:{}}),{status:200});},Deno:{env:{get:(key)=>({GROQ_API_KEY:'fake-groq-for-local-test',SUPABASE_URL:'https://local.invalid',SUPABASE_ANON_KEY:'fake-anon',MARIA_SERVER_SECRET:'test-only-secret-with-32-characters'}[key])},serve:f=>{handler=f;}}};
 const src=edge.replace(/^import \{ createClient \} from [^\n]+\n/m,'');vm.runInNewContext(stripTypeScriptTypes(src),sandbox);
 return{calls,groq,request:body=>handler(new Request('https://local.invalid/maria-chat',{method:'POST',headers:{Authorization:'Bearer token-only-for-mock','Content-Type':'application/json'},body:JSON.stringify(body)}))};
}
await test('Edge: bloqueio direto antes de consumo, ação pendente, ferramentas e Groq',async()=>{
 for(const cfg of [{authorized:false},{gateError:true}]){
  const e=loadEdge(cfg);const res=await e.request({mensagem:'Qual meu financeiro?'});assert.equal(res.status,403);assert.deepEqual(e.calls,['maria_autorizar']);assert.equal(e.groq.length,0);
 }
});
await test('Edge: JWT inválido não consulta RPC e usuário autorizado continua conversando (Groq simulado)',async()=>{
 const invalid=loadEdge({auth:false});assert.equal((await invalid.request({mensagem:'Olá'})).status,401);assert.equal(invalid.calls.length,0);
 const e=loadEdge();const res=await e.request({mensagem:'Olá'});assert.equal(res.status,200);assert.equal(e.calls[0],'maria_autorizar');assert.ok(e.calls.includes('maria_uso_iniciar'));assert.ok(e.calls.includes('maria_uso_finalizar'));assert.equal(e.groq.length,1);
});
await test('Edge: modelo não consegue ampliar whitelist para consultar financeiro sem autorização',async()=>{
 const e=loadEdge({maliciousTool:true});const res=await e.request({mensagem:'Como estão as mesas do bar?'});assert.equal(res.status,200);
 assert.ok(!e.calls.includes('maria_financeiro_resumo'));assert.equal(e.groq.length,2);
});
await test('Edge: alterações limitadas à autorização e whitelist de cadastro, bases publicadas preservadas',async()=>{
 const b=await read('baseline-maria-chat.ts.txt');const inserted=edge.slice(edge.indexOf('    // Antes de ações pendentes'),edge.indexOf('    const rpcServidor'));
 assert.equal(edge.replace(inserted,''),b); // Toda a lógica publicada restante é preservada.
 const users=await fs.readFile(new URL('supabase/functions/distgestor-usuarios/index.ts',erp),'utf8');
 assert.equal(users.replace('  "maria",\n',''),await read('baseline-distgestor-usuarios.ts.txt'));
});
await test('Cadastro: valida nova chave maria e rejeita chave não reconhecida',async()=>{
 const src=await fs.readFile(new URL('supabase/functions/distgestor-usuarios/index.ts',erp),'utf8');
 const modules=src.slice(src.indexOf('const MODULOS = new Set(['),src.indexOf(']);',src.indexOf('const MODULOS = new Set(['))+3);
 const start=src.indexOf('function validarPermissoes('),end=src.indexOf('\n}',start)+2;
 const ctx={};vm.runInNewContext(stripTypeScriptTypes(modules+'\n'+src.slice(start,end)),ctx);
 assert.equal(ctx.validarPermissoes(['maria'])[0],'maria');assert.equal(ctx.validarPermissoes(['inexistente']),null);
});
await test('SQL: preserva corpos e modos das 37 funções fora dos gates novos e do recorte de histórico',async()=>{
 const normalized=up.replaceAll('\r\n','\n');
 for(const f of baseline.public.filter(x=>x.proname!=='maria_uso_finalizar')){
  const start=normalized.indexOf('CREATE OR REPLACE FUNCTION public.'+f.proname+'(');
  const end=normalized.indexOf('$function$',normalized.indexOf('AS $function$',start)+13)+10;
  const actual=normalized.slice(start,end).replace(/\n  perform private\.maria_exigir_acesso\('[^']+'(?:, p_foco)?\);/,'').replace("v_vend := private.perm('relatorios') and private.perm_alguma(","v_vend := private.perm_alguma(").trim();
  const expected=f.definition.replaceAll('\r\n','\n').replaceAll('\r','').trim();
  assert.equal(actual,expected,f.proname);
 }
});

function extractFunction(name){const start=html.indexOf('function '+name+'(');assert.ok(start>=0);const end=html.indexOf('\n}',start)+2;return (html.slice(start-6,start)==='async '?'async ':'')+html.slice(start,end);}
await test('Frontend: checkbox próprio, rota protegida, envio direto e atalho sem vazamento',async()=>{
 const moduleText=html.match(/const MODULOS_ACESSO = (\[[\s\S]*?\n\]);/)[1];
 const modules=vm.runInNewContext(moduleText);assert.equal(modules.filter(m=>m.k==='maria').length,1);
 assert.match(html,/filter\(k => k !== 'usuarios' && k !== 'maria'\)/);
 assert.match(html,/const VIEWS_SEM_PERMISSAO_PROPRIA = \[\]/);
 let touched=0;const sandbox={acesso:{userId:U},podeAcessar:()=>false,MODULOS_ACESSO:modules,VIEWS_SEM_PERMISSAO_PROPRIA:[],viewAtual:null,atualizarMariaFlutuante:()=>touched++,document:{querySelectorAll:()=>{throw Error('rota sem permissão tocou DOM');}}};
 vm.runInNewContext(extractFunction('abrirView'),sandbox);sandbox.abrirView('maria');assert.equal(touched,0);sandbox.abrirView('bar');assert.equal(touched,0);
 const send=extractFunction('mariaEnviar');vm.runInNewContext(send,sandbox);await sandbox.mariaEnviar('Forçar chamada');assert.equal(touched,0);
 let hidden;const floatContext={...sandbox,viewAtual:'clientes',MARIA_FLUTUANTE_OCULTA_EM:[],mariaOcultaAtiva:()=>false,mariaOcultaTimer:null,$:()=>({classList:{toggle:(cls,value)=>{hidden=value;}}})};vm.runInNewContext(extractFunction('atualizarMariaFlutuante'),floatContext);floatContext.atualizarMariaFlutuante();assert.equal(hidden,true);
});
await test('Regressão estática: bloco de operações do Bar e overrides finais permanece igual após normalizar finais de linha',async()=>{
 assert.equal(createHash('sha256').update(html.slice(html.indexOf('const BAR_SUBVIEW_PERMISSOES = {')).replaceAll('\r\n','\n')).digest('hex'),(await read('baseline-bar.sha256')).trim());
});
await test('SQL/RLS: vendas da outra empresa permanecem invisíveis ao funcionário autorizado',async()=>{
 await profile(['maria','relatorios','pdv']);const rows=await q('select empresa_id,total from public.vendas');assert.equal(rows.length,1);assert.equal(rows[0].empresa_id,E);
});
await test('SQL: rollback recusa remover chave em uso e restaura estado sem concessões',async()=>{
 await profile(['maria']);await db.exec('reset role;');await assert.rejects(()=>db.exec(down),/Reversão suspensa/);await db.exec('rollback;');
 await db.query("update public.perfis set permissoes='{}' where id=$1",[U]);await db.exec(down);
 assert.equal((await q("select to_regprocedure('public.maria_autorizar()') as f"))[0].f,null);
 assert.ok(!(await q('select private.usuarios_modulos() as keys'))[0].keys.includes('maria'));
 await db.close();
});
