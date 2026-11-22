const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const read=html.slice(html.indexOf('// Prazo apenas para leituras;'),html.indexOf('async function resolverNomesFuncionariosBar(){'));
const send=html.slice(html.indexOf('// Cada tentativa é guardada antes do envio'),html.indexOf("$('btn-bar-mesa-lancar').addEventListener"));
function setup(storage=new Map()){
 const requests=[],c=vm.createContext({console,AbortController,setTimeout,clearTimeout,crypto:{randomUUID:()=>String(Math.random())},acesso:{userId:'u'},
 localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},
 supabase:{rpc:async(name,args)=>{requests.push({name,args});return c.response;}},response:{error:{message:'Resposta perdida'}},
 barMesaCarrinho:[],renderCarrinhoMesa:()=>{},$:()=>({}),});
 vm.runInContext(read+send,c);return {c,requests,storage,run:s=>vm.runInContext(s,c)};
}
const mesa={id:'m',empresa_id:'e'},itens=[{bar_produto_id:'p',quantidade:2}],cart=[{barProdutoId:'p',quantidade:2}];
test('resposta perdida e reabertura usam mesma chave e conteúdo sem novo pedido',async()=>{
 const t=setup();await t.c.barEnviarPedidoSeguro(mesa,itens,cart,'c');assert.equal(t.storage.size,1);const key=t.requests[0].args.p_idempotencia;
 const reopened=setup(t.storage);reopened.c.response={data:[{pedido_id:'p1',comanda_id:'c'}]};const result=await reopened.c.barEnviarPedidoSeguro(mesa,itens,cart,'outra-comanda');
 assert.equal(result.data[0].recuperado_bar,true);assert.equal(reopened.requests[0].args.p_idempotencia,key);assert.equal(reopened.requests[0].args.p_itens[0]._comanda_esperada,'c');
 const cached=await reopened.c.barEnviarPedidoSeguro(mesa,itens,cart,'outra-comanda');assert.equal(cached.data[0].pedido_id,'p1');assert.equal(reopened.requests.length,1);
});
test('não envia carrinho alterado, armazenamento indisponível ou pendência de outro operador',async()=>{
 const t=setup();await t.c.barEnviarPedidoSeguro(mesa,itens,cart,'c');const changed=await t.c.barEnviarPedidoSeguro(mesa,[{...itens[0],quantidade:3}],cart,'c');assert.match(changed.error.message,/outro conteúdo/);assert.equal(t.requests.length,1);
 t.c.acesso={userId:'outro'};assert.equal(t.c.barEnvioPendente(mesa),null);
 const denied=setup();denied.c.localStorage.setItem=()=>{throw Error('Quota excedida')};assert.ok((await denied.c.barEnviarPedidoSeguro(mesa,itens,cart,'c')).error);assert.equal(denied.requests.length,0);
});
test('erro de negócio confirmado libera tentativa; indisponibilidade mantém chave',async()=>{
 const t=setup();t.c.response={error:{code:'40001',message:'Mesa mudou'}};await t.c.barEnviarPedidoSeguro(mesa,itens,cart,'c');assert.equal(t.storage.size,0);
 t.c.response={error:{code:'57014',message:'Timeout'}};await t.c.barEnviarPedidoSeguro(mesa,itens,cart,'c');assert.equal(t.storage.size,1);
});
test('mudança de sessão preserva tentativa sem aplicar confirmação à nova sessão',async()=>{
 const t=setup();t.c.supabase.rpc=async()=>{t.c.acesso={userId:'outra'};return {data:[{pedido_id:'p1',comanda_id:'c'}]}};
 assert.match((await t.c.barEnviarPedidoSeguro(mesa,itens,cart,'c')).error.message,/sessão mudou/);assert.equal(t.storage.size,1);
});
test('leitura presa é abortada e a consulta seguinte pode completar',async()=>{
 const t=setup();let signal;const read={abortSignal(s){signal=s;return new Promise(()=>{})}};
 await assert.rejects(t.c.barLer(read,5),/leitura demorou/);assert.equal(signal.aborted,true);assert.equal(await t.c.barLer(Promise.resolve('ok'),50),'ok');
});
test('demora de envio libera espera sem apagar a chave e sem repetir a escrita',async()=>{
 const t=setup();t.c.setTimeout=fn=>setTimeout(fn,5);t.c.supabase.rpc=()=>{t.requests.push('write');return new Promise(()=>{})};
 const result=await t.c.barEnviarPedidoSeguro(mesa,itens,cart,'c');assert.match(result.error.message,/sem resposta confirmada/);assert.equal(t.requests.length,1);assert.equal(t.storage.size,1);
});
test('resposta atrasada de outra aba não apaga nem sobrescreve uma tentativa posterior',async()=>{
 const t=setup();let finish;t.c.supabase.rpc=()=>new Promise(resolve=>{finish=resolve});const first=t.c.barEnviarPedidoSeguro(mesa,itens,cart,'c');
 const old=t.c.barEnvioPendente(mesa).chave;const newer={chave:'posterior',origem:itens,itens,carrinho:cart};t.c.localStorage.setItem(t.c.barEnvioKey(mesa),JSON.stringify(newer));
 finish({data:[{pedido_id:'antigo',comanda_id:'c'}]});await first;t.c.barLimparEnvio(mesa,old);assert.equal(t.c.barEnvioPendente(mesa).chave,'posterior');
});
