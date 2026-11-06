// Dados de conferência compartilhados. Não escolhe enquadramento ou alíquota.
export const TOTAIS_NFE55=['vBC','vICMS','vICMSDeson','vFCP','vBCST','vFCPST','vFCPSTRet','vFrete','vSeg','vDesc','vII','vIPI','vIPIDevol','vPIS','vCOFINS','vOutro'];
const text=v=>String(v??'');
export function destinoDoCliente(c={}){
 const cpf=text(c.cpf).replace(/\D/g,'');
 return {CNPJCPF:cpf,xNome:c.nome||'',indIEDest:cpf.length===11?'9':'',ie:'',enderDest:{xLgr:c.logradouro||'',nro:c.numero||'',xBairro:c.bairro||'',cMun:c.codigo_ibge||'',xMun:c.cidade||'',UF:c.uf||'',CEP:c.cep||''}};
}
export function revisaoDoCadastro(snapshot,entrada={}){
 const simples=['1','4'].includes(text(snapshot.emitente?.crt));
 const pagamentos=snapshot.pagamentos?.length?snapshot.pagamentos:[{forma_pagamento:snapshot.venda?.forma_pagamento,valor:snapshot.venda?.total}];
 const meios={dinheiro:'01',pix:'17',boleto:'15',transferencia:'18','transferência':'18',cheque:'02'};
 return {
  dest:entrada.dest||destinoDoCliente(snapshot.venda?.cliente||{}),
  ide:{natOp:'',indFinal:'',indPres:'',...entrada.ide},modFrete:entrada.modFrete||'',infCpl:entrada.infCpl||'',sem_acessorios:entrada.sem_acessorios===true,
  totais:{...entrada.totais},pagamentos:entrada.pagamentos||pagamentos.map(p=>({tPag:meios[text(p.forma_pagamento).trim().toLowerCase()]||'',vPag:text(p.valor)})),
  itens:(snapshot.itens||[]).map((item,i)=>{
   const p=item.produto||{},f=entrada.itens?.[i]||{},base={ICMS:{orig:text(p.origem_mercadoria),...(!simples?{CST:text(p.cst_csosn)==='90'?'cst90':text(p.cst_csosn)}:{})},PIS:{CST:text(p.cst_pis)},COFINS:{CST:text(p.cst_cofins)}};
   return {id:item.id,csosn:simples?text(p.cst_csosn):'',ncm:p.ncm||'',cfop:p.cfop||'',cest:p.cest||'',unidade:p.unidade_comercial||'',gtin:p.gtin||'',...f,imposto:{...base,...f.imposto,ICMS:{...base.ICMS,...f.imposto?.ICMS},PIS:{...base.PIS,...f.imposto?.PIS},COFINS:{...base.COFINS,...f.imposto?.COFINS}}};
  }),
 };
}
export function pendenciasContrato(snapshot,r){
 const pendencias=[],crt=text(snapshot.emitente?.crt);
 if(!/^[1-4]$/.test(crt))pendencias.push('CRT do emitente ausente ou inválido.');
 for(const [i,f] of (r.itens||[]).entries()){
  const prefix=`Item ${i+1}: `;
  if(!(['2','3'].includes(crt)&&f.imposto?.ICMS?.CST==='cst90'))pendencias.push(prefix+`falta confirmar o JSON de ICMS CST/CSOSN ${f.csosn||f.imposto?.ICMS?.CST||'não cadastrado'} para CRT ${crt||'não cadastrado'} no POST /v1/nfe.`);
  for(const g of ['PIS','COFINS'])if(f.imposto?.[g]?.CST!=='07')pendencias.push(prefix+`${g} CST ${f.imposto?.[g]?.CST||'não cadastrado'} ainda não tem contrato de emissão confirmado.`);
  if(f.imposto?.IPI&&f.imposto.IPI.CST!=='53')pendencias.push(prefix+'IPI deste CST ainda não tem contrato de emissão confirmado.');
 }
 if(r.dest?.indIEDest==='1')pendencias.push('Destinatário contribuinte: falta confirmar o campo de IE no JSON de emissão da NF-e.');
 return pendencias;
}
