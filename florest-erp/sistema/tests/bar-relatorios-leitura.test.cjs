const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const pure=html.slice(html.indexOf('const barNovoDia ='),html.indexOf('// ---------- Fim dos cálculos puros'));
const loader=html.slice(html.indexOf('async function barNovoGerar('),html.indexOf("$('btn-bar-rel-exportar-xlsx').onclick"));
function setup(){let allowed=true,company='A',calls=0,reply,request;const c=vm.createContext({Intl,Date,Map,Set,Number,JSON,Error,
 visivelBarSubview:()=>allowed,obterEmpresaId:async()=>company,escapeHtml:String,brl:String,barHistTabela:()=>'',
 supabase:{rpc:async(name,args)=>{calls++;request={name,args};return new Promise(r=>reply=r)}}});
 vm.runInContext('let barNovoFiltroSeq=0,barNovoXlsx=null;'+pure+'\n'+loader,c);
 const data={empresa_id:'A',produtos:[],mesas:[],caixas:[],comandas:[],vendas:[],pagamentos:[],formas:[],itens:[],baixas:[],barProdutos:[]};
 return {c,run:()=>vm.runInContext("barNovoGerar('periodo',{dataInicio:'2026-11-01',dataFim:'2026-11-22',produtos:[]})",c),request:()=>request,calls:()=>calls,allow:v=>allowed=v,company:v=>company=v,reply:extra=>reply({data:{...data,...extra}})};
}
test('relatório pede somente o período escolhido e usa o mesmo cálculo',async()=>{
 const s=setup(),a=s.run();await new Promise(setImmediate);assert.equal(s.request().name,'bar_relatorio_dados');assert.equal(s.request().args.p_inicio,'2026-11-01');assert.equal(s.request().args.p_fim,'2026-11-22');s.reply();const result=await a;assert.equal(result.metricas[0].valor,'0');assert.equal(s.calls(),1);
});
test('sem permissão não consulta e resposta de outra empresa é rejeitada',async()=>{
 const s=setup();s.allow(false);await assert.rejects(s.run(),/Sem permissão/);assert.equal(s.calls(),0);s.allow(true);const a=s.run();await new Promise(setImmediate);s.reply({empresa_id:'B'});await assert.rejects(a,/sessão mudou/);
});
test('troca de empresa ou filtros durante a leitura não mostra o relatório antigo',async()=>{
 for(const mode of ['company','filter']){const s=setup(),a=s.run();await new Promise(setImmediate);if(mode==='company')s.company('B');else vm.runInContext('barNovoFiltroSeq++',s.c);s.reply();await assert.rejects(a,/sessão mudou|filtros mudaram/);}
});
