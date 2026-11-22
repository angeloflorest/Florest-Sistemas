// PostgreSQL isolado em memória. Não escreve vendas no Supabase de produção.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {PGlite}=require(process.env.PGLITE_PATH||'/tmp/erp-perf-pg/node_modules/@electric-sql/pglite');
const root=path.resolve(__dirname,'../../..');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const calcSource=html.slice(html.indexOf('const barNovoDia ='),html.indexOf('// ---------- Fim dos cálculos puros'));
const testSource=fs.readFileSync(path.join(__dirname,'bar-relatorios-novos.test.cjs'),'utf8');
const fixtureSource=testSource.slice(testSource.indexOf('function dados()'),testSource.indexOf('\n\ntest('));
const ctx=vm.createContext({Intl,Date,Map,Set,Number,JSON,Error});vm.runInContext(calcSource+'\n'+fixtureSource,ctx);
const fixture=JSON.parse(JSON.stringify(vm.runInContext('dados()',ctx)));
const idMap=new Map();let seq=1;function uid(v){if(!idMap.has(v))idMap.set(v,'00000000-0000-0000-0000-'+String(seq++).padStart(12,'0'));return idMap.get(v)}
for(const rows of Object.values(fixture))for(const row of rows)for(const k of Object.keys(row))if(k==='id'||k.endsWith('_id'))if(row[k]!=null)row[k]=uid(row[k]);
const E=uid('empresa'),U=uid('owner'),quote=s=>"'"+String(s).replaceAll("'","''")+"'";
const defs={produtos:'id uuid,nome text,unidade_comercial text,atualizado_em timestamptz',bar_mesas:'id uuid,numero int',caixas:'id uuid,numero int,tipo_caixa text,aberto_por_nome text,aberto_em timestamptz,fechado_em timestamptz',bar_comandas:'id uuid,mesa_id uuid,venda_id uuid,status text,cancelada_em timestamptz',vendas:'id uuid,numero_venda int,tipo text,total numeric,criado_em timestamptz,cancelada_em timestamptz',bar_pagamentos:'id uuid,comanda_id uuid,venda_id uuid,caixa_id uuid,total numeric,criado_em timestamptz,estornado boolean,estornado_em timestamptz',bar_pagamentos_formas:'id uuid,pagamento_id uuid,forma_pagamento text,valor numeric',bar_pedidos_itens:'id uuid,comanda_id uuid,produto_id uuid,bar_produto_id uuid,quantidade numeric,preco_unitario numeric,criado_em timestamptz,estornado boolean',bar_pedidos_itens_baixas:'id uuid,pedido_item_id uuid,produto_id uuid,quantidade numeric,criado_em timestamptz,estornada boolean',bar_produtos:'id uuid,produto_id uuid'};
const aliases={produtos:'produtos',mesas:'bar_mesas',caixas:'caixas',comandas:'bar_comandas',vendas:'vendas',pagamentos:'bar_pagamentos',formas:'bar_pagamentos_formas',itens:'bar_pedidos_itens',baixas:'bar_pedidos_itens_baixas',barProdutos:'bar_produtos'};
async function main(){const db=new PGlite();await db.exec(`CREATE SCHEMA private;CREATE SCHEMA auth;CREATE ROLE anon;CREATE ROLE authenticated;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$SELECT current_setting('test.uid')::uuid$$;
CREATE FUNCTION private.exigir_empresa_ativa() RETURNS uuid LANGUAGE sql AS $$SELECT current_setting('test.empresa')::uuid$$;
CREATE FUNCTION private.gastronomia_exigir(text) RETURNS uuid LANGUAGE sql AS $$SELECT private.exigir_empresa_ativa()$$;
CREATE FUNCTION private.empresa_tem_modulo(text) RETURNS boolean LANGUAGE sql AS $$SELECT true$$;
CREATE TABLE public.perfis(id uuid PRIMARY KEY,empresa_id uuid,ativo boolean,papel text);
CREATE TABLE public.gastronomia_configuracoes(empresa_id uuid,opcoes jsonb);
CREATE TABLE public.gastronomia_sinais(empresa_id uuid,revisao bigint);
CREATE TABLE private.gastronomia_produtos_operacionais(id uuid,empresa_id uuid);
CREATE TABLE private.gastronomia_componentes_operacionais(id uuid,empresa_id uuid);
CREATE TABLE private.gastronomia_grupos_operacionais(id uuid,empresa_id uuid);
CREATE TABLE private.gastronomia_opcoes_operacionais(id uuid,empresa_id uuid);
CREATE FUNCTION private.perm(text) RETURNS boolean LANGUAGE sql AS $$SELECT true$$;
CREATE FUNCTION public.gastronomia_rpc(p_acao text,p_dados jsonb DEFAULT '{}',p_chave uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE dados jsonb:=p_dados; BEGIN RETURN jsonb_build_object('empresa_id',private.exigir_empresa_ativa(),'catalogo',CASE WHEN private.perm('gastronomia_pedidos') OR private.perm('gastronomia_configurar') THEN '[{"id":"produto"}]'::jsonb ELSE '[]'::jsonb END);END $$;
SET test.uid=${quote(U)};SET test.empresa=${quote(E)};INSERT INTO public.perfis VALUES(${quote(U)},${quote(E)},true,'proprietario');
`);
for(const [t,cols]of Object.entries(defs))await db.exec(`CREATE TABLE public.${t}(empresa_id uuid,${cols})`);
const d=fixture;
// Recebimento posterior ao período deve continuar entrando no saldo da venda.
d.pagamentos.push({id:uid('posterior'),comanda_id:uid('c'),caixa_id:uid('cx'),total:7,criado_em:'2026-11-02T12:00:00Z'});
// Componente lançado dentro do período com item original fora dele.
d.itens.push({id:uid('fora'),comanda_id:uid('c'),produto_id:uid('2'),quantidade:2,preco_unitario:9,criado_em:'2026-09-20T12:00:00Z'});
d.baixas.push({id:uid('comp-fora'),pedido_item_id:uid('fora'),produto_id:uid('3'),quantidade:4,criado_em:'2026-10-05T12:00:00Z'});
// Período em Brasília, estorno legado e produto sem id direto.
d.itens.push({id:uid('limite-brasilia'),comanda_id:uid('c'),bar_produto_id:uid('legado'),quantidade:1,preco_unitario:5,criado_em:'2026-11-01T02:59:59Z'});d.barProdutos.push({id:uid('legado'),produto_id:uid('1')});
d.pagamentos.push({id:uid('sem-data-estorno'),comanda_id:uid('c'),caixa_id:uid('outro-caixa'),total:1,criado_em:'2026-09-01T12:00:00Z',estornado:true});
for(const [key,rows]of Object.entries(d)){for(const [n,row]of rows.entries()){
 if(!row.id)row.id=uid(key+'-'+n);if(key==='caixas')row.tipo_caixa='BAR';if(key==='vendas')row.tipo='bar';if(key==='pagamentos'&&row.estornado===undefined)row.estornado=false;
 const columns=['empresa_id',...Object.keys(row)],values=[E,...Object.values(row)];await db.query(`INSERT INTO public.${aliases[key]} (${columns.join(',')}) VALUES(${values.map((_,i)=>'$'+(i+1)).join(',')})`,values);
}}
const migration=fs.readFileSync(path.join(root,'supabase/migrations/20261122150759_otimizar_leituras_operacionais.sql'),'utf8');await db.exec(migration);
for(const periodo of [['2026-10-01','2026-10-31'],['2026-10-05','2026-10-05'],['2026-11-01','2026-11-30']])for(const tipo of ['periodo','caixa','produto','comparativo']){
 const f={dataInicio:periodo[0],dataFim:periodo[1],produtos:tipo==='comparativo'?[uid('1'),uid('3')]:[]};
 const result=(await db.query('select public.bar_relatorio_dados($1,$2,$3,$4,$5) d',[tipo,...periodo,null,f.produtos])).rows[0].d;
 // SQL JSON agrega en orden id, igual al transporte anterior.
 const reference={};for(const [key,table]of Object.entries(aliases))reference[key]=(await db.query('SELECT to_jsonb(t) doc FROM public.'+table+' t WHERE empresa_id=$1 ORDER BY id',[E])).rows.map(r=>r.doc);
 // Referência completa: mesmo conjunto recebido pelo transporte anterior.
 ctx.full=reference;ctx.filtered=result;ctx.tipo=tipo;ctx.f=f;
 const expected=JSON.parse(JSON.stringify(vm.runInContext('barNovoCalcular(tipo,f,full)',ctx)));
 const actual=JSON.parse(JSON.stringify(vm.runInContext('barNovoCalcular(tipo,f,filtered)',ctx)));
 assert.deepEqual(actual,expected,`${tipo}: ${periodo}`);
}
// A autorização e o isolamento do novo endpoint são obrigatórios.
await db.query('UPDATE public.perfis SET papel=$1',['funcionario']);await assert.rejects(db.query("SELECT public.bar_relatorio_dados('periodo','2026-10-01','2026-10-31')"),/exclusivos/);await db.query('UPDATE public.perfis SET papel=$1',['proprietario']);
await db.exec(`INSERT INTO public.gastronomia_sinais VALUES(${quote(E)},1)`);
const first=(await db.query('SELECT public.gastronomia_atualizacao() r')).rows[0].r;
const same=(await db.query('SELECT public.gastronomia_atualizacao($1,$2) r',[first.revisao,first.catalogo_revisao])).rows[0].r;assert.equal(same.inalterado,true);
await db.exec('UPDATE public.gastronomia_sinais SET revisao=2');
const changed=(await db.query('SELECT public.gastronomia_atualizacao($1,$2) r',[first.revisao,first.catalogo_revisao])).rows[0].r;assert.equal(changed.catalogo_inalterado,true);assert.deepEqual(changed.catalogo,[]);assert.notEqual(changed.revisao,first.revisao);
await db.exec("UPDATE public.produtos SET atualizado_em=now() WHERE empresa_id="+quote(E));const products=(await db.query('SELECT public.gastronomia_atualizacao($1,$2) r',[changed.revisao,changed.catalogo_revisao])).rows[0].r;assert.equal(products.catalogo_inalterado,false);assert.equal(products.catalogo.length,1);
if(process.env.BAR_REL_FIXTURE_OUT)fs.writeFileSync(process.env.BAR_REL_FIXTURE_OUT,JSON.stringify({d,produtos:d.produtos.map(p=>p.id)}));
await db.close();console.log('OK: 12 comparações completas de relatórios; pagamentos posteriores; componentes fora do período; Brasília; estornos legados; autorização; revisão e catálogo condicional.');
}main().catch(e=>{console.error(e);process.exitCode=1});
