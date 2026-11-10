'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path'),os=require('os');
const {openStore}=require('../src/store.cjs'),{createTransport,origin}=require('../src/transport.cjs');
function fixture(){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'bar-test-')),store=openStore(dir),vault=new Map();let held=null,delay=false,order=null,payment=null;let online=true,token='token-a',writes=0,replyLost=false;const requests=[];
const secrets={getItem:k=>vault.get(k)||null,setItem:(k,v)=>vault.set(k,v),removeItem:k=>vault.delete(k),authSession:()=>({access_token:token})};
const network=async(url,opts)=>{if(!online)throw Error('offline');const headers=opts.headers,user=String(headers.authorization||headers.Authorization).includes('token-b')?'b':'a';if(url.endsWith('/auth/v1/user'))return new Response(JSON.stringify({id:user}));if(url.includes('/perfis?'))return new Response(JSON.stringify([{id:user,empresa_id:'empresa-'+user,ativo:true}]));if(url.includes('/bar_mesas?')&&delay){delay=false;await new Promise(resolve=>held=resolve);}requests.push({url,...opts});if(url.includes('/bar_pagamentos?'))return new Response(JSON.stringify(payment?[payment]:[]));if(url.includes('/bar_pedidos?')&&order)return new Response(JSON.stringify([order]));if(opts.method!=='GET'){writes++;if(replyLost){replyLost=false;online=false;throw Error('resposta perdida');}}return new Response(JSON.stringify(url.includes('bar_mesas')?[{id:user,numero:1}]:[{pagamento_id:'p',saldo_restante:0}]),{headers:{'content-type':'application/json'}});};
const transport=createTransport({store,secrets,network});const get=()=>transport.request({url:origin+'/rest/v1/bar_mesas?select=*',method:'GET',headers:{authorization:'Bearer '+token}});const pay=(key='uuid-original')=>transport.request({url:origin+'/rest/v1/rpc/bar_comanda_pagar_valor',method:'POST',headers:{authorization:'Bearer '+token},body:JSON.stringify({p_comanda_id:'c',p_valor:10,p_formas:[{forma_pagamento:'Pix',valor:10}],p_idempotencia:key})});
return {dir,store,transport,secrets,network,get,pay,requests,delayNext:()=>delay=true,release:()=>held?.(),order:v=>order=v,payment:v=>payment=v,setOnline:v=>online=v,setToken:v=>token=v,lose:()=>replyLost=true,writes:()=>writes,close(){store.close();fs.rmSync(dir,{recursive:true,force:true});}};}
test('cache autenticado não mistura empresas ou operadores',async()=>{const f=fixture();try{assert.equal(JSON.parse((await f.get()).body)[0].id,'a');f.setOnline(false);assert.equal((await f.get()).headers['x-florest-offline'],'true');f.setToken('token-b');await assert.rejects(f.get(),/validar a sessão/);f.setOnline(true);assert.equal(JSON.parse((await f.get()).body)[0].id,'b');}finally{f.close();}});
test('sem rede bloqueia pagamento compartilhado, sem criar recebimento local falso',async()=>{const f=fixture();try{await f.get();f.setOnline(false);await f.get();const r=await f.pay();assert.equal(r.status,409);assert.equal(f.writes(),0);assert.equal(f.store.pending('empresa-a','a').length,0);}finally{f.close();}});
test('resposta perdida é reenviada com a mesma chave, nunca com a chave nova do clique',async()=>{const f=fixture();try{await f.get();f.lose();assert.equal((await f.pay('original')).status,409);assert.equal(f.store.pending('empresa-a','a').length,1);f.setOnline(true);await f.get();assert.equal((await f.pay('nova')).status,200);const sent=f.requests.filter(r=>r.url.includes('pagar_valor'));assert.deepEqual(sent.map(r=>JSON.parse(r.body).p_idempotencia),['original','original']);assert.equal(f.store.pending('empresa-a','a').length,0);const journal=f.store.db.prepare('SELECT request FROM operations').get().request;assert.ok(!journal.includes('token-a'));}finally{f.close();}});
test('pedido sem confirmação não é repetido automaticamente em mesa que pode ter sido reutilizada',async()=>{const f=fixture();try{await f.get();f.lose();const r={url:origin+'/rest/v1/rpc/bar_pedido_lancar',method:'POST',headers:{authorization:'Bearer token-a'},body:JSON.stringify({p_mesa_id:'m',p_idempotencia:'x',p_itens:[]})};await f.transport.request(r);f.setOnline(true);await f.get();assert.equal((await f.transport.request(r)).status,409);await f.transport.flush();assert.equal(f.writes(),1);}finally{f.close();}});
test('rascunhos, identificação do terminal e fila sobrevivem à reabertura e backup',async()=>{const f=fixture();try{f.store.draft('e','u','m',{cart:[{quantidade:2}]});const terminal=f.store.meta('terminal');const op=f.store.intent('e','u','mesa','f',{body:'pedido'});await f.store.db.backup(path.join(f.dir,'backup.sqlite'));f.store.close();const reopened=openStore(f.dir);assert.equal(reopened.meta('terminal'),terminal);assert.equal(reopened.drafts('e','u')[0].data.cart[0].quantidade,2);assert.equal(reopened.pending('e','u')[0].id,op.id);assert.equal(reopened.pending('e','u')[0].state,'uncertain');reopened.close();}finally{try{f.close()}catch{fs.rmSync(f.dir,{recursive:true,force:true})}}});

test('confirmação automática aguarda recuperação do resultado, sem aceitar outro pagamento igual',async()=>{const f=fixture();try{await f.get();f.lose();await f.pay('original');f.setOnline(true);await f.get();await f.transport.flush();assert.equal(f.store.pending('empresa-a','a')[0].state,'confirmed');const calls=f.writes();assert.equal((await f.pay('novo-clique')).status,200);assert.equal(f.writes(),calls);assert.equal(f.store.pending('empresa-a','a').length,0);}finally{f.close();}});
test('pedido confirmado é conciliado por leitura, mesmo se a mesa já mudou de ciclo',async()=>{const f=fixture();try{await f.get();f.lose();const r={url:origin+'/rest/v1/rpc/bar_pedido_lancar',method:'POST',headers:{authorization:'Bearer token-a'},body:JSON.stringify({p_mesa_id:'m',p_idempotencia:'original',p_itens:[{bar_produto_id:'p',quantidade:1}]})};await f.transport.request(r);f.order({id:'pedido-original',empresa_id:'empresa-a',criado_por:'a',mesa_id:'m',comanda_id:'comanda-original'});f.setOnline(true);await f.get();await f.transport.flush();const result=await f.transport.request({...r,body:r.body.replace('"original"','"nova-chave"')});assert.equal(JSON.parse(result.body)[0].recuperado_windows,true);assert.equal(f.writes(),1);}finally{f.close();}});
test('resposta antiga não é entregue depois de trocar de empresa',async()=>{const f=fixture();try{await f.get();f.delayNext();const old=f.get();await new Promise(r=>setImmediate(r));f.setToken('token-b');await f.get();f.release();assert.equal((await old).status,409);assert.equal(f.transport.status().company,'empresa-b');}finally{f.close();}});
test('senhas de cadastro de garçom nunca entram no diário SQLite',async()=>{const f=fixture();try{await f.get();f.lose();await f.transport.request({url:origin+'/functions/v1/florest-garcom-criar',method:'POST',headers:{authorization:'Bearer token-a'},body:JSON.stringify({senha:'segredo-de-teste'})});assert.equal(f.store.db.prepare('SELECT count(*) AS n FROM operations').get().n,0);}finally{f.close();}});

for(const estornado of [false,true])test('fila confirmada é conciliada por leitura, inclusive estorno='+estornado,async()=>{
 const f=fixture();try{
  await f.get();f.lose();await f.pay('original');f.setOnline(true);await f.get();await f.transport.flush();
  assert.equal(f.store.pending('empresa-a','a')[0].state,'confirmed');
  const writes=f.writes();f.payment({id:'p',empresa_id:'empresa-a',comanda_id:'c',total:10,estornado});
  await f.transport.flush();assert.equal(f.writes(),writes);assert.equal(f.store.pending('empresa-a','a').length,0);
 }finally{f.close();}
});
test('pendência antiga estornada não bloqueia novo valor nem devolve confirmação antiga',async()=>{
 const f=fixture();try{
  await f.get();f.lose();await f.pay('original');f.setOnline(true);await f.get();
  f.payment({id:'p',empresa_id:'empresa-a',comanda_id:'c',total:10,estornado:true});
  const result=await f.transport.request({url:origin+'/rest/v1/rpc/bar_comanda_pagar_valor',method:'POST',headers:{authorization:'Bearer token-a'},body:JSON.stringify({p_comanda_id:'c',p_valor:25,p_formas:[{forma_pagamento:'Pix',valor:25}],p_idempotencia:'nova'})});
  assert.equal(result.status,200);const sent=f.requests.filter(r=>r.url.includes('pagar_valor')).map(r=>JSON.parse(r.body));
  assert.equal(sent.length,2);assert.equal(sent[1].p_valor,25);assert.equal(sent[1].p_idempotencia,'nova');
  assert.equal(f.store.pending('empresa-a','a').length,0);
 }finally{f.close();}
});
test('registro de outra empresa nunca libera uma operação incerta',async()=>{
 const f=fixture();try{
  await f.get();f.lose();await f.pay('original');f.setOnline(true);await f.get();
  f.payment({id:'p',empresa_id:'outra',comanda_id:'c',total:10});
  const result=await f.transport.request({url:origin+'/rest/v1/rpc/bar_comanda_pagar_valor',method:'POST',headers:{authorization:'Bearer token-a'},body:JSON.stringify({p_comanda_id:'c',p_valor:25,p_idempotencia:'nova'})});
  assert.equal(result.status,409);assert.equal(f.writes(),1);assert.equal(f.store.pending('empresa-a','a').length,1);
 }finally{f.close();}
});
test('mesmo valor após estorno confirmado usa a nova chave, sem devolver resposta antiga',async()=>{
 const f=fixture();try{
  await f.get();f.lose();await f.pay('original');f.setOnline(true);await f.get();await f.transport.flush();
  f.payment({id:'p',empresa_id:'empresa-a',comanda_id:'c',total:10,estornado:true});
  await f.pay('nova');const sent=f.requests.filter(r=>r.url.includes('pagar_valor')).map(r=>JSON.parse(r.body));
  assert.equal(sent.at(-1).p_idempotencia,'nova');assert.equal(sent.length,3);
  assert.equal(f.store.pending('empresa-a','a').length,0);
 }finally{f.close();}
});
