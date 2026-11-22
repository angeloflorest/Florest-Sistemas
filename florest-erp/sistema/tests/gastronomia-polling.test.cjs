const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const source=html.slice(html.indexOf('let gsAtualizacaoSilenciosa=null;'),html.indexOf('\nfunction gsPrep('));
function setup(){
 let resolve,reject,calls=0,renders=0;
 const ctx=vm.createContext({GS:{ctx:{empresa_id:'A',cardapio_versao:'v'},area:'pedidos'},acesso:{},
  gsPollingPermitido:()=>true,gsSnapshotArea:()=>'',gsRPC:()=>{calls++;return new Promise((a,b)=>{resolve=a;reject=b})},
  window:{},$:()=>({open:false}),document:{querySelector:()=>null},gsRender:()=>renders++});
 vm.runInContext(source,ctx);
 return {ctx,run:()=>vm.runInContext('gsAtualizarSilencioso()',ctx),count:()=>calls,renders:()=>renders,
 reply:(empresa='A')=>resolve({empresa_id:empresa,cardapio_versao:'v'}),fail:()=>reject(Error('offline'))};
}
test('timer, Realtime e visibilidade compartilham a consulta em andamento',async()=>{
 const s=setup(),a=s.run(),b=s.run(),c=s.run();assert.equal(s.count(),1);s.reply();await Promise.all([a,b,c]);
 const d=s.run();assert.equal(s.count(),2);s.reply();await d;
});
test('falha libera a próxima tentativa',async()=>{
 const s=setup(),a=s.run();s.fail();await assert.rejects(a,/offline/);const b=s.run();assert.equal(s.count(),2);s.reply();await b;
});
test('resposta de outra empresa ou sessão antiga não sobrescreve o contexto',async()=>{
 for(const troca of ['acesso={}','GS.ctx={empresa_id:"B",cardapio_versao:"v"}']){
  const s=setup(),original=s.ctx.GS.ctx,a=s.run();vm.runInContext(troca,s.ctx);s.reply();await a;assert.equal(s.renders(),0);if(troca==='acesso={}')assert.equal(s.ctx.GS.ctx,original);
 }
 const s=setup(),a=s.run();s.reply('B');await a;assert.equal(s.ctx.GS.ctx.empresa_id,'A');assert.equal(s.renders(),0);
});
