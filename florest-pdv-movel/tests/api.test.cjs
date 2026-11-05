const { test } = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./helpers.cjs');
const api = load('api', { '@supabase/supabase-js': { createClient() { throw Error('No config must not create client'); } }, './secureStorage': {} });
test('configuração só aceita chave pública apropriada', () => {
  const jwt = role => 'a.' + Buffer.from(JSON.stringify({ role })).toString('base64url') + '.c';
  assert.ok(api.publicConfigValid('https://project.supabase.co', jwt('anon')));
  assert.equal(api.publicConfigValid('https://project.supabase.co', jwt('service_role')), false);
  assert.equal(api.publicConfigValid('https://project.supabase.co', 'sb_secret_invalid'), false);
  assert.equal(api.publicConfigValid('http://project.supabase.co', jwt('anon')), false);
});
test('pesquisa usa a RPC existente sem empresa escolhida ou leitura direta de produtos', async () => {
  let calls = [];
  const c = { async rpc(name, args) { calls.push({ name, args }); return { data: [{ id: 'p', nome: 'Produto', preco_venda: '12.50', codigo: 'A' }] }; }, from() { throw Error('Leitura direta proibida'); } };
  const products = await api.searchProducts(c, 'Produto');
  assert.equal(products[0].preco_venda, 12.5);
  assert.equal(calls[0].name, 'pdv_produtos_consultar');
  assert.equal(calls[0].args.p_busca, 'Produto');
  assert.equal(Object.keys(calls[0].args).some(k => k.includes('empresa')), false);
  assert.equal((await api.searchProducts(c, 'OUTRO', true)).length, 0);
});
test('erro de autorização não ativa fallback e não é apresentado como catálogo vazio', async () => {
  await assert.rejects(() => api.searchProducts({ rpc: async () => ({ error: { code: '42501', message: 'negado' } }) }, 'a'), e => e.code === '42501');
});
test('perfil sempre filtra id do usuário e valida a permissão devolvida', async () => {
  let id;
  const c = { from(table) { assert.equal(table, 'perfis'); return { select() { return this; }, eq(k, v) { assert.equal(k, 'id'); id = v; return this; }, async single() { return { data: { id, empresa_id: 'company', ativo: true, papel: 'funcionario', permissoes: ['pdv'], empresas: { nome: 'Loja', bloqueado: false } } }; } }; } };
  assert.equal((await api.loadProfile(c, 'u')).empresa_id, 'company');
  assert.equal(id, 'u');
});
test('login por e-mail pessoal preserva Supabase Auth e não exige usuário paralelo', async () => {
 let credentials;
 await api.loginERP({auth:{signInWithPassword:async input => {credentials=input;return {};}}},' email@teste.com ','senha','');
 assert.equal(credentials.email,'email@teste.com');assert.equal(credentials.password,'senha');
});
test('clientes filtram a empresa do perfil e não expõem campos fiscais desnecessários', async () => {
 const profile={id:'u',empresa_id:'a',papel:'funcionario',permissoes:['pdv'],ativo:true,empresas:{nome:'Loja',bloqueado:false}};
 const calls=[];const query={select(fields){calls.push(['select',fields]);return this;},eq(k,v){calls.push([k,v]);return this;},ilike(k,v){calls.push([k,v]);return this;},order(){return this;},async limit(){return {data:[{id:'c',nome:'Ana'}]};}};
 const rows=await api.searchCustomers({from(table){assert.equal(table,'clientes');return query;}},profile,'Ana%,()');
 assert.equal(rows[0].id,'c');assert.ok(calls.some(([k,v])=>k==='empresa_id'&&v==='a'));assert.ok(calls.some(([k,v])=>k==='select'&&v==='id,nome'));
});
test('histórico só consulta as RPCs existentes e impede edição ou leitura sem permissão', async () => {
 const profile={id:'u',empresa_id:'a',ativo:true,empresas:{nome:'Loja',bloqueado:false},papel:'proprietario',permissoes:[]};const calls=[];
 const c={async rpc(name,args){calls.push([name,args]);return name==='pdv_movel_vendas_listar'?{data:[{id:'s',criado_em:'2026-11-05',total:'10'}]}:{data:{venda:{id:args.p_venda},itens:[],pagamentos:[]}};}};
 assert.equal((await api.historyPage(c,profile,'Ana',100))[0].total,10);
 assert.equal(calls[0][0],'pdv_movel_vendas_listar');assert.equal(calls[0][1].p_offset,100);
 await api.historyDetail(c,profile,'s');assert.equal(calls[1][0],'pdv_movel_venda_detalhar');
 await assert.rejects(() => api.historyPage(c,{...profile,papel:'funcionario',permissoes:[]},'',0));
 assert.equal(calls.length,2);
});
test('login por usuário reutiliza florest-login e instala somente a sessão confirmada', async () => {
 let request, session;
 const a=load('api',{'@supabase/supabase-js':{createClient:()=>({})},'./secureStorage':{},$env:{EXPO_PUBLIC_SUPABASE_URL:'https://teste.supabase.co',EXPO_PUBLIC_SUPABASE_ANON_KEY:'sb_publishable_fixture_apenas_para_teste'},$fetch:async(url,options)=>{request={url,options};return {ok:true,json:async()=>({ok:true,session:{access_token:'access-fixture',refresh_token:'refresh-fixture'}})};}});
 await a.loginERP({auth:{setSession:async value=>{session=value;return {};}}},'empresa@teste.com','senha-local',' operador ');
 assert.equal(request.url,'https://teste.supabase.co/functions/v1/florest-login');
 const body=JSON.parse(request.options.body);assert.equal(body.usuario,'operador');assert.equal(body.empresa,'empresa@teste.com');assert.equal(body.superficie,'erp');
 assert.equal(session.refresh_token,'refresh-fixture');
});
test('falha no login por usuário não tenta credenciais paralelas nem instala tokens', async () => {
 const a=load('api',{'@supabase/supabase-js':{createClient:()=>({})},'./secureStorage':{},$fetch:async()=>({ok:false,json:async()=>({ok:false,mensagem:'Acesso negado'})})});
 await assert.rejects(()=>a.loginERP({auth:{setSession:()=>{throw Error('não deve ocorrer');},signInWithPassword:()=>{throw Error('fallback proibido');}}},'empresa@teste.com','senha','operador'),/Acesso negado/);
});
test('histórico móvel exibe o ajuste auditado por produto e o título a prazo sem inferir valores',async()=>{
 const profile={id:'u',empresa_id:'a',ativo:true,empresas:{nome:'Loja',bloqueado:false},papel:'proprietario',permissoes:[]};
 const c={rpc:async()=>({data:{venda:{id:'s',pdv_movel_caixa_id:'cash',pdv_movel_ajustes:[{produto_id:'p',desconto:1,acrescimo:2},{produto_id:'outro',desconto:9}]},itens:[{produto_id:'p',preco_unitario:13},{produto_id:'q',preco_unitario:5}],pagamentos:[],titulo:{saldo_aberto:18,vencimento:'2026-11-30'}}})};
 const result=await api.historyDetail(c,profile,'s');assert.equal(result.itens[0].desconto,1);assert.equal(result.itens[0].acrescimo,2);assert.equal(result.itens[1].desconto,undefined);assert.equal(result.titulo.saldo_aberto,18);
});
