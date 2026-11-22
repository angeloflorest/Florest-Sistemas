const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const source=html.slice(html.indexOf('let gsLeituraFalhas=0,'),html.indexOf('\nfunction gsPrep('));
function setup(){
 let resolve,reject,calls=0,renders=0,clock=1000,timer,params;
 const original={empresa_id:'A',cardapio_versao:'v',catalogo:[{id:'original'}],catalogo_revisao:'cat0',revisao:'rev0'};
 const ctx=vm.createContext({GS:{ctx:original,area:'pedidos'},acesso:{},Date:{now:()=>clock},AbortController,
  setTimeout:fn=>(timer=fn,1),clearTimeout:()=>{},
  gsPollingPermitido:()=>true,gsSnapshotArea:()=>'',supabase:{rpc:(name,args)=>{assert.equal(name,'gastronomia_atualizacao');params=args;return{abortSignal:signal=>{calls++;return new Promise((a,b)=>{resolve=a;reject=b;signal.addEventListener('abort',()=>b(Error('Abortado')),{once:true})})}}}},
  window:{},$:()=>({open:false}),document:{querySelector:()=>null},gsRender:()=>renders++});
 vm.runInContext(source,ctx);
 return {ctx,original,run:()=>vm.runInContext('gsAtualizarSilencioso()',ctx),count:()=>calls,renders:()=>renders,params:()=>params,advance:()=>clock+=31000,abort:()=>timer(),
 reply:(empresa='A',extra={})=>resolve({data:{empresa_id:empresa,cardapio_versao:'v',...extra}}),fail:()=>reject(Error('offline'))};
}
test('timer, Realtime e visibilidade compartilham a consulta em andamento',async()=>{
 const s=setup(),a=s.run(),b=s.run(),c=s.run();assert.equal(s.count(),1);s.reply();await Promise.all([a,b,c]);
 const d=s.run();assert.equal(s.count(),2);s.reply();await d;
});
test('falha aplica espera progressiva e depois libera a próxima tentativa',async()=>{
 const s=setup(),a=s.run();s.fail();await assert.rejects(a,/offline/);await s.run();assert.equal(s.count(),1);s.advance();const b=s.run();assert.equal(s.count(),2);s.reply();await b;
});
test('resposta de outra empresa, sessão ou contexto antigo não sobrescreve os dados',async()=>{
 for(const troca of ['acesso={}','GS.ctx={empresa_id:"B",cardapio_versao:"v"}','GS.ctx={empresa_id:"A",cardapio_versao:"v"}']){
  const s=setup(),original=s.ctx.GS.ctx,a=s.run();vm.runInContext(troca,s.ctx);s.reply();await a;assert.equal(s.renders(),0);if(troca==='acesso={}')assert.equal(s.ctx.GS.ctx,original);
 }
 const s=setup(),a=s.run();s.reply('B');await a;assert.equal(s.ctx.GS.ctx.empresa_id,'A');assert.equal(s.renders(),0);
});
test('inalterado não substitui o contexto e catálogo omitido conserva o original',async()=>{
 const s=setup(),a=s.run();assert.equal(s.params().p_revisao,'rev0');s.reply('A',{inalterado:true});await a;assert.equal(s.ctx.GS.ctx,s.original);
 const b=s.run();s.reply('A',{catalogo_inalterado:true,catalogo:[],revisao:'rev1',catalogo_revisao:'cat0'});await b;assert.equal(s.ctx.GS.ctx.catalogo,s.original.catalogo);
 const c=s.run();assert.equal(s.params().p_revisao,'rev1');s.reply('A',{inalterado:true});await c;
});
test('leitura presa é cancelada e a trava permite uma nova tentativa após a espera',async()=>{
 const s=setup(),a=s.run();s.abort();await assert.rejects(a,/Abortado/);s.advance();const b=s.run();assert.equal(s.count(),2);s.reply();await b;
});
