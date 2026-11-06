import {BASE} from './core.mjs';
import campos from './calculo-campos.json' with {type:'json'};
import {revisaoDoCadastro,TOTAIS_NFE55} from '../../sistema/fiscal-nfe55-modelo.js';
const str=v=>String(v??'');
const numero=v=>/^\d+(\.\d{1,10})?$/.test(str(v))&&Number.isFinite(Number(v));
const pick=(o,keys)=>Object.fromEntries(keys.filter(k=>o?.[k]!==undefined&&o[k]!==null&&o[k]!=='').map(k=>[k,o[k]]));
const LISTAS={icms:['/lists/icms'],pis:['/lists/pis'],cofins:['/lists/cofins','/lists/confins'],ipi:['/lists/ipi'],ncm:['/lists/ncm'],cfop:['/lists/cfop'],cest:['/lists/cest']};
export async function consultarLista({tipo,busca='',token,fetcher=fetch}){
 if(!Object.hasOwn(LISTAS,tipo))throw Error('Dados Já: lista fiscal não suportada.');
 let raw,rota;
 for(const path of LISTAS[tipo]){
  rota=path;const response=await fetcher(BASE+path,{method:'GET',headers:{Authorization:'Bearer '+token,Accept:'application/json'},signal:AbortSignal.timeout(20000)});
  if(response.status===404&&path!==LISTAS[tipo].at(-1))continue;
  if(!response.ok)throw Error('Dados Já: consulta da lista '+tipo+' retornou HTTP '+response.status+'.');
  raw=await response.json();break;
 }
 const key={ncm:'NCM',cfop:'CFOP',cest:'CEST'}[tipo]||'fiscoDetails',rows=raw?.data?.[key];
 if(!Array.isArray(rows))throw Error('Dados Já: formato inesperado na lista '+tipo+'.');
 // GET com body é mostrado na collection, mas não é suportado pelo Fetch.
 // Não inventar paginação por query: retornar os metadados da página efetivamente recebida.
 const q=str(busca).trim().toLowerCase().slice(0,80);
 const keys=['codeCST','CRT','description','xmlFields','group','tpNFDesc','codeNCM','codeCFOP','codeCEST','idDest','tpNF','validadeIni','validadeFim'];
 const itens=rows.map(r=>pick(r,keys)).filter(r=>!q||JSON.stringify(r).toLowerCase().includes(q)).slice(0,50);
 return {tipo,rota,itens,pagina:raw.data.currentPage??null,total_paginas:raw.data.totalPages??null,parcial:true,aviso:'Consulta da página retornada pelo fornecedor. Ausência nesta página não significa código inválido. Campos XML das listas não comprovam o JSON de emissão.'};
}
export function montarCalculo(snapshot,entrada){
 const r=revisaoDoCadastro(snapshot,entrada);
 if(!/^[A-Z]{2}$/.test(snapshot.emitente?.uf||''))throw Error('Informe a UF do emitente antes de calcular.');
 if(!r.sem_acessorios)throw Error('Confirme a operação sem frete, seguro, desconto adicional ou outras despesas antes de calcular.');
 if(!snapshot.itens?.length||snapshot.itens.length>500)throw Error('Venda sem itens válidos para cálculo.');
 if(entrada?.itens&&entrada.itens.length!==snapshot.itens.length)throw Error('Conferência dos itens divergente.');
 const simples=['1','4'].includes(str(snapshot.emitente?.crt));
 const det=snapshot.itens.map((item,i)=>{
  const f=r.itens[i],p=item.produto||{};
  if(str(f.id)!==str(item.id))throw Error('Conferência dos itens divergente.');
  if(p.tipo_fiscal==='servico')throw Error('Venda contém serviços. Cálculo deste fluxo é de mercadorias.');
  if(!/^\d{8}$/.test(str(f.ncm)))throw Error('Informe NCM válido no item '+(i+1)+'.');
  if(!numero(item.quantidade)||!numero(item.preco_unitario)||!numero(item.subtotal))throw Error('Item com valores inválidos.');
  if(simples)throw Error('Dados Já: falta confirmar a representação do CSOSN no cálculo para o item '+(i+1)+'. A lista não comprova o enum JSON.');
  if(!str(f.imposto?.ICMS?.CST))throw Error('Informe CST ICMS no item '+(i+1)+'.');
  // O único enum ICMS com valor de exemplo confirmado é cst90. Não criar cstXX/csosnXXX.
  if(f.imposto.ICMS.CST!=='cst90')throw Error('Dados Já: enum de cálculo ICMS '+f.imposto.ICMS.CST+' ainda precisa de confirmação.');
  const imposto={};
  for(const [group,allowed] of Object.entries(campos)){
   const original={...f.imposto?.[group],...f.calculo?.[group]};if(Object.keys(original).length)imposto[group]=pick(original,allowed);
  }
  for(const [group,values] of Object.entries(imposto)){
   const expected=f.imposto?.[group];if(values.CST!==undefined&&values.CST!==expected?.CST)throw Error('Conferência de CST do cálculo diverge do item '+(i+1)+'.');
   if(values.orig!==undefined&&values.orig!==expected?.orig)throw Error('Conferência da origem do cálculo diverge do item '+(i+1)+'.');
   if(values.CST!==undefined&&group!=='ICMS'&&!/^\d{2}$/.test(str(values.CST)))throw Error('Informe CST válido em '+group+'.');
  }
  if(p.aliquota_icms!==undefined&&p.aliquota_icms!==null&&imposto.ICMS?.pICMS===undefined)imposto.ICMS.pICMS=str(p.aliquota_icms);
  for(const [group,values] of Object.entries(imposto))for(const [key,value] of Object.entries(values)){
   if(key==='CST')continue;
   if(typeof value==='boolean'){if(!/^(excluir|Incluir)/.test(key))throw Error('Informe valor numérico válido em '+group+'.'+key+'.');continue;}
   if(key.startsWith('tipoCalculo')){if(!['percentual','valor'].includes(value))throw Error('Informe modalidade de cálculo válida em '+group+'.');continue;}
   if(!numero(value))throw Error('Informe valor numérico válido em '+group+'.'+key+'.');
  }
  return {nItem:str(i+1),prod:{indTot:'1',produtoServico:'produto',NCM:f.ncm,qCom:str(item.quantidade),vUnCom:str(item.preco_unitario),vProd:str(item.subtotal),vFrete:'0.00',vSeg:'0.00',vDesc:'0.00',vOutro:'0.00'},imposto};
 });
 return {UFEmitente:snapshot.emitente.uf,finNFe:'1',det};
}
export function aplicarCalculo(snapshot,entrada,body){
 const r=revisaoDoCadastro(snapshot,entrada),data=body?.data;
 if(!Array.isArray(data?.det)||data.det.length!==snapshot.itens.length)throw Error('Dados Já: quantidade de itens no cálculo divergente.');
 if(data.UFEmitente!==snapshot.emitente.uf||str(data.finNFe)!=='1')throw Error('Dados Já: identidade da operação de cálculo divergente.');
 const seen=new Set();
 for(const line of data.det){
  const index=Number(line.nItem)-1,item=snapshot.itens[index];
  if(!Number.isInteger(index)||!item||seen.has(index))throw Error('Dados Já: identidade dos itens de cálculo divergente.');seen.add(index);
  for(const [key,valor] of Object.entries({qCom:item.quantidade,vUnCom:item.preco_unitario,vProd:item.subtotal}))if(!numero(line.prod?.[key])||Math.abs(Number(line.prod[key])-Number(valor))>.000001)throw Error('Dados Já: cálculo alterou valores da venda.');
  const f=r.itens[index];
  for(const group of ['ICMS','PIS','COFINS','IPI']){const esperado=f.imposto?.[group];if(esperado&&str(line.imposto?.[group]?.CST)!==str(esperado.CST))throw Error('Dados Já: CST retornado diverge da conferência em '+group+'.');}
  if(str(line.imposto?.ICMS?.orig)!==str(f.imposto.ICMS.orig))throw Error('Dados Já: origem retornada diverge da conferência.');
  for(const k of ['vFrete','vSeg','vDesc','vOutro'])if(line.prod?.[k]!==undefined&&(!numero(line.prod[k])||Number(line.prod[k])!==0))throw Error('Dados Já: cálculo alterou despesas da venda.');
  // Aplicar somente propriedades confirmadas no exemplo de emissão NF-e.
  for(const key of ['vBCSTRet','pST','vICMSSubstituto','vICMSSTRet'])if(numero(line.imposto?.ICMS?.[key]))f.imposto.ICMS[key]=str(line.imposto.ICMS[key]);
  if(numero(line.prod?.vTotTrib))f.imposto.vTotTrib=str(line.prod.vTotTrib);
 }
 const totais=data.total?.ICMSTot;
 if(!numero(totais?.vProd)||Math.abs(Number(totais.vProd)-snapshot.itens.reduce((s,i)=>s+Number(i.subtotal),0))>.011)throw Error('Dados Já: total de produtos do cálculo diverge da venda.');
 if(!totais||!numero(totais.vNF)||Math.abs(Number(totais.vNF)-Number(snapshot.venda.total))>.011)throw Error('Dados Já: total calculado diverge da venda.');
 for(const k of TOTAIS_NFE55)if(numero(totais[k]))r.totais[k]=str(totais[k]);
 // Valores não cobertos pelo exemplo de emissão não podem desaparecer ao adaptar o cálculo.
 for(const line of data.det)for(const [group,values] of Object.entries(line.imposto||{})){
  const permitidos={ICMS:['orig','CST','vBCSTRet','pST','vICMSSubstituto','vICMSSTRet'],PIS:['CST'],COFINS:['CST'],IPI:['CST','cEnq','cSelo']}[group]||[];
  for(const [k,v] of Object.entries(values)){if(v!==null&&/^(v|p|q|adRem)/.test(k)&&!numero(v))throw Error('Dados Já: valor calculado inválido em '+group+'.'+k+'.');if(!permitidos.includes(k)&&numero(v)&&Number(v)!==0)throw Error('Dados Já: campo calculado '+group+'.'+k+' não tem contrato de emissão confirmado.');}
 }
 for(const [k,v] of Object.entries(totais))if(!TOTAIS_NFE55.includes(k)&&!['vProd','vNF','vTotTrib'].includes(k)&&numero(v)&&Number(v)!==0)throw Error('Dados Já: total '+k+' não tem contrato de emissão confirmado.');
 return {revisao:r,resumo:{valor_produtos:totais.vProd,valor_nota:totais.vNF},aviso:'Cálculo conferido contra os valores da venda. A validação do contrato de emissão continua independente.'};
}

export async function assinaturaConferencia(snapshot){
 const ordenar=x=>Array.isArray(x)?x.map(ordenar):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,ordenar(x[k])])):x;
 const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(JSON.stringify(ordenar(snapshot))));
 return [...new Uint8Array(digest)].map(n=>n.toString(16).padStart(2,'0')).join('');
}
