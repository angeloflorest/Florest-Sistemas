const {test}=require('node:test');const assert=require('node:assert/strict');const {DatabaseSync}=require('node:sqlite');const {load,profile,product,inventory}=require('./helpers.cjs');
const d=load('domain');
test('quantidade substitui saldo; zero e quatro decimais são aceitos, entradas ambíguas recusadas',()=>{
 assert.equal(d.quantity('0'),0);assert.equal(d.quantity('50'),50);assert.equal(d.quantity('1,2345'),1.2345);
 for(const v of ['-1','1.000,5','1e3','NaN','Infinity','1,12345','1000000000',''])assert.throws(()=>d.quantity(v));
});
test('permissão é Estoque, não PDV, e empresa/operador devem estar ativos',()=>{
 assert.equal(d.validateProfile(profile,'u1').empresa_id,'e1');
 for(const p of [{...profile,permissoes:['pdv']},{...profile,ativo:false},{...profile,empresas:{...profile.empresas,status_conta:'pendente'}}])assert.throws(()=>d.validateProfile(p,'u1'));
 assert.throws(()=>d.validateProfile(profile,'outro'));
});
test('GTIN mantém zeros de embalagem e não aceita injeção no filtro',()=>{
 assert.ok(d.gtins('07891234567895').includes('7891234567895'));assert.equal(d.gtins('1),id.gt.0').length,0);
 assert.throws(()=>d.product({...product,empresa_id:'e2'},'e1'));assert.throws(()=>d.product({...product,tipo_fiscal:'servico'},'e1'));
});
function mockClient(initial=product,p=profile){let state={...initial};const writes=[];let networkLoss=false;return {
 auth:{getUser:async()=>({data:{user:{id:p.id}},error:null})},writes,get stock(){return state;},sale(){state={...state,quantidade_estoque:state.quantidade_estoque-2,atualizado_em:'2026-11-08T15:01:00.000Z'};},loseResponse(){networkLoss=true;},
 from(table){const filters={};let payload;const q={select:async function(){if(table==='perfis')return q;if(!payload)return {data:[state],error:null};if(Object.entries(filters).some(([k,v])=>state[k]!==v))return {data:[],error:null};state={...state,...payload,atualizado_em:'2026-11-08T15:00:01.000Z'};if(networkLoss){networkLoss=false;throw Error('Network request failed');}return {data:[state],error:null};},eq(k,v){filters[k]=v;return q;},single:async()=>({data:p,error:null}),update(v){payload=v;writes.push(v);return q;}};
 // Profile lookup uses select as a chain, unlike stock returning select.
 if(table==='perfis')q.select=function(){return q;};return q;
 }};}
function api(){return load('api',{'@supabase/supabase-js':{createClient:()=>null},'./secureStorage':{secureStorage:{}}});}
test('confirmação altera somente saldo da empresa, sem preço, fiscal ou estoque mínimo',async()=>{
 const c=mockClient();const updated=await api().updateStock(c,profile,product,50);assert.equal(updated.quantidade_estoque,50);assert.equal(JSON.stringify(c.writes),JSON.stringify([{quantidade_estoque:50}]));
});
test('venda concorrente impede sobrescrever o saldo; repetir versão antiga não desfaz venda posterior',async()=>{
 const c=mockClient();c.sale();await assert.rejects(()=>api().updateStock(c,profile,product,50),/mudou/);assert.equal(c.stock.quantidade_estoque,10);
 const c2=mockClient();await api().updateStock(c2,profile,product,50);c2.sale();await assert.rejects(()=>api().updateStock(c2,profile,product,50),/mudou/);assert.equal(c2.stock.quantidade_estoque,48);
});
test('permissão revogada é verificada antes de gravar',async()=>{
 const c=mockClient(product,{...profile,permissoes:[]});await assert.rejects(()=>api().updateStock(c,profile,product,1),/permissão/);assert.equal(c.writes.length,0);
});
function repo(){const sqlite=new DatabaseSync(':memory:');const db={execAsync:async sql=>sqlite.exec(sql),runAsync:async(sql,...params)=>sqlite.prepare(sql).run(...params),getFirstAsync:async(sql,...params)=>sqlite.prepare(sql).get(...params)||null,getAllAsync:async(sql,...params)=>sqlite.prepare(sql).all(...params)};const {Repository}=load('repository');return {r:new Repository(db,profile),db,sqlite};}
test('inventário e contagens persistem, relatório é isolado por usuário, fechar não toca no estoque',async()=>{
 const {r,db}=repo();await r.init();const inv=await r.open('i1');assert.equal(inv.numero,1);const row=await r.prepare('c1',inv,product,0);await assert.rejects(()=>r.close(inv),/pendente/);await r.result(row,'confirmado','confirmado',{...product,quantidade_estoque:0});await r.close(inv);assert.equal((await r.list())[0].status,'fechado');assert.equal((await r.rows('i1'))[0].quantidade,0);
 const {Repository}=load('repository');const restarted=new Repository(db,profile);assert.equal((await restarted.rows('i1')).length,1);
 const other=new Repository(db,{...profile,id:'outro'});assert.equal((await other.list()).length,0);assert.equal((await other.rows('i1')).length,0);
 await assert.rejects(()=>r.prepare('c2',inv,product,10),/aberto/);
});
test('sem diário persistido não envia; chamadas concorrentes só fazem uma atualização',async()=>{
 const {Counting}=load('counting');let calls=0;const bad={pending:async()=>null,prepare:async()=>{throw Error('disco cheio');},result:async()=>{}};
 await assert.rejects(()=>new Counting(bad,async()=>{calls++;return product;}).confirm('c',inventory,product,50),/disco cheio/);assert.equal(calls,0);
 const {r}=repo();await r.init();const inv=await r.open('i');let release;const waiter=new Promise(resolve=>release=resolve);const counter=new Counting(r,async()=>{calls++;await waiter;return {...product,quantidade_estoque:50};});const first=counter.confirm('c1',inv,product,50);await assert.rejects(()=>counter.confirm('c2',inv,product,50),/Aguarde/);release();await first;assert.equal(calls,1);
});
test('resposta perdida fica para conferência; retry original não restaura saldo depois de uma venda',async()=>{
 const {Counting}=load('counting');const {r}=repo();await r.init();const inv=await r.open('i');const c=mockClient();c.loseResponse();const counter=new Counting(r,(p,n)=>api().updateStock(c,profile,p,n));await assert.rejects(()=>counter.confirm('c',inv,product,50),/Network/);const pending=await r.pending();assert.equal(pending.status,'conferir');assert.equal(c.stock.quantidade_estoque,50);c.sale();await assert.rejects(()=>counter.retry(pending),/mudou/);assert.equal(c.stock.quantidade_estoque,48);await assert.rejects(()=>r.close(inv),/pendente/);
});
test('CSV identifica tentativas sem confirmação e protege fórmulas e quebras em nomes',()=>{
 const text=d.reportCSV(inventory,[{id:'c',produto:{...product,nome:'=HYPERLINK("x")'},quantidade:50,status:'encerrado_sem_confirmacao',criado_em:'2026-11-08',mensagem:'Sem confirmação'}]);assert.ok(text.includes("'=HYPERLINK"));assert.ok(text.includes('encerrado_sem_confirmacao'));assert.ok(text.startsWith('\uFEFF'));
});
