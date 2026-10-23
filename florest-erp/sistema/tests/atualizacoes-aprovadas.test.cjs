const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const html=fs.readFileSync(process.env.ERP_HTML||path.join(__dirname,'../index.html'),'utf8');

test('XML permite nova operação depois que a anterior terminou',async()=>{
 const a=ambiente();await a.context.xmlcAbrir();a.el('xmlc-mes').value='2026-09';
 await a.context.xmlcSolicitar('resumo');await a.context.xmlcSolicitar('resumo');
 assert.equal(a.calls.filter(x=>x.url).length,2);
});

const base=fs.readFileSync(process.env.ERP_BASE||path.join(__dirname,'fixtures/autorizacao-original.txt'),'utf8');
function trecho(s,a,b){const i=s.indexOf(a),j=s.indexOf(b,i);assert.ok(i>=0&&j>i);return s.slice(i,j);}
test('filtro não modifica usuários e oferece ativos, inativos e todos',()=>{
 const src=trecho(html,'function usuariosFiltrarSituacao(','$(\'usuarios-situacao\').addEventListener');
 const ctx=vm.createContext({});vm.runInContext(src,ctx);
 const lista=[{id:1,ativo:true},{id:2,ativo:false},{id:3,ativo:true}];const antes=JSON.stringify(lista);
 const ids=s=>Array.from(ctx.usuariosFiltrarSituacao(lista,s),u=>u.id);
 assert.deepEqual(ids('ativos'),[1,3]);assert.deepEqual(ids('inativos'),[2]);assert.deepEqual(ids('todos'),[1,2,3]);
 assert.equal(JSON.stringify(lista),antes);
 assert.match(html,/<option value="ativos" selected>Ativos/);
 assert.match(html,/\$\('usuarios-situacao'\).value='ativos';/);
 assert.match(html,/for\(const u of visiveis\)/);
});
test('autorização por campo atual e demais fluxos preservados',()=>{
 assert.equal(trecho(html,'async function florestAutorizar(', '// Lista proprietários'),trecho(base,'async function florestAutorizar(', '// Lista proprietários'));
 for(const token of ["import { instalarTaxasPagamento","function mariaPodeAcessar","const SECOES_RELATORIOS_BAR","function atualizarPainelPagamentoPdv","function fpqLimparResultados"]){
  assert.ok(html.includes(token),'Preservar '+token);
 }
});
function ambiente(){
 const nodes=new Map(),calls=[],responses=[],confirmacoes=[];
 const el=id=>{if(!nodes.has(id))nodes.set(id,{value:'',textContent:'',disabled:false,style:{},children:[],classList:{add(){},remove(){}},appendChild(x){this.children.push(x)},replaceChildren(){this.children=[]},checkValidity(){return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(this.value)},addEventListener(){},click(){calls.push({click:id})},remove(){}});return nodes.get(id)};
 let empresa='empresa-a',contador={nome:'Contador',email:'contador@teste.com'};
 const query=t=>{const filters=[];const result=()=>Promise.resolve(t==='fiscal_contadores'?{data:contador}:{data:[]});const q={select(){return q},eq(k,v){filters.push([k,v]);return q},order(){return q},limit(){return result()},maybeSingle(){calls.push({consulta:t,filters});return result()},async upsert(data,opts){calls.push({upsert:t,data,opts});contador={nome:data.nome,email:data.email};return {error:null}}};return q};
 const document={createElement:tag=>({...el('element-'+Math.random()),tag}),body:{appendChild(){}}};
 const context=vm.createContext({document,$:el,Date,Map,Set,String,Error,JSON,Promise,URL:{createObjectURL:()=> 'blob:teste',revokeObjectURL(){}},setTimeout(){},obterEmpresaId:async()=>empresa,confirm:msg=>{calls.push({confirm:msg});return confirmacoes.length?confirmacoes.shift():true},fetch:async(url,options)=>{calls.push({url,options});return responses.shift()||{ok:true,status:200,json:async()=>({quantidade:2,pendentes:[]})}},SUPABASE_URL:'https://teste.supabase.co',SUPABASE_ANON_KEY:'chave-publica',supabase:{from:query,auth:{getSession:async()=>({data:{session:{access_token:'sessao-teste'}}})}},fcpTrocarAba(){}});
 const code=trecho(html,'// ===== Fiscal > XMLs',"\n</script>\n\n</body>");
 vm.runInContext(code,context);
 return {context,el,calls,responses,confirmacoes,setEmpresa:v=>empresa=v,getContador:()=>contador,run:s=>vm.runInContext(s,context)};
}
test('XML carrega contador e histórico com filtro da empresa e escapa valores como texto',async()=>{
 const a=ambiente();await a.context.xmlcAbrir();
 assert.equal(a.el('xmlc-email').value,'contador@teste.com');
 assert.ok(a.calls.some(x=>x.consulta==='fiscal_contadores'&&x.filters.some(f=>f[0]==='empresa_id'&&f[1]==='empresa-a')));
 assert.equal(a.el('xmlc-historico').children[0].children[0].textContent,'Nenhum pacote preparado ainda.');
});
test('XML salvar valida e persiste somente cadastro da empresa',async()=>{
 const a=ambiente();await a.context.xmlcAbrir();a.el('xmlc-email').value='invalido';await a.context.xmlcSalvar();assert.equal(a.calls.filter(x=>x.upsert).length,0);
 a.el('xmlc-nome').value='Novo escritório';a.el('xmlc-email').value='novo@teste.com';await a.context.xmlcSalvar();
 assert.deepEqual(JSON.parse(JSON.stringify(a.calls.find(x=>x.upsert).data)),{empresa_id:'empresa-a',nome:'Novo escritório',email:'novo@teste.com'});
});
test('XML resumo usa endpoint e sessão atuais sem invocar emissão',async()=>{
 const a=ambiente();await a.context.xmlcAbrir();a.el('xmlc-mes').value='2026-09';await a.context.xmlcSolicitar('resumo');
 const f=a.calls.find(x=>x.url);assert.equal(f.url,'https://teste.supabase.co/functions/v1/fiscal-xml-contador');
 assert.equal(f.options.headers.Authorization,'Bearer sessao-teste');assert.deepEqual(JSON.parse(f.options.body),{competencia:'2026-09',acao:'resumo'});
 assert.match(a.el('xmlc-resumo-dados').children[0].textContent,/XMLs encontrados: 2/);
});
test('XML não envia destinatário editado sem salvar nem envia ao recusar confirmação',async()=>{
 const a=ambiente();await a.context.xmlcAbrir();a.el('xmlc-email').value='naosalvo@teste.com';await a.context.xmlcSolicitar('enviar');assert.equal(a.calls.filter(x=>x.url).length,0);
 a.el('xmlc-email').value='contador@teste.com';a.confirmacoes.push(false);await a.context.xmlcSolicitar('enviar');assert.equal(a.calls.filter(x=>x.url).length,0);
});
test('XML reenvio requer segunda confirmação e envia flag explícita',async()=>{
 const a=ambiente();await a.context.xmlcAbrir();a.el('xmlc-mes').value='2026-09';
 a.responses.push({ok:false,status:409,json:async()=>({reenvio:true})},{ok:true,status:200,json:async()=>({quantidade:2,destinatario:'contador@teste.com'})});
 await a.context.xmlcSolicitar('enviar');const fetches=a.calls.filter(x=>x.url);assert.equal(fetches.length,2);assert.equal(JSON.parse(fetches[1].options.body).confirmarReenvio,true);assert.equal(a.calls.filter(x=>x.confirm).length,2);
});
test('XML bloqueia troca de empresa e libera botão após erro',async()=>{
 const a=ambiente();await a.context.xmlcAbrir();a.setEmpresa('empresa-b');await a.context.xmlcSolicitar('resumo');
 assert.equal(a.calls.filter(x=>x.url).length,0);assert.equal(a.el('xmlc-resumo').disabled,false);assert.match(a.el('xmlc-pacote-msg').textContent,/Empresa alterada/);
});
test('XML download de ZIP não envia email',async()=>{
 const a=ambiente();await a.context.xmlcAbrir();a.el('xmlc-mes').value='2026-09';
 a.responses.push({ok:true,status:200,blob:async()=>({size:30})});await a.context.xmlcSolicitar('baixar');
 assert.equal(JSON.parse(a.calls.find(x=>x.url).options.body).acao,'baixar');assert.match(a.el('xmlc-pacote-msg').textContent,/ZIP gerado/);
});

