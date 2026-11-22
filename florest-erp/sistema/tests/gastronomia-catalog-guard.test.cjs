const {test}=require('node:test'),assert=require('node:assert/strict');
const guard=()=>import('../../../supabase/functions/gastronomia-cardapio/catalog-guard.mjs');
test('limite de catálogo é separado por link e origem e recupera após a janela',async()=>{
 const {createCatalogGuard}=await guard();let now=0;const g=createCatalogGuard({now:()=>now,limit:2});
 assert.equal(g.allow('A','ip'),true);assert.equal(g.allow('A','ip'),true);assert.equal(g.allow('A','ip'),false);
 assert.equal(g.allow('B','ip'),true);assert.equal(g.allow('A','outro'),true);now=60000;assert.equal(g.allow('A','ip'),true);
});
test('leituras simultâneas compartilham somente o pedido em andamento, sem cache de preço antigo',async()=>{
 const {createCatalogGuard}=await guard();const g=createCatalogGuard();let calls=0,resolve;
 const load=()=>{calls++;return new Promise(r=>resolve=r)};
 const a=g.read('link',load),b=g.read('link',load);await Promise.resolve();assert.equal(calls,1);resolve({preco:10});
 assert.deepEqual(await a,{preco:10});assert.deepEqual(await b,{preco:10});
 const current=await g.read('link',async()=>({preco:12}));assert.equal(current.preco,12);
});
test('falha não fica armazenada e links diferentes não compartilham resultados',async()=>{
 const {createCatalogGuard}=await guard();const g=createCatalogGuard();
 await assert.rejects(g.read('A',async()=>{throw Error('offline')}),/offline/);
 assert.equal(await g.read('A',async()=>1),1);assert.equal(await g.read('B',async()=>2),2);
});
