import {fixture} from './nfe55-fixture.mjs';
import {montarCalculo,assinaturaConferencia} from '../../funcoes-supabase/fiscal-nfe55/automacao.mjs';
import {criarHandler} from '../../funcoes-supabase/fiscal-nfe55/handler.ts';
const assert=(x:unknown,msg='Falha na asserção')=>{if(!x)throw Error(msg);};
const id='00000000-0000-4000-8000-000000000001';
function ambiente({ativo=false,registro=null,sessao=true,permitido=true,base=null,respostas=null,clientes=null}:any={}){
 const calls:any[]=[],writes:any[]=[],provider:any[]=[];
 let atual=registro;
 const snapshot=base||{venda:{id,empresa_id:'empresa-a',total:20},emitente:{},itens:[]};
 const user={auth:{getUser:async()=>({data:{user:sessao?{id:'user-a'}:null},error:sessao?null:Error('expired')})},rpc:async(name:string,args:any)=>{calls.push({name,args});if(name==='fiscal_nfe55_contexto')return permitido?{data:snapshot}:{error:{code:'42501'}};if(name==='fiscal_nfe55_clientes_pesquisar')return {data:clientes||{empresa_id:snapshot.venda.empresa_id,clientes:[]}};if(name==='fiscal_nfe55_reservar'){atual={id:'tentativa',numero:1,serie:snapshot.emitente.nfe_serie,c_nf:'12345678',dh_emissao:'2026-11-06T12:00:00-03:00',status:'reservada'};return {data:atual};}throw Error('RPC não esperada');}};
 const admin={rpc:async(name:string,args:any)=>{calls.push({name,args});return {data:{token:'fake'}};},from:(table:string)=>{
  const filters:any[]=[];let patch:any;const q:any={select(){return q;},update(p:any){patch=p;return q;},eq(k:string,v:any){filters.push([k,v]);return q;},neq(){return q;},is(){return q;},maybeSingle:async()=>{calls.push({table,filters});return {data:atual};},then(resolve:any){writes.push({table,filters,patch});if(atual)Object.assign(atual,patch);return Promise.resolve({data:[{id:'emissao'}]}).then(resolve);}};return q;
 }};
 const env=(name:string)=>({SUPABASE_URL:'https://supabase.invalid',SUPABASE_ANON_KEY:'anon-fake',SUPABASE_SERVICE_ROLE_KEY:'service-fake',RESPTEC_CNPJ:'11222333000181',RESPTEC_CONTATO:'Teste',RESPTEC_EMAIL:'teste@example.com',RESPTEC_FONE:'3133333333',NFE55_PRODUCAO_HABILITADA:ativo?'true':'false'} as any)[name];
 const handler=criarHandler({createClient:(_url:string,key:string)=>key==='anon-fake'?user:admin,env,fetcher:async(url:string,opts:any)=>{provider.push({url,method:opts.method,body:opts.body});if(respostas)return respostas(url,opts);return new Response(JSON.stringify({data:{NFe:[]}}));}});
 const request=async(acao:string,extra:any={},auth=true)=>{const response=await handler(new Request('https://edge.invalid',{method:'POST',headers:{...(auth?{Authorization:'Bearer fake'}:{}),'Content-Type':'application/json'},body:JSON.stringify({acao,venda_id:id,conferencia_hash:await assinaturaConferencia(snapshot),...extra})}));return {status:response.status,data:await response.json()};};
 return {request,calls,writes,provider};
}
Deno.test('handler: sem sessão ou permissão fiscal não acessa credencial e não transmite',async()=>{
 for(const params of [{sessao:false},{permitido:false}]){const a=ambiente(params);const r=await a.request('emitir',{confirmar_producao:true});assert(r.status>=400);assert(!a.calls.some(c=>c.name==='fiscal_nfe55_credencial'));assert(a.provider.length===0);}
});
Deno.test('handler: preparar filtra tentativa pela empresa validada e não modifica dados',async()=>{
 const a=ambiente(),r=await a.request('preparar');assert(r.status===200);assert(r.data.snapshot.venda.empresa_id==='empresa-a');assert(a.calls.some(c=>c.filters?.some(([k,v]:any)=>k==='empresa_id'&&v==='empresa-a')));assert(a.writes.length===0&&a.provider.length===0);
});
Deno.test('handler: liberação de produção e conferência válidas são exigidas antes de reservar número',async()=>{
 for(const ativo of [false,true]){const a=ambiente({ativo}),r=await a.request('emitir',{confirmar_producao:true,revisao:{}});assert(r.status>=400);assert(!a.calls.some(c=>c.name==='fiscal_nfe55_reservar'));assert(a.provider.length===0);}
});
Deno.test('handler: tentativa anterior não pode retransmitir e arquivos exigem autorização',async()=>{
 const a=ambiente({ativo:true,registro:{id:'tentativa',status:'pendente'}});
 assert((await a.request('emitir',{confirmar_producao:true})).status===409);
 assert((await a.request('xml')).status===409);assert(a.provider.length===0);
});
Deno.test('handler: consulta usa GET /nfe e idExternal; resposta inconclusiva fica pendente',async()=>{
 const a=ambiente({registro:{id:'tentativa',numero:1,status:'pendente'}}),r=await a.request('consultar');assert(r.status===200);assert(r.data.registro.status==='pendente');assert(a.provider.length===1&&a.provider[0].method==='GET');assert(a.provider[0].url.includes('/v1/nfe?idExternal=tentativa'));assert(a.writes.every(w=>w.filters.some(([k,v]:any)=>k==='empresa_id'&&v==='empresa-a')));
});

Deno.test('handler: destinatários são somente da empresa da venda; resposta divergente é bloqueada',async()=>{
 const good=ambiente({clientes:{empresa_id:'empresa-a',clientes:[{id:'c1',empresa_id:'empresa-a',nome:'Cliente',cpf:'52998224725'}]}});
 const r=await good.request('clientes',{busca:'Cliente'});assert(r.status===200);assert(r.data.clientes[0].cpf==='52998224725');assert(good.provider.length===0&&good.writes.length===0);
 for(const clientes of [{empresa_id:'empresa-b',clientes:[]},{empresa_id:'empresa-a',clientes:[{empresa_id:'empresa-b'}]}])assert((await ambiente({clientes}).request('clientes',{busca:'Cliente'})).status===400);
});
Deno.test('handler: consulta de lista usa credencial da empresa, sem emissão ou gravação',async()=>{
 const a=ambiente({respostas:async()=>new Response(JSON.stringify({data:{fiscoDetails:[{codeCST:'90',CRT:[2,3],description:'Outros'}],currentPage:1,totalPages:1}}))});
 const r=await a.request('lista',{tipo:'icms',empresa_id:'empresa-b'});assert(r.status===200);assert(r.data.itens.length===1);assert(a.provider[0].method==='GET');assert(a.provider[0].url.endsWith('/lists/icms'));assert(a.calls.find(c=>c.name==='fiscal_nfe55_credencial').args.p_empresa_id==='empresa-a');assert(a.writes.length===0);
});
Deno.test('handler: cálculo é separado da emissão; CPF é preservado e só reserva após validar o cálculo',async()=>{
 const f:any=fixture();f.snapshot.venda.id=id;f.snapshot.venda.empresa_id='empresa-a';f.revisao.sem_acessorios=true;
 const a=ambiente({ativo:true,base:f.snapshot,respostas:async(url:string,opts:any)=>{
  if(url.includes('/tribute-calculation/out')){const q=JSON.parse(opts.body);return new Response(JSON.stringify({data:{...q,det:q.det.map((d:any)=>({...d,imposto:{...d.imposto,ICMS:{...d.imposto.ICMS,vBC:'0',vICMS:'0',vBCSTRet:'0',pST:'0',vICMSSTRet:'0'}}})),total:{ICMSTot:{...f.revisao.totais,vNF:'20',vProd:'20'}}}}));}
  return new Response(JSON.stringify({data:{NFe:[]}}));
 }});
 const preview=await a.request('calcular',{revisao:f.revisao});assert(preview.status===200);assert(a.provider.length===1);assert(a.writes.length===0);assert(!a.calls.some(c=>c.name==='fiscal_nfe55_reservar'));
 const send=await a.request('emitir',{revisao:preview.data.revisao,usar_calculo:true,confirmar_producao:true});assert(send.status===200);assert(a.provider.filter(c=>c.url.endsWith('/nfe?tpDanfe=Retrato')).length===1);assert(a.provider.filter(c=>c.url.endsWith('/tribute-calculation/out')).length===2);
 const sent=JSON.parse(a.provider.at(-1).body);assert(sent.NFe[0].infNF.dest.CNPJCPF==='52998224725');assert(sent.NFe[0].infNF.ide.serie==='1');assert(a.writes.every(w=>w.table==='fiscal_nfe55_emissoes'));
 assert((await a.request('emitir',{revisao:f.revisao,confirmar_producao:true})).status===409);
});
Deno.test('handler: CSOSN sem contrato bloqueia só essa operação antes de autenticar, calcular ou reservar',async()=>{
 const f:any=fixture();f.snapshot.venda.id=id;f.snapshot.venda.empresa_id='empresa-a';f.snapshot.emitente.crt='1';f.revisao.itens[0].csosn='102';f.revisao.sem_acessorios=true;
 const a=ambiente({ativo:true,base:f.snapshot});
 const check=await a.request('validar',{revisao:f.revisao});assert(check.status===200&&!check.data.valida);assert(check.data.pendencias[0].includes('Item 1'));
 assert((await a.request('calcular',{revisao:f.revisao})).status===400);assert((await a.request('emitir',{revisao:f.revisao,confirmar_producao:true})).status===400);assert(a.provider.length===0);assert(!a.calls.some(c=>c.name==='fiscal_nfe55_reservar'));
});

Deno.test('handler: alteração de venda/cadastro/série desde a conferência impede emissão antes de reservar',async()=>{
 const f:any=fixture();f.snapshot.venda.id=id;f.snapshot.venda.empresa_id='empresa-a';const a=ambiente({ativo:true,base:f.snapshot});
 const r=await a.request('emitir',{revisao:f.revisao,confirmar_producao:true,conferencia_hash:'conferencia-antiga'});
 assert(r.status===409);assert(r.data.fase==='validacao');assert(a.provider.length===0&&!a.calls.some(c=>c.name==='fiscal_nfe55_reservar'));
});
