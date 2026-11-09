const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function source(a,b){const i=html.indexOf(a),j=html.indexOf(b,i+a.length);assert.ok(i>=0&&j>i);return html.slice(i,j);}
const controller=source('// Atualização das Mesas: 60 s,','function aoClicarMesaBar(mesa){');
const modal=source('function atualizarSaldoEItensMesa(){','// "TOTAL CONSUMIDO / JÁ PAGO / FALTA PAGAR"');
const realtime=source('function configurarRealtimeBar(){','// ---------- Relatórios (Módulo Bar)');

test('ciclo das mesas é 60 segundos e Realtime não dispara consultas',()=>{
 assert.match(controller,/BAR_MESAS_INTERVALO_MS = 60000/);
 assert.match(realtime,/barSinalizarMudancaMesa/);
 assert.doesNotMatch(realtime,/carregarBarMesas\(|atualizarSaldoEItensMesa\(/);
 assert.doesNotMatch(controller,/saldoPorComanda\.get.*\|\| 0/);
});

test('grade/modal: concorrência, falhas, rascunhos e operações locais', {skip:!process.env.BAR_REFRESH_BROWSER},async t=>{
 const {chromium}=require(process.env.BAR_REFRESH_BROWSER);
 const browser=await chromium.launch({headless:true,executablePath:process.env.BAR_REFRESH_EXECUTABLE||'/usr/bin/chromium',args:['--no-sandbox']});
 async function page(){
  const p=await browser.newPage();const errors=[];p.on('pageerror',e=>errors.push(e.message));
  await p.setContent(`<div id="view-bar"><div id="bar-sub-mesas"><div id="bar-mesas-msg"></div><div id="bar-mesas-atualizacao" class="hidden"></div><div id="bar-mesas-vazio"></div><button id="btn-bar-estornar-busca"></button><div id="bar-mesas-grid"></div></div></div><div id="modal-bar-mesa" class="hidden"><div id="bar-mesa-msg"></div><div id="bar-mesa-atualizacao" class="hidden"></div><span id="bar-mesa-total-consumido"></span><span id="bar-mesa-total-pago"></span><span id="bar-mesa-total-aberto"></span><input id="bar-mesa-pagamento-valor"><button id="btn-bar-mesa-lancar"></button><div id="bar-mesa-historico-wrap"></div></div>`);
  await p.addScriptTag({content:`
   const $=id=>document.getElementById(id);
   let acesso={userId:'A'},barSubViewAtual='mesas',barMesaAtual=null,barComandaAtualId=null,barMesaCarrinho=[],barMesaAjustesTocados=false,barMesaRecebendo=false,barCancelandoMesa=false,barMesaResumoAtual=null,barMesaJuncoes=[],barMesaQtdItensValidos=0,barMesaQtdPagamentos=0,barReaberturaAtual=null,barCanalRealtime=null;
   const escapeHtml=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
   const formatarReais=n=>'R$ '+Number(n).toFixed(2),mensagemBancoAcesso=e=>e.message,podeAcessarBar=()=>true;
   window.data={mesas:[{id:'m1',numero:1,status:'ocupada',comanda_atual_id:'c1'},{id:'m2',numero:2,status:'livre',comanda_atual_id:null}],values:{c1:50},failBalance:false,failList:false};
   window.calls=[];window.held={};window.waiters={};window.intervals=[];window.phases=[];window.phaseActive=0;window.phasePeak=0;window.balanceActive=0;window.balancePeak=0;window.renders=[];
   window.setInterval=(fn,ms)=>{window.intervals.push({fn,ms});return 1;};
   window.release=k=>{window.held[k]=false;const list=window.waiters[k]||[];window.waiters[k]=[];for(const done of list)done();};
   async function gate(k){window.calls.push(k);if(window.held[k])await new Promise(done=>(window.waiters[k]||=([])).push(done));await Promise.resolve();}
   const supabase={
    from(table){let id;const q={select(){return q},eq(k,v){if(k==='comanda_id')id=v;return q},async order(){const rows=structuredClone(window.data.mesas);await gate('list');if(window.data.failList)return{error:{message:'offline'}};return{data:rows,error:null};}};return q;},
    async rpc(name,args){const value=window.data.values[args.p_comanda_id];if(name==='bar_comanda_resumo_financeiro'){window.balanceActive++;window.balancePeak=Math.max(window.balancePeak,window.balanceActive);try{await gate('balance');if(window.data.failBalance)return{error:{message:'timeout'}};return{data:[{subtotal_aberto:value,total_consumido:value,total_pago:0}],error:null};}finally{window.balanceActive--;}}return{data:[],error:null};},
    channel(){const q={on(event,filter,fn){window.rt||={};window.rt[filter.table]=fn;return q},subscribe(){return q}};return q;}
   };
   const buscarTodos=async()=>{await gate('items');if(window.data.throwItems)throw Error('Falha de itens');return{data:[],error:null}},resolverNomesFuncionariosBar=async()=>({});
   const barReaberturaConsultar=async()=>{},barReaberturaPainel=()=>{},barHistoricoErro=e=>e.message;
   const carregarHistoricoPagamentosMesa=async()=>{await gate('history')},atualizarBotaoCancelarMesa=()=>{},atualizarBotaoRelatorioMesa=()=>{},atualizarBotaoTransferirMesa=()=>{},renderItensComandaMesa=()=>{};
   function renderResumoFinanceiroMesa(){window.renders.push({id:barComandaAtualId,value:barMesaResumoAtual?.subtotal_aberto});for(const id of ['bar-mesa-total-consumido','bar-mesa-total-aberto'])$(id).textContent=formatarReais(barMesaResumoAtual?.subtotal_aberto);}
   function aoClicarMesaBar(m){window.clicked=m.id;window.clickedComanda=m.comanda_atual_id;}
  `+controller+'\n'+modal+'\n'+realtime+`
   for(const name of ['barConsultarGradeMesas','barConsultarSaldoEItensMesa']){const original=window[name];window[name]=async(...args)=>{window.phaseActive++;window.phasePeak=Math.max(window.phasePeak,window.phaseActive);window.phases.push(name);try{return await original(...args)}finally{window.phaseActive--;}};}
   window.openMesa=(id='m1')=>{barMesaAtual=structuredClone(window.data.mesas.find(m=>m.id===id));barComandaAtualId=barMesaAtual.comanda_atual_id;barMesaResumoAtual=null;$('modal-bar-mesa').classList.remove('hidden');};
   window.localOperation=async()=>{await atualizarSaldoEItensMesa();await carregarBarMesas();};
   window.snapshot=()=>({saldo:barMesaResumoAtual?.subtotal_aberto,cart:structuredClone(barMesaCarrinho),id:barComandaAtualId,pending:!!barAtualizacaoMesas.promessa});
  `});p.auditErrors=errors;return p;
 }
 try{
  await t.test('um ciclo e chamadas simultâneas são agrupados; saldo zero só aparece quando confirmado',async()=>{
   const p=await page();try{assert.deepEqual(await p.evaluate(()=>window.intervals.map(x=>x.ms)),[60000]);await p.evaluate(()=>Promise.all([carregarBarMesas(),carregarBarMesas(true),carregarBarMesas()]));assert.equal(await p.evaluate(()=>window.calls.filter(x=>x==='list').length),1);assert.equal(await p.evaluate(()=>window.phasePeak),1);assert.match(await p.locator('#bar-mesas-grid').innerText(),/50.00/);await p.evaluate(()=>{window.data.values.c1=0;return carregarBarMesas()});assert.match(await p.locator('#bar-mesas-grid').innerText(),/0.00/);assert.equal(await p.locator('#bar-mesas-atualizacao').getAttribute('class'),'hidden');}finally{await p.close()}
  });
  await t.test('mudança durante uma consulta agenda nova leitura e nunca sobrepõe grade/modal',async()=>{
   const p=await page();try{await p.evaluate(()=>{window.held.list=true;window.first=carregarBarMesas();});await p.waitForFunction(()=>window.calls.includes('list'));await p.evaluate(()=>{window.data.values.c1=75;window.openMesa();window.after=window.localOperation();window.release('list');});await p.evaluate(()=>Promise.all([window.first,window.after]));assert.equal(await p.evaluate(()=>window.phasePeak),1);assert.equal(await p.evaluate(()=>window.snapshot().saldo),75);assert.match(await p.locator('#bar-mesas-grid').innerText(),/75.00/);}finally{await p.close()}
  });
  await t.test('limita consultas de saldo a quatro e deduplica comandas',async()=>{
   const p=await page();try{await p.evaluate(()=>{window.data.mesas=Array.from({length:12},(_,n)=>({id:'m'+n,numero:n,status:'ocupada',comanda_atual_id:'c'+n}));for(let n=0;n<12;n++)window.data.values['c'+n]=n;window.held.balance=true;window.first=carregarBarMesas();});await p.waitForFunction(()=>window.balanceActive===4);await p.evaluate(()=>window.release('balance'));await p.evaluate(()=>window.first);assert.equal(await p.evaluate(()=>window.balancePeak),4);assert.equal(await p.evaluate(()=>window.calls.filter(x=>x==='balance').length),12);}finally{await p.close()}
  });
  await t.test('falha conserva saldo anterior e o botão Atualizar recupera o valor',async()=>{
   const p=await page();try{await p.evaluate(()=>carregarBarMesas());await p.evaluate(()=>{window.data.failBalance=true;return carregarBarMesas(true)});assert.match(await p.locator('#bar-mesas-grid').innerText(),/50.00/);assert.match(await p.locator('#bar-mesas-grid').innerText(),/Valor desatualizado/);await p.evaluate(()=>{window.data.failBalance=false;window.data.values.c1=80;});await p.locator('#bar-mesas-atualizacao button').click();await p.waitForFunction(()=>document.getElementById('bar-mesas-grid').textContent.includes('80.00'));assert.equal(await p.locator('#bar-mesas-atualizacao').getAttribute('class'),'hidden');}finally{await p.close()}
  });
  await t.test('primeira falha não inventa zero nem reaproveita saldo de outra comanda',async()=>{
   const p=await page();try{await p.evaluate(()=>{window.data.failBalance=true;return carregarBarMesas()});assert.match(await p.locator('#bar-mesas-grid').innerText(),/Saldo indisponível/);assert.doesNotMatch(await p.locator('#bar-mesas-grid').innerText(),/R\$ 0/);await p.evaluate(()=>{window.data.failBalance=false;return carregarBarMesas()});await p.evaluate(()=>{window.data.mesas[0].comanda_atual_id='c2';window.data.failBalance=true;return carregarBarMesas()});assert.doesNotMatch(await p.locator('#bar-mesas-grid').innerText(),/50.00/);}finally{await p.close()}
  });
  await t.test('falha na lista conserva cartões e indica desatualização',async()=>{
   const p=await page();try{await p.evaluate(()=>carregarBarMesas());await p.evaluate(()=>{window.data.failList=true;return carregarBarMesas(true)});assert.match(await p.locator('#bar-mesas-grid').innerText(),/Mesa 1/);assert.match(await p.locator('#bar-mesas-grid').innerText(),/50.00/);assert.match(await p.locator('#bar-mesas-grid').innerText(),/Valor desatualizado/);}finally{await p.close()}
  });
  await t.test('ciclo preserva carrinho, digitação e ajustes e continua atualizando a grade',async()=>{
   const p=await page();try{await p.evaluate(()=>{window.openMesa();barMesaCarrinho=[{quantidade:3,observacao:'Sem gelo'}];$('bar-mesa-pagamento-valor').value='17,50';});await p.locator('#bar-mesa-pagamento-valor').focus();await p.evaluate(()=>window.intervals[0].fn());await p.evaluate(()=>barAtualizacaoMesas.promessa);assert.deepEqual(await p.evaluate(()=>window.snapshot().cart),[{quantidade:3,observacao:'Sem gelo'}]);assert.equal(await p.locator('#bar-mesa-pagamento-valor').inputValue(),'17,50');assert.equal(await p.evaluate(()=>window.phases.includes('barConsultarSaldoEItensMesa')),false);assert.equal(await p.evaluate(()=>window.calls.filter(x=>x==='list').length),1);}finally{await p.close()}
  });
  await t.test('Realtime sinaliza sem gerar leituras e o ciclo não roda fora das mesas',async()=>{
   const p=await page();try{await p.evaluate(()=>carregarBarMesas());const before=await p.evaluate(()=>window.calls.length);await p.evaluate(()=>{configurarRealtimeBar();for(let n=0;n<20;n++)window.rt.bar_pedidos_itens({new:{comanda_id:'c1'}});});assert.equal(await p.evaluate(()=>window.calls.length),before);assert.match(await p.locator('#bar-mesas-grid').innerText(),/Valor desatualizado/);await p.evaluate(()=>{$('view-bar').classList.add('hidden');window.intervals[0].fn();});assert.equal(await p.evaluate(()=>window.calls.length),before);}finally{await p.close()}
  });
  await t.test('saldo confirmado no modal também atualiza seu cartão e falha do modal conserva o valor',async()=>{
   const p=await page();try{await p.evaluate(()=>carregarBarMesas());await p.evaluate(()=>{window.openMesa();window.data.values.c1=65;return atualizarSaldoEItensMesa()});assert.equal(await p.evaluate(()=>window.snapshot().saldo),65);assert.match(await p.locator('#bar-mesas-grid').innerText(),/65.00/);await p.evaluate(()=>{window.data.failBalance=true;return atualizarSaldoEItensMesa()});assert.equal(await p.evaluate(()=>window.snapshot().saldo),65);assert.match(await p.locator('#bar-mesa-atualizacao').innerText(),/Valor desatualizado/);assert.match(await p.locator('#bar-mesa-total-aberto').innerText(),/65.00/);assert.deepEqual(p.auditErrors,[]);}finally{await p.close()}
  });
  await t.test('consulta antiga não contamina outra sessão ou outra mesa aberta',async()=>{
   const p=await page();try{await p.evaluate(()=>{window.held.list=true;window.first=carregarBarMesas();});await p.waitForFunction(()=>window.calls.includes('list'));await p.evaluate(()=>{acesso={userId:'B'};window.data.mesas=[{id:'outra',numero:99,status:'livre',comanda_atual_id:null}];window.next=carregarBarMesas();window.release('list');});await p.evaluate(()=>Promise.all([window.first,window.next]));assert.match(await p.locator('#bar-mesas-grid').innerText(),/99/);assert.doesNotMatch(await p.locator('#bar-mesas-grid').innerText(),/Mesa 1/);assert.deepEqual(p.auditErrors,[]);}finally{await p.close()}
  });
  await t.test('cartão com mesmo texto abre a comanda atual, sem reutilizar a referência antiga',async()=>{
   const p=await page();try{await p.evaluate(()=>carregarBarMesas());await p.evaluate(()=>{window.data.mesas[0].comanda_atual_id='c2';window.data.values.c2=50;return carregarBarMesas(true)});await p.locator('[data-mesa-id="m1"]').click();assert.equal(await p.evaluate(()=>window.clickedComanda),'c2');}finally{await p.close()}
  });
  await t.test('erro de uma leitura espera as demais antes de liberar a próxima atualização',async()=>{
   const p=await page();try{await p.evaluate(()=>{window.openMesa();window.data.throwItems=true;window.held.balance=true;window.first=atualizarSaldoEItensMesa();});await p.waitForFunction(()=>window.balanceActive===1);await p.evaluate(()=>{window.next=carregarBarMesas();});assert.equal(await p.evaluate(()=>window.calls.includes('list')),false);await p.evaluate(()=>window.release('balance'));await p.evaluate(()=>Promise.all([window.first,window.next]));assert.equal(await p.evaluate(()=>window.phasePeak),1);assert.equal(await p.evaluate(()=>window.balanceActive),0);}finally{await p.close()}
  });
  await t.test('resposta do modal anterior é descartada ao trocar de mesa',async()=>{
   const p=await page();try{await p.evaluate(()=>{window.data.mesas[1]={id:'m2',numero:2,status:'ocupada',comanda_atual_id:'c2'};window.data.values.c2=30;return carregarBarMesas()});await p.evaluate(()=>{window.openMesa();window.held.balance=true;window.first=atualizarSaldoEItensMesa();});await p.waitForFunction(()=>window.balanceActive===1);await p.evaluate(()=>{window.openMesa('m2');window.next=atualizarSaldoEItensMesa();window.release('balance');});await p.evaluate(()=>Promise.all([window.first,window.next]));assert.equal(await p.evaluate(()=>window.snapshot().saldo),30);assert.equal(await p.evaluate(()=>window.renders.some(r=>r.id==='c1')),false);assert.deepEqual(p.auditErrors,[]);}finally{await p.close()}
  });
  await t.test('pagamento remoto que libera a mesa é reconhecido no próximo ciclo',async()=>{
   const p=await page();try{await p.evaluate(()=>carregarBarMesas());await p.evaluate(()=>{window.openMesa();window.data.mesas[0].status='livre';window.data.mesas[0].comanda_atual_id=null;return barSolicitarAtualizacao({grade:true,modal:true})});assert.equal(await p.evaluate(()=>window.snapshot().id),null);assert.equal(await p.evaluate(()=>window.snapshot().saldo),0);assert.match(await p.locator('#bar-mesas-grid').innerText(),/LIVRE/);}finally{await p.close()}
  });
 }finally{await browser.close();}
});
