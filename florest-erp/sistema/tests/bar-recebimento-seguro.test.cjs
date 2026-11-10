'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const sources=[['navegador','../index.html'],['Windows','../../../florest-bar-windows/src/renderer/erp-bar.js']];
for(const [name,file] of sources){
 const code=fs.readFileSync(path.join(__dirname,file),'utf8');
 function fixture(){
  const storage=new Map(),calls=[];let fail=false,estornado=false,queryError=null,prepareError=false;
  const ctx=vm.createContext({empresaCache:{empresaId:'empresa'},acesso:{userId:'operador'},localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},prepararTaxasRecebimentoMesa:async(_s,formas)=>{if(prepareError)throw Error('Cancelado');return formas.map(p=>({...p,taxas:{bandeira:'Visa'}}))},supabase:{from:()=>{const q={select:()=>q,eq:()=>q,then:resolve=>resolve({data:estornado?[{id:'p',estornado:true}]:[],error:queryError})};return q;},rpc:async(_name,args)=>{calls.push(JSON.parse(JSON.stringify(args)));return fail?{error:{code:'FETCH_ERROR',message:'Sem resposta'}}:{data:[{pagamento_id:'p',saldo_restante:0}]};}}});
  vm.runInContext(code.slice(code.indexOf('function barPagamentoStorageKey('),code.indexOf('async function receberPagamentoMesaComForma(')),ctx);
  const pay=(key='primeira',valor=25)=>{ctx.args={p_comanda_id:'comanda',p_valor:valor,p_formas:[{forma_pagamento:'Crédito',valor}],p_idempotencia:key};return vm.runInContext('barPagamentoSeguro(args)',ctx)};
  return {ctx,storage,calls,pay,fail:v=>fail=v,estorno:()=>estornado=true,queryError:()=>queryError={message:'Consulta indisponível'},cancel:()=>prepareError=true};
 }
 test(name+': recebimento total usa o valor integral e encerra a tentativa confirmada',async()=>{const f=fixture();const r=await f.pay();assert.equal(r.data[0].saldo_restante,0);assert.equal(f.calls[0].p_valor,25);assert.equal(f.storage.size,0)});
 test(name+': resposta perdida recupera a chave e o valor originais sem segundo recebimento',async()=>{const f=fixture();f.fail(true);await f.pay('original',24.96);f.fail(false);const r=await f.pay('nova',25);assert.equal(r.recuperado,true);assert.deepEqual(f.calls.map(c=>[c.p_idempotencia,c.p_valor]),[['original',24.96],['original',24.96]]);assert.deepEqual(f.calls[0].p_formas,f.calls[1].p_formas);assert.equal(f.storage.size,0)});
 test(name+': nova tentativa após estorno recebe o saldo solicitado com outra chave',async()=>{const f=fixture();f.fail(true);await f.pay('original',24.96);f.fail(false);f.estorno();await f.pay('nova',25);assert.equal(f.calls[1].p_idempotencia,'nova');assert.equal(f.calls[1].p_valor,25)});
 test(name+': falha ao consultar pendência não registra novo recebimento',async()=>{const f=fixture();f.fail(true);await f.pay();f.queryError();const r=await f.pay('nova');assert.ok(r.error);assert.equal(f.calls.length,1);assert.equal(f.storage.size,1)});
 test(name+': cancelar escolha de bandeira não cria pendência nem pagamento',async()=>{const f=fixture();f.cancel();assert.ok((await f.pay()).error);assert.equal(f.calls.length,0);assert.equal(f.storage.size,0)});
 test(name+': pendências de outro operador ficam isoladas',async()=>{const f=fixture();f.fail(true);await f.pay('a');f.ctx.acesso.userId='outro';f.fail(false);await f.pay('b');assert.equal(f.calls[1].p_idempotencia,'b');assert.equal(f.storage.size,1)});
}
for(const [name,file] of sources){
 const code=fs.readFileSync(path.join(__dirname,file),'utf8');
 test(name+': lançar R$25 e receber integral libera a mesa sem selecionar produtos',async()=>{
  const nodes=new Map(),storage=new Map();let saldo=25,status='ocupada',writes=0,finished=0;
  const el=id=>{if(!nodes.has(id))nodes.set(id,{value:id==='bar-mesa-pagamento-valor'?'25.00':'',innerHTML:'',classList:{contains:()=>true}});return nodes.get(id)};
  const ctx=vm.createContext({empresaCache:{empresaId:'e'},acesso:{userId:'u'},$:el,crypto:{randomUUID:()=> 'chave'},FORMAS_PAGAMENTO_BAR:['Dinheiro'],formatarReais:String,escapeHtml:String,mensagemBancoAcesso:e=>e.message,setBarMesaFormaCardsDisabled:()=>{},mpBarReceive:async()=>null,mpClearConfirmed:()=>{},atualizarBotaoTransferirMesa:()=>{},carregarBarMesas:async()=>{},abrirModalBarPagamentoConcluido:async()=>finished++,prepararTaxasRecebimentoMesa:async(_s,f)=>f,localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},supabase:{rpc:async(_name,args)=>{writes++;assert.equal(args.p_valor,25);saldo=0;status='livre';return {data:[{valor_recebido:25,saldo_restante:0,mesa_liberada:true}]}},from:()=>{const q={select:()=>q,eq:()=>q,single:async()=>({data:{id:'mesa',numero:1,status,comanda_atual_id:saldo?'comanda':null}})};return q;}}});
  vm.runInContext("let barMesaRecebendo=false,barComandaAtualId='comanda',barMesaAtual={id:'mesa',numero:1},barMesaResumoAtual={subtotal_aberto:25},barMesaAjustesTocados=false,barReaberturaAtual=null,barSubViewAtual='mesas';",ctx);
  ctx.atualizarSaldoEItensMesa=async()=>{ctx.saldoAtual=saldo;vm.runInContext('barMesaResumoAtual={subtotal_aberto:saldoAtual}',ctx)};
  const start=code.indexOf('function barPagamentoStorageKey('),end=code.indexOf("$('bar-mesa-forma-cards').querySelectorAll",start);
  vm.runInContext(code.slice(start,end),ctx);await vm.runInContext("receberPagamentoMesaComForma('Dinheiro')",ctx);
  assert.equal(writes,1);assert.equal(saldo,0);assert.equal(status,'livre');assert.equal(finished,1);assert.equal(storage.size,0);assert.equal(vm.runInContext('barComandaAtualId',ctx),null);assert.equal(el('bar-mesa-pagamento-valor').value,'');
 });
 test(name+': recebimento por produtos pendente é recuperado sem exigir nova seleção',async()=>{
  const pending={chave:'original',dados:{valor:24.96},mesa_id:'mesa'},calls=[];
  const ctx=vm.createContext({mpPending:()=>pending,mpPay:async(...a)=>{calls.push(a);return [{pagamento_id:'p'}]},mpSelected:()=>{throw Error('Não deve exigir seleção para recuperar')},supabase:{from:()=>{const q={select:()=>q,eq:()=>q,then:r=>r({data:[],error:null})};return q;}}});
  vm.runInContext(code.slice(code.indexOf('async function mpBarReceive('),code.indexOf('async function mpGastroReceive(')),ctx);
  const result=await vm.runInContext("mpBarReceive({p_comanda_id:'comanda',p_valor:25})",ctx);assert.equal(result.recuperado,true);assert.equal(calls.length,1);assert.equal(calls[0][3],'original');assert.equal(calls[0][2].valor,24.96);
 });
}
