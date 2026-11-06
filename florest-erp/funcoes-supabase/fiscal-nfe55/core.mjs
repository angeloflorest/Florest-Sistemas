import {revisaoDoCadastro,pendenciasContrato,CST_CONTRIBUICAO_NT} from '../../sistema/fiscal-nfe55-modelo.js';
// Contrato NF-e da collection oficial Dados Já, consultada em 06/11/2026.
export const BASE = 'https://api-dfe.dadosjah.com.br/v1';
const fail = message => { throw Error(message); };
const str = v => String(v ?? '').trim();
const digits = v => str(v).replace(/\D/g, '');
const required = (v, label) => str(v) || fail('Informe '+label+'.');
const pattern = (v, re, label) => re.test(str(v)) ? str(v) : fail(label+' inválido ou ausente.');
export function money(v) { return Number(decimal(v)).toFixed(2); }
function decimal(v) { const value=pattern(v,/^\d+(\.\d{1,10})?$/,'Valor numérico');if(!Number.isFinite(Number(value)))fail('Valor numérico fora do limite.');return value; }
function equal(a,b,label) { if (Math.abs(Number(a)-Number(b))>0.011) fail(label+' diverge da venda cadastrada.'); }
export function documentoValido(value) {
 const d=digits(value);if(!/^(\d{11}|\d{14})$/.test(d)||/^(\d)\1+$/.test(d))return false;
 const dv=(base,weights)=>{const n=base.split('').reduce((s,c,i)=>s+Number(c)*weights[i],0)%11;return n<2?0:11-n;};
 if(d.length===11)return Number(d[9])===dv(d.slice(0,9),[10,9,8,7,6,5,4,3,2])&&Number(d[10])===dv(d.slice(0,10),[11,10,9,8,7,6,5,4,3,2]);
 return Number(d[12])===dv(d.slice(0,12),[5,4,3,2,9,8,7,6,5,4,3,2])&&Number(d[13])===dv(d.slice(0,13),[6,5,4,3,2,9,8,7,6,5,4,3,2]);
}
function endereco(x,label) {
 const out={};for(const k of ['xLgr','nro','xBairro','xMun'])out[k]=required(x?.[k],label+' '+k);
 out.cMun=pattern(x?.cMun,/^\d{7}$/ ,label+' município IBGE');out.UF=pattern(str(x?.UF).toUpperCase(),/^(AC|AL|AP|AM|BA|CE|DF|ES|GO|MA|MT|MS|MG|PA|PB|PR|PE|PI|RJ|RN|RS|RO|RR|SC|SP|SE|TO)$/ ,label+' UF');
 const codigos={AC:'12',AL:'27',AP:'16',AM:'13',BA:'29',CE:'23',DF:'53',ES:'32',GO:'52',MA:'21',MT:'51',MS:'50',MG:'31',PA:'15',PB:'25',PR:'41',PE:'26',PI:'22',RJ:'33',RN:'24',RS:'43',RO:'11',RR:'14',SC:'42',SP:'35',SE:'28',TO:'17'};
 if(out.cMun.slice(0,2)!==codigos[out.UF])fail(label+' município IBGE não corresponde à UF.');
 out.CEP=pattern(digits(x?.CEP),/^\d{8}$/,label+' CEP');out.cPais='1058';out.xPais='BRASIL';
 if(str(x?.fone))out.fone=pattern(digits(x.fone),/^\d{6,14}$/,label+' telefone');return out;
}
export function emitente(config) {
 const c=config||{};
 if(!documentoValido(c.cnpj))fail('CNPJ do emitente inválido.');
 if(c.regime_tributario==='simples_nacional'&&!['1','2'].includes(str(c.crt)))fail('CRT não corresponde ao regime Simples Nacional cadastrado. Confira o cadastro fiscal, sem trocar o regime para contornar validações.');
 if(c.regime_tributario==='mei'&&str(c.crt)!=='4')fail('CRT do MEI precisa ser conferido no cadastro fiscal antes da NF-e.');
 if(!c.emitente_registrado)fail('Confirme o registro do emitente no Dados Já.');
 if(!c.certificado_validade||new Date(c.certificado_validade+'T23:59:59-03:00').getTime()<Date.now())fail('Certificado ausente ou vencido.');
 return {CNPJCPF:digits(c.cnpj),xNome:required(c.razao_social,'razão social'),...(c.nome_fantasia?{xFant:c.nome_fantasia}:{}),IE:required(c.inscricao_estadual,'IE do emitente'),CRT:pattern(c.crt,/^[1-4]$/,'CRT'),enderEmit:endereco({xLgr:c.endereco,nro:c.numero,xBairro:c.bairro,xMun:c.municipio,cMun:c.codigo_ibge,UF:c.uf,CEP:c.cep,fone:c.telefone},'Emitente')};
}
// Adaptadores de emissão por formato confirmado; o CRT vem da empresa, nunca é substituído.
function imposto(x,crt) {
 const sn102=crt==='1'&&str(x?.ICMS?.CSOSN)==='102';
 if(!sn102&&(!['2','3'].includes(crt)||x?.ICMS?.CST!=='cst90'))fail('Dados Já: formato de ICMS deste item/CRT não suportado neste fluxo.');
 const out={...(x.vTotTrib!==undefined&&x.vTotTrib!==''?{vTotTrib:money(x.vTotTrib)}:{}),ICMS:{orig:pattern(x.ICMS.orig,/^[0-8]$/,'Origem'),...(sn102?{CSOSN:'102'}:{CST:'cst90'})}};
 if(sn102){
  for(const [k,v] of Object.entries(x.ICMS))if(!['orig','CSOSN','CST'].includes(k)&&v!==''&&v!=null&&Number(v)!==0)fail('Item com CSOSN 102 não pode ter destaque ou crédito de ICMS informado.');
 }else for(const k of ['vBCSTRet','pST','vICMSSubstituto','vICMSSTRet'])if(x.ICMS[k]!==undefined&&x.ICMS[k]!=='')out.ICMS[k]=k==='pST'?decimal(x.ICMS[k]):money(x.ICMS[k]);
 for(const group of ['PIS','COFINS']){
  const g=x[group]||{},cst=str(g.CST);
  if(!cst)fail('Informe CST de '+group+' do produto conforme orientação do contador.');
  if(!CST_CONTRIBUICAO_NT.includes(cst)&&!(sn102&&['49','99'].includes(cst)&&g.sem_destaque===true))fail('Item: '+group+' CST '+cst+' sem os dados fiscais exigidos para esta operação.');
  for(const [k,v] of Object.entries(g))if(!['CST','sem_destaque'].includes(k)&&v!==''&&v!=null&&Number(v)!==0)fail('Item: valor de '+group+' não corresponde ao enquadramento sem destaque confirmado.');
  out[group]={CST:cst};
 }
 if(x.IPI){if(x.IPI.CST!=='53')fail('IPI diferente do CST 53 não suportado neste fluxo.');out.IPI={CST:'53',cEnq:pattern(x.IPI.cEnq,/^\d{3}$/,'Enquadramento IPI')};if(str(x.IPI.cSelo))out.IPI.cSelo=str(x.IPI.cSelo);}
 return out;
}
export function preparar(snapshot,revisao,respTec) {
 const s=snapshot;
 if(revisao?.itens&&revisao.itens.length!==s.itens?.length)fail('Conferência não corresponde aos itens da venda.');
 const r=revisaoDoCadastro(snapshot,revisao||{});
 const pendencias=pendenciasContrato(snapshot,r);
 if(pendencias.length)fail('Dados Já: '+pendencias.join(' ').slice(0,1600));
 if(s.venda.cancelada_em)fail('Venda cancelada.');
 if(!s.itens?.length||s.itens.length>500)fail('Venda sem itens ou acima do limite de 500.');
 const emit=emitente(s.emitente);
 pattern(s.emitente.nfe_serie,/^[1-9]\d{0,2}$/,'Série NF-e');
 if(!s.emitente.nfe_numeracao_confirmada_em)fail('Confirme a numeração NF-e nas Configurações antes de emitir.');
 if(!documentoValido(r.dest?.CNPJCPF))fail('CPF/CNPJ do destinatário inválido.');
 const dest={CNPJCPF:digits(r.dest.CNPJCPF),xNome:required(r.dest.xNome,'nome do destinatário'),enderDest:endereco(r.dest.enderDest,'Destinatário'),indIEDest:pattern(r.dest.indIEDest,/^[129]$/,'Indicador IE')};
 // A collection não exemplifica a IE do destinatário contribuinte: não omitir nem adivinhar.
 if(dest.indIEDest==='1')fail('Destinatário contribuinte: falta confirmar com Dados Já o campo de IE no contrato NF-e.');
 if(dest.CNPJCPF.length===11&&dest.indIEDest!=='9')fail('CPF deve usar indicador IE 9.');
 const ide={natOp:required(r.ide?.natOp,'natureza da operação'),tpNF:'1',idDest:emit.enderEmit.UF===dest.enderDest.UF?'1':'2',cMunFG:emit.enderEmit.cMun,tpImp:'1',tpEmis:'1',tpAmb:'1',finNFe:'1',indFinal:pattern(r.ide?.indFinal,/^[01]$/,'Consumidor final'),indPres:pattern(r.ide?.indPres,/^[0123459]$/,'Presença'),procEmi:'0',verProc:'Florest-NFe55-1.0',cUF:emit.enderEmit.cMun.slice(0,2)};
 if(r.ide?.tpAmb && r.ide.tpAmb!=='1')fail('Este fluxo é exclusivo de produção.');
 if(!Array.isArray(r.itens)||r.itens.length!==s.itens.length)fail('Conferência não corresponde aos itens da venda.');
 const det=s.itens.map((item,i)=>{
  const p=item.produto, f=r.itens[i];
  if(p?.tipo_fiscal==='servico')fail('Venda contém serviços. O fluxo mínimo aceita somente mercadorias.');
  if(String(f.id)!==String(item.id))fail('Ordem ou identidade de item divergente.');
  if(!(Number(item.quantidade)>0)||!(Number(item.preco_unitario)>0))fail('Item sem quantidade/preço positivo.');
  equal(Number(item.quantidade)*Number(item.preco_unitario),item.subtotal,'Subtotal do item');
  if(f.gtin!=='SEM GTIN'&&!/^(\d{8}|\d{12,14})$/.test(str(f.gtin)))fail('GTIN inválido.');
  const prod={cProd:required(p.codigo||p.id,'código do produto'),xProd:required(p.nome,'produto'),cEAN:required(f.gtin,'GTIN ou SEM GTIN confirmado'),cEANTrib:required(f.gtin,'GTIN'),NCM:pattern(f.ncm,/^\d{8}$/,'NCM'),CFOP:pattern(f.cfop,ide.idDest==='1'?/^5\d{3}$/:/^6\d{3}$/,'CFOP compatível com destino'),uCom:required(f.unidade,'unidade'),qCom:decimal(item.quantidade),vUnCom:decimal(item.preco_unitario),vProd:money(item.subtotal),uTrib:required(f.unidade,'unidade'),qTrib:decimal(item.quantidade),vUnTrib:decimal(item.preco_unitario),indTot:'1'};
  if(str(f.cest))prod.CEST=pattern(f.cest,/^\d{7}$/,'CEST');
  return {nItem:String(i+1),prod,imposto:imposto(f.imposto,emit.CRT)};
 });
 const soma=det.reduce((v,d)=>v+Number(d.prod.vProd),0);equal(soma,s.venda.total,'Total dos itens');
 // Descontos/acréscimos não discriminados no schema da venda não são redistribuídos silenciosamente.
 // Totais do cenário sem destaque vêm do enquadramento explicitamente informado,
 // não de uma chamada separada ao cálculo. Campos tributários obrigatórios já foram validados.
 const total={};
 const todosSimples102=emit.CRT==='1'&&det.every(d=>d.imposto.ICMS.CSOSN==='102');
 const acessorios=['vFrete','vSeg','vDesc','vOutro'];
 for(const k of ['vBC','vICMS','vICMSDeson','vFCP','vBCST','vFCPST','vFCPSTRet','vFrete','vSeg','vDesc','vII','vIPI','vIPIDevol','vPIS','vCOFINS','vOutro']){
  const v=r.totais?.[k];
  if((v===undefined||v==='')&&!todosSimples102)fail('Informe total '+k+' desta operação. O sistema não presume tributação zero para ICMS CST 90.');
  if(acessorios.includes(k)&&(v===undefined||v==='')&&r.sem_acessorios!==true)fail('Confirme que a NF-e mantém os valores da venda sem frete, seguro, desconto adicional ou outras despesas.');
  if(v!==undefined&&v!==''&&Number(money(v))!==0)fail('Total '+k+' não corresponde aos itens sem destaque desta operação.');
  total[k]='0.00';
 }
 total.vProd=money(soma);total.vNF=money(s.venda.total);
 const pagamentos=r.pagamentos;
 if(!Array.isArray(pagamentos)||!pagamentos.length||pagamentos.length>20)fail('Informe os pagamentos conferidos da venda.');
 const detPag=pagamentos.map(p=>({tPag:pattern(p.tPag,/^(01|02|05|10|11|12|13|15|16|17|18|19|90|99)$/,'Pagamento (cartões exigem contrato adicional)'),...(p.tPag==='99'?{xPag:required(p.xPag,'descrição do pagamento')}:{}),vPag:money(p.vPag)}));
 equal(detPag.reduce((v,p)=>v+Number(p.vPag),0),s.venda.total,'Pagamento');
 const transp={modFrete:pattern(r.modFrete,/^9$/,'Modalidade sem transporte (outros fretes exigem cadastro próprio)')};
 const infRespTec={CNPJ:digits(required(respTec?.CNPJ,'CNPJ do responsável técnico')),xContato:required(respTec?.xContato,'contato técnico'),email:pattern(respTec?.email,/^[^\s@]+@[^\s@]+\.[^\s@]+$/,'e-mail técnico'),fone:pattern(digits(respTec?.fone),/^\d{10,14}$/,'telefone técnico')};
 if(!documentoValido(infRespTec.CNPJ))fail('CNPJ do responsável técnico inválido.');
 return {versao:'4.00',ide,emit,dest,det,total:{ICMSTot:total},transp,pag:{detPag},infRespTec,...(str(r.infCpl)?{infAdic:{infCpl:str(r.infCpl)}}:{})};
}
export function payload(infNF,registro) {
 const inf=structuredClone(infNF);Object.assign(inf.ide,{serie:pattern(registro.serie,/^[1-9]\d{0,2}$/,'Série NF-e'),nNF:String(registro.numero),cNF:registro.c_nf,dhEmi:registro.dh_emissao});
 // O modelo é definido pela rota /nfe; o exemplo NF-e oficial não possui ide.mod.
 return {async:false,NFe:[{idExternal:registro.id,infNF:inf}]};
}
function chaveValida(key) {
 if(!/^\d{44}$/.test(key))return false;let sum=0,w=2;for(let i=42;i>=0;i--){sum+=Number(key[i])*w;w=w===9?2:w+1;}const d=11-sum%11;return Number(key[43])===(d>=10?0:d);
}
export function resultado(body,registro) {
 const rows=body?.data?.NFe;
 if(!Array.isArray(rows)||rows.length!==1)return {status:'pendente',mensagem:'Resposta sem resultado único; consulte sem retransmitir.'};
 const n=rows[0],key=str(n.chDfe),num=String(registro.numero),cnpj=registro.payload?.NFe?.[0]?.infNF?.emit?.CNPJCPF;
 const identity=str(n.idExternal)===registro.id&&str(n.nNF)===num&&Number(n.serie)===Number(registro.serie)&&str(n.tpAmb)==='1';
 if(!identity)return {status:'pendente',mensagem:'Identidade fiscal divergente; emissão bloqueada para conciliação.'};
 const common={c_stat:str(n.cStat),mensagem:str(n.xMotivo).slice(0,2000),id_dfe:str(n.idDfe)||null};
 if(['100','150'].includes(str(n.cStat))) {
  if(!chaveValida(key)||key.slice(20,22)!=='55'||key.slice(6,20)!==cnpj||Number(key.slice(22,25))!==Number(registro.serie)||Number(key.slice(25,34))!==Number(num)||!/^\d{15}$/.test(str(n.nProt)))return {...common,status:'pendente',mensagem:'Autorização sem chave/protocolo correspondentes; consulte.'};
  return {...common,status:'autorizada',chave_acesso:key,protocolo:str(n.nProt)};
 }
 // Somente a rejeição explícita da SEFAZ é terminal. HTTP/timeout/cStat desconhecido não libera nova emissão.
 if(/rejeitad[ao]/i.test(str(n.situationDfe))&&/^\d{3}$/.test(str(n.cStat))&&!['103','104','105','106','108','109','110','204','205','301','302','539'].includes(str(n.cStat)))return {...common,status:'rejeitada'};
 return {...common,status:'pendente'};
}
/** @param {{method?: string, body?: any}} options */
export async function chamarDadosJah(fetcher,token,rota,options={}) {
 const {method='GET',body}=options;
 const response=await fetcher(BASE+rota,{method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Accept:'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(25000)});
 if(!response.ok)throw Error('Dados Já retornou HTTP '+response.status+'. Consulte antes de qualquer nova tentativa.');
 return response.json();
}
export async function executar({acao,registro,infNF,token,fetcher=fetch,salvar}) {
 if(acao==='emitir') {
  // Claim persistido antes do POST: nenhum outro clique/processo pode transmitir este registro.
  const p=payload(infNF,registro);await salvar({payload:p,status:'processando'},true);
  registro={...registro,payload:p};
  try {const raw=await chamarDadosJah(fetcher,token,'/nfe?tpDanfe=Retrato',{method:'POST',body:p});const state=resultado(raw,registro);await salvar(state);return {...registro,...state};}
  catch {const state={status:'pendente',mensagem:'Comunicação ou persistência não confirmada. Use Consultar situação; não retransmita.'};await salvar(state);return {...registro,...state};}
 }
 const raw=await chamarDadosJah(fetcher,token,'/nfe?idExternal='+encodeURIComponent(registro.id)+'&tpDanfe=Retrato');const state=resultado(raw,registro);
 // A autorização já persistida nunca é rebaixada por consulta incompleta.
 if(registro.status==='autorizada'&&state.status!=='autorizada')return registro;
 await salvar(state);return {...registro,...state};
}
