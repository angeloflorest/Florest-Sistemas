import {revisaoDoCadastro,pendenciasContrato} from '../../sistema/fiscal-nfe55-modelo.js';
import {consultarLista,montarCalculo,aplicarCalculo,assinaturaConferencia} from './automacao.mjs';
import {BASE,preparar,executar,chamarDadosJah} from './core.mjs';
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS'};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store'}});
const check=(r:any,message:string)=>{if(r.error)throw Error(message);return r.data;};
export function criarHandler({createClient,env,fetcher=fetch}:any){return async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return json({erro:'Método não permitido.'},405);
 let fase='validacao';
 try {
  if(Number(req.headers.get('content-length')||0)>300000)return json({erro:'Requisição muito grande.'},413);
  const auth=req.headers.get('Authorization');if(!auth?.startsWith('Bearer '))return json({erro:'Sessão necessária.'},401);
  const url=env('SUPABASE_URL')!,anon=env('SUPABASE_ANON_KEY')!,key=env('SUPABASE_SERVICE_ROLE_KEY')!;
  if(!url||!anon||!key)throw Error('Configuração interna do servidor incompleta.');
  const user=createClient(url,anon,{global:{headers:{Authorization:auth}},auth:{persistSession:false}});
  const {data:session,error}=await user.auth.getUser();if(error||!session.user)return json({erro:'Sessão inválida.'},401);
  const text=await req.text();if(text.length>300000)return json({erro:'Requisição muito grande.'},413);
  const input=JSON.parse(text),{acao,venda_id}=input;
  if(!['preparar','emitir','consultar','xml','danfe','clientes','lista','calcular','validar','retransmitir'].includes(acao)||!/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/.test(venda_id||''))return json({erro:'Ação ou venda inválida.'},400);
  const snapshot=check(await user.rpc('fiscal_nfe55_contexto',{p_venda_id:venda_id}),'Não foi possível validar a venda e a permissão fiscal.');
  const empresa=snapshot.venda.empresa_id;
  const admin=createClient(url,key,{auth:{persistSession:false}});
  const respTec={CNPJ:env('RESPTEC_CNPJ'),xContato:env('RESPTEC_CONTATO'),email:env('RESPTEC_EMAIL'),fone:env('RESPTEC_FONE')};
  let registro=check(await admin.from('fiscal_nfe55_emissoes').select('*').eq('empresa_id',empresa).eq('venda_id',venda_id).maybeSingle(),'Não foi possível consultar a tentativa NF-e.');
  // Credenciais e payload de transmissão nunca saem do servidor; snapshot já contém somente dados autorizados da conferência.
  const resumo=(r:any)=>r?Object.fromEntries(['id','numero','serie','tp_amb','status','c_stat','mensagem','chave_acesso','protocolo','id_dfe'].map(k=>[k,r[k]])):null;
  if(acao==='clientes'){
   const dados=check(await user.rpc('fiscal_nfe55_clientes_pesquisar',{p_busca:String(input.busca||'').slice(0,80)}),'Não foi possível pesquisar destinatários.');
   if(dados?.empresa_id!==empresa||!Array.isArray(dados.clientes)||dados.clientes.some((c:any)=>c.empresa_id!==empresa))throw Error('Destinatário de outra empresa não será carregado.');return json(dados);
  }
  const conferencia_hash=await assinaturaConferencia(snapshot);
  let revisao=revisaoDoCadastro(snapshot,input.revisao||{});
  if(acao==='preparar')return json({snapshot,revisao,conferencia_hash,pendencias:pendenciasContrato(snapshot,revisao),registro:resumo(registro)});
  if(acao==='validar'){
   const pendencias=pendenciasContrato(snapshot,revisao);try{preparar(snapshot,revisao,respTec);}catch(e){const msg=e instanceof Error?e.message:'Validação não concluída.';if(!pendencias.length)pendencias.push(msg);}
   return json({valida:pendencias.length===0,pendencias});
  }
  if(acao==='lista'&&!['icms','pis','cofins','ipi','ncm','cfop','cest'].includes(input.tipo))return json({erro:'Lista fiscal inválida.',fase},400);
  let infNF,calculoRequest;
  if(acao==='calcular')calculoRequest=montarCalculo(snapshot,revisao);
  if(acao==='retransmitir') {
   if(input.confirmar_producao!==true)return json({erro:'Confirme o reenvio em produção.',fase},400);
   if(env('NFE55_PRODUCAO_HABILITADA')!=='true')return json({erro:'Produção NF-e não liberada.',fase},409);
   if(!registro||registro.status!=='rejeitada'||!/^\d{3}$/.test(String(registro.c_stat||''))||registro.chave_acesso||registro.protocolo)return json({erro:'Somente NF-e expressamente rejeitada e sem autorização pode ser retransmitida.',fase},409);
   if(input.conferencia_hash!==conferencia_hash)return json({erro:'Conferência mudou. Recarregue a venda.',fase},409);
   revisao=revisaoDoCadastro(snapshot,{...registro.revisao,dest:{...registro.revisao?.dest,ie:String(input.ie||'').replace(/\D/g,'')}});
   if(!/^\d{2,14}$/.test(String(revisao.dest.ie||'')))return json({erro:'Informe a inscrição estadual do destinatário.',fase},400);
   infNF=preparar(snapshot,revisao,respTec);
  }
  if(acao==='emitir') {
   if(input.confirmar_producao!==true)return json({erro:'Confirmação explícita de emissão em produção necessária.',fase},400);
   if(env('NFE55_PRODUCAO_HABILITADA')!=='true')return json({erro:'Produção NF-e não liberada. Ativação requer autorização do responsável.',fase},409);
   if(registro)return json({erro:'Já existe tentativa para esta venda. Consulte a situação sem retransmitir.',registro:resumo(registro)},409);
   if(input.conferencia_hash!==conferencia_hash)return json({erro:'Conferência mudou. Recarregue a venda e confirme os dados e a série novamente.',fase},409);
   infNF=preparar(snapshot,revisao,respTec);
  } else if(['consultar','xml','danfe'].includes(acao)&&!registro)return json({erro:'Nenhuma tentativa NF-e encontrada.'},404);
  const cred=check(await admin.rpc('fiscal_nfe55_credencial',{p_empresa_id:empresa}),'Credencial Dados Já indisponível.');
  let token=cred.token;
  if(!token){
   const r=await fetcher(BASE+'/auth/user/login',{method:'POST',headers:{'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify({email:cred.email,password:cred.password}),signal:AbortSignal.timeout(20000)});
   if(!r.ok)throw Error('Dados Já recusou a autenticação. Verifique a credencial fiscal existente.');
   token=(await r.json())?.data?.accessToken;if(!token)throw Error('Dados Já não forneceu token de acesso.');
  }
  if(acao==='lista')return json(await consultarLista({tipo:input.tipo,busca:input.busca,token,fetcher}));
  if(calculoRequest){
   const retorno=await chamarDadosJah(fetcher,token,'/tribute-calculation/out',{method:'POST',body:calculoRequest});
   const calculado=aplicarCalculo(snapshot,revisao,retorno);revisao=calculado.revisao;
   if(acao==='calcular')return json({...calculado,pendencias:pendenciasContrato(snapshot,revisao)});
   infNF=preparar(snapshot,revisao,respTec);
  }
  if(acao==='retransmitir'){
   fase='consulta';const atual=await chamarDadosJah(fetcher,token,'/nfe?idExternal='+encodeURIComponent(registro.id)+'&tpDanfe=Retrato');
   const situacao= (await import('./core.mjs')).resultado(atual,registro);
   if(situacao.status!=='rejeitada'||String(situacao.c_stat)!==String(registro.c_stat))return json({erro:'Situação no Dados Já mudou ou não confirma rejeição. Consulte a NF-e antes de retransmitir.',fase},409);
   const novoPayload=(await import('./core.mjs')).payload(infNF,registro);
   fase='reserva';const claimed=check(await admin.from('fiscal_nfe55_emissoes').update({revisao,payload:novoPayload,status:'processando',c_stat:null,mensagem:'Retransmissão em andamento',atualizado_em:new Date().toISOString()}).eq('id',registro.id).eq('empresa_id',empresa).eq('status','rejeitada').eq('c_stat',registro.c_stat).select('*'),'Não foi possível reservar a retransmissão.');
   if(claimed.length!==1)return json({erro:'Outra operação atualizou a nota. Consulte a situação.',fase},409);
   registro=claimed[0];fase='transmissao';
   try{const raw=await chamarDadosJah(fetcher,token,'/nfe?tpDanfe=Retrato',{method:'POST',body:novoPayload});const state=(await import('./core.mjs')).resultado(raw,registro);await admin.from('fiscal_nfe55_emissoes').update({...state,atualizado_em:new Date().toISOString()}).eq('id',registro.id).eq('status','processando');return json({registro:resumo({...registro,...state})});}
   catch{await admin.from('fiscal_nfe55_emissoes').update({status:'pendente',mensagem:'Resposta da retransmissão não confirmada. Consulte antes de qualquer novo envio.'}).eq('id',registro.id).eq('status','processando');return json({registro:resumo({...registro,status:'pendente',mensagem:'Resposta não confirmada. Consulte situação.'})});}
  }
  if(acao==='emitir'){fase='reserva';registro=check(await user.rpc('fiscal_nfe55_reservar',{p_venda_id:venda_id,p_snapshot:snapshot,p_revisao:revisao}),'Reserva não efetuada. Recarregue a venda, confira documentos anteriores e a sequência da série NF-e configurada.');fase='transmissao';}
  const salvar=async(patch:any,claim=false)=>{
   let q=admin.from('fiscal_nfe55_emissoes').update({...patch,atualizado_em:new Date().toISOString()}).eq('id',registro.id).eq('empresa_id',empresa);
   if(claim)q=q.eq('status','reservada').is('payload',null);
   else if(registro.status!=='autorizada')q=q.neq('status','autorizada');
   const rows=check(await q.select('id'),'Não foi possível persistir a situação fiscal.');
   if(!rows?.length)throw Error('Tentativa já processada ou atualizada por outra consulta. Consulte a situação.');
  };
  if(['xml','danfe'].includes(acao)) {
   if(registro.status!=='autorizada'||!registro.chave_acesso||!registro.protocolo)return json({erro:'Documento ainda não autorizado.'},409);
   const raw=await chamarDadosJah(fetcher,token,'/nfe/'+acao+'?chDfe='+encodeURIComponent(registro.chave_acesso)+'&tpAmb=1'+(acao==='danfe'?'&tpDanfe=Retrato':''));
   const rows=raw?.data?.NFe;
   if(rows?.length!==1)throw Error('Arquivo sem resultado único.');
   const n=rows[0];if(n.chDfe!==registro.chave_acesso||String(n.tpAmb)!=='1'||Number(n.serie)!==Number(registro.serie)||Number(n.nNF)!==Number(registro.numero))throw Error('Arquivo com identidade fiscal divergente.');
   const conteudo=acao==='xml'?n.xml:n.pdf,link=acao==='xml'?n.xmlLink:n.pdfLink;
   if(!conteudo&&!link)throw Error('Arquivo ainda indisponível no Dados Já. Consulte novamente.');
   return json({tipo:acao,conteudo:conteudo||null,link:link||null,numero:registro.numero});
  }
  const result=await executar({acao,registro,infNF,token,fetcher,salvar});return json({registro:resumo(result)});
 }catch(e){
  // Não retornar mensagens do SDK, payload, resposta bruta ou credenciais.
  const message=e instanceof Error?e.message:'';
  const safe=/^(Informe |Valor numérico|CNPJ |CPF\/CNPJ|Certificado |Confirme |CRT|Emitente |Destinatário |Indicador |Destinatário contribuinte|CPF deve|O exemplo oficial|Enquadramento |A collection|IPI |Origem|NCM|CFOP|CEST|Enquadramento IPI|Item |Subtotal |Total |Pagamento|Conferência |Venda |Ordem |Este fluxo|O enquadramento|Modalidade |Dados Já(?::| )|Credencial |Reserva |Tentativa |Não foi possível|Arquivo |Documento )/.test(message);
  return json({fase,erro:safe?message:'Falha técnica. Consulte a situação da NF-e antes de tentar emitir novamente.'},400);
 }
};}
